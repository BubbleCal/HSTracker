//
//  BoardDamageTests.swift
//  HSTrackerTests
//
//  Covers the "n(m)" board damage counters: what a side can still deal to the enemy hero this turn,
//  and what its board could deal on its next turn. Entities are built with tags directly, the way the
//  log leaves them.
//

import XCTest
@testable import HSTracker

class BoardDamageTests: XCTestCase {
    private var nextId = 100

    private func entity(_ type: CardType, cardId: String = "", _ tags: [GameTag: Int] = [:]) -> Entity {
        let entity = Entity(id: nextId)
        nextId += 1
        entity.cardId = cardId
        entity[.cardtype] = type.rawValue
        entity[.zone] = Zone.play.rawValue
        entity[.controller] = 1
        for (tag, value) in tags {
            entity[tag] = value
        }
        return entity
    }

    /// A minion that has been in play since an earlier turn and has not attacked
    private func minion(atk: Int, _ tags: [GameTag: Int] = [:]) -> Entity {
        var all: [GameTag: Int] = [.atk: atk, .health: 3, .num_turns_in_play: 2]
        all.merge(tags) { $1 }
        return entity(.minion, all)
    }

    private func hero(atk: Int = 0, _ tags: [GameTag: Int] = [:]) -> Entity {
        var all: [GameTag: Int] = [.atk: atk, .health: 30, .num_turns_in_play: 5]
        all.merge(tags) { $1 }
        return entity(.hero, cardId: "HERO_01", all)
    }

    private func weapon(atk: Int, health: Int, _ tags: [GameTag: Int] = [:]) -> Entity {
        var all: [GameTag: Int] = [.atk: atk, .health: health]
        all.merge(tags) { $1 }
        return entity(.weapon, all)
    }

    private func acting(_ list: [Entity], playerEntity: Entity? = nil) -> PlayerBoard {
        return PlayerBoard(list: list, isCurrent: true, isActing: true, playerEntity: playerEntity)
    }

    private func notCurrent(_ list: [Entity], playerEntity: Entity? = nil) -> PlayerBoard {
        return PlayerBoard(list: list, isCurrent: false, isActing: false, playerEntity: playerEntity)
    }

    private func assertDamage(_ board: PlayerBoard, now: Int, next: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(board.damageNow, now, "now", file: file, line: line)
        XCTAssertEqual(board.damageNextTurn, next, "next turn", file: file, line: line)
    }

    // MARK: - Turn

    func testNotActingCountsOnlyNextTurn() {
        assertDamage(notCurrent([minion(atk: 3), minion(atk: 2)]), now: 0, next: 5)
    }

    func testActingNotYetAttacked() {
        assertDamage(acting([minion(atk: 3), minion(atk: 2)]), now: 5, next: 5)
    }

    func testActingSteps() {
        XCTAssertFalse(BoardState.isActing(isCurrent: true, step: Step.main_ready.rawValue))
        XCTAssertTrue(BoardState.isActing(isCurrent: true, step: Step.main_start_triggers.rawValue))
        XCTAssertTrue(BoardState.isActing(isCurrent: true, step: Step.main_start.rawValue))
        XCTAssertTrue(BoardState.isActing(isCurrent: true, step: Step.main_action.rawValue))
        XCTAssertTrue(BoardState.isActing(isCurrent: true, step: Step.main_pre_action.rawValue))
        XCTAssertTrue(BoardState.isActing(isCurrent: true, step: Step.main_post_action.rawValue))
        XCTAssertFalse(BoardState.isActing(isCurrent: true, step: Step.main_end.rawValue))
        XCTAssertFalse(BoardState.isActing(isCurrent: true, step: Step.main_cleanup.rawValue))
        XCTAssertFalse(BoardState.isActing(isCurrent: true, step: Step.main_next.rawValue))
        XCTAssertFalse(BoardState.isActing(isCurrent: false, step: Step.main_action.rawValue))
    }

    func testBoardStateReadsCurrentPlayerAndStep() {
        let playerEntity = entity(.player, [.current_player: 1])
        let opponentEntity = entity(.player, [.current_player: 0])
        func state(step: Step) -> BoardState {
            return BoardState(player: [minion(atk: 3)], opponent: [minion(atk: 4)],
                              playerEntity: playerEntity, opponentEntity: opponentEntity, step: step.rawValue)
        }

        let ready = state(step: .main_ready)
        assertDamage(ready.player, now: 0, next: 3)
        assertDamage(ready.opponent, now: 0, next: 4)

        let action = state(step: .main_action)
        assertDamage(action.player, now: 3, next: 3)
        assertDamage(action.opponent, now: 0, next: 4)
        XCTAssertTrue(action.player.isCurrent)
        XCTAssertFalse(action.opponent.isCurrent)

        assertDamage(state(step: .main_end).player, now: 0, next: 3)
        assertDamage(state(step: .main_cleanup).player, now: 0, next: 3)
    }

    // MARK: - Minions this turn

    func testMinionPlayedThisTurn() {
        let played = minion(atk: 4, [.num_turns_in_play: 0, .exhausted: 1])
        assertDamage(acting([played]), now: 0, next: 4)
    }

    func testChargeMinionPlayedThisTurn() {
        let charger = minion(atk: 6, [.num_turns_in_play: 0, .exhausted: 0, .charge: 1])
        assertDamage(acting([charger]), now: 6, next: 6)

        charger[.num_attacks_this_turn] = 1
        charger[.exhausted] = 1
        assertDamage(acting([charger]), now: 0, next: 6)
    }

    func testRushMinionPlayedThisTurnCantHitFace() {
        let rusher = minion(atk: 5, [.num_turns_in_play: 0, .exhausted: 0, .rush: 1])
        assertDamage(acting([rusher]), now: 0, next: 5)

        rusher[.charge] = 1
        assertDamage(acting([rusher]), now: 5, next: 5)
    }

    func testSummoningSickMinionGivenCharge() {
        let given = minion(atk: 3, [.num_turns_in_play: 0, .exhausted: 1, .charge: 1, .num_attacks_this_turn: 0])
        assertDamage(acting([given]), now: 3, next: 3)
    }

    func testMinionThatAlreadyAttacked() {
        let attacked = minion(atk: 4, [.num_turns_in_play: 3, .num_attacks_this_turn: 1, .exhausted: 1])
        assertDamage(acting([attacked]), now: 0, next: 4)
    }

    func testWindfuryMinion() {
        let windfury = minion(atk: 3, [.windfury: 1])
        assertDamage(acting([windfury]), now: 6, next: 6)

        windfury[.num_attacks_this_turn] = 1
        assertDamage(acting([windfury]), now: 3, next: 6)

        windfury[.num_attacks_this_turn] = 2
        windfury[.exhausted] = 1
        assertDamage(acting([windfury]), now: 0, next: 6)
    }

    func testMegaWindfury() {
        assertDamage(acting([minion(atk: 2, [.mega_windfury: 1])]), now: 8, next: 8)
        assertDamage(acting([minion(atk: 2, [.windfury: 3])]), now: 8, next: 8)
        // HDT Include_MegaWindfury_V07TR0N: silencing leaves plain Windfury behind
        assertDamage(acting([minion(atk: 2, [.mega_windfury: 1, .windfury: 1, .silenced: 1])]), now: 4, next: 4)
    }

    func testChargeWindfuryMinionAfterOneAttack() {
        let minion = self.minion(atk: 2, [.num_turns_in_play: 0, .charge: 1, .windfury: 1,
                                     .num_attacks_this_turn: 1, .exhausted: 0])
        XCTAssertEqual(acting([minion]).damageNow, 2)
    }

    // MARK: - Exclusions

    func testCantAttack() {
        for tag in [GameTag.cant_attack, .cannot_attack_heroes] {
            let minion = self.minion(atk: 5, [tag: 1])
            assertDamage(acting([minion]), now: 0, next: 0)
            assertDamage(notCurrent([minion]), now: 0, next: 0)
        }
    }

    func testDormant() {
        assertDamage(acting([minion(atk: 3, [.dormant: 1])]), now: 0, next: 0)
        assertDamage(notCurrent([minion(atk: 3, [.dormant: 1])]), now: 0, next: 0)
    }

    func testTitan() {
        let titan = minion(atk: 7, [.titan: 1, .titan_ability_used_1: 1, .titan_ability_used_2: 1])
        assertDamage(acting([titan]), now: 0, next: 0)

        titan[.titan_ability_used_3] = 1
        assertDamage(acting([titan]), now: 7, next: 7)
    }

    func testHideStats() {
        assertDamage(acting([minion(atk: 5, [.hide_stats: 1])]), now: 0, next: 0)
    }

    func testLocationContributesNothing() {
        let location = entity(.location, [.atk: 3, .health: 3, .num_turns_in_play: 2])
        assertDamage(acting([location]), now: 0, next: 0)
    }

    func testEntitiesOutOfPlayIgnored() {
        let dead = minion(atk: 5, [.zone: Zone.graveyard.rawValue])
        let setAside = minion(atk: 5, [.zone: Zone.setaside.rawValue])
        assertDamage(acting([dead, setAside, minion(atk: 1)]), now: 1, next: 1)
    }

    // MARK: - Freeze

    func testFrozenOnSideNotCurrent() {
        assertDamage(notCurrent([minion(atk: 4, [.frozen: 1])]), now: 0, next: 0)
    }

    func testFrozenBeforeAttackingThaws() {
        let frozen = minion(atk: 4, [.frozen: 1, .exhausted: 0, .num_attacks_this_turn: 0])
        assertDamage(acting([frozen]), now: 0, next: 4)
    }

    func testFrozenAfterAttackingStaysFrozen() {
        let frozen = minion(atk: 4, [.frozen: 1, .exhausted: 1, .num_attacks_this_turn: 1])
        assertDamage(acting([frozen]), now: 0, next: 0)
    }

    func testFrozenWhileSummoningSickStaysFrozen() {
        let frozen = minion(atk: 4, [.frozen: 1, .exhausted: 1, .num_turns_in_play: 0])
        assertDamage(acting([frozen]), now: 0, next: 0)
    }

    func testFrozenWindfuryWithAttackLeftThaws() {
        let frozen = minion(atk: 3, [.frozen: 1, .windfury: 1, .exhausted: 0, .num_attacks_this_turn: 1])
        assertDamage(acting([frozen]), now: 0, next: 6)
    }

    // MARK: - Hero

    func testHeroWithoutWeapon() {
        let druid = hero(atk: 1)
        assertDamage(acting([druid]), now: 1, next: 0)
        assertDamage(notCurrent([druid]), now: 0, next: 0)
    }

    func testHeroWithWeapon() {
        let hero = self.hero(atk: 5)
        let weapon = self.weapon(atk: 3, health: 2)
        assertDamage(acting([hero, weapon]), now: 5, next: 3)

        hero[.num_attacks_this_turn] = 1
        hero[.exhausted] = 1
        assertDamage(acting([hero, weapon]), now: 0, next: 3)
    }

    func testSheathedWeaponOnSideNotCurrent() {
        let hero = self.hero(atk: 0)
        let weapon = self.weapon(atk: 3, health: 2, [.damage: 1, .exhausted: 1])
        assertDamage(notCurrent([hero, weapon]), now: 0, next: 3)
    }

    func testWindfuryWeapon() {
        // HDT WindfuryWeapon
        let weapon = self.weapon(atk: 2, health: 8, [.windfury: 1])
        assertDamage(acting([hero(atk: 2), weapon]), now: 4, next: 4)

        weapon[.damage] = 7
        assertDamage(acting([hero(atk: 2), weapon]), now: 2, next: 2)
    }

    func testWindfuryWeaponSingleChargeAndAttackedOnce() {
        // HDT WindfuryWeaponAttackSingleCharge and WindfuryWeaponAttackedOnce
        XCTAssertEqual(acting([hero(atk: 6), weapon(atk: 6, health: 1, [.windfury: 1])]).damageNow, 6)
        let attackedOnce = hero(atk: 6, [.num_attacks_this_turn: 1])
        XCTAssertEqual(acting([attackedOnce, weapon(atk: 6, health: 3, [.windfury: 1])]).damageNow, 6)
    }

    func testHeroWindfuryWithWeapon() {
        // HDT HeroHasWindfuryWithWeapon
        XCTAssertEqual(acting([hero(atk: 2, [.windfury: 1]), weapon(atk: 2, health: 2)]).damageNow, 4)
    }

    func testHeroWindfuryWithLastWeaponCharge() {
        // The second swing is after the weapon breaks: 2 x ATK - weapon Attack
        XCTAssertEqual(acting([hero(atk: 6, [.windfury: 1]), weapon(atk: 6, health: 1)]).damageNow, 6)
        XCTAssertEqual(acting([hero(atk: 8, [.windfury: 1]), weapon(atk: 6, health: 1)]).damageNow, 10)
    }

    func testHeroGotWindfuryFromMinion() {
        XCTAssertEqual(acting([hero(atk: 1, [.windfury: 1])]).damageNow, 2)
    }

    func testHeroWindfuryNextTurn() {
        let weapon = self.weapon(atk: 3, health: 5)
        // On the current side the hero's Windfury may only last this turn
        XCTAssertEqual(acting([hero(atk: 3, [.windfury: 1]), weapon]).damageNextTurn, 3)
        XCTAssertEqual(notCurrent([hero(atk: 0, [.windfury: 1]), weapon]).damageNextTurn, 6)
    }

    func testFrozenHero() {
        let hero = self.hero(atk: 0, [.frozen: 1])
        assertDamage(notCurrent([hero, weapon(atk: 4, health: 2)]), now: 0, next: 0)

        let frozenNow = self.hero(atk: 4, [.frozen: 1])
        assertDamage(acting([frozenNow, weapon(atk: 4, health: 2)]), now: 0, next: 4)
    }

    func testHeroCantAttack() {
        let hero = self.hero(atk: 4, [.cant_attack: 1])
        assertDamage(acting([hero, weapon(atk: 4, health: 2)]), now: 0, next: 0)
    }

    // MARK: - Infinite

    func testInfiniteAttack() {
        let infinite = minion(atk: BoardCard.infiniteAttack)
        let board = acting([infinite, minion(atk: 2)])
        XCTAssertTrue(board.hasInfiniteDamageNow)
        XCTAssertTrue(board.hasInfiniteDamageNextTurn)

        let sick = minion(atk: BoardCard.infiniteAttack, [.num_turns_in_play: 0, .exhausted: 1])
        let sickBoard = acting([sick, minion(atk: 2)])
        XCTAssertFalse(sickBoard.hasInfiniteDamageNow)
        XCTAssertEqual(sickBoard.damageNow, 2)
        XCTAssertTrue(sickBoard.hasInfiniteDamageNextTurn)
    }

    // MARK: - Hero power

    private func steadyShot(_ tags: [GameTag: Int] = [:]) -> Entity {
        var all: [GameTag: Int] = [.cost: 2]
        all.merge(tags) { $1 }
        return entity(.hero_power, cardId: CardIds.NonCollectible.Hunter.SteadyShot, all)
    }

    private func mana(_ resources: Int, used: Int = 0) -> Entity {
        return entity(.player, [.resources: resources, .resources_used: used])
    }

    func testHeroPower() {
        assertDamage(acting([hero(), steadyShot()], playerEntity: mana(5)), now: 2, next: 2)
        let used = steadyShot([.exhausted: 1, .heropower_activations_this_turn: 1])
        assertDamage(acting([hero(), used], playerEntity: mana(5)), now: 0, next: 2)
        assertDamage(acting([hero(), steadyShot()], playerEntity: mana(5, used: 4)), now: 0, next: 2)
        assertDamage(notCurrent([hero(), steadyShot()], playerEntity: mana(5)), now: 0, next: 2)
        assertDamage(acting([hero(), steadyShot([.hero_power_disabled: 1])], playerEntity: mana(5)), now: 0, next: 0)
    }

    func testHeroPowerTemporaryMana() {
        let player = entity(.player, [.resources: 1, .temp_resources: 1])
        XCTAssertEqual(acting([hero(), steadyShot()], playerEntity: player).damageNow, 2)
    }

    func testHeroPowerWithGarrisonCommander() {
        let commander = minion(atk: 2, [.num_turns_in_play: 0, .exhausted: 1])
        commander.cardId = CardIds.Collectible.Neutral.GarrisonCommander
        let power = steadyShot([.heropower_activations_this_turn: 1, .exhausted: 0])
        assertDamage(acting([hero(), commander, power], playerEntity: mana(2)), now: 2, next: 2 + 4)
    }

    func testShapeshiftNeedsTheHeroToAttack() {
        let shapeshift = entity(.hero_power, cardId: CardIds.NonCollectible.Druid.Shapeshift, [.cost: 2])
        assertDamage(acting([hero(), shapeshift], playerEntity: mana(3)), now: 1, next: 1)
        let attacked = hero(atk: 0, [.num_attacks_this_turn: 1, .exhausted: 1])
        assertDamage(acting([attacked, shapeshift], playerEntity: mana(3)), now: 0, next: 1)
        let cantAttack = hero(atk: 0, [.cant_attack: 1])
        assertDamage(acting([cantAttack, shapeshift], playerEntity: mana(3)), now: 0, next: 0)
    }

    func testCurrentHeroPowersMatchedByName() {
        let cardId = "HERO_05dbp"
        let previous = Cards.cardsById[cardId]
        defer { Cards.cardsById[cardId] = previous }
        let card = Card()
        card.id = cardId
        card.enName = "Steady Shot"
        Cards.cardsById[cardId] = card

        let power = entity(.hero_power, cardId: cardId, [.cost: 2])
        XCTAssertEqual(HeroPower(entity: power).damage, 2)
        XCTAssertFalse(HeroPower(entity: power).isHeroAttack)
    }

    // MARK: - Weapon choice (HDT PlayerBoardTest)

    func testWeaponChoice() {
        let board = PlayerBoard(list: [], isCurrent: false, isActing: false)
        let old = weapon(atk: 1, health: 2)
        let new = weapon(atk: 3, health: 2, [.just_played: 1])
        XCTAssertNil(board.getWeapon(list: []))
        XCTAssertTrue(board.getWeapon(list: [old]) === old)
        XCTAssertTrue(board.getWeapon(list: [new, old]) === new)
        XCTAssertTrue(board.getWeapon(list: [old, new]) === new)

        let buried = weapon(atk: 5, health: 2, [.zone: Zone.graveyard.rawValue])
        assertDamage(notCurrent([hero(), buried]), now: 0, next: 0)
        let setAside = weapon(atk: 5, health: 2, [.zone: Zone.setaside.rawValue])
        assertDamage(notCurrent([hero(), setAside, old]), now: 0, next: 1)
    }

    // MARK: - Dead to board

    func testDeadToBoardUsesNextTurn() {
        let playerHero = hero(atk: 0, [.health: 30, .damage: 26])
        let opponentHero = hero(atk: 0, [.health: 30, .armor: 5])
        let state = BoardState(player: acting([playerHero]),
                               opponent: notCurrent([opponentHero, minion(atk: 4)]))
        XCTAssertTrue(state.isPlayerDeadToBoard())
        XCTAssertFalse(state.isOpponentDeadToBoard())
    }

    // MARK: - Refresh

    func testRefreshTriggers() {
        let inPlay = minion(atk: 2)
        let inHand = minion(atk: 2, [.zone: Zone.hand.rawValue])
        XCTAssertTrue(BoardState.affectsBoardDamage(entity: inPlay, tag: .num_attacks_this_turn, prevValue: 0, value: 1))
        XCTAssertTrue(BoardState.affectsBoardDamage(entity: inPlay, tag: .frozen, prevValue: 0, value: 1))
        XCTAssertTrue(BoardState.affectsBoardDamage(entity: inPlay, tag: .atk, prevValue: 2, value: 4))
        XCTAssertFalse(BoardState.affectsBoardDamage(entity: inHand, tag: .atk, prevValue: 2, value: 4))
        XCTAssertFalse(BoardState.affectsBoardDamage(entity: inPlay, tag: .predamage, prevValue: 0, value: 3))
        XCTAssertTrue(BoardState.affectsBoardDamage(entity: inHand, tag: .step, prevValue: 9, value: 10))
        XCTAssertTrue(BoardState.affectsBoardDamage(entity: inHand, tag: .current_player, prevValue: 0, value: 1))
        XCTAssertTrue(BoardState.affectsBoardDamage(entity: inPlay, tag: .zone,
                                                    prevValue: Zone.hand.rawValue, value: Zone.play.rawValue))
        XCTAssertFalse(BoardState.affectsBoardDamage(entity: inHand, tag: .zone,
                                                     prevValue: Zone.deck.rawValue, value: Zone.hand.rawValue))
    }

    // MARK: - Display

    func testDisplayText() {
        XCTAssertEqual(BoardDamage.attributedText(now: 7, nextTurn: 7).string, "7(7)")
        XCTAssertEqual(BoardDamage.attributedText(now: 0, nextTurn: 9).string, "0(9)")
        XCTAssertEqual(BoardDamage.attributedText(now: 0, nextTurn: Int.max).string, "0(\u{221e})")
        XCTAssertEqual(BoardDamage.attributedText(now: Int.max, nextTurn: Int.max).string, "\u{221e}(\u{221e})")
    }

    func testDisplayFitsTheBadge() {
        // The hosted app registers its bundled fonts; without Belwe the widths below would mean nothing
        XCTAssertNotNil(NSFont(name: BoardDamage.fontName, size: 18))
        for (now, next) in [(12, 20), (24, 38), (99, 120)] {
            let text = BoardDamage.attributedText(now: now, nextTurn: next)
            XCTAssertLessThanOrEqual(text.size().width, BoardDamage.maxTextWidth, text.string)
        }
    }

    func testDisplayFontsKeepTheirRatio() {
        let small = BoardDamage.attributedText(now: 7, nextTurn: 7)
        XCTAssertEqual((small.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual((small.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.pointSize, 12)

        let huge = BoardDamage.attributedText(now: 12345, nextTurn: 123456)
        let nowSize = (huge.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        let nextSize = (huge.attribute(.font, at: huge.length - 1, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        XCTAssertEqual(nowSize, BoardDamage.minNowFontSize)
        XCTAssertEqual(nextSize, 8, accuracy: 0.001)
    }
}
