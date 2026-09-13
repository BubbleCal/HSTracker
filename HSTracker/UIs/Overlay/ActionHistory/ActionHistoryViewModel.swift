//
//  ActionHistoryViewModel.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

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

    // Driven by Game.updateActionHistory, the way Game.updateCounters drives the counters.
    @Published var isShown = false

    // Oldest turn first, as the recorder keeps them
    @Published private(set) var turns: [HistoryTurn] = []

    @Published private(set) var collapsed = Settings.actionHistoryCollapsed

    // Percentages of the canvas size, like BattlegroundsSessionViewModel's top/left. A negative left
    // is the automatic position next to the opponent tracker.
    @Published private(set) var top = Settings.actionHistoryTop
    @Published private(set) var left = Settings.actionHistoryLeft

    // The panel's laid-out size and the height of the scrolled list's content, reported back by the
    // view so the overlay can work out which pixels it covers and how tall the list may be.
    @Published var panelSize: CGSize = .zero
    @Published var listContentHeight: CGFloat = 0

    // Turns the player folded or unfolded by hand, by ActionHistoryTurnSection.key. The others
    // follow autoExpandedTurns, so a new turn unfolds and the one before the previous folds.
    @Published private(set) var turnExpansion: [String: Bool] = [:]
    @Published private(set) var expandedEntries = Set<Int>()

    private var version: Int?
    private var dragOrigin: CGPoint?

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
        let width = panelSize.width > 0 ? panelSize.width : ActionHistoryViewModel.panelWidth
        // Right of the opponent tracker, where SizeHelper.secretTrackerFrame puts the secret helper
        let x = left < 0 ? SizeHelper.trackerWidth + 25 : canvasSize.width * CGFloat(left) / 100.0
        let y = canvasSize.height * CGFloat(top) / 100.0
        // Keep at least the title bar on the canvas
        let titleBarHeight: CGFloat = 24
        return CGPoint(x: min(max(0, x), max(0, canvasSize.width - width)),
                       y: min(max(0, y), max(0, canvasSize.height - titleBarHeight)))
    }

    /// Opens the card image on the side of the panel facing the middle of the screen.
    func tooltipPlacement(canvasSize: CGSize) -> CardTooltipPlacement {
        let width = panelSize.width > 0 ? panelSize.width : ActionHistoryViewModel.panelWidth
        return origin(canvasSize: canvasSize).x + width / 2 < canvasSize.width / 2 ? .right : .left
    }

    func maxListHeight(canvasSize: CGSize) -> CGFloat {
        return max(80, canvasSize.height * ActionHistoryViewModel.maxListHeightRatio)
    }

    // Moves by the drag's total translation from where the panel was when the drag began, which is
    // also where an automatic position turns into a saved percentage.
    func drag(translation: CGSize, canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let start = dragOrigin ?? origin(canvasSize: canvasSize)
        dragOrigin = start
        left = max(0, Double((start.x + translation.width) / canvasSize.width) * 100.0)
        top = max(0, Double((start.y + translation.height) / canvasSize.height) * 100.0)
    }

    // Saved once on mouse up, as BattlegroundsSessionViewModel.endDrag does
    func endDrag() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        Settings.actionHistoryTop = top
        Settings.actionHistoryLeft = left
    }
}
