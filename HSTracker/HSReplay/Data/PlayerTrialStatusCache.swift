//
//  PlayerTrialStatusCache.swift
//  HSTracker
//
//  Shared by MulliganGuideTrial and Tier7Trial: the weekly trial status HSReplay reports for a
//  Battle.net account, kept between calls the way HDT keeps its own _status field.
//

import Foundation

// An async mutex, standing in for the SemaphoreSlim(1, 1) HDT wraps around
// MulliganGuideTrial.ActivateOrContinue. An UnfairLock cannot be held across an
// await, and both the status refresh and the trial activation await the
// network halfway through.
@available(macOS 10.15.0, *)
actor AsyncSerialLock {
    private var isLocked = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        // release() hands the lock straight to the first waiter, so isLocked
        // stays true for it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@available(macOS 10.15.0, *)
final class PlayerTrialStatusCache {
    typealias Fetch = (_ hi: Int64, _ lo: Int64) async -> PlayerTrialStatus?

    let name: String
    private let fetch: Fetch
    private let now: () -> Date
    private let lock = UnfairLock()
    private let serial = AsyncSerialLock()
    private var _status: PlayerTrialStatus?
    private var _fetchedAt: Date?

    init(name: String, fetch: Fetch? = nil, now: @escaping () -> Date = { Date() }) {
        self.name = name
        self.fetch = fetch ?? { hi, lo in await HSReplayAPI.getPlayerTrialStatus(name: name, hi: hi, lo: lo) }
        self.now = now
    }

    var status: PlayerTrialStatus? {
        return lock.around { _status }
    }

    var remainingTrials: Int? {
        return lock.around { _status?.trials_remaining }
    }

    // Counted down from the moment the server answered, so a status kept in
    // memory for hours (HSTracker may sit in the lobby far longer than a match)
    // still reaches its reset instead of reporting the same number forever.
    var hoursUntilReset: Int? {
        return lock.around { hoursUntilResetLocked() }
    }

    private func hoursUntilResetLocked() -> Int? {
        guard let hours = _status?.hours_til_next_reset else {
            return nil
        }
        let elapsedHours = _fetchedAt.map { Int(now().timeIntervalSince($0) / 3600) } ?? 0
        return max(0, hours - elapsedHours)
    }

    // HDT's MulliganGuideTrial.Update / Tier7Trial.Update:
    //   if(_status?.HoursUntilReset < 2) _status = null;
    //   _status ??= await GetPlayerTrialStatus(...);
    // The port had read the first line as `hours ?? 0 < 2`, which also threw the
    // status away when the server sends no reset time - exactly what it sends
    // while this week's trials are still unused - and it refetched on every
    // call, replacing a good status with nil whenever a request failed. A game
    // reaching its mulligan during one of those refetches saw no status and
    // skipped the trial it should have used.
    //
    // Calls are serialized, so a burst of callers makes one request. A stale
    // status stays readable until the new one arrives, and is kept if the
    // request fails.
    func update(hi: Int64, lo: Int64) async {
        await serial.acquire()
        let (cached, stale) = lock.around { () -> (PlayerTrialStatus?, Bool) in
            guard let status = _status else {
                return (nil, false)
            }
            if let hours = hoursUntilResetLocked(), hours < 2 {
                return (status, true)
            }
            return (status, false)
        }
        if let cached, !stale {
            await serial.release()
            logger.debug("\(name) trial status kept: trials_remaining=\(cached.trials_remaining) hours_til_next_reset=\(String(describing: cached.hours_til_next_reset))")
            return
        }
        let fetched = await fetch(hi, lo)
        if let fetched {
            lock.around {
                _status = fetched
                _fetchedAt = now()
            }
        }
        await serial.release()
        if let fetched {
            logger.info("\(name) trial status: trials_remaining=\(fetched.trials_remaining) hours_til_next_reset=\(String(describing: fetched.hours_til_next_reset)) (replaced stale=\(stale))")
        } else {
            logger.warning("\(name) trial status request failed, keeping \(cached.map { "trials_remaining=\($0.trials_remaining)" } ?? "no status")\(stale ? " although it is close to or past its reset" : "")")
        }
    }

    func clear() {
        lock.around {
            _status = nil
            _fetchedAt = nil
        }
    }
}
