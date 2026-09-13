//
//  SecretsManager.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 25/10/17.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//

import Foundation

// Checks whose outcome is only known once the action finished resolving. PowerTaskList logs a
// play's secret TRIGGER and DEATHS task lists after the play's BLOCK_END, so they are resolved at the
// next action boundary instead of by sleeping on the log reader thread (HDT awaits game time):
// the next root PLAY or ATTACK block, a STEP change, or the reset at game end.
private struct SpellCastSnapshot {
    let spellEntityId: Int
    let secretIds: Set<Int>
    let turn: Int
    // "When cast" preconditions, which only the board at cast time decides
    let opponentHadMinions: Bool
    let freeSpaceInHandAtCast: Bool
    let freeSpaceOnBoardAtCast: Bool
    // nil when neither the PLAY block nor CARD_TARGET named a target at cast time
    let targetIsMinion: Bool?
}

// A card that was the third or later one played this turn
private struct CardPlaySnapshot {
    let cardEntityId: Int
    let secretIds: Set<Int>
    let turn: Int
    let freeSpaceOnBoardAtPlay: Bool
    let freeSpaceInHandAtPlay: Bool
}

// A minion played from hand. HDT keeps one list of saved exclusions and re-includes it on every
// secret; this keeps, per secret, only the candidates the play itself ruled out, so taking them
// back cannot re-list a candidate another event excluded.
private final class MinionPlaySnapshot {
    let minionId: Int
    let secretIds: Set<Int>
    let turn: Int
    // The cards in the opponent's hand at the play, for Hidden Cache
    let opponentHandIds: Set<Int>
    // Secret entity id -> candidates this play ruled out. Guarded by SecretsManager.pendingLock.
    var saved = [Int: [MultiIdCard]]()

    init(minionId: Int, secretIds: Set<Int>, turn: Int, opponentHandIds: Set<Int> = []) {
        self.minionId = minionId
        self.secretIds = secretIds
        self.turn = turn
        self.opponentHandIds = opponentHandIds
    }

    func save(_ transitions: [(secretId: Int, card: MultiIdCard)]) {
        for transition in transitions {
            saved[transition.secretId, default: []].append(transition.card)
        }
    }
}

// The player's turn as it stood when it ended (STEP=MAIN_END), before any end-of-turn effect ran.
// The end-of-turn secrets react to it, and only the secrets already in play then could.
private struct PlayerTurnEnd {
    let secretIds: Set<Int>
    let turn: Int
    // Player minions Flames of Infinity could hit; cleared once the opponent's turn checked them
    var minionIds: Set<Int>
}

// One candidate of one secret's pool. Impossible candidates stay in the list as count 0 rows.
private struct SecretCandidate {
    let card: MultiIdCard
    let possible: Bool
}

// The board and hand the after-play secrets may have seen, from the end of the play to the boundary
private struct AfterPlayWindow {
    let fullestBoard: Int
    let fullestHand: Int

    var freeSpaceOnBoard: Bool { return fullestBoard < 7 }
    var freeSpaceInHand: Bool { return fullestHand < 10 }
}

private enum PendingSecretCheck {
    case spellCast(SpellCastSnapshot)
    case threeCards(CardPlaySnapshot)
    case minionPlayed(MinionPlaySnapshot)
    case reckoning(dealerId: Int, secretIds: Set<Int>, turn: Int)
}

class SecretsManager {
    // Avenge is checked once the death phase is over; the deathrattle summons that follow it
    // must not count as survivors
    private var _avengeDeathRattleCount = 0
    private var _avengePending: (secretIds: Set<Int>, turn: Int)?
    private var pendingChecks = [PendingSecretCheck]()
    // Secrets that triggered or left play since the last boundary, for the pending checks
    private var triggeredSinceBoundary = [Entity]()
    private let pendingLock = UnfairLock()
    private var _lastStartOfTurnCheck = 0
    private var _lastStartOfTurnDamageCheck = 0
    private var _lastStartOfTurnMinionCheck = 0
    // Guarded by pendingLock: the MAIN_END snapshot is read by the turn start, which Game runs off
    // the log reader thread
    private var playerTurnEnd: PlayerTurnEnd?
    // Damage context of the current block, for hits that only armor absorbed. PREDAMAGE is back to
    // 0 by the time ARMOR changes, so the ids are kept until the next block starts.
    private var predamagedEntityIds = Set<Int>()
    private var armorLostThisBlock = [Int: Int]()
    // Guarded by pendingLock: the fullest opponent board and hand seen at the end of a root block
    // since the last boundary
    private var fullestSinceBoundary: (board: Int, hand: Int)?
    // Guarded by pendingLock: the minion plays whose after-play secrets had their chance (resolved
    // with the minion in play, or not resolved yet), for Hidden Cache once a card that was in the
    // opponent's hand then turns out to be a minion
    private var minionPlaysSeeingHand = [MinionPlaySnapshot]()
    
    private var game: Game
    private let _availableSecrets: AvailableSecretsProvider
    private let _relatedCardsManager: RelatedCardsManager
    private(set) var secrets = SynchronizedArray<Secret>()
    private var _triggeredSecrets = SynchronizedArray<Entity>()
    private var opponentTookDamageDuringTurns = SynchronizedArray<Int>()
    private var entityDamageDealtHistory = SynchronizedDictionary<Int, SynchronizedDictionary<Int, Int>>()
    
    private var _lastPlayedMinionId: Int = 0
    // The latest minion play, pending or resolved, until the next card is played or the player's
    // next turn starts (HDT clears its saved secrets at the same points)
    private var lastMinionPlay: MinionPlaySnapshot?
    
    var onChanged: (([Card]) -> Void)?
    // The two secret helper settings, read through closures so tests can set them without writing
    // the app's defaults (the hosted test bundle shares them with the user's HSTracker)
    var autoGrayoutSecrets: () -> Bool = { Settings.autoGrayoutSecrets }
    var removeSecretsFromList: () -> Bool = { Settings.removeSecretsFromList }
    // Fired on the parser thread for every candidate that becomes impossible or possible again
    var onExclusionChanged: ((SecretExclusionEvent) -> Void)?
    private var nextEntryOrder = 0
    
    init(game: Game, availableSecrets: AvailableSecretsProvider, relatedCardsManager: RelatedCardsManager) {
        self.game = game
        self._availableSecrets = availableSecrets
        self._relatedCardsManager = relatedCardsManager
    }
    
    private var freeSpaceOnBoard: Bool { return game.opponentBoardCount < 7 }
    private var freeSpaceInHand: Bool { return game.opponentHandCount < 10 }
    // HDT SecretsEventHandler.HandleAction: with Gray out secrets off, no event rules anything out
    private var handleAction: Bool { return hasActiveSecrets && autoGrayoutSecrets() }
    
    private var hasActiveSecrets: Bool {
        return secrets.count > 0
    }
    
    // Excludes the candidates on every active secret, or only on the secrets in `secretIds` (the ones
    // that were active when the event happened), and records why for the hover text and the history.
    func exclude(cardIds: [MultiIdCard], reason: SecretExclusionReason, secretIds: Set<Int>? = nil) {
        applyExclusions(cardIds.map { ($0, reason) }, secretIds: secretIds, turn: nil, invokeCallback: true)
    }

    func exclude(cardId: MultiIdCard, reason: SecretExclusionReason, secretIds: Set<Int>? = nil, invokeCallback: Bool = true) {
        applyExclusions([(cardId, reason)], secretIds: secretIds, turn: nil, invokeCallback: invokeCallback)
    }

    // HDT's signatures, kept for callers that have no reason to record
    func exclude(cardId: MultiIdCard, invokeCallback: Bool = true) {
        applyExclusions([(cardId, nil)], secretIds: nil, turn: nil, invokeCallback: invokeCallback)
    }

    func exclude(cardIds: [MultiIdCard]) {
        applyExclusions(cardIds.map { ($0, nil) }, secretIds: nil, turn: nil, invokeCallback: true)
    }

    // Returns the candidates that became impossible, per secret
    @discardableResult
    private func applyExclusions(_ entries: [(card: MultiIdCard, reason: SecretExclusionReason?)], secretIds: Set<Int>?, turn: Int?,
                                 invokeCallback: Bool) -> [(secretId: Int, card: MultiIdCard)] {
        // Also covers checks queued before Gray out secrets was turned off. A revealed copy is not a
        // deduction but a game rule (HDT's NewSecret and RemoveSecret exclude it either way), and a
        // reason-less exclusion is a manual toggle. What was recorded before is filtered when the
        // list is built (possibleCandidates).
        let entries = autoGrayoutSecrets() ? entries : entries.filter { !SecretExclusionReason.isAutomatic($0.reason) }
        guard !entries.isEmpty else { return [] }
        let turn = turn ?? game.turnNumber()
        var events = [SecretExclusionEvent]()
        var transitions = [(secretId: Int, card: MultiIdCard)]()
        for secret in secrets.array() {
            if let secretIds, !secretIds.contains(secret.entity.id) {
                continue
            }
            var changed = false
            for entry in entries where secret.exclude(cardId: entry.card, reason: entry.reason, turn: turn) {
                changed = true
                transitions.append((secret.entity.id, entry.card))
                events.append(SecretExclusionEvent(secretEntityId: secret.entity.id, cardId: entry.card.ids[0],
                                                   exclusion: SecretExclusion(reason: entry.reason, turn: turn), included: false))
            }
            // Every candidate gone means a wrong rule or a secret we do not know yet. Keep showing
            // the dimmed rows rather than guessing.
            if changed && !secret.excluded.values.contains(false) {
                logger.warning("all candidates excluded for secret \(secret.entity.id)")
            }
        }
        events.forEach { onExclusionChanged?($0) }
        if invokeCallback && !events.isEmpty {
            onChanged?(getSecretList())
        }
        return transitions
    }

    private func include(cardIds: [MultiIdCard], on targets: [Secret]) {
        var events = [SecretExclusionEvent]()
        for secret in targets {
            for card in cardIds {
                if let exclusion = secret.include(cardId: card) {
                    events.append(SecretExclusionEvent(secretEntityId: secret.entity.id, cardId: card.ids[0],
                                                       exclusion: exclusion, included: true))
                }
            }
        }
        events.forEach { onExclusionChanged?($0) }
    }

    // Whether each candidate of the secret is still possible, as the panel shows it. Gray out
    // secrets decides this when the list is built, so turning it off mid-game lists the candidates
    // ruled out so far as possible again, and turning it back on dims them again.
    private func possibleCandidates(_ secret: Secret) -> [MultiIdCard: Bool] {
        let state = secret.state
        guard !autoGrayoutSecrets() else { return state.excluded.mapValues { !$0 } }
        var possible = [MultiIdCard: Bool]()
        for (card, isExcluded) in state.excluded {
            possible[card] = !isExcluded || SecretExclusionReason.isAutomatic(state.exclusions[card]?.reason)
        }
        return possible
    }

    private func isVisiblyExcluded(_ secret: Secret, _ card: MultiIdCard) -> Bool {
        return secret.isExcluded(cardId: card) && (autoGrayoutSecrets() || !SecretExclusionReason.isAutomatic(secret.exclusion(for: card)?.reason))
    }

    private var activeSecretIds: Set<Int> {
        return Set(secrets.array().map { $0.entity.id })
    }

    func refresh() {
        onChanged?(getSecretList())
    }

    // The hover text for a dimmed row, e.g. "Turn 5: You attacked the enemy hero". A row is dimmed
    // once no active secret allows the card, and different secrets may have ruled it out for
    // different reasons, so this lists each distinct reason once, newest first, at most three.
    func exclusionSummary(cardId: String) -> String? {
        guard let card = CardIds.Secrets.getSecretMultiIdCard(cardId) else { return nil }
        var seen = Set<String>()
        let format = String.localizedString("SecretHelper_RuledOutFormat", comment: "")
        let grayout = autoGrayoutSecrets()
        var lines = secrets.array()
            .compactMap { $0.exclusion(for: card) }
            // With Gray out secrets off, the deductions recorded so far do not dim the row
            .filter { grayout || !SecretExclusionReason.isAutomatic($0.reason) }
            .sorted { $0.turn > $1.turn }
            .compactMap { exclusion -> String? in
                guard let reason = exclusion.reason, seen.insert("\(exclusion.turn):\(reason.rawValue)").inserted else { return nil }
                return String(format: format, exclusion.turn, String.localizedString(reason.localizationKey, comment: ""))
            }
            .take(3)
        if gameModeHasCardLimit(game.currentGameType) && hasPlayedBothCopies(card) {
            lines.append(String.localizedString("SecretReason_BothCopiesPlayed", comment: ""))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func gameModeHasCardLimit(_ gameMode: GameType) -> Bool {
        return switch gameMode {
        case .gt_casual, .gt_ranked, .gt_vs_friend, .gt_vs_ai:
            true
        default:
            false
        }
    }

    // Revealed secrets from the opponent's starting deck; ids above 68 were created during the game
    private func hasPlayedBothCopies(_ card: MultiIdCard) -> Bool {
        return game.opponent.revealedEntities.filter {
            $0.id < 68 && $0.isSecret && $0.hasCardId && card == $0.cardId && !$0.info.created
        }.count >= 2
    }

    func reset() {
        pendingLock.around {
            _avengeDeathRattleCount = 0
            _avengePending = nil
            pendingChecks.removeAll()
            triggeredSinceBoundary.removeAll()
            lastMinionPlay = nil
            playerTurnEnd = nil
            predamagedEntityIds.removeAll()
            armorLostThisBlock.removeAll()
            fullestSinceBoundary = nil
            minionPlaysSeeingHand.removeAll()
        }
        _lastPlayedMinionId = 0
        entityDamageDealtHistory.removeAll()
        _lastStartOfTurnCheck = 0
        _lastStartOfTurnDamageCheck = 0
        _lastStartOfTurnMinionCheck = 0
        opponentTookDamageDuringTurns.removeAll()
        secrets.removeAll()
        _triggeredSecrets.removeAll()
        nextEntryOrder = 0
    }
    
    @discardableResult
    func newSecret(entity: Entity) -> Bool {
        if !entity.isSecret || !entity.has(tag: .class) {
            return false
        }
        
        if entity.hasCardId {
            if let secretMultiIdCard = CardIds.Secrets.getSecretMultiIdCard(entity.cardId) {
                exclude(cardId: secretMultiIdCard, reason: .copyRevealed, invokeCallback: false)
            }
        }
        do {
            let secret = try Secret(entity: entity, entryOrder: nextEntryOrder)
            nextEntryOrder += 1
            secrets.append(secret)
            logger.info("new secret : \(entity)")
            onChanged?(getSecretList())
            return true
        } catch {
            logger.error("\(error)")
            return false
        }
    }
    
    @discardableResult
    func removeSecret(entity: Entity) -> Bool {
        guard let secret = secrets.first(where: { $0.entity.id == entity.id }) else {
            logger.info("Secret not found \(entity)")
            return false
        }
        
        handleFastCombat(entity: entity)
        // A secret destroyed or stolen after a spell may be the Counterspell that countered it
        recordTriggered(entity)
        secrets.remove(secret)
        if secret.entity.hasCardId {
            if let secretMultiIdCard = CardIds.Secrets.getSecretMultiIdCard(secret.entity.cardId) {
                exclude(cardId: secretMultiIdCard, reason: .copyRevealed, invokeCallback: false)
                // A revealed copy keeps the card excluded on the others, whatever happens to the play
                forgetSaved(card: secretMultiIdCard)
            }
        }
        onChanged?(getSecretList())
        return true
    }
    
    func toggle(cardId: String) {
        // MultiIdCard equality compares every id, so look up the full card for multi-print secrets
        let mcid = CardIds.Secrets.getSecretMultiIdCard(cardId) ?? MultiIdCard(cardId)
        // What the panel shows: with Gray out secrets off, an automatic exclusion lists the card as
        // possible, and a click has to replace it with a manual one to dim the row
        let excluded = secrets.any { isVisiblyExcluded($0, mcid) }
        include(cardIds: [mcid], on: secrets.array())
        if !excluded {
            exclude(cardId: mcid, invokeCallback: false)
        }
    }
    
    func getAvailableSecrets(gameMode: GameType, format: FormatType) -> Set<String> {
        if let byType = _availableSecrets.byType {
            if let gameModeSecrets = byType["\(gameMode)".uppercased()] {
                return gameModeSecrets
            }
            if let formatSecrets = byType["\(format)".uppercased()] {
                return formatSecrets
            }
        }
        // Fallback in case query isn't available
        // The format test alone lets arena-only secrets (Hand of Salvation, whose Legacy print
        // counts as Wild) into constructed pools, and keeps secrets arena bans, so apply the
        // arena lists here. The remote pools already account for both.
        let isArena = gameMode == .gt_arena || gameMode == .gt_underground_arena
        let excludedByMode = isArena ? CardIds.Secrets.arenaExcludes : CardIds.Secrets.arenaOnly
        let candidates = CardIds.Secrets.All.filter { x in !excludedByMode.contains(x) }
        return switch format {
        case .ft_standard:
            Set<String>(candidates.filter { x in x.isStandard }.map { x in x.ids[0] })
        default:
            Set<String>(candidates.filter { x in x.isWild }.map { x in x.ids[0] })
        }
    }
    
    func getCreatedBySecretsByCreator(gameMode: GameType, format: FormatType) -> [String: Set<String>]? {
        if gameMode != .gt_arena && gameMode != .gt_underground_arena {
            return nil
        }
        
        if let createdByTypeByCretor = _availableSecrets.createdByTypeByCreator, let res = createdByTypeByCretor["\(gameMode)"] {
            return res
        }
        return nil
    }

    // Every candidate in the pool of at least one active secret, with the number of secrets that
    // still allow it. HDT's GetSecretsFromDeck drops the impossible ones since fc4c39a635 (Oct 2025);
    // HSTracker keeps them as count 0 rows, which the panel darkens (HDT's behaviour before that),
    // unless Remove impossible secrets is on. concatCardList sums the created and the deck half, so a
    // row is only dimmed when neither half allows it.
    func getSecretList() -> [Card] {
        let gameMode = game.currentGameType
        let format = game.currentFormatType
        
        let deckSecrets = getSecretsFromDeck(gameMode, format)
        let createdSecretsList = getSecretsCreatedBy(gameMode, format)
        
        var cards = createdSecretsList.concatCardList(deckSecrets)
        if removeSecretsFromList() {
            cards = cards.filter { $0.count > 0 }
        }
        return SecretsManager.sortedForPanel(cards)
    }

    // Possible candidates first, then the impossible ones, each group in class-list order (HDT's
    // GroupBy order). The list is rebuilt from dictionaries, so without this the rows would move
    // around on every refresh.
    static func sortedForPanel(_ cards: [Card]) -> [Card] {
        return cards.sorted { a, b in
            let aPossible = a.count > 0, bPossible = b.count > 0
            if aPossible != bPossible {
                return aPossible
            }
            let aIndex = secretOrderIndex[a.id] ?? Int.max, bIndex = secretOrderIndex[b.id] ?? Int.max
            if aIndex != bIndex {
                return aIndex < bIndex
            }
            return a.id < b.id
        }
    }

    // Position of every print of every secret in CardIds.Secrets.All (Hunter, Mage, Paladin, Rogue)
    static let secretOrderIndex: [String: Int] = {
        var index = [String: Int]()
        for (position, card) in CardIds.Secrets.All.enumerated() {
            for id in card.ids where index[id] == nil {
                index[id] = position
            }
        }
        return index
    }()
    
    private func getSecretsFromDeck(_ gameMode: GameType, _ format: FormatType) -> [Card] {
        let gameModeHasCardLimit = gameModeHasCardLimit(gameMode)

        let createdSecrets = secrets
            .filter { $0.entity.info.created }
            .flatMap { self.possibleCandidates($0) }
            .filter { $0.value }
            .map { $0.key }
            .unique()
        
        let availableSecrets = getAvailableSecrets(gameMode: gameMode, format: format)
        
        let secretsFromDeck = secrets.filter { s in !s.entity.info.created }
        
        let filteredSecretsFromDeck = getFilteredSecretsByDrawer(secretsFromDeck, availableSecrets)
        
        let adjustCount: ((_ card: MultiIdCard, _ count: Int) -> Int) = { card, count in
            gameModeHasCardLimit && self.hasPlayedBothCopies(card) && !createdSecrets.contains(card) ? 0 : count
        }
        
        let cards = filteredSecretsFromDeck
            .group { m in m.card }
            .compactMap { group in
                if let multiIdCard = CardIds.Secrets.getSecretMultiIdCard(group.key.ids[0]) {
                    return QuantifiedMultiIdCard(baseCard: group.key, count: adjustCount(multiIdCard, group.value.filter { $0.possible }.count))
                } else {
                    return QuantifiedMultiIdCard(baseCard: group.key, count: 0)
                }
            }
                
        return SecretsManager.quantifiedCardsToCards(cards, format)
    }
    
    private func getSecretsCreatedBy(_ gameMode: GameType, _ format: FormatType) -> [Card] {
        let createdBySecrets = secrets.filter { $0.entity.info.created }
        
        var availableSecrets = getAvailableSecrets(gameMode: gameMode, format: format)
        
        if gameMode == .gt_arena || gameMode == .gt_underground_arena {
            return getArenaCreatedSecrets(createdBySecrets, availableSecrets, gameMode, format)
        }
        
        var secretsCreated = [SecretCandidate]()

        for secret in createdBySecrets {
            let creator = tryGetCreator(secret)
            let drawer = tryGetDrawer(secret)
            
            if let creator, creator.cardId == CardIds.Collectible.Mage.FacelessEnigma {
                let storedIds = creator.info.storedCardIds
                let controlledByPlayer = creator.isControlled(by: game.player.id)
                
                if storedIds.isEmpty {
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, availableSecrets))
                } else if controlledByPlayer {
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, Set<String>(storedIds)))
                } else {
                    availableSecrets.remove(storedIds.last ?? "")
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, availableSecrets))
                }
            } else if let creator, creator.cardId == CardIds.NonCollectible.Mage.TheForbiddenSequence_TheOriginStoneToken {
                // Which secret The Origin Stone cast is never public: the game hides the copy it
                // puts into play until it triggers. The most we may narrow to is the pool the
                // Discover it came from could offer.
                if let sourceGenerator = tryGetOriginStoneSourceGenerator(secret: secret) {
                    let creatableSecrets = getCreatableSecretsFromGenerator(sourceGenerator, gameMode, format)
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, creatableSecrets))
                } else {
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, availableSecrets))
                }
            } else if let creator, let generator = _relatedCardsManager.getCardGenerator(creator.cardId) {
                let creatableSecrets = getCreatableSecretsFromGenerator(generator, gameMode, format)
                
                if let drawer, let tutor = _relatedCardsManager.getSpellSchoolTutor(drawer.cardId) {
                    secretsCreated.append(contentsOf: getFilteredSecretsByDrawerFromSingleSecret(secret, tutor, creatableSecrets))
                } else {
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, creatableSecrets))
                }
            } else {
                if let drawer, let tutor = _relatedCardsManager.getSpellSchoolTutor(drawer.cardId) {
                    secretsCreated.append(contentsOf: getFilteredSecretsByDrawerFromSingleSecret(secret, tutor, availableSecrets))
                } else {
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, availableSecrets))
                }
            }
        }
        
        return quantifyAndConvertSecrets(secretsCreated, format)
    }
    
    private func getArenaCreatedSecrets(_ createdBySecrets: [Secret], _ availableSecrets: Set<String>, _ gameMode: GameType, _ format: FormatType) -> [Card] {
        var secretsCreated = [SecretCandidate]()
        if let availableCreatedBy = getCreatedBySecretsByCreator(gameMode: gameMode, format: format) {
            let creators = createdBySecrets.compactMap { s in (s, game.opponent.revealedEntities.first { e in e.id == s.entity.info.getCreatorId()})}
            for (secret, creator) in creators {
                let drawer = game.opponent.revealedEntities.first { e in e.id == secret.entity.info.getDrawerId() }
                
                if let drawer, let spellSchoolTutor = _relatedCardsManager.getSpellSchoolTutor(drawer.cardId) {
                    if let creator, let creatableSecrets = availableCreatedBy[creator.cardId] {
                        let secrets = getFilteredSecretsByDrawerFromSingleSecret(secret, spellSchoolTutor, creatableSecrets)
                        secretsCreated.append(contentsOf: secrets)
                    } else {
                        let secrets = getFilteredSecretsByDrawerFromSingleSecret(secret, spellSchoolTutor, availableSecrets)
                        secretsCreated.append(contentsOf: secrets)
                    }
                } else {
                    if let creator, let creatableSecrets = availableCreatedBy[creator.cardId] {
                        secretsCreated.append(contentsOf: getFilteredSecrets(secret, creatableSecrets))
                    } else {
                        secretsCreated.append(contentsOf: getFilteredSecrets(secret, availableSecrets))
                    }
                }
            }
            
            return quantifyAndConvertSecrets(secretsCreated, format)
        }
        
        return quantifyAndConvertSecrets(getFilteredSecretsByDrawer(createdBySecrets, availableSecrets), format)
    }
    
    private func getFilteredSecretsByDrawer(_ allSecrets: [Secret], _ availableSecrets: Set<String>) -> [SecretCandidate] {
        let secretAndDrawSource = allSecrets.compactMap { s in
            (s, game.opponent.revealedEntities.first { e in e.id == s.entity.info.getDrawerId() })
        }

        var filteredSecrets = [SecretCandidate]()
        for (secret, drawSource) in secretAndDrawSource {
            if let drawSource, let spellSchoolTutor = _relatedCardsManager.getSpellSchoolTutor(drawSource.cardId) {
                filteredSecrets.append(contentsOf: getFilteredSecretsByDrawerFromSingleSecret(secret, spellSchoolTutor, availableSecrets))
            } else {
                filteredSecrets.append(contentsOf: getFilteredSecrets(secret, availableSecrets))
            }
        }

        return filteredSecrets
    }

    // The pool is what a tutor could have drawn; whether a candidate is still possible is kept apart
    private func getFilteredSecretsByDrawerFromSingleSecret(_ secret: Secret, _ spellSchoolTutor: ISpellSchoolTutor, _ availableSecrets: Set<String>) -> [SecretCandidate] {
        let spellSchools = spellSchoolTutor.tutoredSpellSchools
        return possibleCandidates(secret)
            .filter { x in x.key.ids.any { availableSecrets.contains($0) }}
            .map { x in (card: Card(id: x.key.ids[0]), possible: x.value) }
            .filter { x in spellSchools.contains(x.card.spellSchool.rawValue) }
            .compactMap { x in CardIds.Secrets.getSecretMultiIdCard(x.card.id).map { SecretCandidate(card: $0, possible: x.possible) } }
    }
    
    private func tryGetCreator(_ secret: Secret) -> Entity? {
        if let opponentCreator = game.opponent.revealedEntities.first(where: { e in e.id == secret.entity.info.getCreatorId() }) {
            return opponentCreator
        }
        if let playerCreator = game.player.revealedEntities.first(where: { e in e.id == secret.entity.info.getCreatorId() }), playerCreator.cardId == CardIds.Collectible.Mage.FacelessEnigma {
            return playerCreator
        }
        return nil
    }
    
    private func tryGetDrawer(_ secret: Secret) -> Entity? {
        return game.opponent.revealedEntities.first { e in e.id == secret.entity.info.getDrawerId() }
    }

    private func tryGetOriginStoneSourceGenerator(secret: Secret) -> ICardGenerator? {
        // Which unchosen option The Origin Stone turned into the face-down secret is private,
        // but the Discover that offered them is not. Trace back to the card that offered them
        // and reuse its generation pool - that is as narrow as we may legitimately get.
        let discoverOption = tryGetOriginStoneDiscoverOption(secret: secret)
        let creatorId = discoverOption?[.creator]
        let discoverSource = game.opponent.revealedEntities
            .first(where: { $0.id == creatorId })

        if let generatorCardId = discoverSource?.cardId,
           let sourceGenerator = _relatedCardsManager.cardGeneratorCards[generatorCardId] {
            return sourceGenerator
        }

        return nil
    }

    // Finds an option of the Discover whose leftovers The Origin Stone cast, so its creator can
    // be read off. Any option will do - all of them share one creator.
    private func tryGetOriginStoneDiscoverOption(secret: Secret) -> Entity? {
        // The options are revealed when The Origin Stone casts them, secrets included, so they
        // are the reliable route back. The secret is created in the same block as the cast, so
        // the newest option below it belongs to the Discover that triggered it.
        if let option = game.opponent.revealedEntities
            .filter({ e in
                e.id < secret.entity.id &&
                e[.was_discover_option] == 1 &&
                e[.creator] > 0
            })
            .max(by: { $0.id < $1.id }) {
            return option
        }

        // Failing that, go through the copy The Origin Stone revealed just before casting it.
        // Only non-secret options are revealed that way, so this alone misses a Discover that
        // offered nothing but secrets.
        let revealedCast = game.opponent.revealedEntities
            .filter { e in
                e.id < secret.entity.id &&
                e[.copied_from_entity_id] > 0 &&
                e.isInZone(zone: .setaside)
            }
            .max(by: { $0.id < $1.id })

        let copiedFromId = revealedCast?[.copied_from_entity_id]
        return game.opponent.revealedEntities
            .first(where: { $0.id == copiedFromId })
    }

    private func getCreatableSecretsFromGenerator(_ generator: ICardGenerator, _ gameMode: GameType, _ format: FormatType) -> Set<String> {
        let allSecrets = CardIds.Secrets.Mage.All + CardIds.Secrets.Hunter.All + CardIds.Secrets.Paladin.All + CardIds.Secrets.Rogue.All
        
        return Set<String>(allSecrets
            .filter { s in generator.isInGeneratorPool(s, gameMode, format) }
            .flatMap { m in m.ids })
    }
    
    private func getFilteredSecrets(_ secret: Secret, _ allowedSecrets: Set<String>) -> [SecretCandidate] {
        return possibleCandidates(secret)
            .filter { x in x.key.ids.any { allowedSecrets.contains($0) }}
            .map { x in SecretCandidate(card: x.key, possible: x.value) }
    }
    
    // count is the number of secrets whose pool holds the card and that still allow it
    private func quantifyAndConvertSecrets(_ secrets: [SecretCandidate], _ format: FormatType) -> [Card] {
        let quantified = secrets
            .group { m in m.card }
            .compactMap { g in
                if CardIds.Secrets.getSecretMultiIdCard(g.key.ids[0]) != nil {
                    return QuantifiedMultiIdCard(baseCard: g.key, count: g.value.filter { $0.possible }.count)
                } else {
                    return QuantifiedMultiIdCard(baseCard: g.key, count: 0)
                }
            }
        return SecretsManager.quantifiedCardsToCards(quantified, format)
    }
    
    private static func quantifiedCardsToCards(_ quantified: [QuantifiedMultiIdCard], _ format: FormatType) -> [Card] {
        return quantified.compactMap { x in
            if let card = x.getCardForFormat(format: format) {
                card.count = x.count
                return card
            }
            return nil
        }
    }

    func handleAttack(attacker: Entity, defender: Entity, fastOnly: Bool = false) {
        guard handleAction else { return }
        // Secrets only trigger on the opponent's turn. A player minion forced to attack during the
        // opponent's own turn (their Hysteria) goes through here too and must not rule anything out.
        guard game.playerEntity?.isCurrentPlayer == true else { return }

        if attacker[.controller] == defender[.controller] {
            return
        }

        var exclude: [MultiIdCard] = []
        
        if freeSpaceOnBoard {
            exclude.append(CardIds.Secrets.Paladin.NobleSacrifice)
        }
        
        if !attacker.isHero {
            exclude.append(CardIds.Secrets.Paladin.JudgementofJustice)
            exclude.append(CardIds.Secrets.Mage.MysticMisdirection)
        }

        if defender.isHero {
            if !fastOnly && attacker.health >= 1 {
                if freeSpaceOnBoard {
                    exclude.append(CardIds.Secrets.Hunter.BearTrap)
                }

                if game.entities.values.first(where: { x in
                    x.isInPlay && (x.isHero || x.isMinion) && !x.has(tag: .immune) && x != attacker && x != defender
                    }) != nil {
                    exclude.append(CardIds.Secrets.Hunter.Misdirection)
                }

                if attacker.isMinion {
                    if game.playerMinionCount > 1 {
                        exclude.append(CardIds.Secrets.Rogue.SuddenBetrayal)
                    }

                    exclude.append(CardIds.Secrets.Mage.FlameWard)
                    exclude.append(CardIds.Secrets.Hunter.FreezingTrap)
                    exclude.append(CardIds.Secrets.Mage.Vaporize)
                    if freeSpaceOnBoard {
                        exclude.append(CardIds.Secrets.Rogue.ShadowClone)
                    }
                }
            }

            if freeSpaceOnBoard {
                exclude.append(CardIds.Secrets.Hunter.WanderingMonster)
                if attacker.isMinion {
                    exclude.append(CardIds.Secrets.Mage.VengefulVisage)
                }
            }

            exclude.append(CardIds.Secrets.Mage.IceBarrier)
            exclude.append(CardIds.Secrets.Hunter.ExplosiveTrap)
        } else {
            exclude.append(CardIds.Secrets.Rogue.Bamboozle)
            exclude.append(CardIds.Secrets.Hunter.BaitAndSwitch)
            if !defender.has(tag: .divine_shield) {
                exclude.append(CardIds.Secrets.Paladin.AutodefenseMatrix)
            }
            
            if freeSpaceOnBoard {
                exclude.append(CardIds.Secrets.Mage.SplittingImage)
                exclude.append(CardIds.Secrets.Hunter.PackTactics)
                exclude.append(CardIds.Secrets.Hunter.SnakeTrap)
                exclude.append(CardIds.Secrets.Hunter.VenomstrikeTrap)
                exclude.append(CardIds.Secrets.Mage.OasisAlly)
            }

            if attacker.isMinion {
                exclude.append(CardIds.Secrets.Hunter.FreezingTrap)
            }
        }
        let defenderReason: SecretExclusionReason = defender.isHero ? .attackedHero : .attackedMinion
        let attackerRuled = [CardIds.Secrets.Paladin.JudgementofJustice, CardIds.Secrets.Mage.MysticMisdirection]
        applyExclusions(exclude.map { card in (card, attackerRuled.contains(card) ? .minionAttacked : defenderReason) },
                        secretIds: nil, turn: nil, invokeCallback: true)
    }

    func handleFastCombat(entity: Entity) {
        guard handleAction else { return }

        if !entity.hasCardId || game.proposedAttacker == 0 || game.proposedDefender == 0 {
            return
        }
        guard let multiIdCard = CardIds.Secrets.getSecretMultiIdCard(entity.cardId) else {
            return
        }
        if !CardIds.Secrets.fastCombat.contains(multiIdCard) {
            return
        }
        if let attacker = game.entities[game.proposedAttacker],
            let defender = game.entities[game.proposedDefender] {
            handleAttack(attacker: attacker, defender: defender, fastOnly: true)
        }
    }

    func handleMinionPlayed(entity: Entity) {
        guard handleAction else { return }

        var exclude: [MultiIdCard] = []

        _lastPlayedMinionId = entity.id
        _triggeredSecrets.removeAll()

        if !entity.has(tag: .dormant) {
            exclude.append(CardIds.Secrets.Hunter.BargainBin)
            exclude.append(CardIds.Secrets.Hunter.Snipe)
            exclude.append(CardIds.Secrets.Mage.ExplosiveRunes)
            exclude.append(CardIds.Secrets.Mage.Objection)
            exclude.append(CardIds.Secrets.Mage.PotionOfPolymorph)
            exclude.append(CardIds.Secrets.Paladin.Repentance)
        }

        if freeSpaceOnBoard {
            exclude.append(CardIds.Secrets.Mage.MirrorEntity)
            exclude.append(CardIds.Secrets.Hunter.Zombeeees)
        }

        if freeSpaceInHand {
            exclude.append(CardIds.Secrets.Mage.FrozenClone)
        }
        // Ambush and Kidnap are decided once the battlecry and the older secrets resolved (see
        // resolveMinionPlayed): Kidnap's Sack or a battlecry summon can fill the board first.

        // Hidden Cache only triggers with a minion in the opponent's hand. The unknown cards are
        // kept with the play, so one revealed as a minion later still rules it out (see
        // onEntityRevealedAsMinion).
        let cardsInOpponentsHand = game.entities.values.filter { e in
            e.isInHand && e.isControlled(by: game.opponent.id)
        }
        if cardsInOpponentsHand.any({ $0.isMinion }) {
            exclude.append(CardIds.Secrets.Hunter.HiddenCache)
        }

        let secretIds = activeSecretIds
        let snapshot = MinionPlaySnapshot(minionId: entity.id, secretIds: secretIds, turn: game.turnNumber(),
                                          opponentHandIds: Set(cardsInOpponentsHand.map { $0.id }))
        let transitions = applyExclusions(exclude.map { ($0, .minionPlayed) }, secretIds: snapshot.secretIds, turn: snapshot.turn, invokeCallback: true)
        pendingLock.around {
            snapshot.save(transitions)
            pendingChecks.append(.minionPlayed(snapshot))
            lastMinionPlay = snapshot
            // A play only matters while one of the secrets it saw is still in play
            minionPlaysSeeingHand.removeAll { $0.secretIds.isDisjoint(with: secretIds) }
            minionPlaysSeeingHand.append(snapshot)
        }
    }

    // At the boundary after a minion play
    private func resolveMinionPlayed(_ snapshot: MinionPlaySnapshot, window: AfterPlayWindow) {
        // After-play secrets do not trigger on a minion that was countered, removed, returned or is
        // about to die by then (Mirror Entity's wiki notes), so anything that took the minion out of
        // play before the boundary means they never had their chance: Explosive Runes or Snipe
        // killing it, Objection! countering it, its own battlecry. Only Objection! reacts before that.
        guard let minion = game.entities[snapshot.minionId], minion.isInPlay, minion.isControlled(by: game.player.id),
              !minion.has(tag: .to_be_destroyed), !(minion.has(tag: .health) && minion.health <= 0) else {
            restoreSaved(snapshot)
            return
        }
        // The board counts Kidnapper's Sacks, Ambushers and copies the older secrets summoned, and a
        // board that was full at any point after the play may be the one they saw
        guard window.freeSpaceOnBoard else { return }
        let transitions = applyExclusions([(CardIds.Secrets.Rogue.Ambush, .minionPlayed), (CardIds.Secrets.Rogue.Kidnap, .minionPlayed)],
                                          secretIds: snapshot.secretIds, turn: snapshot.turn, invokeCallback: true)
        pendingLock.around { snapshot.save(transitions) }
    }

    // Takes back what the play ruled out on each secret, except Objection!, which reacts to the
    // play itself before anything can remove the minion
    private func restoreSaved(_ snapshot: MinionPlaySnapshot) {
        let saved: [Int: [MultiIdCard]] = pendingLock.around {
            let saved = snapshot.saved
            snapshot.saved.removeAll()
            // Its after-play secrets never had their chance, so its hand says nothing about Hidden Cache
            minionPlaysSeeingHand.removeAll { $0 === snapshot }
            return saved
        }
        var restored = false
        for secret in secrets.array() {
            guard let cards = saved[secret.entity.id] else { continue }
            let restore = cards.filter { $0 != CardIds.Secrets.Mage.Objection }
            restored = restored || restore.any { secret.isExcluded(cardId: $0) }
            include(cardIds: restore, on: [secret])
        }
        if restored {
            onChanged?(getSecretList())
        }
    }

    private func forgetSaved(card: MultiIdCard) {
        pendingLock.around {
            var plays = pendingChecks.compactMap { check -> MinionPlaySnapshot? in
                if case .minionPlayed(let snapshot) = check { return snapshot }
                return nil
            }
            if let lastMinionPlay {
                plays.append(lastMinionPlay)
            }
            for play in plays {
                for (secretId, cards) in play.saved {
                    play.saved[secretId] = cards.filter { $0 != card }
                }
            }
        }
    }

    func handleOpponentMinionDeath(entity: Entity) {
        guard handleAction else { return }

        var exclude: [MultiIdCard] = []
        if freeSpaceInHand {
            exclude.append(CardIds.Secrets.Mage.Duplicate)
            exclude.append(CardIds.Secrets.Paladin.GetawayKodo)
            exclude.append(CardIds.Secrets.Rogue.CheatDeath)
        }
        
        var numDeathrattleMinions = 0
        if entity.isActiveDeathrattle {
            if let count = CardIds.DeathrattleSummonCardIds[entity.cardId] {
                numDeathrattleMinions = count
            } else if entity.cardId == CardIds.Collectible.Neutral.Stalagg
                && game.opponent.graveyard.any({ $0.cardId == CardIds.Collectible.Neutral.Feugen })
                || entity.cardId == CardIds.Collectible.Neutral.Feugen
                && game.opponent.graveyard.any({ $0.cardId == CardIds.Collectible.Neutral.Stalagg }) {
                numDeathrattleMinions = 1
            }

            if game.entities.values.any({ $0.cardId == CardIds.NonCollectible.Druid.SouloftheForest_SoulOfTheForestEnchantment
                && $0[.attached] == entity.id }) {
                numDeathrattleMinions += 1
            }
            if game.entities.values.any({ $0.cardId == CardIds.NonCollectible.Shaman.AncestralSpirit_AncestralSpiritEnchantment
                && $0[.attached] == entity.id }) {
                numDeathrattleMinions += 1
            }
        }

        if let opponentEntity = game.opponentEntity,
            opponentEntity.has(tag: .extra_deathrattles) {
            numDeathrattleMinions *= opponentEntity[.extra_deathrattles] + 1
        }

        handleAvenge(deathRattleCount: numDeathrattleMinions)

        // redemption never triggers if a deathrattle effect fills up the board
        // effigy can trigger ahead of the deathrattle effect, but only if effigy was played before the deathrattle minion
        let freeSpaceAfterDeathrattles = game.opponentBoardCount < 7 - numDeathrattleMinions
        if freeSpaceAfterDeathrattles {
            exclude.append(CardIds.Secrets.Paladin.Redemption)
        }

        // NUM_FRIENDLY_MINIONS_THAT_DIED_THIS_TURN is logged right after each ZONE=GRAVEYARD, so it
        // still counts only the earlier deaths: 1 means this is the second one. Later deaths do not
        // trigger it, and like Redemption it needs a slot to bring the minion back into.
        var secondDeathExclude: [MultiIdCard] = []
        if game.opponentEntity?[.num_friendly_minions_that_died_this_turn] == 1 && freeSpaceAfterDeathrattles {
            secondDeathExclude.append(CardIds.Secrets.Paladin.HandOfSalvation)
        }

        // TODO: break ties when Effigy + Deathrattle played on the same turn
        exclude.append(CardIds.Secrets.Mage.Effigy)
        exclude.append(CardIds.Secrets.Hunter.EmergencyManeuvers)
        
        // Untimely Death resummons the minion, so a board the deathrattles fill keeps it possible
        if entity.info.turnPlayed == (game.gameEntity?[.turn] ?? 0) - 1 && freeSpaceAfterDeathrattles {
            exclude.append(CardIds.Secrets.Hunter.UntimelyDeath)
        }

        applyExclusions(exclude.map { ($0, .enemyMinionDied) } + secondDeathExclude.map { ($0, .secondEnemyMinionDied) },
                        secretIds: nil, turn: nil, invokeCallback: true)
    }
    
    func handlePlayerMinionDeath(entity: Entity) {
        guard entity.id == _lastPlayedMinionId,
              let play = pendingLock.around({ lastMinionPlay }), play.minionId == entity.id else { return }
        // HDT's rule: only one secret triggers per event, so when a minion-played secret triggered
        // on the minion, the others were ruled out wrongly, even if the minion survived it and died
        // later in the turn. The boundary already restores when the minion left play before it.
        guard _triggeredSecrets.any({ x in CardIds.Secrets.minionPlayed.any({ s in s == x.cardId }) }) else { return }
        restoreSaved(play)
    }

    // HDT HandleAvengeAsync waits 50 ms of game time; here the check waits for the end of the
    // DEATHS block (or the next boundary), and every death adds its deathrattle summons first.
    func handleAvenge(deathRattleCount: Int) {
        guard handleAction else { return }
        let secretIds = activeSecretIds
        let turn = game.turnNumber()
        pendingLock.around {
            _avengeDeathRattleCount += deathRattleCount
            if _avengePending == nil {
                _avengePending = (secretIds, turn)
            }
        }
    }

    // Called when a DEATHS block ends, before any deathrattle has summoned
    func resolvePendingAvenge() {
        resolveAvenge(summonsResolved: false)
    }

    private func resolveAvenge(summonsResolved: Bool) {
        let pending: (pending: (secretIds: Set<Int>, turn: Int)?, deathrattles: Int) = pendingLock.around {
            let state = (_avengePending, _avengeDeathRattleCount)
            _avengePending = nil
            _avengeDeathRattleCount = 0
            return state
        }
        guard let avenge = pending.pending else { return }
        // Past the death phase the board also holds the deathrattle summons, which Avenge cannot see.
        // Dormant minions cannot be buffed either (opponentMinionCount already skips untouchable ones).
        let dormant = game.entities.values.filter { $0.isInPlay && $0.isMinion && $0.has(tag: .dormant)
            && !$0.has(tag: .untouchable) && $0.isControlled(by: game.opponent.id) }.count
        let survivors = game.opponentMinionCount - dormant - (summonsResolved ? pending.deathrattles : 0)
        if survivors > 0 {
            applyExclusions([(CardIds.Secrets.Paladin.Avenge, .enemyMinionDied)], secretIds: avenge.secretIds, turn: avenge.turn, invokeCallback: true)
        }
    }

    // Resolves every check that was waiting for the previous action to finish. Runs on the log
    // reader thread at a root PLAY/ATTACK BLOCK_START and at every STEP change.
    func resolvePendingChecks() {
        resolveAvenge(summonsResolved: true)
        let (checks, triggered, fullest) = pendingLock.around {
            let state = (pendingChecks, triggeredSinceBoundary, fullestSinceBoundary)
            pendingChecks.removeAll()
            triggeredSinceBoundary.removeAll()
            fullestSinceBoundary = nil
            return state
        }
        // Both callers run for every action and step in every game mode, and the window below
        // scans every entity twice, so skip it when nothing is waiting (the common case).
        guard !checks.isEmpty else { return }
        let window = AfterPlayWindow(fullestBoard: max(fullest?.board ?? 0, game.opponentBoardCount),
                                     fullestHand: max(fullest?.hand ?? 0, game.opponentHandCount))
        for check in checks {
            switch check {
            case .spellCast(let snapshot):
                resolveSpellCast(snapshot, triggered: triggered, window: window)
            case .threeCards(let snapshot):
                resolveThreeCards(snapshot, triggered: triggered, window: window)
            case .minionPlayed(let snapshot):
                resolveMinionPlayed(snapshot, window: window)
            case .reckoning(let dealerId, let secretIds, let turn):
                // The dealer has to survive the exchange for Reckoning to have had a target
                if let dealer = game.entities[dealerId], dealer.isInPlay && dealer.health > 0 && !dealer.has(tag: .to_be_destroyed) {
                    applyExclusions([(CardIds.Secrets.Paladin.Reckoning, .minionDealtThreeDamage)], secretIds: secretIds, turn: turn, invokeCallback: true)
                }
            }
        }
    }

    // Called at the end of every root block. The after-play triggers (the older secrets, Knife
    // Juggler, Wild Pyromancer...) each resolve in a root block of their own, in play order, so a
    // secret may have seen the board or hand as it stood between any two of them. Only the fullest
    // state since the play is safe to rule a summon or draw out with, not the one at the next action.
    func sampleAfterRootBlock() {
        guard pendingLock.around({ !pendingChecks.isEmpty }) else { return }
        // Minions the block mortally wounded leave in the death phase that follows, before any
        // other trigger resolves
        let board = game.entities.values.filter { $0.isInPlay && $0.takesBoardSlot && $0.isControlled(by: game.opponent.id)
            && !$0.has(tag: .to_be_destroyed) && !($0.isMinion && $0.has(tag: .health) && $0.health <= 0) }.count
        let hand = game.opponentHandCount
        pendingLock.around {
            fullestSinceBoundary = (max(fullestSinceBoundary?.board ?? 0, board), max(fullestSinceBoundary?.hand ?? 0, hand))
        }
    }

    // HDT HandleCardPlayed checks these 750 ms after the cast with the board as it was then. The
    // "after cast" secrets react once the spell resolved, so their board and hand conditions are
    // read here, when its deaths and the older secrets' summons are on the board.
    private func resolveSpellCast(_ snapshot: SpellCastSnapshot, triggered: [Entity], window: AfterPlayWindow) {
        // An older Ice Trap sends the spell back before a newer Counterspell sees it, and whether
        // Counterspell reacts to the spell Oh My Yogg! casts instead is unverified, so both keep it
        // possible (HDT returns after Ice Trap without ruling Counterspell out). A spell that was
        // countered anyway (CANT_PLAY) was not countered by another Counterspell of the same
        // player, since the same secret cannot be in play twice; one that triggered is revealed.
        let returnedToHand = game.entities[snapshot.spellEntityId]?.isInHand ?? true
        let iceTrapOrYoggTriggered = triggered.any {
            CardIds.Secrets.Hunter.IceTrap == $0.cardId || CardIds.Secrets.Paladin.OhMyYogg == $0.cardId
        }
        var candidates = !returnedToHand && !iceTrapOrYoggTriggered ? [CardIds.Secrets.Mage.Counterspell] : []
        // A countered or returned spell was never cast, so nothing else had a chance to trigger.
        // Which of Counterspell and Ice Trap came first does not matter for the others.
        if playWasStopped(snapshot.spellEntityId, triggered: triggered) {
            applyExclusions(candidates.map { ($0, .spellCast) }, secretIds: snapshot.secretIds, turn: snapshot.turn, invokeCallback: true)
            return
        }
        candidates += [CardIds.Secrets.Hunter.IceTrap, CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Paladin.OhMyYogg]

        // Oh My Yogg! replaces the spell, and whether Never Surrender! still reacts is unknown
        let ohMyYoggTriggered = triggered.any { CardIds.Secrets.Paladin.OhMyYogg == $0.cardId }
        if snapshot.opponentHadMinions && !ohMyYoggTriggered {
            candidates.append(CardIds.Secrets.Paladin.NeverSurrender)
        }
        if snapshot.freeSpaceInHandAtCast && window.freeSpaceInHand {
            candidates.append(CardIds.Secrets.Mage.ManaBind)
        }
        // Dirty Tricks does not activate when the hand is full after the spell was cast
        if window.freeSpaceInHand {
            candidates.append(CardIds.Secrets.Rogue.DirtyTricks)
        }
        if window.freeSpaceOnBoard {
            candidates.append(CardIds.Secrets.Hunter.CatTrick)
            candidates.append(CardIds.Secrets.Mage.NetherwindPortal)
            candidates.append(CardIds.Secrets.Rogue.StickySituation)
        }
        // Pressure Plate needs a minion of the player left to destroy once the spell resolved
        if game.entities.values.any({ $0.isInPlay && $0.isMinion && $0.isControlled(by: game.player.id)
            && !$0.has(tag: .dormant) && !$0.has(tag: .untouchable) }) {
            candidates.append(CardIds.Secrets.Hunter.PressurePlate)
        }
        if snapshot.freeSpaceOnBoardAtCast && spellTargetedMinion(snapshot) {
            candidates.append(CardIds.Secrets.Mage.Spellbender)
        }
        applyExclusions(candidates.map { ($0, .spellCast) }, secretIds: snapshot.secretIds, turn: snapshot.turn, invokeCallback: true)
    }

    private func spellTargetedMinion(_ snapshot: SpellCastSnapshot) -> Bool {
        if let targetIsMinion = snapshot.targetIsMinion {
            return targetIsMinion
        }
        // Older logs write CARD_TARGET after the spell's ZONE change
        guard let spell = game.entities[snapshot.spellEntityId], spell.has(tag: .card_target) else { return false }
        return game.entities[spell[.card_target]]?.isMinion ?? false
    }

    // Rat Trap, Galloping Savior and Hidden Wisdom summon or draw after the card resolved
    private func resolveThreeCards(_ snapshot: CardPlaySnapshot, triggered: [Entity], window: AfterPlayWindow) {
        // Whether a countered or returned card still counts as played is unverified, so it rules
        // nothing out
        if playWasStopped(snapshot.cardEntityId, triggered: triggered) {
            return
        }
        var entries: [(card: MultiIdCard, reason: SecretExclusionReason?)] = [(CardIds.Secrets.Hunter.MotionDenied, .threeCardsPlayed)]
        if snapshot.freeSpaceOnBoardAtPlay && window.freeSpaceOnBoard {
            entries.append((CardIds.Secrets.Hunter.RatTrap, .threeCardsPlayed))
            entries.append((CardIds.Secrets.Paladin.GallopingSavior, .threeCardsPlayed))
        }
        if snapshot.freeSpaceInHandAtPlay && window.freeSpaceInHand {
            entries.append((CardIds.Secrets.Paladin.HiddenWisdom, .threeCardsPlayed))
        }
        applyExclusions(entries, secretIds: snapshot.secretIds, turn: snapshot.turn, invokeCallback: true)
    }

    // True when the card was countered (CANT_PLAY, Counterspell, or Objection! for a minion) or sent
    // back to the hand (Ice Trap), which the secrets that triggered since the play tell apart from
    // the card simply resolving
    private func playWasStopped(_ entityId: Int, triggered: [Entity]) -> Bool {
        guard let card = game.entities[entityId] else { return true }
        if card[.cant_play] == 1 || card.isInHand {
            return true
        }
        return triggered.any { secret in
            CardIds.Secrets.Mage.Counterspell == secret.cardId || CardIds.Secrets.Hunter.IceTrap == secret.cardId
                || (card.isMinion && CardIds.Secrets.Mage.Objection == secret.cardId)
        }
    }

    private func recordTriggered(_ entity: Entity) {
        pendingLock.around {
            if !triggeredSinceBoundary.contains(where: { $0.id == entity.id }) {
                triggeredSinceBoundary.append(entity)
            }
        }
    }

    // PREDAMAGE > 0 marks the entity as being hit in this block
    func handleEntityPredamage(entity: Entity) {
        pendingLock.around { _ = predamagedEntityIds.insert(entity.id) }
    }

    // Called on the player's turn. A hit that armor absorbs entirely logs no DAMAGE change, only the
    // ARMOR loss, and a hit that just empties the armor takes it to 0.
    func handleEntityLostArmor(entity: Entity, value: Int) {
        guard value > 0, entity.isHero && entity.isControlled(by: game.opponent.id), !entity.has(tag: .immune) else {
            return
        }
        opponentTookDamageDuringTurns.append(game.turnNumber())

        // Armor also goes away without damage (effects that remove or swap it), so only a loss inside
        // a damage context counts as the hero being damaged. Whether Evasion reacts to armor-only
        // hits is unverified, so only Eye for an Eye is ruled out.
        let damaged: Bool = pendingLock.around {
            guard predamagedEntityIds.contains(entity.id) else { return false }
            armorLostThisBlock[entity.id, default: 0] += value
            return true
        }
        if damaged {
            exclude(cardId: CardIds.Secrets.Paladin.EyeForAnEye, reason: .enemyHeroDamaged)
        }
    }

    // NUM_TURNS_IN_PLAY of a non-hero entity. Every entity in play gets it at MAIN_READY of each
    // turn, but revealed or created entities also carry it mid-turn, which must not count as a turn
    // start.
    func handleTurnsInPlayChange(entity: Entity, turn: Int) {
        guard game.opponentEntity?.isCurrentPlayer ?? false else { return }
        let step = game.gameEntity?[.step]
        guard step == Step.main_ready.rawValue || step == Step.main_start_triggers.rawValue else { return }

        // The markers move even without secrets (HDT returns first): otherwise the first mid-turn
        // change after a turn that started without secrets would rule out the start-of-turn
        // secrets played since.
        let startOfTurn = turn > _lastStartOfTurnCheck
        if startOfTurn {
            _lastStartOfTurnCheck = turn
        }
        let startOfTurnWithMinion = turn > _lastStartOfTurnMinionCheck && entity.isMinion && entity.isControlled(by: game.opponent.id)
        if startOfTurnWithMinion {
            _lastStartOfTurnMinionCheck = turn
        }
        let startOfTurnDamageCheck = turn > _lastStartOfTurnDamageCheck
        if startOfTurnDamageCheck {
            _lastStartOfTurnDamageCheck = turn
        }
        // Flames of Infinity looks at the minions once, whether or not there are secrets now
        let turnEnd: PlayerTurnEnd? = startOfTurn ? pendingLock.around {
            let snapshot = playerTurnEnd
            playerTurnEnd?.minionIds.removeAll()
            return snapshot
        } : nil

        guard handleAction else { return }

        if startOfTurn {
            exclude(cardId: CardIds.Secrets.Rogue.Perjury, reason: .opponentTurnStarted)
            if game.opponentMinionCount >= 1 && freeSpaceOnBoard {
                exclude(cardId: CardIds.Secrets.Mage.SummoningWard, reason: .opponentTurnStarted)
            }
            // A minion at MAIN_END that is still there now was on the board all through the
            // end-of-turn effects. One that died to them, or was summoned by them, proves nothing.
            if let turnEnd, turnEnd.minionIds.contains(where: { id in
                game.entities[id].map { $0.isInPlay && $0.isControlled(by: game.player.id) } ?? false
            }) {
                applyExclusions([(CardIds.Secrets.Mage.FlamesOfInfinity, .turnEndedWithMinion)], secretIds: turnEnd.secretIds,
                                turn: turnEnd.turn, invokeCallback: true)
            }
        }

        if startOfTurnWithMinion {
            exclude(cardId: CardIds.Secrets.Paladin.CompetitiveSpirit, reason: .opponentTurnStarted)
            if game.opponentMinionCount >= 2 && freeSpaceOnBoard {
                exclude(cardId: CardIds.Secrets.Hunter.OpenTheCages, reason: .opponentTurnStarted)
            }
        }
        if startOfTurnDamageCheck {
            // The player's turn that just ended: the same turn number when the player went first
            let turnToCheck = turn - (game.playerEntity?.has(tag: .first_player) ?? false ? 0 : 1)
            if !opponentTookDamageDuringTurns.contains(turnToCheck) {
                applyExclusions([(CardIds.Secrets.Mage.RiggedFaireGame, .enemyHeroNotDamaged)], secretIds: nil,
                                turn: max(turnToCheck, 0), invokeCallback: true)
            }
        }
    }
    
    func handlePlayerTurnStart() {
        pendingLock.around { lastMinionPlay = nil }
    }

    // STEP=MAIN_END on the player's turn, before the end-of-turn triggers
    func handlePlayerTurnEnding() {
        let minionIds = game.entities.values.filter { $0.isInPlay && $0.isMinion && $0.isControlled(by: game.player.id)
            && !$0.has(tag: .dormant) && !$0.has(tag: .untouchable) }.map { $0.id }
        let snapshot = PlayerTurnEnd(secretIds: activeSecretIds, turn: game.turnNumber(), minionIds: Set(minionIds))
        pendingLock.around { playerTurnEnd = snapshot }
    }

    // Game runs this off the log reader thread, after Player.onTurnEnd moved the player's plays to
    // cardsPlayedLastTurn (HDT reads the list it has just cleared, so Plagiarize was never ruled out).
    func handleOpponentTurnStart() {
        guard handleAction, game.player.cardsPlayedLastTurn.count > 0,
              let turnEnd = pendingLock.around({ playerTurnEnd }) else { return }
        // A secret that came into play after the player's turn ended never saw those cards
        applyExclusions([(CardIds.Secrets.Rogue.Plagiarize, .cardsPlayedInTurn)], secretIds: turnEnd.secretIds,
                        turn: turnEnd.turn, invokeCallback: true)
    }

    // STEP=MAIN_CLEANUP on the player's turn, after the end-of-turn triggers
    func handlePlayerTurnEnded(mana: Int) {
        guard handleAction, let turnEnd = pendingLock.around({ playerTurnEnd }) else { return }
        // Hidden Meaning summons, so a full board (or one an older end-of-turn summon filled) keeps it
        if mana == 0 && freeSpaceOnBoard {
            exclude(cardId: CardIds.Secrets.Hunter.HiddenMeaning, reason: .turnEndedNoMana, secretIds: turnEnd.secretIds)
        }
    }
    
    func handlePlayerManaRemaining(mana: Int) {
        if mana == 0 && freeSpaceInHand {
            exclude(cardId: CardIds.Secrets.Rogue.DoubleCross, reason: .allManaSpent)
        }
    }
    
    func secretTriggered(entity: Entity) {
        _triggeredSecrets.append(entity)
        recordTriggered(entity)
    }

    func handleCardPlayed(entity: Entity, parentCardId: String, targetEntityId: Int? = nil) {
        guard handleAction else { return }

        // Sparkjoy Cheat casts the secret, which is not a play and does not count as one
        if entity.isSpell && parentCardId == CardIds.Collectible.Rogue.SparkjoyCheat {
            return
        }

        pendingLock.around { lastMinionPlay = nil }

        var exclude = playedFromHandExclusions(entity: entity)

        if entity.isSpell {
            // Every reaction, Counterspell included, waits for the spell to resolve, in case an older
            // Ice Trap or Counterspell stopped it. The PLAY block names the target before CARD_TARGET
            // is logged.
            let targetId = targetEntityId ?? (entity.has(tag: .card_target) ? entity[.card_target] : nil)
            let snapshot = SpellCastSnapshot(spellEntityId: entity.id, secretIds: activeSecretIds, turn: game.turnNumber(),
                                             opponentHadMinions: game.opponentMinionCount > 0,
                                             freeSpaceInHandAtCast: freeSpaceInHand,
                                             freeSpaceOnBoardAtCast: freeSpaceOnBoard,
                                             targetIsMinion: targetId.flatMap { game.entities[$0]?.isMinion })
            pendingLock.around { pendingChecks.append(.spellCast(snapshot)) }
        } else if entity.isMinion && game.playerMinionCount > 3 {
            exclude.append((CardIds.Secrets.Paladin.SacredTrial, .minionPlayed))
        }
        
        if entity.isWeapon {
            exclude.append((CardIds.Secrets.Hunter.BargainBin, .weaponPlayed))
        }
        applyExclusions(exclude, secretIds: nil, turn: nil, invokeCallback: true)
    }

    // Quests, sidequests, sigils and objectives go from the hand to the secret zone like secrets,
    // and count as played cards. HDT skips them; whether the spell reactions see them is unverified,
    // so only the played-card counts apply.
    func handleQuestPlayed(entity: Entity) {
        guard handleAction else { return }
        applyExclusions(playedFromHandExclusions(entity: entity), secretIds: nil, turn: nil, invokeCallback: true)
    }

    // The rules every card played from hand is subject to. Returns the immediate exclusions and
    // queues the ones that wait for the card to resolve.
    private func playedFromHandExclusions(entity: Entity) -> [(card: MultiIdCard, reason: SecretExclusionReason?)] {
        var exclude: [(card: MultiIdCard, reason: SecretExclusionReason?)] = []

        // NUM_CARDS_PLAYED_THIS_TURN is logged before the ZONE change, so it already counts this card
        if let player = game.playerEntity, player.isCurrentPlayer && player[.num_cards_played_this_turn] >= 3 {
            let snapshot = CardPlaySnapshot(cardEntityId: entity.id, secretIds: activeSecretIds, turn: game.turnNumber(),
                                            freeSpaceOnBoardAtPlay: freeSpaceOnBoard, freeSpaceInHandAtPlay: freeSpaceInHand)
            pendingLock.around { pendingChecks.append(.threeCards(snapshot)) }
        }

        // Azerite Vein triggers when the card is played, so countering it changes nothing
        if entity[.num_turns_in_hand] == 1 && freeSpaceInHand {
            exclude.append((CardIds.Secrets.Mage.AzeriteVein, .cardFromThisTurnPlayed))
        }
        return exclude
    }
    
    func handleCardDrawn(entity: Entity) {
        guard handleAction else { return }
        // Draws on the opponent's turn (their AoE on Acolyte of Pain) cannot trigger their secret
        guard game.playerEntity?.isCurrentPlayer == true else { return }

        var exclude: [MultiIdCard] = []
        if let playerEntity = game.playerEntity, playerEntity[.num_cards_drawn_this_turn] >= 1 {
            exclude.append(CardIds.Secrets.Rogue.Shenanigans)
        }
        
        self.exclude(cardIds: exclude, reason: .secondCardDrawn)
    }

    func handleHeroPower() {
        guard handleAction else { return }
        exclude(cardId: CardIds.Secrets.Hunter.DartTrap, reason: .heroPowerUsed)
    }
    
    // A card that was in the opponent's hand when minions were played turned out to be a minion.
    // Only the plays whose after-play secrets had their chance count, and only on the secrets that
    // were in play for them.
    func onEntityRevealedAsMinion(entity: Entity) {
        guard entity.isMinion else { return }
        let plays = pendingLock.around { minionPlaysSeeingHand.filter { $0.opponentHandIds.contains(entity.id) } }
        for play in plays {
            let transitions = applyExclusions([(CardIds.Secrets.Hunter.HiddenCache, .minionPlayed)], secretIds: play.secretIds,
                                              turn: play.turn, invokeCallback: true)
            // Saved with the play, so it is taken back like the others if the play is
            pendingLock.around { play.save(transitions) }
        }
    }
    
    func onNewBlock() {
        entityDamageDealtHistory.removeAll()
        pendingLock.around {
            predamagedEntityIds.removeAll()
            armorLostThisBlock.removeAll()
        }
    }
    
    // A DAMAGE increase on the player's turn. The dealer is LAST_AFFECTED_BY, which HDT also allows
    // to be unknown.
    func entityDamage(dealer: Entity?, target: Entity, damage: Int) {
        guard damage > 0 else { return }
        if target.isHero && target.isControlled(by: game.opponent.id) {
            if !target.has(tag: .immune) {
                opponentTookDamageDuringTurns.append(game.turnNumber())
                exclude(cardIds: [CardIds.Secrets.Paladin.EyeForAnEye, CardIds.Secrets.Rogue.Evasion], reason: .enemyHeroDamaged)
            }
        }
        if let dealer, dealer.isMinion && dealer.isControlled(by: game.player.id) {
            // Armor the same hit took first counts toward the 3 damage (5 attack into 4 armor logs
            // ARMOR -4 and DAMAGE +1)
            let absorbed: Int = pendingLock.around { armorLostThisBlock.removeValue(forKey: target.id) ?? 0 }
            let dealt = damage + absorbed
            if let dict = entityDamageDealtHistory[dealer.id] {
                if let hist = dict[target.id] {
                    dict[target.id] = hist + dealt
                } else {
                    dict[target.id] = dealt
                }
            } else {
                let dict = SynchronizedDictionary<Int, Int>()
                entityDamageDealtHistory[dealer.id] = dict
                dict[target.id] = dealt
            }
            let damageDealt = entityDamageDealtHistory[dealer.id]?[target.id] ?? 0
            guard damageDealt >= 3 && handleAction else { return }
            // Whether the dealer survived the exchange is only known once the attack resolved
            let secretIds = activeSecretIds
            let turn = game.turnNumber()
            pendingLock.around {
                let alreadyPending = pendingChecks.contains { check in
                    if case .reckoning(let pendingDealerId, _, _) = check { return pendingDealerId == dealer.id }
                    return false
                }
                if !alreadyPending {
                    pendingChecks.append(.reckoning(dealerId: dealer.id, secretIds: secretIds, turn: turn))
                }
            }
        }
    }
}
