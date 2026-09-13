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
    private var localPlayerId = 0
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
                            entryId: type != nil ? takeEntryId() : 0, rawTurn: rawTurn, activeSide: currentSide(),
                            isStartOfGame: isStartOfGame, suppressesEffects: suppressesEffects)
            if type == .attack {
                node.targetEntityId = info.targetEntityId
                if let source, source.isHero {
                    node.weaponEntityId = weaponByController[source[.controller]]
                }
            } else if type != nil, let targetId = info.targetEntityId {
                setTarget(of: node, targetId, entities: entities)
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
             .current_player, .mulligan_state, .frozen, .silenced, .divine_shield:
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
                    attack.targetEntityId = value
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
            guard let before = ActionHistoryVisibility.ref(for: entity, context: .transformed, localPlayerId: self.localPlayerId,
                                                            hideShowEntities: hideShowEntities, displayedCardId: fromCardId,
                                                            entities: entities) else {
                return
            }
            let after = ActionHistoryVisibility.ref(for: entity, context: .transformed, localPlayerId: self.localPlayerId,
                                                    hideShowEntities: hideShowEntities, entities: entities)
            record(EffectRecord(kind: .transformed, target: before, amount: nil, detailCardId: after?.cardId))
        }
    }

    /// SHOW_ENTITY, after the parser updated the entity's card and hidden state.
    func entityShown(entity: Entity, localPlayerId: Int, entities: Entities) {
        lock.around {
            updateLocalPlayer(localPlayerId)
            flushPendingCreationZone()
            // A Secret shown after it left play; one still in the Secret zone is handled by its
            // TRIGGER block or its move to the graveyard.
            if excludedGameType != true && entity.isSecret && entity.isInGraveyard {
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

    /// Game.reset. A game that has not ended is kept aside, in case this is a Hearthstone reconnect.
    func reset(opponentName: String?, now: Date = Date()) {
        lock.around {
            if hasGameEnded {
                interrupted = nil
            } else if !turns.isEmpty {
                interrupted = InterruptedGame(turns: turns, opponentName: opponentName, date: now)
            }
            pendingCreationZone = nil
            turns.removeAll()
            openNodes.removeAll()
            lastTopLevel = nil
            resetGameStateCaches()
            localPlayerId = 0
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
            interrupted = nil
            guard now.timeIntervalSince(saved.date) <= ActionHistoryRecorder.reconnectWindow,
                  let opponentName, !opponentName.isBlank, opponentName == saved.opponentName,
                  var lastSaved = saved.turns.last else {
                return false
            }
            var restored = Array(saved.turns.dropLast())
            let marker = HistoryEntry(id: takeEntryId(), rawTurn: lastSaved.rawTurn, turn: ActionHistoryRecorder.turnNumber(lastSaved.rawTurn),
                                      activeSide: lastSaved.side, type: .reconnected, time: now)
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
            let built = turns.map { state in
                HistoryTurn(rawTurn: state.rawTurn, turn: ActionHistoryRecorder.turnNumber(state.rawTurn), side: state.side,
                            header: ActionHistoryRecorder.aggregate(state.header), entries: state.entries)
            }
            return ActionHistorySnapshot(turns: built, version: version)
        }
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

        // TRIGGER, POWER, RITUAL, DECK_ACTION and anything newer
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
                return
            default:
                break
            }
        }
        if let parent = node.parentSink {
            parent.children.append(entry(from: node))
            if parent.isFinished {
                refinalize(parent)
            }
            return
        }
        let turnIndex = ensureTurn(node.rawTurn)
        turns[turnIndex].entries.append(entry(from: node))
        node.turnUid = turns[turnIndex].uid
        node.isFinished = true
        lastTopLevel = type == .gameReset ? nil : node
        markChanged()
    }

    /// Entries are value snapshots; an action that received late deaths or triggers is rebuilt in place.
    private func refinalize(_ node: Node) {
        guard let turnIndex = turns.lastIndex(where: { $0.uid == node.turnUid }),
              let entryIndex = turns[turnIndex].entries.lastIndex(where: { $0.id == node.entryId }) else {
            return
        }
        // Keep a Secret annotation added after the entry was built
        let revealedLater = turns[turnIndex].entries[entryIndex].revealedLater
        var rebuilt = entry(from: node)
        rebuilt.revealedLater = rebuilt.revealedLater ?? revealedLater
        turns[turnIndex].entries[entryIndex] = rebuilt
        markChanged()
    }

    private func entry(from node: Node) -> HistoryEntry {
        return HistoryEntry(id: node.entryId,
                            rawTurn: node.rawTurn,
                            turn: ActionHistoryRecorder.turnNumber(node.rawTurn),
                            activeSide: node.activeSide,
                            type: node.type ?? .trigger,
                            triggerKeyword: ActionHistoryRecorder.meaningfulKeyword(node.info.triggerKeyword),
                            source: node.sourceRef,
                            target: node.targetRef,
                            weapon: node.weaponRef,
                            effects: ActionHistoryRecorder.aggregate(node.records),
                            children: node.children,
                            revealedLater: node.revealedLater,
                            time: node.time)
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
            let context: HistoryRefContext = node.type == .attack ? .attackTarget : .inPlayTarget
            let atEnd = ref(target, context, entities: entities)
            // A spell's target may have died by now; it was public when it was targeted.
            node.targetRef = atEnd?.cardId != nil || node.targetRef?.entityId != targetId ? atEnd : node.targetRef
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
        case (.hand, .graveyard), (.hand, .removedfromgame), (.hand, .setaside):
            if !isPlaying(entity) {
                recordEffect(.discarded, entity, .discarded, tap)
            }
        case (.deck, .graveyard):
            recordEffect(.burned, entity, .burned, tap)
        case (_, .deck):
            if from != .deck {
                if let target = ref(entity, .shuffled, tap, sourceIsLocalPlayer: sinkSourceIsLocalPlayer(tap.entities)) {
                    record(EffectRecord(kind: .shuffledIntoDeck, target: target, amount: nil, detailCardId: nil))
                }
            }
        case (.play, .hand):
            recordEffect(.returnedToHand, entity, .returnedToHand, tap)
        case (_, .play):
            if entity.isWeapon {
                if !isPlaying(entity) {
                    recordEffect(.equipped, entity, .equipped, tap)
                }
            } else if (entity.isMinion || entity.isLocation) && from != .play && !isPlaying(entity) {
                recordEffect(.summoned, entity, .summoned, tap)
            }
        case (.play, .graveyard):
            if entity.isMinion || (entity.isHero && entity.health <= 0) {
                recordEffect(entity.has(tag: .to_be_destroyed) ? .destroyed : .died, entity, .died, tap)
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
            if from != .secret && !isPlaying(entity) && (entity.isSecret || !entity.hasCardId) {
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

    /// Whether `entity` is the card of an open PLAY block, whose own zone moves are the action itself.
    private func isPlaying(_ entity: Entity) -> Bool {
        return openNodes.contains { $0.info.blockType == "PLAY" && $0.info.sourceEntityId == entity.id }
    }

    private func sinkSourceIsLocalPlayer(_ entities: Entities) -> Bool {
        guard localPlayerId > 0, let sourceId = openNodes.last?.sink?.info.sourceEntityId,
              let source = entities[sourceId] else {
            return false
        }
        return source.isControlled(by: localPlayerId)
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
                  let target = ActionHistoryVisibility.ref(for: attached, context: .inPlayTarget, localPlayerId: localPlayerId,
                                                           hideShowEntities: pending.hideShowEntities, entities: entities),
                  !target.isHidden,
                  let enchantmentRef = ActionHistoryVisibility.ref(for: enchantment, context: .enchantment, localPlayerId: localPlayerId,
                                                                   hideShowEntities: pending.hideShowEntities, entities: entities),
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

    private func ref(_ entity: Entity, _ context: HistoryRefContext, _ tap: Tap, sourceIsLocalPlayer: Bool = false) -> HistoryCardRef? {
        return ActionHistoryVisibility.ref(for: entity, context: context, localPlayerId: localPlayerId,
                                           hideShowEntities: tap.hideShowEntities, sourceIsLocalPlayer: sourceIsLocalPlayer,
                                           entities: tap.entities)
    }

    private func ref(_ entity: Entity, _ context: HistoryRefContext, entities: Entities) -> HistoryCardRef? {
        return ActionHistoryVisibility.ref(for: entity, context: context, localPlayerId: localPlayerId,
                                           hideShowEntities: false, entities: entities)
    }

    private func recordEffect(_ kind: HistoryEffectKind, _ entity: Entity, _ context: HistoryRefContext, _ tap: Tap, amount: Int? = nil) {
        // DONT_SHOW_IN_HISTORY cards are left out entirely
        guard let target = ref(entity, context, tap) else {
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
    private func annotateRevealedSecret(_ secret: Entity, entities: Entities) {
        guard let revealed = ActionHistoryVisibility.ref(for: secret, context: .secretRevealed, localPlayerId: localPlayerId,
                                                         hideShowEntities: false, entities: entities),
              !revealed.isHidden, revealed.side != .player else {
            // The local player's own Secrets were named when they were played
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
        for node in openNodes + [lastTopLevel].compactMap({ $0 }) where node.revealedLater == nil && node.hidesSecret(secret.id) {
            node.revealedLater = revealed
        }
        if annotated {
            markChanged()
        }
    }

    private static func annotate(_ entry: inout HistoryEntry, secretId: Int, with revealed: HistoryCardRef) -> Bool {
        var changed = false
        if entry.revealedLater == nil {
            let playedIt = entry.type == .play && entry.source?.entityId == secretId && entry.source?.isHidden == true
            let putIt = entry.effects.contains { $0.kind == .secretPlayed && $0.targets.contains { $0.entityId == secretId && $0.isHidden } }
            if playedIt || putIt {
                entry.revealedLater = revealed
                changed = true
            }
        }
        for index in entry.children.indices where annotate(&entry.children[index], secretId: secretId, with: revealed) {
            changed = true
        }
        return changed
    }

    // MARK: - Turns and caches

    private struct TurnState {
        // Identifies the turn for open blocks even when restored turns are put in front
        var uid: Int
        let rawTurn: Int
        let side: HistorySide
        var header: [EffectRecord]
        var entries: [HistoryEntry]
    }

    private struct InterruptedGame {
        let turns: [TurnState]
        let opponentName: String?
        let date: Date
    }

    private var isMulliganDone: Bool {
        // Some modes skip the mulligan; the main steps come after it either way
        return mulliganDoneEntities.count >= 2 || step >= Step.main_ready.rawValue
    }

    private func ensureTurn(_ rawTurn: Int) -> Int {
        if let last = turns.indices.last, turns[last].rawTurn == rawTurn {
            return last
        }
        turns.append(TurnState(uid: nextTurnUid, rawTurn: rawTurn, side: currentSide(), header: [], entries: []))
        nextTurnUid += 1
        return turns.count - 1
    }

    private func currentSide() -> HistorySide {
        let playerId = currentPlayerEntity?[.player_id] ?? 0
        guard playerId > 0, localPlayerId > 0 else {
            return .neutral
        }
        return playerId == localPlayerId ? .player : .opponent
    }

    private func isGameEntity(_ entity: Entity) -> Bool {
        return entity[.cardtype] == CardType.game.rawValue || entity.name == "GameEntity"
    }

    private func updateLocalPlayer(_ id: Int) {
        if id > 0 {
            localPlayerId = id
        }
    }

    private func resetGameStateCaches() {
        rawTurn = 0
        step = 0
        currentPlayerEntity = nil
        mulliganDoneEntities.removeAll()
        weaponByController.removeAll()
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
        let activeSide: HistorySide
        // Inherited: START_OF_GAME triggers are recorded before the mulligan ends
        let isStartOfGame: Bool
        // Inherited: a GAME_RESET re-creates the board, which is not something anyone did
        let suppressesEffects: Bool

        var targetEntityId: Int?
        var weaponEntityId: Int?
        var records: [EffectRecord] = []
        var children: [HistoryEntry] = []
        var pendingEnchantments: [(entityId: Int, hideShowEntities: Bool)] = []
        var revealedLater: HistoryCardRef?

        var refsBuilt = false
        var sourceRef: HistoryCardRef?
        var targetRef: HistoryCardRef?
        var weaponRef: HistoryCardRef?

        // Set once a top-level node was added to its turn
        var isFinished = false
        var turnUid = 0

        init(blockId: Int, info: HistoryBlockInfo, time: Date, parentSink: Node?, type: HistoryActionType?, entryId: Int,
             rawTurn: Int, activeSide: HistorySide, isStartOfGame: Bool, suppressesEffects: Bool) {
            self.blockId = blockId
            self.info = info
            self.time = time
            self.parentSink = parentSink
            self.type = type
            self.entryId = entryId
            self.rawTurn = rawTurn
            self.activeSide = activeSide
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
