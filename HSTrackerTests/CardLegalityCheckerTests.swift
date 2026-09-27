//
//  CardLegalityCheckerTests.swift
//  HSTrackerTests
//
//  Legality before and after HSReplay's legal cards list is in, which decides what the related
//  cards pools (Infest the Scullery's random minions, discover pools) are made of.
//

import XCTest
@testable import HSTracker

class CardLegalityCheckerTests: HSTrackerTests {
    static var database: Database!

    override class func setUp() {
        super.setUp()
        database = Database()
        database.loadDatabase(splashscreen: nil, withLanguages: [.enUS])
    }

    override func setUp() {
        super.setUp()
        CardLegalityChecker.clearLegalCards()
    }

    override func tearDown() {
        CardLegalityChecker.clearLegalCards()
        super.tearDown()
    }

    /// Until the list is in, legality comes from the card's set. It used to be read off a bare
    /// Card(id:), which has no set, so every card was illegal and the pools came out empty.
    func testFallbackReadsTheCardsSet() throws {
        let scullery = try XCTUnwrap(Cards.by(cardId: CardIds.Collectible.Druid.InfestTheScullery))
        XCTAssertNotNil(scullery.set)
        XCTAssertTrue(scullery.isCardLegal(gameType: .gt_ranked, format: .ft_wild))
        XCTAssertTrue(InfestTheScullery().isCardLegal(gameType: .gt_ranked, format: .ft_wild))

        let minions = Cards.collectible().filter { $0.type == .minion }
        XCTAssertFalse(minions.filter { $0.isCardLegal(gameType: .gt_ranked, format: .ft_standard) }.isEmpty)
    }

    func testTheListWinsOnceItIsIn() {
        CardLegalityChecker.store([CardIds.Collectible.Druid.InfestTheScullery], gameType: .gt_ranked, format: .ft_standard)

        XCTAssertTrue(InfestTheScullery().isCardLegal(gameType: .gt_ranked, format: .ft_standard))
        XCTAssertFalse(CardLegalityChecker.poolKey(gameType: .gt_ranked, format: .ft_standard)
            == CardLegalityChecker.poolKey(gameType: .gt_ranked, format: .ft_wild))
    }

    /// A pool cached while the list was loading is keyed apart from one worked out with it, so the
    /// list's arrival brings in a fresh pool rather than the one from game start.
    func testPoolKeyChangesWhenTheListArrives() {
        let before = CardLegalityChecker.poolKey(gameType: .gt_ranked, format: .ft_standard)
        CardLegalityChecker.store(["JAIL_200"], gameType: .gt_ranked, format: .ft_standard)
        XCTAssertNotEqual(before, CardLegalityChecker.poolKey(gameType: .gt_ranked, format: .ft_standard))
    }
}
