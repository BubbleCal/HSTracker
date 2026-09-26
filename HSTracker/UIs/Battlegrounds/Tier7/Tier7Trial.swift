//
//  Tier7Trial.swift
//  HSTracker
//
//  Created by Francisco Moraes on 12/9/22.
//  Copyright © 2022 Benjamin Michotte. All rights reserved.
//

import Foundation

class Tier7Trial {
    // Same status handling as MulliganGuideTrial - see PlayerTrialStatusCache.update
    // for the HDT Update() semantics this had lost.
    static let statusCache = PlayerTrialStatusCache(name: "tier7-overlay")
    static private(set) var token: String?
    static var remainingTrials: Int? { return statusCache.remainingTrials }
    static var timeRemaining: String? {
        guard let hours = statusCache.hoursUntilReset else {
            return nil
        }
        return String(format: String.localizedString("BattlegroundsPreLobby_Trial_ResetTimeRemaining_DaysHours", comment: ""), hours / 24, hours % 24)
    }
    // HDT's ActivateOrContinue. "Continue" matters now that clear() runs at the
    // end of every Battlegrounds match: a token that is still set belongs to the
    // match in progress, so hand it back rather than reporting failure. Returning
    // nil here meant whichever of the two callers ran second - hero pick stats
    // and session composition stats both activate - treated an already-active
    // trial as "could not get a token" and gave up.
    static func activate(hi: Int64, lo: Int64) async -> String? {
        if let token {
            return token
        }
        if statusCache.status == nil || statusCache.remainingTrials == 0 {
            return nil
        }
        token = await HSReplayAPI.activatePlayerTrial(name: "tier7-overlay", hi: hi, lo: lo)?.token
        if token != nil {
            // HDT raises Tier7Trial.OnTrialActivated here; posting a notification
            // keeps the multicast semantics without giving this static type a
            // subscriber list of its own.
            NotificationCenter.default.post(name: Notification.Name(rawValue: Events.tier7_trial_activated), object: nil)
        }
        return token
    }

    static func update(hi: Int64, lo: Int64) async {
        await statusCache.update(hi: hi, lo: lo)
    }

    static func clear() {
        statusCache.clear()
        token = nil
    }
}
