//
//  ActionHistoryModels.swift
//  HSTracker
//
//  Value types for the in-match action history. HDT has no counterpart (its only equivalent is
//  the HSReplay.net replay), so the shapes follow what the overlay needs to render a turn-grouped
//  log. Everything is a Codable value type: the recorder hands immutable snapshots from the
//  log-reader queue to the main thread, and a later "keep the last N games" option can write
//  them as JSON without a new model. Nothing here imports SwiftUI or needs macOS 10.15.
//

import Foundation

/// Whose action or card a history item belongs to, from the local player's point of view.
enum HistorySide: Int, Codable {
    case player
    case opponent
    // The GameEntity, or an entity without a controller
    case neutral
}

/// A card as it may be shown in the history. `cardId` is nil when the card is not public at the
/// moment it was recorded; the UI then shows "a card" / "a Secret" and attaches no card tooltip.
/// See `ActionHistoryVisibility` for the rules that decide it.
struct HistoryCardRef: Codable, Equatable, Hashable {
    let entityId: Int
    let cardId: String?
    let side: HistorySide
    // CardType.rawValue at record time
    let cardType: Int
    // Lets the UI say "a Secret" instead of "a card" for a hidden ref
    let isSecret: Bool
    // Set only when the creator is itself public
    let creatorCardId: String?
    // Set while the recorder does not know which player is local yet (HSTracker started mid-match
    // replays Power.log before the mirror has answered). The ref above is what an opponent's card
    // may show; this keeps what the card would show if it turned out to be the local player's, so
    // `resolved(localPlayerId:)` can pick one once the local player is known. Never encoded: a
    // published snapshot is always resolved first.
    var undetermined: UndeterminedController?

    struct UndeterminedController: Equatable, Hashable {
        let controller: Int
        let cardIdIfLocal: String?
        let creatorCardIdIfLocal: String?
    }

    private enum CodingKeys: String, CodingKey {
        case entityId, cardId, side, cardType, isSecret, creatorCardId
    }

    init(entityId: Int, cardId: String?, side: HistorySide, cardType: Int, isSecret: Bool = false, creatorCardId: String? = nil,
         undetermined: UndeterminedController? = nil) {
        self.entityId = entityId
        self.cardId = cardId
        self.side = side
        self.cardType = cardType
        self.isSecret = isSecret
        self.creatorCardId = creatorCardId
        self.undetermined = undetermined
    }

    var isHidden: Bool {
        return cardId == nil
    }

    /// The ref as it may be shown once the local player's id is known. With no id yet the card is
    /// treated as the opponent's, which never names more than the client showed.
    func resolved(localPlayerId: Int) -> HistoryCardRef {
        guard let undetermined else {
            return self
        }
        if localPlayerId > 0 && undetermined.controller == localPlayerId {
            return HistoryCardRef(entityId: entityId, cardId: undetermined.cardIdIfLocal, side: .player, cardType: cardType,
                                  isSecret: isSecret, creatorCardId: undetermined.creatorCardIdIfLocal)
        }
        return HistoryCardRef(entityId: entityId, cardId: cardId, side: side, cardType: cardType, isSecret: isSecret,
                              creatorCardId: creatorCardId)
    }
}

/// The title of a history entry: what the top-level block (or a titled child block) was.
enum HistoryActionType: String, Codable {
    case play
    case heroPower
    case useLocation
    case attack
    // POWER block whose source is not the titled ancestor's source
    case power
    case trigger
    case secret
    case deathrattle
    case fatigue
    // JOUST / REVEAL_CARD
    case reveal
    case turnStart
    // BlockType=DECK_ACTION that moved its card into the deck
    case trade
    // Any other BlockType=DECK_ACTION: Prepare, Forge and later hand options
    case deckAction
    // DEATHS that could not be attached to the action that caused them
    case deaths
    // Time-travel cards rewinding the game (BlockType=GAME_RESET)
    case gameReset
    // Marker for turns restored after a Hearthstone reconnect
    case reconnected
}

/// What an action did to a card.
enum HistoryEffectKind: String, Codable {
    case damage
    case heal
    case armorGained
    case armorLost
    case died
    case destroyed
    case summoned
    case equipped
    case drew
    // Opponent draws: only the count is public
    case drewUnknown
    case generated
    case discarded
    case burned
    case shuffledIntoDeck
    case returnedToHand
    case transformed
    case stolen
    case enchanted
    case frozen
    case silenced
    case divineShieldLost
    case secretPlayed
}

struct HistoryEffect: Codable, Equatable {
    let kind: HistoryEffectKind
    // Effects of the same kind (and amount / detail) on one entry merge, so an AoE is one line
    var targets: [HistoryCardRef]
    // Damage, healing or armor; the card count for drewUnknown and hidden generated cards
    var amount: Int?
    // Transform result or enchantment cardId, only when public
    var detailCardId: String?

    init(kind: HistoryEffectKind, targets: [HistoryCardRef], amount: Int? = nil, detailCardId: String? = nil) {
        self.kind = kind
        self.targets = targets
        self.amount = amount
        self.detailCardId = detailCardId
    }
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    // Recorder-wide sequence number. Not the parser's block id, which restarts on CREATE_GAME.
    let id: Int
    // GameEntity TURN
    let rawTurn: Int
    // (rawTurn + 1) / 2, 0 before the first turn
    let turn: Int
    var activeSide: HistorySide
    let type: HistoryActionType
    let triggerKeyword: String?
    var source: HistoryCardRef?
    // ATTACK: the final PROPOSED_DEFENDER; PLAY: CARD_TARGET
    var target: HistoryCardRef?
    // The weapon a hero attacked with
    var weapon: HistoryCardRef?
    var effects: [HistoryEffect]
    // Titled sub-actions, such as a Deathrattle during deaths
    var children: [HistoryEntry]
    // The opponent's hidden Secrets this entry put into play, once each has become public
    var revealedLater: [HistoryCardRef]
    let time: Date
    // The PLAYER_ID whose turn it was, so activeSide can be worked out once the local player is known
    var activePlayerId: Int

    init(id: Int, rawTurn: Int, turn: Int, activeSide: HistorySide, type: HistoryActionType, triggerKeyword: String? = nil,
         source: HistoryCardRef? = nil, target: HistoryCardRef? = nil, weapon: HistoryCardRef? = nil,
         effects: [HistoryEffect] = [], children: [HistoryEntry] = [], revealedLater: [HistoryCardRef] = [], time: Date,
         activePlayerId: Int = 0) {
        self.id = id
        self.rawTurn = rawTurn
        self.turn = turn
        self.activeSide = activeSide
        self.type = type
        self.triggerKeyword = triggerKeyword
        self.source = source
        self.target = target
        self.weapon = weapon
        self.effects = effects
        self.children = children
        self.revealedLater = revealedLater
        self.time = time
        self.activePlayerId = activePlayerId
    }
}

struct HistoryTurn: Codable, Equatable, Identifiable {
    var id: Int {
        return rawTurn
    }
    let rawTurn: Int
    let turn: Int
    let side: HistorySide
    // Effects outside any titled block, such as the turn-start draw or fatigue
    var header: [HistoryEffect]
    var entries: [HistoryEntry]

    init(rawTurn: Int, turn: Int, side: HistorySide, header: [HistoryEffect] = [], entries: [HistoryEntry] = []) {
        self.rawTurn = rawTurn
        self.turn = turn
        self.side = side
        self.header = header
        self.entries = entries
    }
}

/// What the recorder publishes to the overlay. `version` lets the view model skip unchanged snapshots.
struct ActionHistorySnapshot: Codable, Equatable {
    let turns: [HistoryTurn]
    let version: Int
}

/// The fields of a Power.log BLOCK_START line that the history needs, parsed by
/// `ActionHistoryLineParser`.
struct HistoryBlockInfo: Codable, Equatable {
    /// Who the Entity field names. The log writes the GameEntity and players by name only
    /// ("Entity=GameEntity", "Entity=Name#1234"); cards come as "[entityName=... id=N ...]".
    enum SourceKind: String, Codable {
        case entity
        case gameEntity
        case player
    }

    // PLAY, ATTACK, POWER, TRIGGER, DEATHS, FATIGUE, JOUST, RITUAL, DECK_ACTION, GAME_RESET, ...
    let blockType: String
    let sourceKind: SourceKind
    // The Entity field's id; nil for the GameEntity and players, which are logged by name
    let sourceEntityId: Int?
    // The Target field's id; nil for "Target=0", like Block.targetEntityId
    let targetEntityId: Int?
    // Only TRIGGER blocks carry one (SECRET, DEATHRATTLE, TAG_NOT_SET, ...)
    let triggerKeyword: String?
    let effectIndex: Int?
    // -1 when no choice was made
    let subOption: Int?

    init(blockType: String, sourceKind: SourceKind, sourceEntityId: Int?, targetEntityId: Int? = nil,
         triggerKeyword: String? = nil, effectIndex: Int? = nil, subOption: Int? = nil) {
        self.blockType = blockType
        self.sourceKind = sourceKind
        self.sourceEntityId = sourceEntityId
        self.targetEntityId = targetEntityId
        self.triggerKeyword = triggerKeyword
        self.effectIndex = effectIndex
        self.subOption = subOption
    }

    /// A block started by the game or a player rather than a card, such as DEATHS or the
    /// turn-start draw. Its effects belong to the enclosing action or the turn header.
    var isBareEntity: Bool {
        return sourceKind != .entity
    }
}
