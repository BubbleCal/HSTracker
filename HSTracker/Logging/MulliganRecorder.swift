//
//  MulliganRecorder.swift
//  HSTracker
//

import Foundation

/// Collects the local player's mulligan and later draws from the parsed log, and turns
/// them into the MulliganRecord stored with the game.
///
/// MulliganState is not used for this: its offered-cards snapshot is taken by the
/// Mulligan Guide in a detached task that polls STEP and gives up once the mulligan is
/// past BEGIN_MULLIGAN, so a slow poll or a reconnect leaves it empty. This recorder
/// is fed synchronously from the log stream instead, at points that always happen:
///
/// - the MULLIGAN choice and its EntitiesChosen echo (GameState lines, ChoicesHandler),
/// - each player's MULLIGAN_STATE reaching DONE (PowerTaskList, TagChangeActions),
///   where the hand and deck are snapshotted,
/// - each player's draws from the deck, as their ZONE tag is set (TagChangeHandler),
/// - the first turn starting (STEP=MAIN_READY), a reconnect (Game.handleGameReconnect),
///   and the end of the game.
///
/// Choices and snapshots are kept per player id rather than only for the local player,
/// because player.id comes from HearthMirror and may still be unknown when the
/// GameState lines of the mulligan are read. The local one is picked when the record
/// is built.
final class MulliganRecorder {
    /// What is needed of an entity of the mulligan once the hand is final.
    struct CardSnapshot: Equatable {
        let cardId: String
        let isCoin: Bool
        /// Quests and questlines always start in the opening hand.
        let isQuest: Bool
        /// Created before the mulligan was done, by a start-of-game or similar effect.
        let isCreated: Bool
    }

    /// A player's cards when their MULLIGAN_STATE reached DONE.
    struct MulliganDoneSnapshot {
        /// Entity ids in hand, in zone order.
        let hand: [Int]
        /// Entity ids left in the deck: the original deck cards not in hand, including
        /// the mulliganed ones. Later draws only count cards from here.
        let deck: Set<Int>
        /// Every hand and deck entity with a card id.
        let cards: [Int: CardSnapshot]
    }

    struct Draw: Equatable {
        let entityId: Int
        let cardId: String
        let gameTurn: Int
    }

    private let lock = UnfairLock()
    private var offered = [Int: [Int]]()
    private var chosen = [Int: [Int]]()
    private var done = [Int: MulliganDoneSnapshot]()
    private var draws = [Int: [Draw]]()
    private var drawsTruncated = Set<Int>()
    private var firstTurnStarted = false
    private var reconnected = false

    func reset() {
        lock.around {
            offered.removeAll()
            chosen.removeAll()
            done.removeAll()
            draws.removeAll()
            drawsTruncated.removeAll()
            firstTurnStarted = false
            reconnected = false
        }
    }

    /// DebugPrintEntityChoices with ChoiceType=MULLIGAN. The entities are the opening
    /// hand in zone order, The Coin included when the player goes second.
    func mulliganOffered(playerId: Int, entityIds: [Int]) {
        lock.around {
            // A second offer is a new game whose Gameplay.Start was missed, or the choice
            // sent again after a reconnect: start over rather than mix the two. A reconnect
            // seen earlier still marks the game.
            if offered[playerId] != nil {
                let wasReconnected = reconnected
                resetLocked()
                reconnected = wasReconnected
            }
            offered[playerId] = entityIds
        }
    }

    /// DebugPrintEntitiesChosen of the MULLIGAN choice: the cards the server kept.
    func mulliganChosen(playerId: Int, entityIds: [Int]) {
        lock.around {
            chosen[playerId] = entityIds
        }
    }

    /// MULLIGAN_STATE=DONE for a player entity. By then the replacements have been
    /// dealt and the replaced cards are back in the deck.
    func mulliganDone(playerId: Int, entities: [Entity]) {
        var hand = [Entity]()
        var deck = Set<Int>()
        var cards = [Int: CardSnapshot]()
        for entity in entities where entity.isControlled(by: playerId) {
            if entity.isInHand {
                hand.append(entity)
            } else if entity.isInDeck {
                deck.insert(entity.id)
            } else {
                continue
            }
            if entity.hasCardId {
                cards[entity.id] = MulliganRecorder.snapshot(of: entity)
            }
        }
        let snapshot = MulliganDoneSnapshot(hand: hand.sorted { $0.zonePosition < $1.zonePosition }.map { $0.id },
                                            deck: deck, cards: cards)
        lock.around {
            if done[playerId] == nil {
                done[playerId] = snapshot
            }
        }
    }

    /// A card a player drew from the deck. Only cards that were in the deck when that
    /// player's mulligan was done count, so cards shuffled in or created later are left
    /// out, and each entity counts once.
    ///
    /// Fed for either controller, like the choices and the DONE snapshot: player.id may
    /// still be unknown while a Power.log backlog is replayed, and the local player's
    /// draws are picked when the record is built.
    ///
    /// - Parameters:
    ///   - cardId: the card drawn, as revealed.
    ///   - gameTurn: the game entity's TURN.
    func cardDrawn(playerId: Int, entityId: Int, cardId: String, gameTurn: Int) {
        lock.around {
            guard let snapshot = done[playerId], snapshot.deck.contains(entityId), !cardId.isEmpty else {
                return
            }
            var list = draws[playerId] ?? []
            guard !list.contains(where: { $0.entityId == entityId }) else {
                return
            }
            if list.count >= MulliganRecord.drawLimit {
                drawsTruncated.insert(playerId)
                return
            }
            list.append(Draw(entityId: entityId, cardId: cardId, gameTurn: max(gameTurn, 0)))
            draws[playerId] = list
        }
    }

    /// STEP=MAIN_READY: the first turn is starting, so both mulligans are over and the
    /// result of the game can be tied to the opening hand.
    func turnStarted() {
        lock.around {
            firstTurnStarted = true
        }
    }

    func gameReconnected() {
        lock.around {
            reconnected = true
        }
    }

    /// Builds the record for the local player and clears what was collected, so a
    /// following game never sees this one's entity ids even if its Gameplay.Start
    /// (Game.reset) is missed.
    ///
    /// - Parameters:
    ///   - localPlayerId: player.id, 0 or less when it was never known.
    ///   - entity: looks up an entity of the current game, for card ids that were not
    ///     known yet when the mulligan finished.
    func buildRecord(localPlayerId: Int, entity: (Int) -> Entity?) -> MulliganRecord {
        let record = MulliganRecord()
        record.version = MulliganRecord.currentVersion
        lock.around {
            defer { resetLocked() }
            record.status = fill(record: record, localPlayerId: localPlayerId, entity: entity)
            if reconnected {
                record.status = .reconnected
            }
        }
        return record
    }

    private func resetLocked() {
        offered.removeAll()
        chosen.removeAll()
        done.removeAll()
        draws.removeAll()
        drawsTruncated.removeAll()
        firstTurnStarted = false
        reconnected = false
    }

    private static func snapshot(of entity: Entity) -> CardSnapshot {
        // The entity tags first; the card data too, since the tag is only there when
        // the log showed it
        let mechanics = entity.card.mechanics
        let isQuest = entity.isQuest || mechanics.contains("QUEST") || mechanics.contains("QUESTLINE")
        return CardSnapshot(cardId: entity.cardId, isCoin: entity.isTheCoin, isQuest: isQuest, isCreated: entity.info.created)
    }

    private func fill(record: MulliganRecord, localPlayerId: Int, entity: (Int) -> Entity?) -> MulliganRecordStatus {
        guard localPlayerId > 0 else {
            return .unknownPlayer
        }
        for draw in draws[localPlayerId] ?? [] {
            // TRANSFORMED_FROM_CARD is read only now, since it can follow the ZONE tag in the
            // SHOW_ENTITY. Naming another card than the one drawn, the entity was transformed
            // in the deck (Lady Prestor): store the deck's card, so draws stay cards of the deck
            // list. A card transformed after the draw names the drawn card itself.
            let transformedFrom = entity(draw.entityId)?[.transformed_from_card] ?? 0
            let deckCardId = transformedFrom > 0 ? Cards.by(dbfId: transformedFrom, collectible: false)?.id : nil
            if let deckCardId, deckCardId != draw.cardId {
                record.draws.append(MulliganDrawnCard(cardId: deckCardId, gameTurn: draw.gameTurn, transformed: true))
            } else {
                record.draws.append(MulliganDrawnCard(cardId: draw.cardId, gameTurn: draw.gameTurn))
            }
        }
        record.drawsTruncated = drawsTruncated.contains(localPlayerId)

        guard let offeredIds = offered[localPlayerId] else {
            return .noMulliganOffer
        }
        let doneSnapshot = done[localPlayerId]

        func card(_ id: Int) -> CardSnapshot? {
            if let card = doneSnapshot?.cards[id] {
                return card
            }
            guard let entity = entity(id), entity.hasCardId else {
                return nil
            }
            return MulliganRecorder.snapshot(of: entity)
        }

        var hasUnknownCards = false
        let offeredCards = offeredIds.compactMap { id -> (id: Int, card: CardSnapshot?)? in
            let card = card(id)
            return card?.isCoin == true ? nil : (id, card)
        }
        guard let snapshot = doneSnapshot else {
            // Keep what was offered so the game still says what the hand looked like.
            for (_, card) in offeredCards {
                record.offered.append(MulliganOfferedCard(cardId: card?.cardId ?? "", kept: false,
                                                          forced: (card?.isQuest ?? false) || (card?.isCreated ?? false)))
            }
            return .mulliganUnfinished
        }

        let hand = Set(snapshot.hand)
        let chosenIds = chosen[localPlayerId].map(Set.init)
        var mulliganedCount = 0
        var isInconsistent = false
        for (id, card) in offeredCards {
            let kept = hand.contains(id)
            let wasChosen = chosenIds?.contains(id)
            if !kept {
                mulliganedCount += 1
                // The server said to keep it, yet it left the hand.
                if wasChosen == true {
                    isInconsistent = true
                }
            }
            // Left in hand although a seen echo does not list it: the player could not have
            // replaced it. Hearthstone lists quests among the chosen cards, so this is only a
            // guard; the card data is what finds them.
            let forced = (card?.isQuest ?? false) || (card?.isCreated ?? false) || (kept && wasChosen == false)
            if card == nil {
                hasUnknownCards = true
            }
            record.offered.append(MulliganOfferedCard(cardId: card?.cardId ?? "", kept: kept, forced: forced))
        }

        let offeredSet = Set(offeredIds)
        for id in snapshot.hand {
            let card = card(id)
            if card?.isCoin == true {
                continue
            }
            guard let card else {
                hasUnknownCards = true
                record.finalHandCardIds.append("")
                continue
            }
            record.finalHandCardIds.append(card.cardId)
            // Anything created into the hand meanwhile (a start-of-game or Discover-like
            // effect) is part of the final hand but did not replace a card.
            if !offeredSet.contains(id) && !card.isCreated {
                record.replacementCardIds.append(card.cardId)
            }
        }
        if record.replacementCardIds.count != mulliganedCount {
            isInconsistent = true
        }

        if !firstTurnStarted {
            return .endedBeforeFirstTurn
        }
        // Kept is read from the hand at DONE, so without the echo nothing says the player
        // chose it rather than the server keeping the hand on a timeout or disconnect
        if chosenIds == nil {
            return .mulliganChoiceMissing
        }
        if hasUnknownCards {
            return .unknownCards
        }
        return isInconsistent ? .inconsistent : .complete
    }
}
