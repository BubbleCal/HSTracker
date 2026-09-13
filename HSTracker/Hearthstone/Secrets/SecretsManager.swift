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
    // Spell reactions whose preconditions held when the spell was cast
    let candidates: [MultiIdCard]
    let freeSpaceOnBoard: Bool
    let targetEntityId: Int?
}

private enum PendingSecretCheck {
    case spellCast(SpellCastSnapshot)
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
    
    private var entititesInHandOnMinionsPlayed: Set<Entity>  = Set<Entity>()
    
    private var game: Game
    private let _availableSecrets: AvailableSecretsProvider
    private let _relatedCardsManager: RelatedCardsManager
    private(set) var secrets = SynchronizedArray<Secret>()
    private var _triggeredSecrets = SynchronizedArray<Entity>()
    private var opponentTookDamageDuringTurns = SynchronizedArray<Int>()
    private var entityDamageDealtHistory = SynchronizedDictionary<Int, SynchronizedDictionary<Int, Int>>()
    
    private var _lastPlayedMinionId: Int = 0
    private var savedSecrets = SynchronizedArray<MultiIdCard>()
    
    var onChanged: (([Card]) -> Void)?
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
    private var handleAction: Bool { return hasActiveSecrets }
    private var isAnyMinionInOpponentsHand: Bool { return entititesInHandOnMinionsPlayed.first(where: { entity in entity.isMinion }) != nil }
    
    private var hasActiveSecrets: Bool {
        return secrets.count > 0
    }
    
    private func saveSecret(secret: MultiIdCard) {
        if !secrets.any({ (s) -> Bool in
            s.isExcluded(cardId: secret)
        }) {
            savedSecrets.append(secret)
        }
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

    private func applyExclusions(_ entries: [(card: MultiIdCard, reason: SecretExclusionReason?)], secretIds: Set<Int>?, turn: Int?, invokeCallback: Bool) {
        guard !entries.isEmpty else { return }
        let turn = turn ?? game.turnNumber()
        var events = [SecretExclusionEvent]()
        for secret in secrets.array() {
            if let secretIds, !secretIds.contains(secret.entity.id) {
                continue
            }
            var changed = false
            for entry in entries where secret.exclude(cardId: entry.card, reason: entry.reason, turn: turn) {
                changed = true
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

    private var activeSecretIds: Set<Int> {
        return Set(secrets.array().map { $0.entity.id })
    }

    func refresh() {
        onChanged?(getSecretList())
    }

    // The hover line for a dimmed row, e.g. "Turn 5: You attacked the enemy hero". A row is dimmed
    // once no active secret allows the card, so the latest exclusion is the one that dimmed it.
    func exclusionSummary(cardId: String) -> String? {
        guard let card = CardIds.Secrets.getSecretMultiIdCard(cardId) else { return nil }
        let latest = secrets.array()
            .compactMap { $0.exclusion(for: card) }
            .filter { $0.reason != nil }
            .max { $0.turn < $1.turn }
        if let latest, let reason = latest.reason {
            let text = String.localizedString(reason.localizationKey, comment: "")
            return String(format: String.localizedString("SecretHelper_RuledOutFormat", comment: ""), latest.turn, text)
        }
        if gameModeHasCardLimit(game.currentGameType) && hasPlayedBothCopies(card) {
            return String.localizedString("SecretReason_BothCopiesPlayed", comment: "")
        }
        return nil
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
        }
        savedSecrets.removeAll()
        _lastPlayedMinionId = 0
        entityDamageDealtHistory.removeAll()
        _lastStartOfTurnCheck = 0
        _lastStartOfTurnDamageCheck = 0
        _lastStartOfTurnMinionCheck = 0
        opponentTookDamageDuringTurns.removeAll()
        entititesInHandOnMinionsPlayed.removeAll()
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
            onNewSecret(secret: secret)
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
                savedSecrets.remove(secretMultiIdCard)
            }
        }
        onChanged?(getSecretList())
        return true
    }
    
    func toggle(cardId: String) {
        // MultiIdCard equality compares every id, so look up the full card for multi-print secrets
        let mcid = CardIds.Secrets.getSecretMultiIdCard(cardId) ?? MultiIdCard(cardId)
        let excluded = secrets.any { $0.isExcluded(cardId: mcid) }
        if excluded {
            include(cardIds: [mcid], on: secrets.array())
        } else {
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

    func getSecretList() -> [Card] {
        let gameMode = game.currentGameType
        let format = game.currentFormatType
        
        let deckSecrets = getSecretsFromDeck(gameMode, format)
        let createdSecretsList = getSecretsCreatedBy(gameMode, format)
        
        return createdSecretsList.concatCardList(deckSecrets)
    }
    
    private func getSecretsFromDeck(_ gameMode: GameType, _ format: FormatType) -> [Card] {
        let gameModeHasCardLimit = gameModeHasCardLimit(gameMode)

        let createdSecrets = secrets
            .filter { $0.entity.info.created }
            .flatMap { $0.excluded }
            .filter { !$0.value }
            .map { $0.key }
            .unique()
        
        let availableSecrets = getAvailableSecrets(gameMode: gameMode, format: format)
        
        let secretsFromDeck = secrets.filter { s in !s.entity.info.created }
        
        let filteredSecretsFromDeck = getFilteredSecretsByDrawer(secretsFromDeck, availableSecrets)
        
        let adjustCount: ((_ card: MultiIdCard, _ count: Int) -> Int) = { card, count in
            gameModeHasCardLimit && self.hasPlayedBothCopies(card) && !createdSecrets.contains(card) ? 0 : count
        }
        
        let cards = filteredSecretsFromDeck
            .group { m in m }
            .compactMap { group in
                if let multiIdCard = CardIds.Secrets.getSecretMultiIdCard(group.key.ids[0]) {
                    return QuantifiedMultiIdCard(baseCard: group.key, count: adjustCount(multiIdCard, group.value.count))
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
        
        var secretsCreated = [MultiIdCard]()

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
                    secretsCreated.append(contentsOf: SecretsManager.getFilteredSecretsByDrawerFromSingleSecret(secret, tutor, creatableSecrets))
                } else {
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, creatableSecrets))
                }
            } else {
                if let drawer, let tutor = _relatedCardsManager.getSpellSchoolTutor(drawer.cardId) {
                    secretsCreated.append(contentsOf: SecretsManager.getFilteredSecretsByDrawerFromSingleSecret(secret, tutor, availableSecrets))
                } else {
                    secretsCreated.append(contentsOf: getFilteredSecrets(secret, availableSecrets))
                }
            }
        }
        
        return quantifyAndConvertSecrets(secretsCreated, format)
    }
    
    private func getArenaCreatedSecrets(_ createdBySecrets: [Secret], _ availableSecrets: Set<String>, _ gameMode: GameType, _ format: FormatType) -> [Card] {
        var secretsCreated = [MultiIdCard]()
        if let availableCreatedBy = getCreatedBySecretsByCreator(gameMode: gameMode, format: format) {
            let creators = createdBySecrets.compactMap { s in (s, game.opponent.revealedEntities.first { e in e.id == s.entity.info.getCreatorId()})}
            for (secret, creator) in creators {
                let drawer = game.opponent.revealedEntities.first { e in e.id == secret.entity.info.getDrawerId() }
                
                if let drawer, let spellSchoolTutor = _relatedCardsManager.getSpellSchoolTutor(drawer.cardId) {
                    if let creator, let creatableSecrets = availableCreatedBy[creator.cardId] {
                        let secrets = SecretsManager.getFilteredSecretsByDrawerFromSingleSecret(secret, spellSchoolTutor, creatableSecrets)
                        secretsCreated.append(contentsOf: secrets)
                    } else {
                        let secrets = SecretsManager.getFilteredSecretsByDrawerFromSingleSecret(secret, spellSchoolTutor, availableSecrets)
                        secretsCreated.append(contentsOf: secrets)
                    }
                } else {
                    if let creator, let creatableSecrets = availableCreatedBy[creator.cardId] {
                        let secrets = secret.excluded.filter { x in x.key.ids.any { creatableSecrets.contains($0) }}
                        secretsCreated.append(contentsOf: secrets.filter { x in !x.value }.compactMap { x in x.key })
                    } else {
                        let secrets = secret.excluded.filter { x in x.key.ids.any { availableSecrets.contains($0) }}
                        secretsCreated.append(contentsOf: secrets.filter { x in !x.value }.compactMap { x in x.key })
                    }
                }
            }
            
            let quantified = secretsCreated
                .group { m in m }
                .compactMap { g in
                    if CardIds.Secrets.getSecretMultiIdCard(g.key.ids[0]) != nil {
                        return QuantifiedMultiIdCard(baseCard: g.key, count: g.value.count)
                    } else {
                        return QuantifiedMultiIdCard(baseCard: g.key, count: 0)
                    }
                }
            return SecretsManager.quantifiedCardsToCards(quantified, format)
        }
        
        let filteredSecrets = getFilteredSecretsByDrawer(createdBySecrets, availableSecrets)
        
        let quantifiedSecrets = filteredSecrets
            .group { x in x }
            .compactMap { g in
                if CardIds.Secrets.getSecretMultiIdCard(g.key.ids[0]) != nil {
                    return QuantifiedMultiIdCard(baseCard: g.key, count: g.value.count)
                } else {
                    return QuantifiedMultiIdCard(baseCard: g.key, count: 0)
                }
            }
        
        return SecretsManager.quantifiedCardsToCards(quantifiedSecrets, format)
    }
    
    private func getFilteredSecretsByDrawer(_ allSecrets: [Secret], _ availableSecrets: Set<String>) -> [MultiIdCard] {
        let secretAndDrawSource = allSecrets.compactMap { s in
            (s, game.opponent.revealedEntities.first { e in e.id == s.entity.info.getDrawerId() })
        }

        var filteredSecrets = [MultiIdCard]()
        for (secret, drawSource) in secretAndDrawSource {
            if let drawSource, let spellSchoolTutor = _relatedCardsManager.getSpellSchoolTutor(drawSource.cardId) {
                filteredSecrets.append(contentsOf: SecretsManager.getFilteredSecretsByDrawerFromSingleSecret(secret, spellSchoolTutor, availableSecrets))
            } else {
                let secrets = secret.excluded.filter { x in x.key.ids.any { availableSecrets.contains($0) } }
                filteredSecrets.append(contentsOf: secrets.filter { x in !x.value }.compactMap { x in x.key })
            }
        }

        return filteredSecrets
    }

    private static func getFilteredSecretsByDrawerFromSingleSecret(_ secret: Secret, _ spellSchoolTutor: ISpellSchoolTutor, _ availableSecrets: Set<String>) -> [MultiIdCard] {
        let spellSchools = spellSchoolTutor.tutoredSpellSchools
        return secret.excluded
            .filter { x in x.key.ids.any { availableSecrets.contains($0) && !x.value }}
            .compactMap { x in Card(id: x.key.ids[0]) }
            .filter { c in spellSchools.contains(c.spellSchool.rawValue) }
            .compactMap { c in CardIds.Secrets.getSecretMultiIdCard(c.id) }
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
    
    private func getFilteredSecrets(_ secret: Secret, _ allowedSecrets: Set<String>) -> [MultiIdCard] {
        return secret.excluded.filter { x in x.key.ids.any { allowedSecrets.contains($0) && !x.value }}.compactMap { x in x.key }
    }
    
    private func quantifyAndConvertSecrets(_ secrets: [MultiIdCard], _ format: FormatType) -> [Card] {
        let quantified = secrets
            .group { m in m }
            .compactMap { g in
                if CardIds.Secrets.getSecretMultiIdCard(g.key.ids[0]) != nil {
                    return QuantifiedMultiIdCard(baseCard: g.key, count: g.value.count)
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
                //I think most of the secrets here could (and maybe should) check for this, but this one definitley does because of Hysteria.
                if game.playerEntity?.isCurrentPlayer ?? false {
                    exclude.append(CardIds.Secrets.Mage.OasisAlly)
                }
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
            saveSecret(secret: CardIds.Secrets.Hunter.BargainBin)
            exclude.append(CardIds.Secrets.Hunter.BargainBin)
            saveSecret(secret: CardIds.Secrets.Hunter.Snipe)
            exclude.append(CardIds.Secrets.Hunter.Snipe)
            saveSecret(secret: CardIds.Secrets.Mage.ExplosiveRunes)
            exclude.append(CardIds.Secrets.Mage.ExplosiveRunes)
            saveSecret(secret: CardIds.Secrets.Mage.Objection)
            exclude.append(CardIds.Secrets.Mage.Objection)
            saveSecret(secret: CardIds.Secrets.Mage.PotionOfPolymorph)
            exclude.append(CardIds.Secrets.Mage.PotionOfPolymorph)
            saveSecret(secret: CardIds.Secrets.Paladin.Repentance)
            exclude.append(CardIds.Secrets.Paladin.Repentance)
        }

        if freeSpaceOnBoard {
            saveSecret(secret: CardIds.Secrets.Mage.MirrorEntity)
            exclude.append(CardIds.Secrets.Mage.MirrorEntity)
            saveSecret(secret: CardIds.Secrets.Rogue.Ambush)
            exclude.append(CardIds.Secrets.Rogue.Ambush)
            saveSecret(secret: CardIds.Secrets.Hunter.Zombeeees)
            exclude.append(CardIds.Secrets.Hunter.Zombeeees)
        }

        if freeSpaceInHand {
            exclude.append(CardIds.Secrets.Mage.FrozenClone)
        }
        exclude.append(CardIds.Secrets.Rogue.Kidnap)

        //Hidden cache will only trigger if the opponent has a minion in hand.
        //We might not know this for certain - requires additional tracking logic.
        let cardsInOpponentsHand = game.entities.values.filter({ e in
            e.isInHand && e.isControlled(by: game.opponent.id)
        }).compactMap({ e in e })
        for cardInOpponentsHand in cardsInOpponentsHand {
            entititesInHandOnMinionsPlayed.insert(cardInOpponentsHand)
        }

        if isAnyMinionInOpponentsHand {
            exclude.append(CardIds.Secrets.Hunter.HiddenCache)
        }

        self.exclude(cardIds: exclude, reason: .minionPlayed)
    }

    func handleOpponentMinionDeath(entity: Entity) {
        guard handleAction else { return }

        var exclude: [MultiIdCard] = []
        if freeSpaceInHand {
            exclude.append(CardIds.Secrets.Mage.Duplicate)
            exclude.append(CardIds.Secrets.Paladin.GetawayKodo)
            exclude.append(CardIds.Secrets.Rogue.CheatDeath)
        }
        
        var secondDeathExclude: [MultiIdCard] = []
        if let opponent_minions_died = game.opponentEntity?[.num_friendly_minions_that_died_this_turn], opponent_minions_died >= 1 {
            secondDeathExclude.append(CardIds.Secrets.Paladin.HandOfSalvation)
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
        if game.opponentBoardCount < 7 - numDeathrattleMinions {
            exclude.append(CardIds.Secrets.Paladin.Redemption)
        }

        // TODO: break ties when Effigy + Deathrattle played on the same turn
        exclude.append(CardIds.Secrets.Mage.Effigy)
        exclude.append(CardIds.Secrets.Hunter.EmergencyManeuvers)
        
        if entity.info.turnPlayed == (game.gameEntity?[.turn] ?? 0) - 1 {
            exclude.append(CardIds.Secrets.Hunter.UntimelyDeath)
        }

        applyExclusions(exclude.map { ($0, .enemyMinionDied) } + secondDeathExclude.map { ($0, .secondEnemyMinionDied) },
                        secretIds: nil, turn: nil, invokeCallback: true)
    }
    
    func handlePlayerMinionDeath(entity: Entity) {
        guard entity.id == _lastPlayedMinionId && savedSecrets.count > 0 else { return }
        // Only one secret triggers per event, so the exclusions made when the minion was played
        // are only invalid if one of those secrets actually triggered on it. Anything else
        // killing the minion later in the turn (combat, board clears, end of turn effects)
        // leaves them valid.
        guard _triggeredSecrets.any({ x in CardIds.Secrets.minionPlayed.any({ s in s == x.cardId }) }) else { return }
        include(cardIds: savedSecrets.array(), on: secrets.array())

        onChanged?(getSecretList())
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
        // Past the death phase the board also holds the deathrattle summons, which Avenge cannot see
        let survivors = game.opponentMinionCount - (summonsResolved ? pending.deathrattles : 0)
        if survivors > 0 {
            applyExclusions([(CardIds.Secrets.Paladin.Avenge, .enemyMinionDied)], secretIds: avenge.secretIds, turn: avenge.turn, invokeCallback: true)
        }
    }

    // Resolves every check that was waiting for the previous action to finish. Runs on the log
    // reader thread at a root PLAY/ATTACK BLOCK_START and at every STEP change.
    func resolvePendingChecks() {
        resolveAvenge(summonsResolved: true)
        let (checks, triggered) = pendingLock.around {
            let state = (pendingChecks, triggeredSinceBoundary)
            pendingChecks.removeAll()
            triggeredSinceBoundary.removeAll()
            return state
        }
        for check in checks {
            switch check {
            case .spellCast(let snapshot):
                resolveSpellCast(snapshot, triggered: triggered)
            case .reckoning(let dealerId, let secretIds, let turn):
                // The dealer has to survive the hit for Reckoning to have had a target
                if let dealer = game.entities[dealerId], dealer.health > 0 && dealer[.zone] != Zone.graveyard.rawValue {
                    applyExclusions([(CardIds.Secrets.Paladin.Reckoning, .minionDealtThreeDamage)], secretIds: secretIds, turn: turn, invokeCallback: true)
                }
            }
        }
    }

    private func resolveSpellCast(_ snapshot: SpellCastSnapshot, triggered: [Entity]) {
        // Counterspell/Ice trap order may matter in rare edge cases where both are in play.
        // This is currently not handled.
        if triggered.any({ x in CardIds.Secrets.Mage.Counterspell == x.cardId }) {
            return
        }
        if triggered.any({ x in CardIds.Secrets.Hunter.IceTrap == x.cardId }) {
            applyExclusions([(CardIds.Secrets.Hunter.IceTrap, .spellCast)], secretIds: snapshot.secretIds, turn: snapshot.turn, invokeCallback: true)
            return
        }
        var candidates = snapshot.candidates
        if snapshot.freeSpaceOnBoard {
            // The PLAY block's Target is known at cast time; CARD_TARGET has been logged by now either way
            let spell = game.entities[snapshot.spellEntityId]
            let targetId = snapshot.targetEntityId ?? (spell?.has(tag: .card_target) == true ? spell?[.card_target] : nil)
            if let targetId, let target = game.entities[targetId], target.isMinion {
                candidates.append(CardIds.Secrets.Mage.Spellbender)
            }
        }
        applyExclusions(candidates.map { ($0, .spellCast) }, secretIds: snapshot.secretIds, turn: snapshot.turn, invokeCallback: true)
    }

    private func recordTriggered(_ entity: Entity) {
        pendingLock.around {
            if !triggeredSinceBoundary.contains(where: { $0.id == entity.id }) {
                triggeredSinceBoundary.append(entity)
            }
        }
    }

    func handleOpponentDamage(entity: Entity, damage: Int) {
        guard handleAction else { return }

        if entity.isHero && entity.isControlled(by: game.opponent.id) {
            if !entity.has(tag: GameTag.immune) {
                exclude(cardIds: [CardIds.Secrets.Paladin.EyeForAnEye, CardIds.Secrets.Rogue.Evasion], reason: .enemyHeroDamaged)
                opponentTookDamageDuringTurns.append(game.turnNumber())
            }
        }
        
        if damage >= 3 && entity.isMinion && entity.isControlled(by: game.opponent.id) && entity[.zone] != Zone.graveyard.rawValue {
            exclude(cardId: CardIds.Secrets.Paladin.Reckoning, reason: .minionDealtThreeDamage)
        }
    }
    
    func handleEntityLostArmor(entity: Entity, value: Int) {
        if value <= 0 {
            return
        }
        
        if entity.isHero && entity.isControlled(by: game.opponent.id) {
            if !entity.has(tag: .immune) {
                opponentTookDamageDuringTurns.append(game.turnNumber())
            }
        }
    }

    func handleTurnsInPlayChange(entity: Entity, turn: Int) {
        guard handleAction else { return }

        let isCurrentPlayer = game.opponentEntity?.isCurrentPlayer ?? false
        
        if isCurrentPlayer && (turn > _lastStartOfTurnCheck) {
            _lastStartOfTurnCheck = turn
            exclude(cardId: CardIds.Secrets.Rogue.Perjury, reason: .opponentTurnStarted)
            if game.opponentMinionCount >= 1 && freeSpaceOnBoard {
                exclude(cardId: CardIds.Secrets.Mage.SummoningWard, reason: .opponentTurnStarted)
            }
            if game.playerMinionCount >= 1 {
                exclude(cardId: CardIds.Secrets.Mage.FlamesOfInfinity, reason: .turnEndedWithMinion)
            }
        }
        
        if isCurrentPlayer && (turn > _lastStartOfTurnMinionCheck) {
            if entity.isMinion && entity.isControlled(by: game.opponent.id) {
                _lastStartOfTurnMinionCheck = turn
                exclude(cardId: CardIds.Secrets.Paladin.CompetitiveSpirit, reason: .opponentTurnStarted)
                if game.opponentMinionCount >= 2 && freeSpaceOnBoard {
                    exclude(cardId: CardIds.Secrets.Hunter.OpenTheCages, reason: .opponentTurnStarted)
                }
            }
        }
        if isCurrentPlayer && (turn > _lastStartOfTurnDamageCheck) {
            _lastStartOfTurnDamageCheck = turn
            let turnToCheck = turn - (game.playerEntity?.has(tag: .first_player) ?? false ? 0 : 1)
            if !opponentTookDamageDuringTurns.contains(turnToCheck) {
                exclude(cardId: CardIds.Secrets.Mage.RiggedFaireGame, reason: .enemyHeroNotDamaged)
            }
        }
    }
    
    func handlePlayerTurnStart() {
        savedSecrets.removeAll()
    }
    
    func handleOpponentTurnStart() {
        if game.player.cardsPlayedThisTurn.count > 0 {
            exclude(cardId: CardIds.Secrets.Rogue.Plagiarize, reason: .cardsPlayedInTurn)
        }
    }
    
    func handlePlayerTurnEnded(mana: Int) {
        if mana == 0 {
            exclude(cardId: CardIds.Secrets.Hunter.HiddenMeaning, reason: .turnEndedNoMana)
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

    func handleCardPlayed(entity: Entity, parentCardId: String) {
        guard handleAction else { return }
        
        savedSecrets.removeAll()

        var exclude: [(card: MultiIdCard, reason: SecretExclusionReason?)] = []
        
        if let player = game.playerEntity, player.has(tag: .num_cards_played_this_turn) && (player[.num_cards_played_this_turn] >= 3) {
            exclude.append((CardIds.Secrets.Hunter.MotionDenied, .threeCardsPlayed))
            if freeSpaceOnBoard {
                exclude.append((CardIds.Secrets.Hunter.RatTrap, .threeCardsPlayed))
                exclude.append((CardIds.Secrets.Paladin.GallopingSavior, .threeCardsPlayed))
            }
            
            if freeSpaceInHand {
                exclude.append((CardIds.Secrets.Paladin.HiddenWisdom, .threeCardsPlayed))
            }
        }
        
        if entity[.num_turns_in_hand] == 1 {
            if freeSpaceInHand {
                exclude.append((CardIds.Secrets.Mage.AzeriteVein, .cardFromThisTurnPlayed))
            }
        }
        
        if entity.isSpell {
            if parentCardId == CardIds.Collectible.Rogue.SparkjoyCheat {
                return
            }
            // Two Counterspells cannot be active at once, so casting a spell rules it out now
            exclude.append((CardIds.Secrets.Mage.Counterspell, .spellCast))

            // The other reactions wait for the spell to resolve, in case Counterspell or Ice Trap
            // stopped it
            var candidates = [CardIds.Secrets.Hunter.IceTrap, CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Paladin.OhMyYogg]
            
            if game.opponentMinionCount > 0 {
                candidates.append(CardIds.Secrets.Paladin.NeverSurrender)
            }

            if game.opponentHandCount < 10 {
                candidates.append(CardIds.Secrets.Rogue.DirtyTricks)
                candidates.append(CardIds.Secrets.Mage.ManaBind)
            }

            if freeSpaceOnBoard {
                candidates.append(CardIds.Secrets.Hunter.CatTrick)
                candidates.append(CardIds.Secrets.Mage.NetherwindPortal)
                candidates.append(CardIds.Secrets.Rogue.StickySituation)
            }

            if game.playerMinionCount > 0 {
                candidates.append(CardIds.Secrets.Hunter.PressurePlate)
            }
            let snapshot = SpellCastSnapshot(spellEntityId: entity.id, secretIds: activeSecretIds, turn: game.turnNumber(),
                                             candidates: candidates, freeSpaceOnBoard: freeSpaceOnBoard,
                                             targetEntityId: entity.has(tag: .card_target) ? entity[.card_target] : nil)
            pendingLock.around { pendingChecks.append(.spellCast(snapshot)) }
        } else if entity.isMinion && game.playerMinionCount > 3 {
            exclude.append((CardIds.Secrets.Paladin.SacredTrial, .minionPlayed))
        }
        
        if entity.isWeapon {
            exclude.append((CardIds.Secrets.Hunter.BargainBin, .weaponPlayed))
        }
        applyExclusions(exclude, secretIds: nil, turn: nil, invokeCallback: true)
    }
    
    func onNewSecret(secret: Secret) {
        if secret.entity[GameTag.class] == CardClass.allCases.firstIndex(of: .hunter) {
            entititesInHandOnMinionsPlayed.removeAll()
        }
    }
    
    func handleCardDrawn(entity: Entity) {
        guard handleAction else { return }

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
    
    func onEntityRevealedAsMinion(entity: Entity) {
        if entititesInHandOnMinionsPlayed.contains(entity) && entity.isMinion {
            exclude(cardId: CardIds.Secrets.Hunter.HiddenCache, reason: .minionPlayed)
        }
    }
    
    func onNewBlock() {
        entityDamageDealtHistory.removeAll()
    }
    
    func entityDamage(dealer: Entity, target: Entity, damage: Int) {
        if target.isHero && target.isControlled(by: game.opponent.id) {
            if !target.has(tag: .immune) {
                exclude(cardIds: [CardIds.Secrets.Paladin.EyeForAnEye, CardIds.Secrets.Rogue.Evasion], reason: .enemyHeroDamaged)
                opponentTookDamageDuringTurns.append(game.turnNumber())
            }
        }
        if dealer.isMinion && dealer.isControlled(by: game.player.id) {
            if let dict = entityDamageDealtHistory[dealer.id] {
                if let hist = dict[target.id] {
                    dict[target.id] = hist + damage
                } else {
                    dict[target.id] = damage
                }
            } else {
                let dict = SynchronizedDictionary<Int, Int>()
                entityDamageDealtHistory[dealer.id] = dict
                dict[target.id] = damage
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
