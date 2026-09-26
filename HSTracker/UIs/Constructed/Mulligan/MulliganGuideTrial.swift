//
//  MulliganGuideTrial.swift
//  HSTracker
//
//  Created by Francisco Moraes on 8/10/26.
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

// Persisted across app relaunches (matches HDT's own JsonSerializer<TrialData>
// file, ported here as a JSON string in UserDefaults instead) so a trial
// activated earlier in the SAME match is reused rather than burning a second
// one, and so "the player's last trial was just used" survives until they're
// back in the lobby to see the one-time alert for it.
struct MulliganGuideTrialData: Codable, Equatable {
    var token: String?
    var gameHandle: Int?
    var lastTrialAlertPending: Bool
}

// What MulliganGuideTrial.activateOrContinue did. HDT only hands back a token or
// null; the reason is kept here so a guide that stays blank can be explained in
// hstracker.log.
enum MulliganGuideTrialActivation: Equatable, CustomStringConvertible {
    case reused(token: String)
    case activated(token: String, wasLastTrial: Bool)
    case noGameHandle
    case pastMulligan
    case noStatus
    case noTrialsRemaining
    case requestFailed

    // Never prints the token itself: it is a credential for the trial.
    var description: String {
        switch self {
        case .reused:
            return "reusing the token activated for this match"
        case .activated(_, let wasLastTrial):
            return "activated a new trial (isLastTrial=\(wasLastTrial))"
        case .noGameHandle:
            return "no gameHandle"
        case .pastMulligan:
            return "refused: past BEGIN_MULLIGAN"
        case .noStatus:
            return "trial status unknown"
        case .noTrialsRemaining:
            return "no trials remaining"
        case .requestFailed:
            return "activation request failed"
        }
    }

    var token: String? {
        switch self {
        case .reused(let token), .activated(let token, _):
            return token
        default:
            return nil
        }
    }
}

// Why a mulligan guide request was not made (or came back empty). HDT's
// GetMulliganGuideData/GetMulliganV2Data return a bare null at each of these
// points and log nothing, which left "the guide doesn't show" undiagnosable.
enum MulliganGuideUnavailableReason: Equatable, CustomStringConvertible {
    case spectator
    case disabledBySetting
    case disabledRemotely
    // Not an HSReplay Premium account and no free trial left this week (or the
    // trial status could not be read at all, when remainingTrials is nil).
    case notPremiumNoTrials(signedIn: Bool, remainingTrials: Int?, hoursUntilReset: Int?)
    case noParams
    case deckNotAvailable(gameType: Int, state: String)
    case noAccountId
    case trialNotActivated(MulliganGuideTrialActivation)
    case requestFailed

    var description: String {
        switch self {
        case .spectator:
            return "spectating"
        case .disabledBySetting:
            return "disabled in preferences"
        case .disabledRemotely:
            return "disabled by HSReplay remote config"
        case .notPremiumNoTrials(let signedIn, let remainingTrials, let hoursUntilReset):
            let stale = remainingTrials == 0 && hoursUntilReset == 0 ? " (status is at or past its reset and could not be refreshed)" : ""
            return "not premium and remainingTrials=\(remainingTrials.map(String.init) ?? "nil") hoursUntilReset=\(hoursUntilReset.map(String.init) ?? "nil") signedIn=\(signedIn)\(stale)"
        case .noParams:
            return "mulligan params were not cached"
        case .deckNotAvailable(let gameType, let state):
            return "deck has no guide coverage for trials (gameType=\(gameType) status=\(state))"
        case .noAccountId:
            return "no Battle.net account id from the mirror"
        case .trialNotActivated(let activation):
            return "trial not activated (\(activation))"
        case .requestFailed:
            return "guide request failed"
        }
    }

    // Only a known zero is worth telling the player about: a status that could
    // not be read is a network problem, not a used-up allowance. A zero whose
    // reset time has already counted down to 0 is not known either - the
    // trials have most likely reset and only the refresh failed - and saying
    // "used up, resets in 0d 0h" there would be wrong twice over.
    var isTrialsExhausted: Bool {
        if case .notPremiumNoTrials(_, let remainingTrials, let hoursUntilReset) = self {
            return remainingTrials == 0 && hoursUntilReset != 0
        }
        return false
    }
}

// A guide lookup's data, or why there is none.
struct MulliganGuideResult<T> {
    let data: T?
    let unavailable: MulliganGuideUnavailableReason?

    init(data: T) {
        self.data = data
        self.unavailable = nil
    }

    init(unavailable: MulliganGuideUnavailableReason) {
        self.data = nil
        self.unavailable = unavailable
    }
}

final class MulliganGuideTrialState {
    typealias Activate = (_ hi: Int64, _ lo: Int64) async -> PlayerTrialActivation?

    let statusCache: PlayerTrialStatusCache
    private let activate: Activate
    private let loadData: () -> String?
    private let saveData: (String) -> Void
    private let serial = AsyncSerialLock()
    private let lock = UnfairLock()
    private var _token: String?

    init(statusCache: PlayerTrialStatusCache, activate: @escaping Activate, loadData: @escaping () -> String?, saveData: @escaping (String) -> Void) {
        self.statusCache = statusCache
        self.activate = activate
        self.loadData = loadData
        self.saveData = saveData
    }

    var token: String? {
        return lock.around { _token }
    }

    var persistedData: MulliganGuideTrialData {
        get {
            guard let json = loadData(),
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(MulliganGuideTrialData.self, from: data) else {
                return MulliganGuideTrialData(token: nil, gameHandle: nil, lastTrialAlertPending: false)
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue), let json = String(data: data, encoding: .utf8) else {
                return
            }
            saveData(json)
        }
    }

    // Matches HDT's MulliganGuideTrial.ActivateOrContinue(): reuses the trial
    // already activated for this same match (identified by gameHandle) instead
    // of burning a second one, and otherwise activates a new one - recording
    // whether this was the player's *last* remaining trial so the pre-lobby can
    // show a one-time "trials exhausted" alert once they're back from the match.
    //
    // isPastMulligan is HDT's "STEP <= BEGIN_MULLIGAN" guard: a trial activated
    // once the cards are kept can no longer show anything, so it would only use
    // up the weekly allowance. Serialized like HDT's SemaphoreSlim so two
    // requests for the same match cannot both activate.
    func activateOrContinue(hi: Int64, lo: Int64, gameHandle: Int?, isPastMulligan: Bool) async -> MulliganGuideTrialActivation {
        await serial.acquire()
        let result = await activateOrContinueLocked(hi: hi, lo: lo, gameHandle: gameHandle, isPastMulligan: isPastMulligan)
        await serial.release()
        switch result {
        case .reused, .activated:
            logger.info("MulliganGuideTrial: \(result) for gameHandle \(gameHandle.map(String.init) ?? "nil"), remaining before=\(statusCache.remainingTrials.map(String.init) ?? "nil")")
        default:
            logger.info("MulliganGuideTrial: no token for gameHandle \(gameHandle.map(String.init) ?? "nil"): \(result)")
        }
        return result
    }

    private func activateOrContinueLocked(hi: Int64, lo: Int64, gameHandle: Int?, isPastMulligan: Bool) async -> MulliganGuideTrialActivation {
        guard let gameHandle else {
            return .noGameHandle
        }

        let current = persistedData
        if current.gameHandle == gameHandle, let existingToken = current.token {
            lock.around { _token = existingToken }
            return .reused(token: existingToken)
        }

        if isPastMulligan {
            return .pastMulligan
        }

        guard let status = statusCache.status else {
            return .noStatus
        }
        guard status.trials_remaining > 0 else {
            return .noTrialsRemaining
        }
        // Not decremented locally - trials_remaining still reflects the
        // pre-activation count here.
        let isLastTrial = status.trials_remaining == 1

        guard let newToken = await activate(hi, lo)?.token else {
            return .requestFailed
        }
        lock.around { _token = newToken }
        persistedData = MulliganGuideTrialData(token: newToken, gameHandle: gameHandle, lastTrialAlertPending: isLastTrial)
        return .activated(token: newToken, wasLastTrial: isLastTrial)
    }

    // HDT's premium-or-trials gate at the top of GetMulliganGuideData and
    // GetMulliganV2Data, with one addition: the status is brought up to date
    // here first. update() makes no request for a fresh status, but it does
    // fetch one that is missing (the app started mid-match, or the lobby
    // refresh failed) or close to its reset, and because it is serialized it
    // also waits for a lobby refresh already in flight. Reading the cache
    // as-is let the first game after the weekly reset see last week's zero
    // and skip a game that had trials again.
    func premiumOrTrialGate(isPremium: Bool, signedIn: Bool, hi: Int64?, lo: Int64?) async -> MulliganGuideUnavailableReason? {
        if isPremium {
            return nil
        }
        if let hi, let lo {
            await statusCache.update(hi: hi, lo: lo)
        }
        let remaining = statusCache.remainingTrials
        if (remaining ?? 0) == 0 {
            return .notPremiumNoTrials(signedIn: signedIn, remainingTrials: remaining, hoursUntilReset: statusCache.hoursUntilReset)
        }
        return nil
    }

    // Read-and-clear: returns true (once) if the most recent trial
    // activation consumed the player's last one, so the pre-lobby can show
    // the "trials exhausted" alert exactly once.
    func consumePendingLastTrialAlert() -> Bool {
        var data = persistedData
        if !data.lastTrialAlertPending {
            return false
        }
        data.lastTrialAlertPending = false
        persistedData = data
        return true
    }

    // HDT's UpdateMulliganGuideTrialsExhausted consumes the pending flag before
    // it looks at the trial count. That only works because HDT awaits a fresh
    // status first; with a count left over from before the match (one trial
    // still "remaining"), the flag was used up without the alert ever showing.
    // Checking premium and a known zero first leaves the flag for the next
    // lobby visit whenever the count cannot be trusted yet.
    func shouldShowTrialsExhaustedAlert(seen: Bool, isPremium: Bool) -> Bool {
        if seen {
            logger.debug("MulliganGuideTrial exhausted alert: already seen")
            return false
        }
        if isPremium {
            logger.debug("MulliganGuideTrial exhausted alert: premium")
            return false
        }
        guard let remaining = statusCache.remainingTrials, remaining == 0 else {
            // Trials may have reset while the player was away, or the status
            // is not loaded yet.
            logger.debug("MulliganGuideTrial exhausted alert: remainingTrials=\(statusCache.remainingTrials.map(String.init) ?? "nil")")
            return false
        }
        guard consumePendingLastTrialAlert() else {
            logger.debug("MulliganGuideTrial exhausted alert: no pending last-trial flag")
            return false
        }
        return true
    }

    // In-memory only, matching HDT's own Clear() - the persisted per-game
    // activation record deliberately survives so a later match's
    // ActivateOrContinue can still detect a stale/mismatched gameHandle.
    func clear() {
        statusCache.clear()
        lock.around { _token = nil }
    }
}

@available(macOS 10.15.0, *)
class MulliganGuideTrial {
    static let trialName = "mulligan-guide-overlay"

    static let shared = MulliganGuideTrialState(
        statusCache: PlayerTrialStatusCache(name: trialName),
        activate: { hi, lo in await HSReplayAPI.activatePlayerTrial(name: trialName, hi: hi, lo: lo) },
        loadData: { Settings.mulliganGuideTrialData },
        saveData: { Settings.mulliganGuideTrialData = $0 }
    )

    static var token: String? {
        return shared.token
    }

    static var remainingTrials: Int? {
        return shared.statusCache.remainingTrials
    }

    static var timeRemaining: String? {
        guard let hours = shared.statusCache.hoursUntilReset else { return nil }
        return String(format: String.localizedString("BattlegroundsPreLobby_Trial_ResetTimeRemaining_DaysHours", comment: ""), hours / 24, hours % 24)
    }

    static func activateOrContinue(hi: Int64, lo: Int64, gameHandle: Int?, isPastMulligan: Bool) async -> MulliganGuideTrialActivation {
        return await shared.activateOrContinue(hi: hi, lo: lo, gameHandle: gameHandle, isPastMulligan: isPastMulligan)
    }

    static func consumePendingLastTrialAlert() -> Bool {
        return shared.consumePendingLastTrialAlert()
    }

    static func update(hi: Int64, lo: Int64) async {
        await shared.statusCache.update(hi: hi, lo: lo)
    }

    static func clear() {
        shared.clear()
    }
}
