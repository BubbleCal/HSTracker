//
//  TrackerPanelLayoutTests.swift
//  HSTrackerTests
//
//  Created by Francisco Moraes on 9/17/26.
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import SwiftUI
import XCTest
@testable import HSTracker

/// The part of the deck-tracker port that is pure arithmetic: which sections a
/// stack shows, in what order, and how far the card rows have to shrink to fit
/// the box HDT's `PlayerStackHeight` gives them.
@available(macOS 10.15, *)
class TrackerPanelLayoutTests: HSTrackerTests {

    private var saved: [String: Any?] = [:]

    private static let keys = [
        Settings.deck_panel_order_player, Settings.deck_panel_order_opponent,
        Settings.player_deck_height, Settings.opponent_deck_height,
        Settings.overlay_player_scaling, Settings.overlay_opponent_scaling,
        Settings.card_size,
        Settings.show_deck_name, Settings.show_win_loss_ratio,
        Settings.player_card_count, Settings.player_draw_chance,
        Settings.player_cards_top, Settings.player_cards_bottom, Settings.hide_player_sideboards,
        Settings.opponent_card_count, Settings.opponent_draw_chance,
        Settings.show_opponent_class, Settings.opponent_related_cards,
        Settings.hide_opponent_arena_packages, Settings.show_matchup_win_rate
    ]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.keys {
            saved[key] = defaults.object(forKey: key)
        }
        // A known baseline, so a developer's own settings cannot change the
        // outcome of any of these.
        Settings.cardSize = .big
        Settings.showDeckNameInTracker = true
        Settings.showWinLossRatio = true
        Settings.showMatchupWinRate = true
        Settings.showPlayerCardCount = true
        Settings.showPlayerDrawChance = true
        Settings.showPlayerCardsTop = true
        Settings.showPlayerCardsBottom = true
        Settings.hidePlayerSideboards = false
        Settings.showOpponentCardCount = true
        Settings.showOpponentDrawChance = true
        Settings.showOpponentClassInTracker = true
        Settings.showOpponentRelatedCards = true
        Settings.hideOpponentArenaPackages = false
        Settings.deckPanelOrderPlayer = DeckPanel.defaultPlayerOrder.map { $0.rawValue }
        Settings.deckPanelOrderOpponent = DeckPanel.defaultOpponentOrder.map { $0.rawValue }
        Settings.overlayPlayerScaling = 100
        Settings.overlayOpponentScaling = 100
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for (key, value) in saved {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        saved.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func cards(_ count: Int) -> [Card] {
        (0..<count).map { index in
            let card = Card()
            card.id = "TEST_\(index)"
            card.count = 1
            return card
        }
    }

    private func playerModel(deck: Int = 0, top: Int = 0, bottom: Int = 0,
                             height: Double = 88) -> TrackerPanelViewModel {
        let model = TrackerPanelViewModel(playerType: .player)
        model.update(cards: cards(deck), top: cards(top), bottom: cards(bottom),
                     sideboards: [], relatedCards: [])
        model.playerClassId = "HERO_01"
        // A saved deck's record: without one the W-L line is not drawn at all
        model.recordMessage = "3-2 (60%)"
        model.height = height
        model.panelOrder = DeckPanel.order(for: .player)
        return model
    }

    private func kinds(_ layout: TrackerPanelLayout) -> [TrackerPanelLayout.Kind] {
        layout.sections.map { $0.kind }
    }

    // MARK: - Order

    func testPlayerSectionsFollowHDTDefaultOrder() {
        let model = playerModel(deck: 5, top: 1, bottom: 1)
        model.showGraveyard = true
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        XCTAssertEqual(kinds(layout), [
            .deckPanel(.deckTitle), .deckPanel(.wins), .deckPanel(.cardsTop), .deckPanel(.cards),
            .deckPanel(.cardsBottom), .deckPanel(.cardCounter), .deckPanel(.drawChances),
            .deckPanel(.graveyard)
        ])
    }

    func testSavedOrderIsHonoured() {
        Settings.deckPanelOrderPlayer = [DeckPanel.drawChances, .cardCounter, .cards, .deckTitle]
            .map { $0.rawValue }
        let model = playerModel(deck: 3)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        // The saved order comes first; anything it predates is appended in the
        // default order's own sequence, so nothing silently goes missing.
        XCTAssertEqual(Array(kinds(layout).prefix(4)), [
            .deckPanel(.drawChances), .deckPanel(.cardCounter), .deckPanel(.cards), .deckPanel(.deckTitle)
        ])
        XCTAssertTrue(kinds(layout).contains(.deckPanel(.wins)))
    }

    func testHiddenSectionsAreLeftOut() {
        Settings.showWinLossRatio = false
        Settings.showPlayerCardCount = false
        let model = playerModel(deck: 3)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        XCTAssertFalse(kinds(layout).contains(.deckPanel(.wins)))
        XCTAssertFalse(kinds(layout).contains(.deckPanel(.cardCounter)))
        XCTAssertTrue(kinds(layout).contains(.deckPanel(.cards)))
    }

    /// This fork hides the W-L line without a saved deck to count, as HDT hides its label, and
    /// draws the active deck's record against the opponent's class on a second line under it.
    func testWinsSectionDrawsOneFramePerLine() {
        let model = playerModel(deck: 3)
        model.recordMessage = ""
        XCTAssertFalse(kinds(TrackerPanelLayout(viewModel: model, canvasHeight: 1080)).contains(.deckPanel(.wins)))

        func winsHeight() -> CGFloat? {
            TrackerPanelLayout(viewModel: model, canvasHeight: 1080).sections
                .first { $0.kind == .deckPanel(.wins) }?.height
        }
        model.recordMessage = "3-2 (60%)"
        let one = try? XCTUnwrap(winsHeight())
        model.matchupMessage = "VS Mage: 1-0 (100%)"
        let two = try? XCTUnwrap(winsHeight())
        XCTAssertEqual(two ?? 0, 2 * (one ?? 0), accuracy: 0.01)
        XCTAssertGreaterThan(one ?? 0, 0)

        // The matchup line alone, for a deck with no games yet against anyone else
        Settings.showWinLossRatio = false
        XCTAssertEqual(winsHeight() ?? 0, one ?? -1, accuracy: 0.01)
    }

    func testEmptyLensesAreLeftOut() {
        let model = playerModel(deck: 3, top: 0, bottom: 0)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        XCTAssertFalse(kinds(layout).contains(.deckPanel(.cardsTop)))
        XCTAssertFalse(kinds(layout).contains(.deckPanel(.cardsBottom)))
    }

    /// HDT appends OpponentPackageCardsDeckLens and then OpponentRelatedCardsDeckLens
    /// after whatever DeckPanelOrderOpponent says (OverlayWindow.UpdateOpponentLayout).
    func testOpponentLensesComeAfterTheOrderedSections() {
        let model = TrackerPanelViewModel(playerType: .opponent)
        model.update(cards: cards(4), top: [], bottom: [], sideboards: [],
                     relatedCards: cards(2), packageCards: cards(1), packageLabel: "pkg")
        model.playerClassId = "HERO_02"
        model.panelOrder = DeckPanel.order(for: .opponent)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        XCTAssertEqual(kinds(layout), [
            .deckPanel(.deckTitle), .deckPanel(.cards), .deckPanel(.cardCounter),
            .deckPanel(.drawChances), .packageLens, .relatedLens
        ])
    }

    /// The opponent has no top/bottom/sideboard sections, and a saved order that
    /// names them must not resurrect them.
    func testOpponentOrderDropsPlayerOnlySections() {
        Settings.deckPanelOrderOpponent = [DeckPanel.cardsTop, .cards, .sideboards, .cardCounter]
            .map { $0.rawValue }
        let order = DeckPanel.order(for: .opponent)

        XCTAssertFalse(order.contains(.cardsTop))
        XCTAssertFalse(order.contains(.sideboards))
        XCTAssertEqual(Array(order.prefix(2)), [.cards, .cardCounter])
    }

    // MARK: - Sizing

    /// PlayerStackHeight = (PlayerDeckHeight / 100 * Height) / (OverlayPlayerScaling / 100)
    func testBoxHeightFollowsHDTsStackHeight() {
        Settings.overlayPlayerScaling = 50
        let model = playerModel(deck: 1)
        model.scaling = 50
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1000)

        XCTAssertEqual(layout.boxHeight, 1000 * 0.88 / 0.5, accuracy: 0.001)
    }

    /// CardListHelper.AutoScaleCardTiles: the rows shrink until the stack fits.
    func testCardRowsShrinkToFitTheBox() {
        let model = playerModel(deck: 60, height: 40)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        XCTAssertLessThan(layout.cardHeight, CGFloat(kRowHeight))
        let content = layout.sections.reduce(0) { $0 + $1.height }
        XCTAssertLessThanOrEqual(content, layout.boxHeight + 0.001)
    }

    /// The frames shrink with the rows. They used to stay at their full 40pt while
    /// only the rows gave way, so a long deck drew its counters twice the height of
    /// a card row - and, since a row narrows as it shrinks, far wider too.
    func testFramesShrinkWithTheCardRows() {
        let model = playerModel(deck: 30, top: 2, height: 50)
        model.showGraveyard = true
        model.matchupMessage = "VS Mage: 1-0 (100%)"
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        XCTAssertLessThan(layout.fit, 1)
        XCTAssertEqual(layout.cardHeight, CGFloat(kRowHeight) * layout.fit, accuracy: 0.001)
        XCTAssertEqual(layout.smallFrameHeight, 40 * layout.fit, accuracy: 0.001)
        XCTAssertEqual(layout.bigFrameHeight, 71 * layout.fit, accuracy: 0.001)
        XCTAssertEqual(layout.contentWidth, layout.width * layout.fit, accuracy: 0.001)
        // A frame keeps its authored proportion to a row
        XCTAssertEqual(layout.smallFrameHeight / layout.cardHeight, 40 / CGFloat(kRowHeight), accuracy: 0.001)
        // ... and the whole stack, frames included, just fills the box
        let content = layout.sections.reduce(0) { $0 + $1.height }
        XCTAssertEqual(content, layout.boxHeight, accuracy: 0.01)
    }

    /// With room to spare nothing is shrunk.
    func testNothingShrinksWhenTheStackFits() {
        let model = playerModel(deck: 5, height: 100)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 2000)

        XCTAssertEqual(layout.fit, 1)
        XCTAssertEqual(layout.smallFrameHeight, 40)
        XCTAssertEqual(layout.contentWidth, layout.width)
    }

    /// ... and never past the card size the user picked, however much room there is.
    func testCardRowsNeverGrowPastTheChosenCardSize() {
        Settings.cardSize = .small
        let model = playerModel(deck: 2, height: 100)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 2000)

        XCTAssertEqual(layout.cardHeight, CGFloat(kSmallRowHeight), accuracy: 0.001)
    }

    /// The frame PNGs are authored at 217x40 (x71 for the opponent's chances) and
    /// drawn divided by the card size's ratio - see TextFrame.ratio.
    func testFrameHeightsFollowTheCardSizeRatio() {
        Settings.cardSize = .medium
        let model = playerModel(deck: 1)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        XCTAssertEqual(layout.smallFrameHeight, (40 / CGFloat(CardSize.medium.ratio)).rounded())
        XCTAssertEqual(layout.bigFrameHeight, (71 / CGFloat(CardSize.medium.ratio)).rounded())
    }

    // MARK: - Section offsets

    func testSectionOffsetIsTheSumOfWhatPrecedesIt() {
        let model = playerModel(deck: 4)
        model.showGraveyard = true
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)

        guard let graveyard = layout.offset(of: .deckPanel(.graveyard), centered: false) else {
            return XCTFail("graveyard section missing")
        }
        var expected: CGFloat = 0
        for section in layout.sections {
            if section.kind == .deckPanel(.graveyard) { break }
            expected += section.height
        }
        XCTAssertEqual(graveyard.y, expected, accuracy: 0.001)
        XCTAssertEqual(graveyard.height, layout.smallFrameHeight, accuracy: 0.001)
    }

    /// OverlayCenterPlayerStackPanel, which HDT expresses as the stack's
    /// VerticalAlignment inside its fixed-height border.
    func testCenteredStackOffsetsEverySectionByHalfTheSlack() {
        let model = playerModel(deck: 2, height: 90)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: 1080)
        let content = layout.sections.reduce(0) { $0 + $1.height }

        guard let top = layout.offset(of: layout.sections[0].kind, centered: true) else {
            return XCTFail("first section missing")
        }
        XCTAssertEqual(top.y, (layout.boxHeight - content) / 2, accuracy: 0.001)
    }

    // MARK: - Rows

    /// The rows are SwiftUI now, so the panel has to report where each one is for
    /// the cursor sweep to raise its preview - `CardBar`'s own tracking areas are
    /// gone, and were dead over a click-through window anyway.
    func testPanelReportsARowPerCardForHover() throws {
        Settings.showDeckNameInTracker = false
        Settings.showWinLossRatio = false
        Settings.showPlayerCardCount = false
        Settings.showPlayerDrawChance = false

        let model = playerModel(deck: 6)
        model.isShown = true
        let canvas = CGSize(width: 1920, height: 1080)
        let layout = TrackerPanelLayout(viewModel: model, canvasHeight: canvas.height)

        let rows = try reportedRows(for: model, canvas: canvas)
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .playerDeck })

        // Stacked, each one row tall, and all the same width.
        let sorted = rows.sorted { $0.rect.minY < $1.rect.minY }
        for (index, row) in sorted.enumerated() {
            XCTAssertEqual(row.rect.height, layout.cardHeight, accuracy: 0.5,
                           "row \(index) is not one card tall")
            XCTAssertEqual(row.rect.width, layout.width, accuracy: 0.5)
            if index > 0 {
                XCTAssertEqual(row.rect.minY, sorted[index - 1].rect.maxY, accuracy: 0.5,
                               "row \(index) does not sit on the one above")
            }
        }
    }

    /// The opponent's rows report a different kind, which is what sends their
    /// hover to the opponent's handler rather than the player's.
    func testOpponentRowsReportTheOpponentKind() throws {
        Settings.showOpponentClassInTracker = false
        Settings.showOpponentCardCount = false
        Settings.showOpponentDrawChance = false

        let model = TrackerPanelViewModel(playerType: .opponent)
        model.update(cards: cards(3), top: [], bottom: [], sideboards: [], relatedCards: [])
        model.panelOrder = DeckPanel.order(for: .opponent)
        model.isShown = true

        let rows = try reportedRows(for: model, canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .opponentDeck })
    }

    /// A hidden panel reports nothing, so a torn-down tracker cannot keep
    /// answering for the cursor.
    func testHiddenPanelReportsNoRows() throws {
        let model = playerModel(deck: 4)
        model.isShown = false
        XCTAssertTrue(try reportedRows(for: model, canvas: CGSize(width: 1920, height: 1080)).isEmpty)
    }

    /// Hosts the panel and collects what it publishes through TrackerRowHoverKey.
    private func reportedRows(for model: TrackerPanelViewModel, canvas: CGSize) throws -> [TrackerRowHover] {
        let collected = RowCollector()
        let root = TrackerPanelView(viewModel: model, canvasSize: canvas, isLocked: true,
                                    hoverHandler: TrackerCardHoverHandler(playerType: model.playerType))
            .coordinateSpace(name: "rootOverlayCanvas")
            .onPreferenceChange(TrackerRowHoverKey.self) { collected.rows = $0 }

        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        return collected.rows
    }

    // MARK: - Synergy highlight

    /// Hovering a card in hand (or a Discover choice, or a deck row) lights up the deck rows that
    /// go with it. The SwiftUI list dropped that when it replaced AnimatedCardList: the hover
    /// handler still published the highlight, and nothing drew it.
    func testDeckRowsTakeTheHoveredCardsHighlight() {
        let deck = cards(3)
        deck[1].count = 0
        let jousted = Card()
        jousted.id = "TEST_JOUSTED"
        jousted.count = 1
        jousted.jousted = true
        let rows = deck + [jousted]

        var askedWith = [[String]]()
        let list = CardTileListView(cards: rows, playerType: .player, cardHeight: 34,
                                    highlight: { card, inDeck in
                                        askedWith.append(inDeck.map { $0.id })
                                        return card.id == "TEST_2" ? .green : .none
                                    })
        let inDeck = rows.filter { $0.count > 0 }
        XCTAssertEqual(list.highlightColor(for: deck[2], inDeck: inDeck), .green)
        XCTAssertEqual(list.highlightColor(for: deck[0], inDeck: inDeck), HighlightColor.none)
        XCTAssertEqual(list.highlightColor(for: deck[1], inDeck: inDeck), HighlightColor.none,
                       "a card with none left in the deck is never lit")
        XCTAssertEqual(list.highlightColor(for: jousted, inDeck: inDeck), HighlightColor.none)
        XCTAssertEqual(askedWith.first, ["TEST_0", "TEST_2", "TEST_JOUSTED"])

        // Nothing hovered: no override, the card's own colour stands
        let idle = CardTileListView(cards: rows, playerType: .player, cardHeight: 34)
        XCTAssertNil(idle.highlightColor(for: deck[2], inDeck: inDeck))
    }

    /// Hovering Timethief Rafaam lights up the Rafaams it still needs played - HDT has no highlight
    /// for it, so the deck stayed dark while every other Rafaam card lit its siblings.
    func testTimethiefRafaamLightsUpTheOtherRafaams() {
        if ReflectionHelper.getHighlightClasses().isEmpty {
            ReflectionHelper.initialize()
        }
        XCTAssertTrue(ReflectionHelper.getHighlightClasses().contains { $0 == TimethiefRafaam.self },
                      "the highlight is found at run time, like every other card's")

        let highlight = TimethiefRafaam()
        XCTAssertEqual(highlight.getCardId(), CardIds.Collectible.Warlock.TimethiefRafaam)
        func card(_ id: String) -> Card {
            let card = Card()
            card.id = id
            card.count = 1
            return card
        }
        XCTAssertEqual(TimethiefRafaam.otherRafaams.count, 9)
        for id in TimethiefRafaam.otherRafaams {
            XCTAssertNotEqual(highlight.shouldHighlight(card: card(id), deck: []), HighlightColor.none, id)
        }
        XCTAssertEqual(highlight.shouldHighlight(card: card(CardIds.Collectible.Warlock.TimethiefRafaam), deck: []),
                       HighlightColor.none, "it does not light itself")
        XCTAssertEqual(highlight.shouldHighlight(card: card("CS2_062"), deck: []), HighlightColor.none)
    }

    private final class RowCollector {
        var rows: [TrackerRowHover] = []
    }
}
