//
//  ActionHistoryPresentationTests.swift
//  HSTrackerTests
//
//  The action history panel's wording and grouping (ActionHistoryPresentation), its view model's
//  folding and dragging, and the ActionHistory_* entries in Localizable.xcstrings.
//
//  Nothing here writes Settings: the test host is HSTracker.app, whose defaults domain is the
//  player's own, so toggleCollapsed and endDrag (which persist) are not called.
//

import XCTest
import Foundation

@testable import HSTracker

class ActionHistoryPresentationTests: HSTrackerTests {
    private static let knownCardId = "ACTIONHISTORY_TEST_001"
    private static let knownCardName = "Test Minion"
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        let card = Card()
        card.id = ActionHistoryPresentationTests.knownCardId
        card.name = ActionHistoryPresentationTests.knownCardName
        Cards.cardsById[card.id] = card
    }

    override func tearDown() {
        Cards.cardsById.removeValue(forKey: ActionHistoryPresentationTests.knownCardId)
        super.tearDown()
    }

    private func ref(_ entityId: Int, _ cardId: String?, side: HistorySide = .opponent, isSecret: Bool = false) -> HistoryCardRef {
        return HistoryCardRef(entityId: entityId, cardId: cardId, side: side, cardType: CardType.minion.rawValue, isSecret: isSecret)
    }

    private func entry(_ id: Int, _ type: HistoryActionType = .play, effects: [HistoryEffect] = [], children: [HistoryEntry] = []) -> HistoryEntry {
        return HistoryEntry(id: id, rawTurn: 3, turn: 2, activeSide: .player, type: type, effects: effects, children: children, time: time)
    }

    // MARK: - Turns

    func testSectionsListTheNewestTurnFirstWithStableKeys() {
        let turns = [
            HistoryTurn(rawTurn: 1, turn: 1, side: .player),
            HistoryTurn(rawTurn: 2, turn: 1, side: .opponent),
            // A GAME_RESET rewind records the same raw turn again
            HistoryTurn(rawTurn: 2, turn: 1, side: .opponent),
            HistoryTurn(rawTurn: 3, turn: 2, side: .player)
        ]
        let sections = ActionHistoryPresentation.sections(turns)
        XCTAssertEqual(sections.map { $0.turn.rawTurn }, [3, 2, 2, 1])
        XCTAssertEqual(sections.map { $0.index }, [3, 2, 1, 0])
        XCTAssertEqual(sections.map { $0.key }, ["3.0", "2.1", "2.0", "1.0"])

        // Appending a turn leaves the keys of the earlier ones alone
        let more = ActionHistoryPresentation.sections(turns + [HistoryTurn(rawTurn: 4, turn: 2, side: .opponent)])
        XCTAssertEqual(more.map { $0.key }, ["4.0", "3.0", "2.1", "2.0", "1.0"])
    }

    func testTurnTitlesCarryTheTurnNumberAndSide() {
        let mine = ActionHistoryPresentation.turnTitle(HistoryTurn(rawTurn: 13, turn: 7, side: .player))
        let theirs = ActionHistoryPresentation.turnTitle(HistoryTurn(rawTurn: 14, turn: 7, side: .opponent))
        XCTAssertTrue(mine.contains("7"), mine)
        XCTAssertTrue(theirs.contains("7"), theirs)
        XCTAssertNotEqual(mine, theirs)
        XCTAssertEqual(ActionHistoryPresentation.turnTitle(HistoryTurn(rawTurn: 0, turn: 0, side: .neutral)),
                       String.localizedString("ActionHistory_StartOfGame", comment: ""))
    }

    // MARK: - Names

    func testHiddenCardsAreNamedGenericallyAndPublicOnesByTheirCard() {
        XCTAssertEqual(ActionHistoryPresentation.name(ref(5, ActionHistoryPresentationTests.knownCardId)),
                       ActionHistoryPresentationTests.knownCardName)
        XCTAssertEqual(ActionHistoryPresentation.name(ref(5, nil)),
                       String.localizedString("ActionHistory_UnknownCard", comment: ""))
        XCTAssertEqual(ActionHistoryPresentation.name(ref(6, nil, isSecret: true)),
                       String.localizedString("ActionHistory_UnknownSecret", comment: ""))
        // A card missing from the database still prints something
        XCTAssertEqual(ActionHistoryPresentation.name(ref(7, "NOT_A_CARD_ID")), "NOT_A_CARD_ID")
    }

    // MARK: - Effects

    func testEffectLinesListEveryTargetAndCountHiddenCards() {
        let effects = [
            HistoryEffect(kind: .damage, targets: [ref(10, "A"), ref(11, "B"), ref(12, "C")], amount: 2),
            HistoryEffect(kind: .drewUnknown, targets: [ref(20, nil), ref(21, nil)], amount: 2),
            HistoryEffect(kind: .generated, targets: [ref(30, nil)], amount: 1),
            HistoryEffect(kind: .transformed, targets: [ref(40, "BEFORE")], detailCardId: "AFTER"),
            HistoryEffect(kind: .died, targets: [ref(50, "D")])
        ]
        let lines = ActionHistoryPresentation.lines(effects, idPrefix: "e")

        XCTAssertEqual(lines.count, 3 + 1 + 1 + 1 + 1)
        XCTAssertEqual(Set(lines.map { $0.id }).count, lines.count, "line ids must be unique for ForEach")

        let damage = Array(lines[0..<3])
        XCTAssertEqual(damage.map { $0.cards.map { $0.entityId } }, [[10], [11], [12]])
        XCTAssertTrue(damage.allSatisfy { $0.label == String(format: String.localizedString("ActionHistory_EffectDamage", comment: ""), 2) })
        XCTAssertTrue(damage.allSatisfy { $0.tone == .damage })

        XCTAssertEqual(lines[3].label, String(format: String.localizedString("ActionHistory_EffectDrewCount", comment: ""), 2))
        XCTAssertTrue(lines[3].cards.isEmpty, "the opponent's draws are only a count")
        XCTAssertEqual(lines[4].label, String(format: String.localizedString("ActionHistory_EffectGeneratedCount", comment: ""), 1))
        XCTAssertTrue(lines[4].cards.isEmpty)

        XCTAssertEqual(lines[5].cards.map { $0.cardId }, ["BEFORE", "AFTER"])
        XCTAssertEqual(lines[6].tone, .death)
    }

    func testATransformIntoAHiddenCardShowsOnlyTheCardBefore() {
        let lines = ActionHistoryPresentation.lines([HistoryEffect(kind: .transformed, targets: [ref(40, "BEFORE")])], idPrefix: "e")
        XCTAssertEqual(lines.map { $0.cards.map { $0.cardId } }, [["BEFORE"]])
    }

    func testEnchantmentLinesUseTheEnchantmentName() {
        let named = HistoryEffect(kind: .enchanted, targets: [ref(10, "A")], detailCardId: ActionHistoryPresentationTests.knownCardId)
        XCTAssertEqual(ActionHistoryPresentation.label(named), ActionHistoryPresentationTests.knownCardName)
        let unknown = HistoryEffect(kind: .enchanted, targets: [ref(10, "A")], detailCardId: "NOT_A_CARD_ID")
        XCTAssertEqual(ActionHistoryPresentation.label(unknown), String.localizedString("ActionHistory_EffectEnchanted", comment: ""))
    }

    // MARK: - Entries

    func testSummaryAddsUpTheEntryAndItsSubActions() {
        let secret = entry(2, .secret, effects: [
            HistoryEffect(kind: .damage, targets: [ref(10, "A")], amount: 4),
            HistoryEffect(kind: .destroyed, targets: [ref(11, "B")])
        ])
        let play = entry(1, effects: [
            HistoryEffect(kind: .damage, targets: [ref(12, "C"), ref(13, "D")], amount: 3),
            HistoryEffect(kind: .heal, targets: [ref(14, "E")], amount: 2),
            HistoryEffect(kind: .died, targets: [ref(12, "C"), ref(13, "D")])
        ], children: [secret])

        let summary = ActionHistoryPresentation.summary(play)
        XCTAssertEqual(summary, ActionHistorySummary(damage: 3 * 2 + 4, heal: 2, deaths: 3))
        XCTAssertTrue(ActionHistoryPresentation.summary(entry(3, .secret)).isEmpty)
    }

    func testChildrenAreFlattenedInResolutionOrder() {
        let grandchild = entry(4, .deathrattle)
        let child = entry(2, .secret, children: [grandchild])
        let sibling = entry(3, .trigger)
        let parent = entry(1, children: [child, sibling])

        let flat = ActionHistoryPresentation.flattenedChildren(parent)
        XCTAssertEqual(flat.map { $0.id }, [2, 4, 3])
        XCTAssertTrue(flat.allSatisfy { $0.children.isEmpty })
    }

    func testOnlyRowsWithSomethingToUnfoldAreExpandable() {
        XCTAssertFalse(ActionHistoryPresentation.hasDetails(entry(1, .secret)))
        XCTAssertTrue(ActionHistoryPresentation.hasDetails(entry(2, effects: [HistoryEffect(kind: .died, targets: [ref(1, "A")])])))
        XCTAssertTrue(ActionHistoryPresentation.hasDetails(entry(3, children: [entry(4, .secret)])))
        var attack = entry(5, .attack)
        attack.weapon = ref(6, "W", side: .player)
        XCTAssertTrue(ActionHistoryPresentation.hasDetails(attack))
    }

    // MARK: - View model

    func testTheLatestTwoTurnsUnfoldUntilThePlayerFoldsThem() {
        guard #available(macOS 10.15, *) else { return }
        let viewModel = ActionHistoryViewModel()
        let turns = (1...4).map { HistoryTurn(rawTurn: $0, turn: ($0 + 1) / 2, side: $0 % 2 == 1 ? .player : .opponent) }
        viewModel.apply(ActionHistorySnapshot(turns: turns, version: 1))

        var sections = ActionHistoryPresentation.sections(viewModel.turns)
        XCTAssertEqual(sections.map { viewModel.isTurnExpanded($0) }, [true, true, false, false])

        viewModel.toggleTurn(sections[0])
        viewModel.toggleTurn(sections[3])
        XCTAssertEqual(sections.map { viewModel.isTurnExpanded($0) }, [false, true, false, true])

        // A new turn unfolds; the ones the player touched keep their state
        viewModel.apply(ActionHistorySnapshot(turns: turns + [HistoryTurn(rawTurn: 5, turn: 3, side: .player)], version: 2))
        sections = ActionHistoryPresentation.sections(viewModel.turns)
        XCTAssertEqual(sections.map { viewModel.isTurnExpanded($0) }, [true, false, false, false, true])
    }

    func testANewGameForgetsWhatWasUnfolded() {
        guard #available(macOS 10.15, *) else { return }
        let viewModel = ActionHistoryViewModel()
        let played = entry(7)
        viewModel.apply(ActionHistorySnapshot(turns: [HistoryTurn(rawTurn: 3, turn: 2, side: .player, entries: [played])], version: 1))
        viewModel.toggleEntry(played)
        viewModel.toggleTurn(ActionHistoryPresentation.sections(viewModel.turns)[0])
        XCTAssertTrue(viewModel.isEntryExpanded(played))
        XCTAssertFalse(viewModel.turnExpansion.isEmpty)

        // An equal version is skipped
        viewModel.apply(ActionHistorySnapshot(turns: [], version: 1))
        XCTAssertEqual(viewModel.turns.count, 1)

        viewModel.apply(ActionHistorySnapshot(turns: [], version: 2))
        XCTAssertTrue(viewModel.turns.isEmpty)
        XCTAssertFalse(viewModel.isEntryExpanded(played))
        XCTAssertTrue(viewModel.turnExpansion.isEmpty)
    }

    func testDraggingMovesThePanelFromWhereItWasAndKeepsItOnTheCanvas() {
        guard #available(macOS 10.15, *) else { return }
        let viewModel = ActionHistoryViewModel()
        viewModel.panelSize = CGSize(width: ActionHistoryViewModel.panelWidth, height: 300)
        let canvas = CGSize(width: 2000, height: 1000)
        let start = viewModel.origin(canvasSize: canvas)
        XCTAssertGreaterThanOrEqual(start.x, 0)
        XCTAssertLessThanOrEqual(start.x, canvas.width - ActionHistoryViewModel.panelWidth)

        // Moves by the total translation, and a second event does not add the first one again
        viewModel.drag(translation: CGSize(width: 30, height: 10), canvasSize: canvas)
        viewModel.drag(translation: CGSize(width: 60, height: 20), canvasSize: canvas)
        let moved = viewModel.origin(canvasSize: canvas)
        XCTAssertEqual(moved.x, min(max(0, start.x + 60), canvas.width - ActionHistoryViewModel.panelWidth), accuracy: 0.01)
        XCTAssertEqual(moved.y, min(max(0, start.y + 20), canvas.height - 24), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(viewModel.left, 0, "a dragged panel no longer follows the tracker")

        // Far past the edge it stops at the canvas
        viewModel.drag(translation: CGSize(width: 10_000, height: 10_000), canvasSize: canvas)
        let clamped = viewModel.origin(canvasSize: canvas)
        XCTAssertEqual(clamped.x, canvas.width - ActionHistoryViewModel.panelWidth, accuracy: 0.01)
        XCTAssertEqual(clamped.y, canvas.height - 24, accuracy: 0.01)
        XCTAssertEqual(viewModel.tooltipPlacement(canvasSize: canvas), .left)
    }

    // MARK: - Localization

    func testEveryPanelStringHasEnglishAndChineseTranslations() throws {
        // The catalog in the source tree, next to this file's folder
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Translations/macOS/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        let used = Set(ActionHistoryPresentation.localizationKeys)
        let catalogued = Set(strings.keys.filter { $0.hasPrefix("ActionHistory_") })
        XCTAssertEqual(used, catalogued, "keys used by the panel and keys in the catalog differ")

        func specifiers(_ value: String) -> [String] {
            let regex = try? NSRegularExpression(pattern: "%[d@]")
            let range = NSRange(value.startIndex..., in: value)
            return regex?.matches(in: value, range: range).compactMap { Range($0.range, in: value).map { String(value[$0]) } } ?? []
        }

        for key in used.sorted() {
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            var english: String?
            for language in ["en", "zh-Hans", "zh-Hant"] {
                let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                XCTAssertFalse(value?.isEmpty ?? true, "\(key) has no \(language) value")
                XCTAssertEqual(unit?["state"] as? String, "translated", "\(key) \(language)")
                if language == "en" {
                    english = value
                } else if let english, let value {
                    XCTAssertEqual(specifiers(value), specifiers(english), "\(key) \(language) format specifiers")
                }
            }
            // And the built app resolves it
            XCTAssertNotEqual(String.localizedString(key, comment: ""), key, key)
        }
    }
}
