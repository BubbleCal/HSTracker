//
//  ActionHistoryVisibilityTests.swift
//  HSTrackerTests
//

import XCTest
import Foundation

@testable import HSTracker

class ActionHistoryVisibilityTests: HSTrackerTests {
    private static let localPlayerId = 1
    private static let opponentId = 2

    private var entities: SynchronizedDictionary<Int, Entity>!
    private var nextId = 10

    override func setUp() {
        super.setUp()
        entities = SynchronizedDictionary<Int, Entity>()
        nextId = 10
    }

    override func tearDown() {
        entities = nil
        super.tearDown()
    }

    private func createEntity(cardId: String, controller: Int, zone: Zone, cardType: CardType = .minion) -> Entity {
        let entity = Entity(id: nextId)
        nextId += 1
        entity.cardId = cardId
        entity[.controller] = controller
        entity[.zone] = zone.rawValue
        entity[.cardtype] = cardType.rawValue
        entities[entity.id] = entity
        return entity
    }

    private func ref(_ entity: Entity, _ context: HistoryRefContext, hideShowEntities: Bool = false,
                     sourceIsLocalPlayer: Bool = false, displayedCardId: String? = nil) -> HistoryCardRef? {
        return ActionHistoryVisibility.ref(for: entity, context: context, localPlayerId: ActionHistoryVisibilityTests.localPlayerId,
                                           hideShowEntities: hideShowEntities, sourceIsLocalPlayer: sourceIsLocalPlayer,
                                           displayedCardId: displayedCardId, entities: entities)
    }

    // MARK: - Local player

    func testLocalPlayerCardsAreNamed() {
        let drawn = createEntity(cardId: "CORE_CS2_029", controller: 1, zone: .hand, cardType: .spell)
        XCTAssertEqual(ref(drawn, .drew), HistoryCardRef(entityId: drawn.id, cardId: "CORE_CS2_029", side: .player,
                                                         cardType: CardType.spell.rawValue))
        XCTAssertEqual(ref(drawn, .generated)?.cardId, "CORE_CS2_029")
        XCTAssertEqual(ref(drawn, .discarded)?.cardId, "CORE_CS2_029")

        let secret = createEntity(cardId: "CORE_ULD_152", controller: 1, zone: .secret, cardType: .spell)
        secret[.secret] = 1
        let secretRef = ref(secret, .secretPlayed)
        XCTAssertEqual(secretRef?.cardId, "CORE_ULD_152")
        XCTAssertEqual(secretRef?.isSecret, true)
    }

    func testTrackerHiddenCardIsAnonymousEvenForLocalPlayer() {
        let entity = createEntity(cardId: "CORE_CS2_029", controller: 1, zone: .hand, cardType: .spell)
        entity.info.hidden = true
        let hiddenRef = ref(entity, .drew)
        XCTAssertNotNil(hiddenRef)
        XCTAssertNil(hiddenRef?.cardId)
        XCTAssertEqual(hiddenRef?.isHidden, true)
        XCTAssertEqual(hiddenRef?.side, .player)
    }

    func testOverrideHistoryBlockIsAnonymousEvenForLocalPlayer() {
        let entity = createEntity(cardId: "CORE_CS2_029", controller: 1, zone: .hand, cardType: .spell)
        XCTAssertNil(ref(entity, .drew, hideShowEntities: true)?.cardId)

        let opponentMinion = createEntity(cardId: "CORE_UNG_928", controller: 2, zone: .graveyard)
        XCTAssertNil(ref(opponentMinion, .burned, hideShowEntities: true)?.cardId)
    }

    func testGuessedCardIsAnonymousEvenForLocalPlayer() {
        // e.g. a card copied from the opponent's hand by Dark Gift, predicted by the tracker
        let entity = createEntity(cardId: "EDR_463", controller: 1, zone: .hand, cardType: .spell)
        entity.info.guessedCardState = .guessed
        XCTAssertNil(ref(entity, .generated)?.cardId)
    }

    func testShuffleIntoLocalDeckIsNamedOnlyForLocalSources() {
        let plague = createEntity(cardId: "TTN_450t", controller: 1, zone: .deck, cardType: .spell)
        XCTAssertNil(ref(plague, .shuffled)?.cardId)
        XCTAssertNil(ref(plague, .shuffled, sourceIsLocalPlayer: false)?.cardId)
        XCTAssertEqual(ref(plague, .shuffled, sourceIsLocalPlayer: true)?.cardId, "TTN_450t")
    }

    // MARK: - Opponent

    func testOpponentDrawsGenerationsAndShufflesStayAnonymous() {
        // The tracker may know these cards (created cards, knownCardIds without a guess mark); the
        // client does not show them.
        let known = createEntity(cardId: "GAME_005", controller: 2, zone: .hand, cardType: .spell)
        for context in [HistoryRefContext.drew, .generated, .shuffled, .secretPlayed] {
            let hiddenRef = ref(known, context)
            XCTAssertNotNil(hiddenRef, "\(context)")
            XCTAssertNil(hiddenRef?.cardId, "\(context)")
            XCTAssertEqual(hiddenRef?.side, .opponent)
        }
        XCTAssertNil(ref(known, .shuffled, sourceIsLocalPlayer: true)?.cardId)
    }

    func testOpponentPredictedDrawStaysAnonymous() {
        let predicted = createEntity(cardId: "CORE_EX1_610", controller: 2, zone: .hand, cardType: .spell)
        predicted.info.guessedCardState = .guessed
        XCTAssertNil(ref(predicted, .drew)?.cardId)
        predicted[.zone] = Zone.play.rawValue
        XCTAssertNil(ref(predicted, .playSource)?.cardId)
    }

    func testOpponentSecretStaysAnonymousUntilRevealed() {
        let secret = createEntity(cardId: "CORE_EX1_610", controller: 2, zone: .secret, cardType: .spell)
        secret[.secret] = 1
        let played = ref(secret, .playSource)
        XCTAssertNil(played?.cardId)
        XCTAssertEqual(played?.isSecret, true)
        XCTAssertNil(ref(secret, .triggerSource)?.cardId)
        XCTAssertNil(ref(secret, .secretPlayed)?.cardId)

        XCTAssertEqual(ref(secret, .secretTriggerSource)?.cardId, "CORE_EX1_610")
        secret[.zone] = Zone.graveyard.rawValue
        XCTAssertEqual(ref(secret, .secretRevealed)?.cardId, "CORE_EX1_610")
    }

    func testOpponentQuestInSecretZoneIsPublic() {
        let quest = createEntity(cardId: "TLC_817t", controller: 2, zone: .secret, cardType: .spell)
        quest[.quest] = 1
        XCTAssertEqual(ref(quest, .triggerSource)?.cardId, "TLC_817t")
        XCTAssertEqual(ref(quest, .playSource)?.cardId, "TLC_817t")
    }

    func testOpponentPlayedCardIsNamedOnceItLeftTheHand() {
        let spell = createEntity(cardId: "EDR_463", controller: 2, zone: .hand, cardType: .spell)
        XCTAssertNil(ref(spell, .playSource)?.cardId)
        spell[.zone] = Zone.play.rawValue
        XCTAssertEqual(ref(spell, .playSource)?.cardId, "EDR_463")
        spell[.zone] = Zone.graveyard.rawValue
        XCTAssertEqual(ref(spell, .playSource)?.cardId, "EDR_463")
    }

    func testOpponentBoardContextsAreNamed() {
        let minion = createEntity(cardId: "CORE_UNG_928", controller: 2, zone: .play)
        for context in [HistoryRefContext.attackSource, .attackTarget, .inPlayTarget, .summoned, .stolen, .transformed, .triggerSource] {
            XCTAssertEqual(ref(minion, context)?.cardId, "CORE_UNG_928", "\(context)")
        }
        minion[.zone] = Zone.graveyard.rawValue
        XCTAssertEqual(ref(minion, .died)?.cardId, "CORE_UNG_928")
        XCTAssertEqual(ref(minion, .triggerSource)?.cardId, "CORE_UNG_928")
        minion[.zone] = Zone.hand.rawValue
        XCTAssertEqual(ref(minion, .returnedToHand)?.cardId, "CORE_UNG_928")

        let weapon = createEntity(cardId: "CORE_CS2_106", controller: 2, zone: .play, cardType: .weapon)
        XCTAssertEqual(ref(weapon, .equipped)?.cardId, "CORE_CS2_106")
    }

    func testOpponentHandCardsAreNotBoardTargets() {
        // Cost changes and "while in hand" effects hit hand cards; only board cards are public
        let handCard = createEntity(cardId: "CORE_UNG_928", controller: 2, zone: .hand)
        XCTAssertNil(ref(handCard, .inPlayTarget)?.cardId)
        XCTAssertNil(ref(handCard, .transformed)?.cardId)
        XCTAssertNil(ref(handCard, .triggerSource)?.cardId)
        XCTAssertNil(ref(handCard, .creator)?.cardId)
    }

    func testOpponentRevealedCardsAreNamed() {
        let discarded = createEntity(cardId: "CORE_EX1_308", controller: 2, zone: .graveyard, cardType: .spell)
        XCTAssertEqual(ref(discarded, .discarded)?.cardId, "CORE_EX1_308")
        let burned = createEntity(cardId: "CORE_CS2_029", controller: 2, zone: .graveyard, cardType: .spell)
        XCTAssertEqual(ref(burned, .burned)?.cardId, "CORE_CS2_029")
        let jousted = createEntity(cardId: "CORE_CS2_029", controller: 2, zone: .deck, cardType: .spell)
        XCTAssertEqual(ref(jousted, .reveal)?.cardId, "CORE_CS2_029")
    }

    func testCardWithoutLoggedCardIdIsAnonymous() {
        let unknown = createEntity(cardId: "", controller: 2, zone: .play)
        let unknownRef = ref(unknown, .attackSource)
        XCTAssertNotNil(unknownRef)
        XCTAssertNil(unknownRef?.cardId)
    }

    func testStaleDrawFlagDoesNotHideACardOnTheBoard() {
        // Player.draw marks every opponent draw hidden and handToPlay clears it only after the zone
        // tag that summoned the card has been recorded.
        let summoned = createEntity(cardId: "CORE_UNG_928", controller: 2, zone: .play)
        summoned.info.hidden = true
        XCTAssertEqual(ref(summoned, .summoned)?.cardId, "CORE_UNG_928")

        summoned[.zone] = Zone.hand.rawValue
        XCTAssertNil(ref(summoned, .returnedToHand)?.cardId)
    }

    func testUnknownLocalPlayerTreatsCardsAsOpponents() {
        let card = createEntity(cardId: "CORE_CS2_029", controller: 1, zone: .hand, cardType: .spell)
        let unknownPlayerRef = ActionHistoryVisibility.ref(for: card, context: .drew, localPlayerId: 0, hideShowEntities: false, entities: entities)
        XCTAssertEqual(unknownPlayerRef?.side, .opponent)
        XCTAssertNil(unknownPlayerRef?.cardId)
    }

    func testEntityWithoutControllerIsNeutral() {
        let gameEntity = createEntity(cardId: "", controller: 0, zone: .play, cardType: .game)
        XCTAssertEqual(ActionHistoryVisibility.side(of: gameEntity, localPlayerId: 1), .neutral)
    }

    // MARK: - Skipped entities

    func testDontShowInHistoryIsOmitted() {
        let entity = createEntity(cardId: "CORE_UNG_928", controller: 1, zone: .play)
        entity[.dont_show_in_history] = 1
        XCTAssertNil(ref(entity, .summoned))
    }

    func testEnchantmentsOnlyInEnchantmentContext() {
        let minion = createEntity(cardId: "CORE_UNG_928", controller: 1, zone: .play)
        XCTAssertNil(ref(minion, .enchantment))

        let buff = createEntity(cardId: "CORE_CS2_004e", controller: 1, zone: .play, cardType: .enchantment)
        buff[.attached] = minion.id
        XCTAssertNil(ref(buff, .summoned))
        XCTAssertEqual(ref(buff, .enchantment)?.cardId, "CORE_CS2_004e")
    }

    func testOpponentEnchantmentIsAsPublicAsWhatItIsAttachedTo() {
        let handCard = createEntity(cardId: "", controller: 2, zone: .hand)
        let costReduction = createEntity(cardId: "CATA_897e", controller: 2, zone: .play, cardType: .enchantment)
        costReduction[.attached] = handCard.id
        XCTAssertNil(ref(costReduction, .enchantment)?.cardId)

        let boardMinion = createEntity(cardId: "CORE_UNG_928", controller: 2, zone: .play)
        costReduction[.attached] = boardMinion.id
        XCTAssertEqual(ref(costReduction, .enchantment)?.cardId, "CATA_897e")

        let localHandCard = createEntity(cardId: "CORE_CS2_029", controller: 1, zone: .hand, cardType: .spell)
        costReduction[.attached] = localHandCard.id
        XCTAssertEqual(ref(costReduction, .enchantment)?.cardId, "CATA_897e")

        let opponentPlayer = createEntity(cardId: "", controller: 2, zone: .play, cardType: .player)
        costReduction[.attached] = opponentPlayer.id
        XCTAssertEqual(ref(costReduction, .enchantment)?.cardId, "CATA_897e")

        costReduction[.attached] = 999
        XCTAssertNil(ref(costReduction, .enchantment)?.cardId)
    }

    // MARK: - Transforms

    func testTransformUsesTheLatestCardUnlessTheShownCardIsGiven() {
        let minion = createEntity(cardId: "CORE_UNG_928", controller: 2, zone: .play)
        // CHANGE_ENTITY updates latestCardId and leaves cardId alone
        minion.info.latestCardId = "hexfrog"
        XCTAssertEqual(ref(minion, .inPlayTarget)?.cardId, "hexfrog")
        XCTAssertEqual(ref(minion, .transformed, displayedCardId: "CORE_UNG_928")?.cardId, "CORE_UNG_928")

        minion[.zone] = Zone.hand.rawValue
        XCTAssertNil(ref(minion, .transformed, displayedCardId: "CORE_UNG_928")?.cardId)
    }

    // MARK: - Creator

    func testCreatorIsNamedOnlyWhenItIsPublic() {
        let opponentMinion = createEntity(cardId: "JAIL_912", controller: 2, zone: .play)
        let token = createEntity(cardId: "JAIL_912t", controller: 2, zone: .play)
        token[.creator] = opponentMinion.id
        XCTAssertEqual(ref(token, .summoned)?.creatorCardId, "JAIL_912")

        // A creator still in the opponent's hand is not named
        opponentMinion[.zone] = Zone.hand.rawValue
        XCTAssertNil(ref(token, .summoned)?.creatorCardId)

        // A guessed creator is not named either
        opponentMinion[.zone] = Zone.graveyard.rawValue
        XCTAssertEqual(ref(token, .summoned)?.creatorCardId, "JAIL_912")
        opponentMinion.info.guessedCardState = .guessed
        XCTAssertNil(ref(token, .summoned)?.creatorCardId)
    }

    func testHiddenCardShowsOnlyTheDisplayedCreator() {
        let localSpell = createEntity(cardId: "CORE_EX1_339", controller: 1, zone: .graveyard, cardType: .spell)
        let generated = createEntity(cardId: "CORE_UNG_928", controller: 2, zone: .hand)

        generated[.creator] = localSpell.id
        let plainCreator = ref(generated, .generated)
        XCTAssertNil(plainCreator?.cardId)
        XCTAssertNil(plainCreator?.creatorCardId)

        generated[.displayed_creator] = localSpell.id
        let displayedCreator = ref(generated, .generated)
        XCTAssertNil(displayedCreator?.cardId)
        XCTAssertEqual(displayedCreator?.creatorCardId, "CORE_EX1_339")
    }

    // MARK: - Models

    func testSnapshotRoundTripsThroughJSON() throws {
        let minion = HistoryCardRef(entityId: 91, cardId: "CORE_UNG_928", side: .opponent, cardType: CardType.minion.rawValue)
        let hero = HistoryCardRef(entityId: 71, cardId: "HERO_05bo", side: .player, cardType: CardType.hero.rawValue)
        let secret = HistoryCardRef(entityId: 96, cardId: nil, side: .opponent, cardType: CardType.spell.rawValue, isSecret: true)
        let trigger = HistoryEntry(id: 2, rawTurn: 5, turn: 3, activeSide: .opponent, type: .secret, triggerKeyword: "SECRET",
                                   source: secret, effects: [HistoryEffect(kind: .died, targets: [minion])],
                                   time: Date(timeIntervalSince1970: 1_000))
        let attack = HistoryEntry(id: 1, rawTurn: 5, turn: 3, activeSide: .opponent, type: .attack, source: minion, target: hero,
                                  effects: [HistoryEffect(kind: .damage, targets: [hero], amount: 3)], children: [trigger],
                                  revealedLater: [], time: Date(timeIntervalSince1970: 1_000))
        let turn = HistoryTurn(rawTurn: 5, turn: 3, side: .opponent,
                               header: [HistoryEffect(kind: .drewUnknown, targets: [], amount: 1)], entries: [attack])
        let snapshot = ActionHistorySnapshot(turns: [turn], version: 7)

        let decoded = try JSONDecoder().decode(ActionHistorySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.turns.first?.id, 5)
        XCTAssertEqual(decoded.turns.first?.entries.first?.children.first?.source?.isHidden, true)
    }
}
