//
//  ActionHistoryVisibility.swift
//  HSTracker
//
//  Decides whether a card may be named in the action history at the moment it is recorded.
//  The history must never show more than the Hearthstone client showed: HSTracker fills in
//  predicted cardIds for hidden opponent cards (knownCardIds, the Coin, Plagues, Ectoplasm...)
//  so a cardId alone is no proof that a card is public. Every ref the recorder stores comes
//  from here.
//

import Foundation

/// Why a card is being referenced. The opponent's cards are only named in contexts where the
/// client shows them to the player.
enum HistoryRefContext {
    // Source of a PLAY block
    case playSource
    case attackSource
    case attackTarget
    // Damage, healing, armor, freeze or silence on a card on the board
    case inPlayTarget
    // Also used for destroyed
    case died
    case summoned
    case equipped
    case drew
    // Added to a hand from outside the deck
    case generated
    case discarded
    // Destroyed from the deck
    case burned
    // Moved into a deck, including trades and mulligans
    case shuffled
    // Bounced from the board back to a hand
    case returnedToHand
    case stolen
    // A card on the board changing into another card
    case transformed
    // A card entering the Secret zone
    case secretPlayed
    // Source of a TRIGGER block with TriggerKeyword=SECRET
    case secretTriggerSource
    // A Secret leaving play in a way that shows it, for the earlier "played a Secret" entry
    case secretRevealed
    // Source of POWER and other TRIGGER blocks (deathrattles, auras, quests, hero powers...)
    case triggerSource
    // JOUST and REVEAL_CARD
    case reveal
    // An enchantment entity, named after the card it is attached to
    case enchantment
    // The card named in "created by"
    case creator
}

enum ActionHistoryVisibility {

    /// The history ref for `entity`, or nil when the entity must not appear in the history at all
    /// (DONT_SHOW_IN_HISTORY, or an enchantment outside the `.enchantment` context).
    /// - Parameters:
    ///   - localPlayerId: the local player's PLAYER_ID; 0 when not known yet, which treats every
    ///     card as the opponent's.
    ///   - hideShowEntities: the current block had META_DATA OVERRIDE_HISTORY, so the client keeps
    ///     the cards it shows out of its own history (Block.hideShowEntities).
    ///   - sourceIsLocalPlayer: whether the action this ref belongs to comes from a card the local
    ///     player controls. Cards shuffled into the local player's deck by the opponent (Plagues)
    ///     stay anonymous.
    ///   - displayedCardId: the card the entity showed when that differs from its current card,
    ///     e.g. the minion before a CHANGE_ENTITY transform. Subject to the same checks.
    static func ref(for entity: Entity,
                    context: HistoryRefContext,
                    localPlayerId: Int,
                    hideShowEntities: Bool,
                    sourceIsLocalPlayer: Bool = false,
                    displayedCardId: String? = nil,
                    entities: SynchronizedDictionary<Int, Entity>) -> HistoryCardRef? {
        if entity.has(tag: .dont_show_in_history) {
            return nil
        }
        if entity.isEnchantment != (context == .enchantment) {
            return nil
        }
        let isPublic = self.isPublic(entity, context: context, localPlayerId: localPlayerId, hideShowEntities: hideShowEntities,
                                     sourceIsLocalPlayer: sourceIsLocalPlayer, entities: entities)
        var cardId: String?
        if isPublic {
            let shown = displayedCardId ?? entity.info.latestCardId
            cardId = shown.isBlank ? nil : shown
        }
        return HistoryCardRef(entityId: entity.id,
                              cardId: cardId,
                              side: side(of: entity, localPlayerId: localPlayerId),
                              cardType: entity[.cardtype],
                              isSecret: entity.isSecret,
                              creatorCardId: creatorCardId(of: entity, refIsPublic: cardId != nil, localPlayerId: localPlayerId,
                                                           hideShowEntities: hideShowEntities, entities: entities))
    }

    static func side(of entity: Entity, localPlayerId: Int) -> HistorySide {
        let controller = entity[.controller]
        if controller <= 0 {
            return .neutral
        }
        return localPlayerId > 0 && controller == localPlayerId ? .player : .opponent
    }

    /// Whether the card may be named: first the tracker's own leak guards, then, for anything the
    /// local player does not control, whether this context shows the card in the client.
    static func isPublic(_ entity: Entity,
                         context: HistoryRefContext,
                         localPlayerId: Int,
                         hideShowEntities: Bool,
                         sourceIsLocalPlayer: Bool = false,
                         entities: SynchronizedDictionary<Int, Entity>) -> Bool {
        // The cardId must come from the log, not from a prediction; OVERRIDE_HISTORY blocks show
        // cards the client keeps out of its history (Hemet, Plagues shown in the deck...).
        if !entity.hasCardId || entity.info.latestCardId.isBlank || entity.info.guessedCardState == .guessed || hideShowEntities {
            return false
        }
        // info.hidden covers Togwaggle and Plague HIDE_ENTITY, Garona, Classic Tracking, Nightmare
        // Fuel, Dark Gift and trades. It is also set on every opponent draw and only cleared by the
        // tracker's play/handToPlay/deckToPlay actions, which run after the tag change that moved the
        // card. A card on the board is public whatever the flag says.
        if entity.info.hidden && !(entity.isInPlay && !entity.isSecret) {
            return false
        }

        if side(of: entity, localPlayerId: localPlayerId) == .player {
            if context == .shuffled {
                return sourceIsLocalPlayer
            }
            return true
        }

        switch context {
        // Everything that ends in a hand, a deck or the Secret zone stays anonymous, whatever
        // HSTracker knows about the card.
        case .drew, .generated, .shuffled, .secretPlayed:
            return false
        // The client shows these cards as it happens
        case .attackSource, .attackTarget, .died, .summoned, .equipped, .discarded, .burned,
             .returnedToHand, .stolen, .secretTriggerSource, .secretRevealed, .reveal:
            return true
        case .inPlayTarget, .transformed:
            return entity.isInPlay
        case .playSource:
            // An opponent's played card is shown, except a Secret, which only becomes public once
            // it is revealed.
            if entity.isInHand || entity.isInDeck {
                return false
            }
            return !(entity.isSecret && entity.isInSecret)
        case .triggerSource, .creator:
            // Cards acting from the board, or public after leaving it. Quests, Sidequests and
            // Objectives sit in the Secret zone face up; Secrets do not.
            if entity.isInPlay || entity.isInGraveyard {
                return true
            }
            return entity.isInSecret && !entity.isSecret
        case .enchantment:
            // An enchantment is as public as what it is attached to: the game or a player, a card on
            // the board, or one of the local player's own cards. Enchantments on the opponent's hand
            // or deck would tell which card was buffed.
            guard let attached = entities[entity[.attached]] else {
                return false
            }
            let attachedType = attached[.cardtype]
            if attachedType == CardType.game.rawValue || attachedType == CardType.player.rawValue {
                return true
            }
            return attached.isInPlay || side(of: attached, localPlayerId: localPlayerId) == .player
        }
    }

    // The client shows "created by" through DISPLAYED_CREATOR. For a public card the plain
    // CREATOR is fine too, as long as the creator itself may be named.
    private static func creatorCardId(of entity: Entity, refIsPublic: Bool, localPlayerId: Int,
                                      hideShowEntities: Bool, entities: SynchronizedDictionary<Int, Entity>) -> String? {
        var creatorId = entity[.displayed_creator]
        if creatorId <= 0 && refIsPublic {
            creatorId = entity[.creator]
        }
        guard creatorId > 0, creatorId != entity.id, let creator = entities[creatorId],
              !creator.has(tag: .dont_show_in_history), !creator.isEnchantment else {
            return nil
        }
        guard isPublic(creator, context: .creator, localPlayerId: localPlayerId, hideShowEntities: hideShowEntities,
                       entities: entities) else {
            return nil
        }
        let cardId = creator.info.latestCardId
        return cardId.isBlank ? nil : cardId
    }
}
