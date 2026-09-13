//
//  ActionHistoryViewModel.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import SwiftUI

// What the action history panel on the RootOverlay canvas shows: the turns of the current match as
// Game's ActionHistoryRecorder last published them, and whether the panel is visible at all.
//
// Entry points hop to the main thread instead of being @MainActor, like CountersOverlayViewModel:
// Game calls them from its GUI update queue and from the recorder's publish callback.
@available(macOS 10.15, *)
class ActionHistoryViewModel: ObservableObject {
    // Driven by Game.updateActionHistory, the way Game.updateCounters drives the counters.
    @Published var isShown = false

    // Oldest turn first, as the recorder keeps them
    @Published private(set) var turns: [HistoryTurn] = []

    private var version: Int?

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
        turns = snapshot.turns
    }
}
