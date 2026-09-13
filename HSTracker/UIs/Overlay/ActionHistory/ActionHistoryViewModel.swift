//
//  ActionHistoryViewModel.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import AppKit
import SwiftUI

// What the action history panel on the RootOverlay canvas shows: the turns of the current match as
// Game's ActionHistoryRecorder last published them, whether the panel is visible at all, and the
// panel's own chrome state (position, collapsed, which turns and rows are unfolded).
//
// Entry points hop to the main thread instead of being @MainActor, like CountersOverlayViewModel:
// Game calls them from its GUI update queue and from the recorder's publish callback.
@available(macOS 10.15, *)
class ActionHistoryViewModel: ObservableObject {
    static let panelWidth: CGFloat = 280
    // How much of the canvas height the list may take before it scrolls
    static let maxListHeightRatio: CGFloat = 0.45
    // The number of most recent turns shown unfolded until the player folds them
    static let autoExpandedTurns = 2
    static let titleBarHeight: CGFloat = 24
    // Room kept free under the panel and below the secret helper
    static let margin: CGFloat = 8
    // How far the mouse has to move with the button down before the title bar starts dragging. A
    // click that wobbles a pixel or two must not turn the automatic position into a saved one.
    static let dragThreshold: CGFloat = 4

    // Driven by Game.updateActionHistory, the way Game.updateCounters drives the counters.
    @Published var isShown = false

    // Oldest turn first, as the recorder keeps them
    @Published private(set) var turns: [HistoryTurn] = []

    @Published private(set) var collapsed: Bool

    // Percentages of the canvas size, like BattlegroundsSessionViewModel's top/left. A negative left
    // is the automatic position next to the opponent tracker.
    @Published private(set) var top: Double
    @Published private(set) var left: Double

    // The panel's laid-out size and the height of the scrolled list's content, reported back by the
    // view so the overlay can work out which pixels it covers and how tall the list may be.
    @Published var panelSize: CGSize = .zero
    @Published var listContentHeight: CGFloat = 0

    // The bottom edge of the secret helper in canvas pixels, 0 while it is hidden. Game.updateSecretTracker
    // sets it: the helper is its own window in the same column as the automatic position, above the
    // overlay, so it would hide the panel's title bar - its only drag handle.
    @Published var secretHelperBottom: CGFloat = 0

    // How much of the list's width a legacy (always shown) scroller takes. Overlay scrollers draw
    // over the content and take none; a mouse or "Show scroll bars: Always" switches to legacy ones,
    // which would cover the totals and fold glyphs at each row's right edge.
    @Published private(set) var scrollerInset = ActionHistoryViewModel.currentScrollerInset()

    // Turns the player folded or unfolded by hand, by ActionHistoryTurnSection.key. The others
    // follow autoExpandedTurns, so a new turn unfolds and the one before the previous folds.
    @Published private(set) var turnExpansion: [String: Bool] = [:]
    @Published private(set) var expandedEntries = Set<Int>()

    private var version: Int?
    // Where the panel was when the current drag began, and where that drag's mouse went down
    private var dragOrigin: CGPoint?
    private var dragStartLocation: CGPoint?
    private let savePosition: (_ top: Double, _ left: Double) -> Void
    private var scrollerStyleObserver: NSObjectProtocol?

    // The saved chrome state is passed in so tests can start from a known position rather than
    // wherever the player last left the panel in the app, whose defaults the hosted tests share -
    // and for the same reason where a moved position is saved to.
    init(top: Double = Settings.actionHistoryTop, left: Double = Settings.actionHistoryLeft,
         collapsed: Bool = Settings.actionHistoryCollapsed,
         savePosition: @escaping (_ top: Double, _ left: Double) -> Void = { top, left in
             Settings.actionHistoryTop = top
             Settings.actionHistoryLeft = left
         }) {
        self.top = top
        self.left = left
        self.collapsed = collapsed
        self.savePosition = savePosition
        scrollerStyleObserver = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            let inset = ActionHistoryViewModel.currentScrollerInset()
            if self?.scrollerInset != inset {
                self?.scrollerInset = inset
            }
        }
    }

    deinit {
        if let scrollerStyleObserver {
            NotificationCenter.default.removeObserver(scrollerStyleObserver)
        }
    }

    static func currentScrollerInset() -> CGFloat {
        guard NSScroller.preferredScrollerStyle == .legacy else {
            return 0
        }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    var hasTurns: Bool {
        return !turns.isEmpty
    }

    func apply(_ snapshot: ActionHistorySnapshot) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.apply(snapshot)
            }
            return
        }
        // The recorder bumps its version on every change, so an equal one has nothing new
        guard snapshot.version != version else {
            return
        }
        version = snapshot.version
        if snapshot.turns.isEmpty {
            // A new game: what was folded belonged to the last one
            turnExpansion = [:]
            expandedEntries = []
        }
        turns = snapshot.turns
    }

    // MARK: - Folding

    func toggleCollapsed() {
        collapsed.toggle()
        Settings.actionHistoryCollapsed = collapsed
    }

    func isTurnExpanded(_ section: ActionHistoryTurnSection) -> Bool {
        return turnExpansion[section.key] ?? (section.index >= turns.count - ActionHistoryViewModel.autoExpandedTurns)
    }

    func toggleTurn(_ section: ActionHistoryTurnSection) {
        turnExpansion[section.key] = !isTurnExpanded(section)
    }

    func isEntryExpanded(_ entry: HistoryEntry) -> Bool {
        return expandedEntries.contains(entry.id)
    }

    func toggleEntry(_ entry: HistoryEntry) {
        if expandedEntries.contains(entry.id) {
            expandedEntries.remove(entry.id)
        } else {
            expandedEntries.insert(entry.id)
        }
    }

    // MARK: - Position

    /// The panel's top-left corner in the canvas's real pixels, kept on the canvas so a smaller
    /// Hearthstone window cannot push it out of reach.
    func origin(canvasSize: CGSize) -> CGPoint {
        var y = canvasSize.height * CGFloat(top) / 100.0
        let x: CGFloat
        if left < 0 {
            // Right of the opponent tracker, in the secret helper's column (SizeHelper.secretTrackerFrame),
            // so the automatic position moves down below the helper while it is up. A position the
            // player dragged to is left where it was put.
            x = SizeHelper.trackerWidth + 25
            if secretHelperBottom > 0 {
                y = max(y, secretHelperBottom + ActionHistoryViewModel.margin)
            }
        } else {
            x = canvasSize.width * CGFloat(left) / 100.0
        }
        return clamped(CGPoint(x: x, y: y), canvasSize: canvasSize)
    }

    // The whole width and at least the title bar - the only drag handle - stay on the canvas
    private func clamped(_ point: CGPoint, canvasSize: CGSize) -> CGPoint {
        let width = panelSize.width > 0 ? panelSize.width : ActionHistoryViewModel.panelWidth
        return CGPoint(x: min(max(0, point.x), max(0, canvasSize.width - width)),
                       y: min(max(0, point.y), max(0, canvasSize.height - ActionHistoryViewModel.titleBarHeight)))
    }

    /// Opens the card image on the side of the panel facing the middle of the screen.
    func tooltipPlacement(canvasSize: CGSize) -> CardTooltipPlacement {
        let width = panelSize.width > 0 ? panelSize.width : ActionHistoryViewModel.panelWidth
        return origin(canvasSize: canvasSize).x + width / 2 < canvasSize.width / 2 ? .right : .left
    }

    /// The tallest the scrolled list may be: a share of the canvas, and never past its bottom edge,
    /// or the oldest turns would scroll into a part of the viewport nobody can see.
    func maxListHeight(canvasSize: CGSize) -> CGFloat {
        let preferred = max(80, canvasSize.height * ActionHistoryViewModel.maxListHeightRatio)
        // The title bar and the 1 pt rule under it
        let listTop = origin(canvasSize: canvasSize).y + ActionHistoryViewModel.titleBarHeight + 1
        return min(preferred, max(0, canvasSize.height - listTop - ActionHistoryViewModel.margin))
    }

    // Moves by the drag's total translation from where the panel was when the drag began, which is
    // also where an automatic position turns into a saved percentage: from then on the player's
    // position wins over the spot below the secret helper.
    //
    // The position is clamped here rather than only when it is drawn, so pulling the panel past an
    // edge does not store an overshoot that has to be dragged back before it moves again, and what
    // is saved is where the panel is seen. Being percentages, it keeps its place when the
    // Hearthstone window is resized; origin(canvasSize:) clamps again if the window got smaller.
    //
    // - Parameter startLocation: where the gesture's mouse went down. A different one is a new
    //   gesture even if the last one never ended - SwiftUI cancels a drag without calling onEnded
    //   when the panel is removed under it, for instance at the end of a game.
    func drag(translation: CGSize, startLocation: CGPoint? = nil, canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        if let startLocation, startLocation != dragStartLocation {
            dragOrigin = nil
            dragStartLocation = startLocation
        }
        let start = dragOrigin ?? origin(canvasSize: canvasSize)
        dragOrigin = start
        let moved = clamped(CGPoint(x: start.x + translation.width, y: start.y + translation.height), canvasSize: canvasSize)
        left = Double(moved.x / canvasSize.width) * 100.0
        top = Double(moved.y / canvasSize.height) * 100.0
    }

    // Saved once on mouse up, as BattlegroundsSessionViewModel.endDrag does
    func endDrag() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        dragStartLocation = nil
        savePosition(top, left)
    }

    // Back to the automatic position below the secret helper, for a panel dragged somewhere it is
    // no longer wanted.
    func resetPosition() {
        dragOrigin = nil
        dragStartLocation = nil
        top = Settings.actionHistoryDefaultTop
        left = Settings.actionHistoryDefaultLeft
        savePosition(top, left)
    }
}
