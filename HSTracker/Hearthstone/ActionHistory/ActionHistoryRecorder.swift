//
//  ActionHistoryRecorder.swift
//  HSTracker
//
//  Builds the in-match action history from the raw Power.log stream: the block stack, every tag
//  change with its previous value, and entity reveals and transforms. HDT has no counterpart; the
//  closest thing is the client's own history bar, which groups the same way (one row per action,
//  with the damage, deaths and summons it caused underneath).
//
//  The recorder deliberately does not use the tracker's semantic hooks (entityDamage, minion death,
//  hero power, secret triggers). They skip heals and zero-damage updates, fire only on the player's
//  own turn or only for the first hero power, and turnStart runs on a global queue, so turn
//  boundaries taken from them race the log. Instead it taps the parser directly and keeps its own
//  TURN / STEP / CURRENT_PLAYER / MULLIGAN_STATE caches. Every tap is O(1): no Game.gameEntity,
//  playerEntity or isMulliganDone, which scan all entities.
//
//  Threading: the parser calls in on the log-reader queue, the overlay takes snapshots on main and
//  Game restores an interrupted game from a global queue, so all state sits behind one lock.
//  onChanged is coalesced so a Power.log replay after an HSTracker restart publishes a few times,
//  not once per block.
//

import Foundation

final class ActionHistoryRecorder {
    typealias Entities = SynchronizedDictionary<Int, Entity>

    /// How old an interrupted game may be for a reconnect to restore it.
    static let reconnectWindow: TimeInterval = 20 * 60
    static let publishDelay: TimeInterval = 0.25

    /// Called on the main thread, at most once per `publishDelay`, after the history changed.
    /// Set it before the log reader starts.
    var onChanged: (() -> Void)?
    /// The current game type. Battlegrounds and Mercenaries are not recorded. Only asked when a
    /// block starts and until a known type has been seen, because Game.currentGameType can scan
    /// entities for Battlegrounds Duos.
    var gameTypeProvider: (() -> GameType)?

    private let lock = UnfairLock()

    // MARK: - Match state

    private var openNodes: [Node] = []
    private var turns: [TurnState] = []
    // The last top-level action of the turn. DEATHS blocks and triggers that resolve right after it
    // at top level (an attack's deaths and deathrattles) are shown under it, until the step or turn
    // changes or a new action starts.
    private var lastTopLevel: Node?
    private var rawTurn = 0
    private var step = 0
    private weak var currentPlayerEntity: Entity?
    private var mulliganDoneEntities = Set<Int>()
    // Weapon entity id per controller, for "attacked with"
    private var weaponByController: [Int: Int] = [:]
    // Cards a destroy effect marked with TO_BE_DESTROYED. The client sets the tag back to 0 inside
    // the DEATHS block, right before the card moves to the graveyard, so it has to be remembered.
    private var markedForDestruction = Set<Int>()
    private var localPlayerId = 0
    // Something was recorded before the local player was known; snapshots resolve it
    private var hasUndetermined = false
    private var hasGameEnded = false
    private var excludedGameType: Bool?
    private var interrupted: InterruptedGame?
    // A zone move from a FULL_ENTITY / SHOW_ENTITY body. ZONE is listed before CARDTYPE and
    // CONTROLLER there, so the move is looked at once the body is over.
    private var pendingCreationZone: Tap?

    // Never reset: entry ids must stay unique when an interrupted game is restored
    private var nextEntryId = 1
    private var nextTurnUid = 1
    private var version = 0
    private var publishScheduled = false

    init() {
    }

    // MARK: - Parser API (log-reader queue)

    /// BLOCK_START. `blockId` is the parser's Block.id, used to match the BLOCK_END.
    func blockStarted(blockId: Int, info: HistoryBlockInfo, localPlayerId: Int, entities: Entities, time: Date) {
        lock.around {
            updateLocalPlayer(localPlayerId)
            flushPendingCreationZone()
            if isExcludedGameType() {
                openNodes.removeAll()
                lastTopLevel = nil
                return
            }
            let parent = openNodes.last
            let isStartOfGame = (parent?.isStartOfGame ?? false) || (info.triggerKeyword?.hasPrefix("START_OF_GAME") ?? false)
            let suppressesEffects = (parent?.suppressesEffects ?? false) || info.blockType == "GAME_RESET"
            let mayTitle = !(parent?.suppressesEffects ?? false) && (isMulliganDone || isStartOfGame)
            let source = info.sourceEntityId.flatMap { entities[$0] }

            var type: HistoryActionType?
            var parentSink = parent?.sink
            if mayTitle {
                (type, parentSink) = classify(info: info, source: source, inheritedSink: parent?.sink)
            }

            let node = Node(blockId: blockId, info: info, time: time, parentSink: parentSink, type: type,
                            entryId: type != nil ? takeEntryId() : 0, rawTurn: rawTurn, activePlayerId: currentPlayerId(),
                            isStartOfGame: isStartOfGame, suppressesEffects: suppressesEffects)
            if type != nil, let targetId = info.targetEntityId {
                setTarget(of: node, targetId, entities: entities)
            }
            if type == .attack, let source, source.isHero {
                node.weaponEntityId = weaponByController[source[.controller]]
            }
            openNodes.append(node)

            // The client flips a triggered Secret face up before its effect resolves
            if info.blockType == "TRIGGER", info.triggerKeyword == "SECRET", let source {
                annotateRevealedSecret(source, entities: entities)
            }
        }
    }

    /// BLOCK_END, called before the parser pops the block. Also ends any block above it that never
    /// got its own BLOCK_END.
    func blockEnded(blockId: Int?, localPlayerId: Int, entities: Entities) {
        lock.around {
            updateLocalPlayer(localPlayerId)
            flushPendingCreationZone()
            guard let blockId, let index = openNodes.lastIndex(where: { $0.blockId == blockId }) else {
                return
            }
            while openNodes.count > index {
                let node = openNodes.removeLast()
                end(node, entities: entities)
            }
        }
    }

    /// Every tag change, right after the parser stored the new value (TagChangeHandler.tagChange).
    /// - Parameters:
    ///   - isCreationTag: the tag came from a FULL_ENTITY / SHOW_ENTITY / CHANGE_ENTITY body.
    ///   - hideShowEntities: the current block had META_DATA OVERRIDE_HISTORY.
    func tagChanged(entity: Entity, tag: GameTag, prevValue: Int, value: Int, isCreationTag: Bool,
                    hideShowEntities: Bool, localPlayerId: Int, entities: Entities) {
        switch tag {
        case .zone, .damage, .armor, .controller, .proposed_defender, .card_target, .turn, .step,
             .current_player, .mulligan_state, .frozen, .silenced, .divine_shield, .to_be_destroyed:
            break
        default:
            return
        }
        lock.around {
            updateLocalPlayer(localPlayerId)
            if excludedGameType == true {
                return
            }
            if let pending = pendingCreationZone, !(isCreationTag && pending.entity === entity) {
                flushPendingCreationZone()
            }
            let tap = Tap(entity: entity, prevValue: prevValue, value: value, isCreationTag: isCreationTag,
                          hideShowEntities: hideShowEntities, entities: entities)
            switch tag {
            case .turn:
                if isGameEntity(entity) {
                    turnChanged(value)
                }
            case .step:
                if isGameEntity(entity) {
                    step = value
                    lastTopLevel = nil
                }
            case .current_player:
                if value == 1 {
                    currentPlayerEntity = entity
                }
            case .mulligan_state:
                if value == Mulligan.done.rawValue {
                    mulliganDoneEntities.insert(entity.id)
                } else {
                    mulliganDoneEntities.remove(entity.id)
                }
            case .zone:
                if isCreationTag {
                    flushPendingCreationZone()
                    pendingCreationZone = tap
                } else {
                    zoneChanged(tap)
                }
            case .proposed_defender:
                if !isCreationTag && value > 0 && isGameEntity(entity),
                   let attack = openNodes.last(where: { $0.type == .attack }) {
                    setTarget(of: attack, value, entities: entities)
                }
            case .to_be_destroyed:
                if value > 0 {
                    markedForDestruction.insert(entity.id)
                }
            case .card_target:
                if value > 0, let node = openNodes.last(where: { $0.type != nil && $0.info.sourceEntityId == entity.id }) {
                    setTarget(of: node, value, entities: entities)
                }
            default:
                effectTagChanged(tag, tap)
            }
        }
    }

    /// CHANGE_ENTITY, after the parser updated `info.latestCardId`. `fromCardId` is the card the
    /// entity showed before, since `entity.cardId` is not overwritten on a transform.
    func entityChanged(entity: Entity, fromCardId: String?, toCardId: String, hideShowEntities: Bool,
                       localPlayerId: Int, entities: Entities) {
        lock.around {
            updateLocalPlayer(localPlayerId)
            flushPendingCreationZone()
            // Board transforms only: hand cards changing every turn (Shifter Zerus, Corrupt) and
            // hero rerolls would be noise.
            guard canRecordEffect, !openNodes.isEmpty, entity.isInPlay, !entity.isEnchantment,
                  let fromCardId, !fromCardId.isBlank, !toCardId.isBlank, fromCardId != toCardId else {
                return
            }
            guard let before = makeRef(entity, .transformed, hideShowEntities: hideShowEntities, displayedCardId: fromCardId,
                                       entities: entities) else {
                return
            }
            let after = makeRef(entity, .transformed, hideShowEntities: hideShowEntities, entities: entities)
            record(EffectRecord(kind: .transformed, target: before, amount: nil, detailCardId: after?.cardId))
        }
    }

    /// SHOW_ENTITY, after the parser updated the entity's card and hidden state.
    func entityShown(entity: Entity, localPlayerId: Int, entities: Entities) {
        lock.around {
            updateLocalPlayer(localPlayerId)
            flushPendingCreationZone()
            // A Secret shown after it left play, or one the local player took over (Kezan Mystic) and
            // now sees. One still in the opponent's Secret zone is handled by its TRIGGER block or its
            // move to the graveyard.
            if excludedGameType != true && entity.isSecret
                && (entity.isInGraveyard || (entity.isInSecret && self.localPlayerId > 0 && entity.isControlled(by: self.localPlayerId))) {
                annotateRevealedSecret(entity, entities: entities)
            }
        }
    }

    /// CREATE_GAME. Block ids restart, but after a Hearthstone reconnect it is still the same match,
    /// so the turns stay. The game state caches are rebuilt from the CREATE_GAME dump.
    func parserReset() {
        lock.around {
            pendingCreationZone = nil
            openNodes.removeAll()
            lastTopLevel = nil
            resetGameStateCaches()
        }
    }

    // MARK: - Game API

    /// Game.updatePlayers, once the mirror has told which player is local. The parser hooks pass the
    /// id too, but a quiet stretch of the log would otherwise leave a replayed history unresolved.
    func localPlayerDetermined(_ id: Int) {
        lock.around {
            updateLocalPlayer(id)
        }
    }

    /// Game.reset. A game that has not ended is kept aside, in case this is a Hearthstone reconnect.
    func reset(opponentName: String?, now: Date = Date()) {
        lock.around {
            if hasGameEnded {
                interrupted = nil
            } else if !turns.isEmpty {
                interrupted = InterruptedGame(turns: turns, opponentName: opponentName, date: now, hasUndetermined: hasUndetermined)
            }
            pendingCreationZone = nil
            turns.removeAll()
            openNodes.removeAll()
            lastTopLevel = nil
            resetGameStateCaches()
            localPlayerId = 0
            hasUndetermined = false
            hasGameEnded = false
            excludedGameType = nil
            markChanged()
        }
    }

    /// Game.handleGameReconnect. Puts the turns of the interrupted game back in front of the current
    /// ones, with a "reconnected" marker, if that game is recent and was against the same opponent.
    /// Otherwise the interrupted game is dropped.
    @discardableResult
    func restoreInterruptedIfReconnect(opponentName: String?, now: Date = Date()) -> Bool {
        return lock.around { () -> Bool in
            guard let saved = interrupted else {
                return false
            }
            guard now.timeIntervalSince(saved.date) <= ActionHistoryRecorder.reconnectWindow else {
                interrupted = nil
                return false
            }
            // The mirror may not have named the opponent yet; a later call can still match
            guard let nameKey = ActionHistoryRecorder.playerNameKey(opponentName) else {
                return false
            }
            interrupted = nil
            guard nameKey == ActionHistoryRecorder.playerNameKey(saved.opponentName), var lastSaved = saved.turns.last else {
                return false
            }
            hasUndetermined = hasUndetermined || saved.hasUndetermined
            var restored = Array(saved.turns.dropLast())
            let marker = HistoryEntry(id: takeEntryId(), rawTurn: lastSaved.rawTurn, turn: ActionHistoryRecorder.turnNumber(lastSaved.rawTurn),
                                      activeSide: side(forPlayerId: lastSaved.activePlayerId), type: .reconnected, time: now,
                                      activePlayerId: lastSaved.activePlayerId)
            lastSaved.entries.append(marker)
            var current = turns
            if let first = current.first, first.rawTurn == lastSaved.rawTurn {
                // Same turn on both sides of the disconnect. Keep the current uid, open blocks point to it.
                lastSaved.uid = first.uid
                lastSaved.header += first.header
                lastSaved.entries += first.entries
                current.removeFirst()
            }
            restored.append(lastSaved)
            turns = restored + current
            lastTopLevel = nil
            markChanged()
            return true
        }
    }

    /// Game.handleEndGame. The history stays visible on the end screen until the next reset.
    func gameEnded() {
        lock.around {
            hasGameEnded = true
            interrupted = nil
            lastTopLevel = nil
            markChanged()
        }
    }

    func snapshot() -> ActionHistorySnapshot {
        return lock.around { () -> ActionHistorySnapshot in
            let built = turns.map { state -> HistoryTurn in
                var header = ActionHistoryRecorder.aggregate(state.header)
                var entries = state.entries
                if hasUndetermined {
                    header = resolve(header)
                    entries = entries.map(resolve)
                }
                return HistoryTurn(rawTurn: state.rawTurn, turn: ActionHistoryRecorder.turnNumber(state.rawTurn),
                                   side: side(forPlayerId: state.activePlayerId), header: header, entries: entries)
            }
            return ActionHistorySnapshot(turns: built, version: version)
        }
    }

    /// The part of a player name that stays the same whether it was read with or without the
    /// BattleTag number (MatchInfo's name, then updatePlayers' BattleTag). Nil when unknown.
    static func playerNameKey(_ name: String?) -> String? {
        guard var key = name?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        if let hash = key.lastIndex(of: "#"), key[key.index(after: hash)...].allSatisfy({ $0.isNumber }) {
            key = String(key[..<hash])
        }
        return key.isEmpty ? nil : key
    }

    static func isExcluded(gameType: GameType) -> Bool {
        switch gameType {
        case .gt_battlegrounds, .gt_battlegrounds_friendly, .gt_battlegrounds_ai_vs_ai, .gt_battlegrounds_player_vs_ai,
             .gt_battlegrounds_duo, .gt_battlegrounds_duo_vs_ai, .gt_battlegrounds_duo_friendly, .gt_battlegrounds_duo_ai_vs_ai,
             .gt_mercenaries_pvp, .gt_mercenaries_pve, .gt_mercenaries_pve_coop, .gt_mercenaries_ai_vs_ai, .gt_mercenaries_friendly:
            return true
        default:
            return false
        }
    }

    static func turnNumber(_ rawTurn: Int) -> Int {
        return (rawTurn + 1) / 2
    }

    // MARK: - Blocks

    /// The title of a new block, and the titled node its effects and titled children go to.
    private func classify(info: HistoryBlockInfo, source: Entity?,
                          inheritedSink: Node?) -> (HistoryActionType?, Node?) {
        let isTopLevel = inheritedSink == nil
        // Actions the player starts close the previous action's resolution window
        func action(_ type: HistoryActionType) -> (HistoryActionType?, Node?) {
            if isTopLevel {
                lastTopLevel = nil
            }
            return (type, inheritedSink)
        }
        // Blocks that resolve an action: at top level they belong to the action that just ended
        let resolvingSink = inheritedSink ?? openLastTopLevel

        switch info.blockType {
        case "PLAY":
            if source?.isHeroPower == true {
                return action(.heroPower)
            }
            if let source, source.isLocation, source.isInPlay {
                return action(.useLocation)
            }
            return action(.play)
        case "ATTACK":
            return action(.attack)
        case "DECK_ACTION":
            // Trading, Prepare or Forge from the hand: the player's own action, not a reaction to the
            // previous one. Its POWER block (the trade's draw) merges into it below.
            return action(.deckAction)
        case "FATIGUE":
            return action(.fatigue)
        case "JOUST", "REVEAL_CARD":
            return action(.reveal)
        case "GAME_RESET":
            return action(.gameReset)
        case "DEATHS":
            if !isTopLevel {
                return (nil, inheritedSink)
            }
            if let resolvingSink {
                return (nil, resolvingSink)
            }
            return (.deaths, nil)
        default:
            break
        }

        // TRIGGER, POWER, RITUAL and anything newer
        guard !info.isBareEntity, info.sourceEntityId != nil else {
            // The game or a player: turn-start draws, step changes, weapon durability. Effects go to
            // the enclosing action, or to the turn header.
            return (nil, inheritedSink)
        }
        let keyword = info.triggerKeyword
        // A battlecry, a spell's body or a hero power's effect is a POWER block under the PLAY
        // block of the same card; lifesteal and "whenever this attacks" are triggers of the
        // attacker. They are the action itself, not a separate row. Secrets and deathrattles stay
        // separate rows.
        if let resolvingSink, resolvingSink.info.sourceEntityId == info.sourceEntityId,
           keyword != "SECRET", keyword != "DEATHRATTLE", info.blockType == "POWER" || info.blockType == "TRIGGER" {
            return (nil, resolvingSink)
        }
        let type: HistoryActionType
        switch (info.blockType, keyword) {
        case ("POWER", _):
            type = .power
        case ("TRIGGER", "SECRET"?):
            type = .secret
        case ("TRIGGER", "DEATHRATTLE"?):
            type = .deathrattle
        default:
            type = .trigger
        }
        return (type, resolvingSink)
    }

    private var openLastTopLevel: Node? {
        guard let lastTopLevel, lastTopLevel.rawTurn == rawTurn else {
            return nil
        }
        return lastTopLevel
    }

    private func end(_ node: Node, entities: Entities) {
        resolvePendingEnchantments(of: node, entities: entities)
        guard let type = node.type else {
            return
        }
        buildRefs(of: node, entities: entities)
        // Triggers with nothing to show (TRIGGER_VISUAL, counters) are dropped. Actions, rewinds and
        // Secrets are always worth a row, even when a Secret's effect left no tag behind (Counterspell).
        if node.isEmpty {
            switch type {
            case .trigger, .power, .deathrattle, .deaths:
                if node.parentSink == nil && !node.promoted.isEmpty {
                    // The Secrets it set off still get their rows
                    let turnIndex = ensureTurn(node.rawTurn)
                    turns[turnIndex].entries += node.promoted
                    markChanged()
                }
                return
            default:
                break
            }
        }
        if let parent = node.parentSink {
            if type == .secret {
                promote(entry(from: node), from: parent)
                return
            }
            parent.children.append(entry(from: node))
            if parent.isFinished {
                refinalize(parent)
            }
            return
        }
        let turnIndex = ensureTurn(node.rawTurn)
        turns[turnIndex].entries.append(entry(from: node))
        turns[turnIndex].entries += node.promoted
        node.promoted.removeAll()
        node.turnUid = turns[turnIndex].uid
        node.isFinished = true
        lastTopLevel = type == .gameReset ? nil : node
        markChanged()
    }

    /// A Secret always gets a row of its own, even though it fires inside the play or attack that
    /// set it off: it is the other player's action, and folded under the row that provoked it the
    /// panel would not show that a Secret went off at all. It is listed right after that action.
    private func promote(_ secret: HistoryEntry, from parent: Node) {
        var root = parent
        while let up = root.parentSink {
            root = up
        }
        guard root.isFinished else {
            root.promoted.append(secret)
            return
        }
        // A finished parent is the last top-level action (see classify), so its turn ends with it
        // and whatever was already promoted from it
        guard let turnIndex = turns.lastIndex(where: { $0.uid == root.turnUid }) else {
            return
        }
        turns[turnIndex].entries.append(secret)
        markChanged()
    }

    /// Entries are value snapshots; an action that received late deaths or triggers is rebuilt in place.
    private func refinalize(_ node: Node) {
        guard let turnIndex = turns.lastIndex(where: { $0.uid == node.turnUid }),
              let entryIndex = turns[turnIndex].entries.lastIndex(where: { $0.id == node.entryId }) else {
            return
        }
        // Keep Secret annotations added after the entry was built
        let revealedLater = turns[turnIndex].entries[entryIndex].revealedLater
        var rebuilt = entry(from: node)
        for revealed in revealedLater where !rebuilt.revealedLater.contains(where: { $0.entityId == revealed.entityId }) {
            rebuilt.revealedLater.append(revealed)
        }
        turns[turnIndex].entries[entryIndex] = rebuilt
        markChanged()
    }

    private func entry(from node: Node) -> HistoryEntry {
        var type = node.type ?? .trigger
        if type == .deckAction && node.movedSourceToDeck {
            type = .trade
        }
        return HistoryEntry(id: node.entryId,
                            rawTurn: node.rawTurn,
                            turn: ActionHistoryRecorder.turnNumber(node.rawTurn),
                            activeSide: side(forPlayerId: node.activePlayerId),
                            type: type,
                            triggerKeyword: ActionHistoryRecorder.meaningfulKeyword(node.info.triggerKeyword),
                            source: node.sourceRef,
                            target: node.targetRef,
                            weapon: node.weaponRef,
                            effects: ActionHistoryRecorder.aggregate(node.records),
                            children: node.children,
                            revealedLater: node.revealedLater,
                            time: node.time,
                            activePlayerId: node.activePlayerId)
    }

    private static func meaningfulKeyword(_ keyword: String?) -> String? {
        guard let keyword, !keyword.isEmpty, keyword != "0", keyword != "TAG_NOT_SET" else {
            return nil
        }
        return keyword
    }

    /// Source, target and weapon refs are built once, when the block ends: an opponent's played card
    /// is only shown by the SHOW_ENTITY inside its PLAY block, and a Secret it played must still be
    /// in the Secret zone to stay anonymous.
    private func buildRefs(of node: Node, entities: Entities) {
        guard !node.refsBuilt else {
            return
        }
        node.refsBuilt = true
        if let sourceId = node.info.sourceEntityId, let source = entities[sourceId] {
            node.sourceRef = sourceRef(source, type: node.type, entities: entities)
        }
        if let targetId = node.targetEntityId, let target = entities[targetId] {
            // The target as it was when it was chosen: a Polymorph's target is the minion, not the
            // Sheep it became, and a target that died since is still named. The ref at the end of
            // the block only helps when the card was not public yet at that point.
            if let chosen = node.targetRef, chosen.entityId == targetId, !chosen.isHidden {
                // keep it
            } else {
                let context: HistoryRefContext = node.type == .attack ? .attackTarget : .inPlayTarget
                node.targetRef = ref(target, context, entities: entities)
            }
        }
        if let weaponId = node.weaponEntityId, let weapon = entities[weaponId] {
            node.weaponRef = ref(weapon, .attackSource, entities: entities)
        }
    }

    private func sourceRef(_ source: Entity, type: HistoryActionType?, entities: Entities) -> HistoryCardRef? {
        if source.isEnchantment {
            // An enchantment's trigger is shown as the card that created it, when that card is public
            if let creator = entities[source[.creator]], !creator.isEnchantment,
               let creatorRef = ref(creator, .triggerSource, entities: entities), creatorRef.cardId != nil {
                return creatorRef
            }
            return ref(source, .enchantment, entities: entities)
        }
        let context: HistoryRefContext
        switch type {
        case .play?, .heroPower?, .useLocation?:
            context = .playSource
        case .attack?:
            context = .attackSource
        case .secret?:
            context = .secretTriggerSource
        case .reveal?:
            context = .reveal
        default:
            context = .triggerSource
        }
        return ref(source, context, entities: entities)
    }

    private func setTarget(of node: Node, _ targetId: Int, entities: Entities) {
        node.targetEntityId = targetId
        if let target = entities[targetId] {
            node.targetRef = ref(target, node.type == .attack ? .attackTarget : .inPlayTarget, entities: entities)
        }
    }

    // MARK: - Tags

    private struct Tap {
        let entity: Entity
        let prevValue: Int
        let value: Int
        let isCreationTag: Bool
        let hideShowEntities: Bool
        let entities: Entities
    }

    private func turnChanged(_ value: Int) {
        rawTurn = value
        lastTopLevel = nil
        markedForDestruction.removeAll()
        if isMulliganDone && value > 0 {
            if turns.last?.rawTurn != value {
                _ = ensureTurn(value)
                markChanged()
            }
        }
    }

    private func flushPendingCreationZone() {
        if let pending = pendingCreationZone {
            pendingCreationZone = nil
            zoneChanged(pending)
        }
    }

    private func zoneChanged(_ tap: Tap) {
        let entity = tap.entity
        let from = Zone(rawValue: tap.prevValue) ?? .invalid
        let to = Zone(rawValue: tap.value) ?? .invalid
        let wasMarkedForDestruction = from == .play && markedForDestruction.remove(entity.id) != nil

        if entity.isWeapon {
            let controller = entity[.controller]
            if to == .play {
                weaponByController[controller] = entity.id
            } else if from == .play && weaponByController[controller] == entity.id {
                weaponByController[controller] = nil
            }
        }

        // The initial deal and the CREATE_GAME dump after a reconnect come as creation tags outside
        // any block
        guard canRecordEffect, !(tap.isCreationTag && openNodes.isEmpty) else {
            return
        }

        if entity.isEnchantment {
            queueEnchantment(tap)
            return
        }
        let cardType = entity[.cardtype]
        if cardType == CardType.game.rawValue || cardType == CardType.player.rawValue || entity.isHeroPower {
            return
        }

        switch (from, to) {
        case (.deck, .hand):
            if let target = ref(entity, .drew, tap) {
                record(EffectRecord(kind: target.isHidden ? .drewUnknown : .drew, target: target, amount: 1, detailCardId: nil))
            }
        case (.invalid, .hand), (.setaside, .hand), (.removedfromgame, .hand), (.graveyard, .hand):
            recordEffect(.generated, entity, .generated, tap)
        case (.hand, .graveyard):
            // Only the graveyard is a discard. Cards set aside or removed from the hand are the
            // mechanics of another effect (Solitos' pieces combining, Prepare) that the client does
            // not show as a discard.
            if !isActing(entity) {
                recordEffect(.discarded, entity, .discarded, tap)
            }
        case (.deck, .graveyard):
            // Classic Tracking discards the cards it did not keep. The log names them, and
            // TagChangeActions.zoneChangeFromDeck hides them from the tracker right after this tap, but
            // the client never shows them.
            let hidden = tap.hideShowEntities || isInside(cardId: TagChangeActions.ClassicTrackingCardId, tap.entities)
            recordEffect(.burned, entity, .burned, tap, hideShowEntities: hidden)
        case (_, .deck):
            if from != .deck {
                if let deckAction = openNodes.last(where: { $0.info.blockType == "DECK_ACTION" && $0.info.sourceEntityId == entity.id }) {
                    // A trade: the card going into the deck is the action itself
                    deckAction.movedSourceToDeck = true
                } else if let target = ref(entity, .shuffled, tap, sourceController: sinkSourceController(tap.entities)) {
                    record(EffectRecord(kind: .shuffledIntoDeck, target: target, amount: nil, detailCardId: nil))
                }
            }
        case (.play, .hand):
            recordEffect(.returnedToHand, entity, .returnedToHand, tap)
        case (_, .play):
            if entity.isWeapon {
                if !isActing(entity) {
                    recordEffect(.equipped, entity, .equipped, tap)
                }
            } else if (entity.isMinion || entity.isLocation) && from != .play && !isActing(entity) {
                recordEffect(.summoned, entity, .summoned, tap)
            }
        case (.play, .graveyard):
            if entity.isMinion || (entity.isHero && entity.health <= 0) {
                let destroyed = wasMarkedForDestruction || entity.has(tag: .to_be_destroyed)
                recordEffect(destroyed ? .destroyed : .died, entity, .died, tap)
            } else if entity.isWeapon || entity.isLocation {
                recordEffect(.destroyed, entity, .died, tap)
            }
        case (.secret, .graveyard):
            if entity.isSecret {
                annotateRevealedSecret(entity, entities: tap.entities)
            }
        case (_, .secret):
            // Quests, Sigils and Objectives are public cards; only a Secret, or a card too hidden to
            // tell, is "played a Secret"
            if from != .secret && !isActing(entity) && (entity.isSecret || !entity.hasCardId) {
                recordEffect(.secretPlayed, entity, .secretPlayed, tap)
            }
        default:
            break
        }
    }

    private func effectTagChanged(_ tag: GameTag, _ tap: Tap) {
        let entity = tap.entity
        // Creation tags repeat what the entity already had (SHOW_ENTITY, CHANGE_ENTITY bodies)
        guard !tap.isCreationTag, canRecordEffect, !entity.isEnchantment else {
            return
        }
        let delta = tap.value - tap.prevValue
        switch tag {
        case .damage:
            // Weapon durability and location uses are DAMAGE too
            guard entity.isMinion || entity.isHero else {
                return
            }
            if delta > 0 {
                recordEffect(.damage, entity, .inPlayTarget, tap, amount: delta)
            } else if entity[.zone] == Zone.play.rawValue {
                // A reset after death or a return to hand is not a heal
                recordEffect(.heal, entity, .inPlayTarget, tap, amount: -delta)
            }
        case .armor:
            guard entity.isHero else {
                return
            }
            recordEffect(delta > 0 ? .armorGained : .armorLost, entity, .inPlayTarget, tap, amount: abs(delta))
        case .controller:
            if tap.prevValue > 0 && (entity[.zone] == Zone.play.rawValue || entity[.zone] == Zone.secret.rawValue) {
                recordEffect(.stolen, entity, .stolen, tap)
                // The local player now sees a Secret they took from the opponent
                if entity.isSecret && entity.isInSecret && localPlayerId > 0 && tap.value == localPlayerId {
                    annotateRevealedSecret(entity, entities: tap.entities)
                }
            }
        case .frozen:
            if tap.prevValue == 0 && tap.value > 0 && entity.isInPlay {
                recordEffect(.frozen, entity, .inPlayTarget, tap)
            }
        case .silenced:
            if tap.prevValue == 0 && tap.value > 0 && entity.isInPlay {
                recordEffect(.silenced, entity, .inPlayTarget, tap)
            }
        case .divine_shield:
            if tap.prevValue > 0 && tap.value == 0 && entity.isInPlay {
                recordEffect(.divineShieldLost, entity, .inPlayTarget, tap)
            }
        default:
            break
        }
    }

    /// Whether `entity` is the card of an open PLAY or DECK_ACTION block, whose own zone moves are the
    /// action itself.
    private func isActing(_ entity: Entity) -> Bool {
        return openNodes.contains { ($0.info.blockType == "PLAY" || $0.info.blockType == "DECK_ACTION") && $0.info.sourceEntityId == entity.id }
    }

    /// Whether any open block comes from a card with this cardId.
    private func isInside(cardId: String, _ entities: Entities) -> Bool {
        return openNodes.contains { node in
            node.info.sourceEntityId.flatMap { entities[$0] }?.cardId == cardId
        }
    }

    /// The controller of the card whose action is being recorded, for shuffles.
    private func sinkSourceController(_ entities: Entities) -> Int? {
        guard let sourceId = openNodes.last?.sink?.info.sourceEntityId, let source = entities[sourceId] else {
            return nil
        }
        return source[.controller]
    }

    // An enchantment entering play as the effect of a POWER or TRIGGER block of the card that
    // created it: a battlecry buff, a spell's buff, a triggered buff. Aura enchantments are applied
    // straight in the PLAY block, or by a card other than the block's source, and are skipped.
    // ATTACHED can follow ZONE in a FULL_ENTITY body, so it is resolved when the block ends.
    private func queueEnchantment(_ tap: Tap) {
        guard tap.value == Zone.play.rawValue, let node = openNodes.last, node.sink != nil, !node.info.isBareEntity,
              node.info.blockType == "POWER" || node.info.blockType == "TRIGGER" else {
            return
        }
        node.pendingEnchantments.append((entityId: tap.entity.id, hideShowEntities: tap.hideShowEntities))
    }

    private func resolvePendingEnchantments(of node: Node, entities: Entities) {
        guard !node.pendingEnchantments.isEmpty, let sink = node.sink else {
            return
        }
        for pending in node.pendingEnchantments {
            guard let enchantment = entities[pending.entityId], enchantment.isInPlay,
                  enchantment[.creator] == node.info.sourceEntityId,
                  let attached = entities[enchantment[.attached]], !attached.isEnchantment,
                  attached[.cardtype] != CardType.game.rawValue, attached[.cardtype] != CardType.player.rawValue,
                  let target = makeRef(attached, .inPlayTarget, hideShowEntities: pending.hideShowEntities, entities: entities),
                  !target.isHidden,
                  let enchantmentRef = makeRef(enchantment, .enchantment, hideShowEntities: pending.hideShowEntities, entities: entities),
                  let enchantmentCardId = enchantmentRef.cardId else {
                continue
            }
            record(EffectRecord(kind: .enchanted, target: target, amount: nil, detailCardId: enchantmentCardId), sink: sink)
        }
        node.pendingEnchantments.removeAll()
    }

    // MARK: - Effects

    private struct EffectRecord {
        let kind: HistoryEffectKind
        let target: HistoryCardRef
        let amount: Int?
        let detailCardId: String?
    }

    private var canRecordEffect: Bool {
        guard excludedGameType != true else {
            return false
        }
        if let top = openNodes.last {
            return !top.suppressesEffects && (isMulliganDone || top.isStartOfGame)
        }
        return isMulliganDone
    }

    /// Every ref the recorder stores. While the local player is unknown the card is judged as the
    /// opponent's, and what it would show as the local player's is kept alongside for snapshots.
    /// - Parameter sourceController: the controller of the card whose action this is, for shuffles.
    private func makeRef(_ entity: Entity, _ context: HistoryRefContext, hideShowEntities: Bool, sourceController: Int? = nil,
                         displayedCardId: String? = nil, entities: Entities) -> HistoryCardRef? {
        if localPlayerId > 0 {
            return ActionHistoryVisibility.ref(for: entity, context: context, localPlayerId: localPlayerId, hideShowEntities: hideShowEntities,
                                               sourceIsLocalPlayer: sourceController == localPlayerId,
                                               displayedCardId: displayedCardId, entities: entities)
        }
        guard var ref = ActionHistoryVisibility.ref(for: entity, context: context, localPlayerId: 0, hideShowEntities: hideShowEntities,
                                                    displayedCardId: displayedCardId, entities: entities) else {
            return nil
        }
        let controller = entity[.controller]
        if controller > 0 {
            let asLocal = ActionHistoryVisibility.ref(for: entity, context: context, localPlayerId: controller, hideShowEntities: hideShowEntities,
                                                      sourceIsLocalPlayer: sourceController == controller,
                                                      displayedCardId: displayedCardId, entities: entities)
            ref.undetermined = HistoryCardRef.UndeterminedController(controller: controller, cardIdIfLocal: asLocal?.cardId,
                                                                     creatorCardIdIfLocal: asLocal?.creatorCardId)
            hasUndetermined = true
        }
        return ref
    }

    private func ref(_ entity: Entity, _ context: HistoryRefContext, _ tap: Tap, sourceController: Int? = nil,
                     hideShowEntities: Bool? = nil) -> HistoryCardRef? {
        return makeRef(entity, context, hideShowEntities: hideShowEntities ?? tap.hideShowEntities, sourceController: sourceController,
                       entities: tap.entities)
    }

    private func ref(_ entity: Entity, _ context: HistoryRefContext, entities: Entities) -> HistoryCardRef? {
        return makeRef(entity, context, hideShowEntities: false, entities: entities)
    }

    private func recordEffect(_ kind: HistoryEffectKind, _ entity: Entity, _ context: HistoryRefContext, _ tap: Tap, amount: Int? = nil,
                              hideShowEntities: Bool? = nil) {
        // DONT_SHOW_IN_HISTORY cards are left out entirely
        guard let target = ref(entity, context, tap, hideShowEntities: hideShowEntities) else {
            return
        }
        record(EffectRecord(kind: kind, target: target, amount: amount, detailCardId: nil))
    }

    /// Adds an effect to the innermost titled action, or to the turn header outside of any.
    private func record(_ effect: EffectRecord, sink explicitSink: Node? = nil) {
        if let sink = explicitSink ?? openNodes.last?.sink {
            sink.records.append(effect)
            if sink.isFinished {
                refinalize(sink)
            }
            return
        }
        let turnIndex = ensureTurn(rawTurn)
        turns[turnIndex].header.append(effect)
        markChanged()
    }

    /// Collapses raw effects into what a row shows: amounts summed per card, an AoE's equal amounts
    /// on one line, hidden cards counted.
    private static func aggregate(_ records: [EffectRecord]) -> [HistoryEffect] {
        guard !records.isEmpty else {
            return []
        }
        struct Item {
            let kind: HistoryEffectKind
            let target: HistoryCardRef
            var amount: Int?
            let detailCardId: String?
        }
        var items: [Item] = []
        var itemIndex: [String: Int] = [:]
        for record in records {
            let key: String
            switch record.kind {
            case .damage, .heal, .armorGained, .armorLost:
                key = "\(record.kind.rawValue)|\(record.target.entityId)"
            default:
                key = "\(record.kind.rawValue)|\(record.target.entityId)|\(record.detailCardId ?? "")"
            }
            if let index = itemIndex[key] {
                if let amount = record.amount, isAmountKind(record.kind) {
                    items[index].amount = (items[index].amount ?? 0) + amount
                }
                continue
            }
            itemIndex[key] = items.count
            items.append(Item(kind: record.kind, target: record.target, amount: isAmountKind(record.kind) ? record.amount : nil,
                              detailCardId: record.detailCardId))
        }

        // Armor absorbs damage before health: show the total on the hero, and the armor part on its own
        for item in items where item.kind == .armorLost {
            if let damageIndex = items.firstIndex(where: { $0.kind == .damage && $0.target.entityId == item.target.entityId }) {
                items[damageIndex].amount = (items[damageIndex].amount ?? 0) + (item.amount ?? 0)
            }
        }

        var effects: [HistoryEffect] = []
        var effectIndex: [String: Int] = [:]
        for item in items {
            if isAmountKind(item.kind) && (item.amount ?? 0) <= 0 {
                continue
            }
            let key: String
            switch item.kind {
            case .damage, .heal, .armorGained, .armorLost:
                key = "\(item.kind.rawValue)|\(item.amount ?? 0)"
            case .generated, .drew:
                key = "\(item.kind.rawValue)|\(item.target.isHidden)"
            case .enchanted, .transformed:
                key = "\(item.kind.rawValue)|\(item.detailCardId ?? "")"
            default:
                key = item.kind.rawValue
            }
            if let index = effectIndex[key] {
                effects[index].targets.append(item.target)
            } else {
                effectIndex[key] = effects.count
                effects.append(HistoryEffect(kind: item.kind, targets: [item.target], amount: item.amount, detailCardId: item.detailCardId))
            }
        }
        // Hidden cards are shown as a count
        for index in effects.indices {
            let effect = effects[index]
            if effect.kind == .drewUnknown || (effect.kind == .generated && effect.targets.first?.isHidden == true) {
                effects[index].amount = effect.targets.count
            }
        }
        return effects
    }

    private static func isAmountKind(_ kind: HistoryEffectKind) -> Bool {
        switch kind {
        case .damage, .heal, .armorGained, .armorLost:
            return true
        default:
            return false
        }
    }

    // MARK: - Secrets

    /// Names the opponent's earlier "played a Secret" row once the Secret is public. Only rows after
    /// the last game reset are searched, since a rewind can reuse entity ids.
    ///
    /// Whether a row may be annotated depends on the row, not on who controls the Secret now: only
    /// rows that kept the Secret anonymous match, and those are the opponent's. A Secret the local
    /// player has since taken over (Kezan Mystic) is shown to them and names its row too.
    private func annotateRevealedSecret(_ secret: Entity, entities: Entities) {
        guard let revealed = makeRef(secret, .secretRevealed, hideShowEntities: false, entities: entities), !revealed.isHidden else {
            return
        }
        var annotated = false
        for turnIndex in turns.indices.reversed() {
            var stop = false
            for entryIndex in turns[turnIndex].entries.indices.reversed() {
                let entry = turns[turnIndex].entries[entryIndex]
                if entry.type == .gameReset || entry.children.contains(where: { $0.type == .gameReset }) {
                    stop = true
                    break
                }
                if ActionHistoryRecorder.annotate(&turns[turnIndex].entries[entryIndex], secretId: secret.id, with: revealed) {
                    annotated = true
                }
            }
            if stop {
                break
            }
        }
        // Actions still open, or finished actions that may be rebuilt
        for node in openNodes + [lastTopLevel].compactMap({ $0 }) {
            if node.hidesSecret(secret.id) && !node.revealedLater.contains(where: { $0.entityId == secret.id }) {
                node.revealedLater.append(revealed)
            }
            for index in node.promoted.indices {
                _ = ActionHistoryRecorder.annotate(&node.promoted[index], secretId: secret.id, with: revealed)
            }
        }
        if annotated {
            markChanged()
        }
    }

    private static func annotate(_ entry: inout HistoryEntry, secretId: Int, with revealed: HistoryCardRef) -> Bool {
        var changed = false
        if !entry.revealedLater.contains(where: { $0.entityId == secretId }) {
            let playedIt = entry.type == .play && entry.source?.entityId == secretId && entry.source?.isHidden == true
            let putIt = entry.effects.contains { $0.kind == .secretPlayed && $0.targets.contains { $0.entityId == secretId && $0.isHidden } }
            if playedIt || putIt {
                entry.revealedLater.append(revealed)
                changed = true
            }
        }
        for index in entry.children.indices where annotate(&entry.children[index], secretId: secretId, with: revealed) {
            changed = true
        }
        return changed
    }

    // MARK: - Resolving the local player

    private func resolve(_ entry: HistoryEntry) -> HistoryEntry {
        var entry = entry
        if entry.activePlayerId > 0 {
            entry.activeSide = side(forPlayerId: entry.activePlayerId)
        }
        entry.source = entry.source?.resolved(localPlayerId: localPlayerId)
        entry.target = entry.target?.resolved(localPlayerId: localPlayerId)
        entry.weapon = entry.weapon?.resolved(localPlayerId: localPlayerId)
        entry.effects = resolve(entry.effects)
        entry.children = entry.children.map(resolve)
        // A Secret that turned out to be the local player's own was named all along
        let named = Set(([entry.source].compactMap { $0 } + entry.effects.filter { $0.kind == .secretPlayed }.flatMap { $0.targets })
                            .filter { !$0.isHidden }.map { $0.entityId })
        entry.revealedLater = entry.revealedLater.map { $0.resolved(localPlayerId: localPlayerId) }.filter { !named.contains($0.entityId) }
        return entry
    }

    /// Resolves effect targets. Draws and generated cards are grouped by whether they are hidden, so
    /// those are grouped again once it is known which of them the local player may see.
    private func resolve(_ effects: [HistoryEffect]) -> [HistoryEffect] {
        guard effects.contains(where: { $0.targets.contains { $0.undetermined != nil } }) else {
            return effects
        }
        enum Slot {
            case effect(HistoryEffect)
            case draws
            case generated
        }
        var slots: [Slot] = []
        var drawn: [HistoryCardRef] = []
        var generated: [HistoryCardRef] = []
        for var effect in effects {
            effect.targets = effect.targets.map { $0.resolved(localPlayerId: localPlayerId) }
            switch effect.kind {
            case .drew, .drewUnknown:
                if drawn.isEmpty {
                    slots.append(.draws)
                }
                drawn += effect.targets
            case .generated:
                if generated.isEmpty {
                    slots.append(.generated)
                }
                generated += effect.targets
            default:
                slots.append(.effect(effect))
            }
        }
        func split(_ cards: [HistoryCardRef], publicKind: HistoryEffectKind, hiddenKind: HistoryEffectKind) -> [HistoryEffect] {
            var result: [HistoryEffect] = []
            let named = cards.filter { !$0.isHidden }
            let hidden = cards.filter { $0.isHidden }
            if !named.isEmpty {
                result.append(HistoryEffect(kind: publicKind, targets: named))
            }
            if !hidden.isEmpty {
                result.append(HistoryEffect(kind: hiddenKind, targets: hidden, amount: hidden.count))
            }
            return result
        }
        return slots.flatMap { slot -> [HistoryEffect] in
            switch slot {
            case .effect(let effect):
                return [effect]
            case .draws:
                return split(drawn, publicKind: .drew, hiddenKind: .drewUnknown)
            case .generated:
                return split(generated, publicKind: .generated, hiddenKind: .generated)
            }
        }
    }

    // MARK: - Turns and caches

    private struct TurnState {
        // Identifies the turn for open blocks even when restored turns are put in front
        var uid: Int
        let rawTurn: Int
        // The PLAYER_ID whose turn it is; the side is worked out when a snapshot is taken
        let activePlayerId: Int
        var header: [EffectRecord]
        var entries: [HistoryEntry]
    }

    private struct InterruptedGame {
        let turns: [TurnState]
        let opponentName: String?
        let date: Date
        let hasUndetermined: Bool
    }

    private var isMulliganDone: Bool {
        // Some modes skip the mulligan; the main steps come after it either way
        return mulliganDoneEntities.count >= 2 || step >= Step.main_ready.rawValue
    }

    private func ensureTurn(_ rawTurn: Int) -> Int {
        if let last = turns.indices.last, turns[last].rawTurn == rawTurn {
            return last
        }
        turns.append(TurnState(uid: nextTurnUid, rawTurn: rawTurn, activePlayerId: currentPlayerId(), header: [], entries: []))
        nextTurnUid += 1
        return turns.count - 1
    }

    private func currentPlayerId() -> Int {
        let playerId = currentPlayerEntity?[.player_id] ?? 0
        if localPlayerId <= 0 {
            hasUndetermined = true
        }
        return playerId
    }

    private func side(forPlayerId playerId: Int) -> HistorySide {
        guard playerId > 0, localPlayerId > 0 else {
            return .neutral
        }
        return playerId == localPlayerId ? .player : .opponent
    }

    private func isGameEntity(_ entity: Entity) -> Bool {
        return entity[.cardtype] == CardType.game.rawValue || entity.name == "GameEntity"
    }

    private func updateLocalPlayer(_ id: Int) {
        guard id > 0, id != localPlayerId else {
            return
        }
        localPlayerId = id
        // What was recorded before can now be shown with the right sides and names
        if hasUndetermined && (!turns.isEmpty || interrupted != nil) {
            markChanged()
        }
    }

    private func resetGameStateCaches() {
        rawTurn = 0
        step = 0
        currentPlayerEntity = nil
        mulliganDoneEntities.removeAll()
        weaponByController.removeAll()
        markedForDestruction.removeAll()
    }

    private func isExcludedGameType() -> Bool {
        if let excludedGameType {
            return excludedGameType
        }
        guard let gameType = gameTypeProvider?(), gameType != .gt_unknown else {
            return false
        }
        let excluded = ActionHistoryRecorder.isExcluded(gameType: gameType)
        excludedGameType = excluded
        // The mirror can report the game type after the first blocks were read
        if excluded && !turns.isEmpty {
            turns.removeAll()
            markChanged()
        }
        return excluded
    }

    private func takeEntryId() -> Int {
        let id = nextEntryId
        nextEntryId += 1
        return id
    }

    private func markChanged() {
        version += 1
        guard !publishScheduled else {
            return
        }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ActionHistoryRecorder.publishDelay) { [weak self] in
            guard let self else {
                return
            }
            self.lock.around {
                self.publishScheduled = false
            }
            self.onChanged?()
        }
    }

    // MARK: - Node

    /// An open (or, for the last top-level action, recently finished) block.
    private final class Node {
        let blockId: Int
        let info: HistoryBlockInfo
        let time: Date
        // The titled node this node's effects go to when it is untitled, and the parent a titled
        // node is added to as a child. Nil at top level.
        let parentSink: Node?
        let type: HistoryActionType?
        let entryId: Int
        let rawTurn: Int
        let activePlayerId: Int
        // Inherited: START_OF_GAME triggers are recorded before the mulligan ends
        let isStartOfGame: Bool
        // Inherited: a GAME_RESET re-creates the board, which is not something anyone did
        let suppressesEffects: Bool

        var targetEntityId: Int?
        var weaponEntityId: Int?
        var records: [EffectRecord] = []
        var children: [HistoryEntry] = []
        var pendingEnchantments: [(entityId: Int, hideShowEntities: Bool)] = []
        var revealedLater: [HistoryCardRef] = []
        // Secrets that fired inside this top-level action, listed after it once it is added
        var promoted: [HistoryEntry] = []
        // A DECK_ACTION that put its card into the deck is a trade
        var movedSourceToDeck = false

        var refsBuilt = false
        var sourceRef: HistoryCardRef?
        var targetRef: HistoryCardRef?
        var weaponRef: HistoryCardRef?

        // Set once a top-level node was added to its turn
        var isFinished = false
        var turnUid = 0

        init(blockId: Int, info: HistoryBlockInfo, time: Date, parentSink: Node?, type: HistoryActionType?, entryId: Int,
             rawTurn: Int, activePlayerId: Int, isStartOfGame: Bool, suppressesEffects: Bool) {
            self.blockId = blockId
            self.info = info
            self.time = time
            self.parentSink = parentSink
            self.type = type
            self.entryId = entryId
            self.rawTurn = rawTurn
            self.activePlayerId = activePlayerId
            self.isStartOfGame = isStartOfGame
            self.suppressesEffects = suppressesEffects
        }

        /// Where effects inside this block are recorded: itself when titled.
        var sink: Node? {
            return type != nil ? self : parentSink
        }

        var isEmpty: Bool {
            return records.isEmpty && children.isEmpty
        }

        func hidesSecret(_ secretId: Int) -> Bool {
            if type == .play && info.sourceEntityId == secretId && sourceRef?.isHidden != false {
                return true
            }
            return records.contains { $0.kind == .secretPlayed && $0.target.entityId == secretId && $0.target.isHidden }
        }
    }
}
