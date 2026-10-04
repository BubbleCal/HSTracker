//
//  PlayerTrialStatusCacheTests.swift
//  HSTrackerTests
//
//  The weekly trial status behind HSReplay's free trials (Tier7Trial): when it is refetched,
//  and how a failed or concurrent refetch is handled. The network call is injected, so
//  nothing here reaches HSReplay.
//

import XCTest
import Foundation

@testable import HSTracker

private final class Counter {
    private let lock = UnfairLock()
    private var _value = 0

    var value: Int {
        return lock.around { _value }
    }

    func increment() {
        lock.around { _value += 1 }
    }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@available(macOS 10.15, *)
class PlayerTrialStatusCacheTests: XCTestCase {
    private var fetchCount: Counter!
    private var clock: Clock!
    private var nextStatus: PlayerTrialStatus?
    private var fetchDelay: UInt64 = 0

    override func setUp() {
        super.setUp()
        fetchCount = Counter()
        clock = Clock()
        nextStatus = nil
        fetchDelay = 0
    }

    private func makeCache() -> PlayerTrialStatusCache {
        return PlayerTrialStatusCache(name: "test-trial", fetch: { [unowned self] _, _ in
            self.fetchCount.increment()
            if self.fetchDelay > 0 {
                try? await Task.sleep(nanoseconds: self.fetchDelay)
            }
            return self.nextStatus
        }, now: { [unowned self] in self.clock.now })
    }

    // MARK: - Trial status refresh

    func testUnusedTrialsWithoutResetTimeAreKept() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 2, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)
        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 99)
        await cache.update(hi: 1, lo: 2)

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(cache.remainingTrials, 2)
    }

    func testStatusCloseToResetIsRefetched() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 1)
        await cache.update(hi: 1, lo: 2)
        nextStatus = PlayerTrialStatus(trials_remaining: 3, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)

        XCTAssertEqual(fetchCount.value, 2)
        XCTAssertEqual(cache.remainingTrials, 3)
    }

    func testFailedRefetchKeepsPreviousStatus() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 1, hours_til_next_reset: 1)
        await cache.update(hi: 1, lo: 2)
        nextStatus = nil
        await cache.update(hi: 1, lo: 2)

        XCTAssertEqual(fetchCount.value, 2)
        XCTAssertEqual(cache.remainingTrials, 1)
    }

    func testConcurrentUpdatesMakeOneRequest() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 2, hours_til_next_reset: 30)
        fetchDelay = 50_000_000
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask { await cache.update(hi: 1, lo: 2) }
            }
        }

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(cache.remainingTrials, 2)
    }

    func testResetTimeCountsDownAndExpiresTheStatus() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 8)
        await cache.update(hi: 1, lo: 2)
        clock.now = clock.now.addingTimeInterval(3 * 3600)
        await cache.update(hi: 1, lo: 2)

        XCTAssertEqual(cache.hoursUntilReset, 5)
        XCTAssertEqual(fetchCount.value, 1)

        clock.now = clock.now.addingTimeInterval(4 * 3600)
        nextStatus = PlayerTrialStatus(trials_remaining: 3, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)

        XCTAssertEqual(fetchCount.value, 2)
        XCTAssertEqual(cache.remainingTrials, 3)
    }

    func testClearForcesARefetch() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 1, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)
        cache.clear()
        XCTAssertNil(cache.status)
        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 8)
        await cache.update(hi: 1, lo: 2)

        XCTAssertEqual(fetchCount.value, 2)
        XCTAssertEqual(cache.remainingTrials, 0)
    }

    // MARK: - Authorized request failures

    func testExpiredTokenWithoutRenewalHandlerCompletes() {
        if case .fail(let error) = HSReplayAPI.failedRequestDisposition(.tokenExpired(error: nil), hasRenewalHandler: false) {
            if case .tokenExpired = error {
            } else {
                XCTFail("expected the tokenExpired error to be passed on, got \(error)")
            }
        } else {
            XCTFail("a request with no renewal handler must complete")
        }

        if case .renewAndRetry = HSReplayAPI.failedRequestDisposition(.tokenExpired(error: nil), hasRenewalHandler: true) {
        } else {
            XCTFail("a request with a renewal handler renews")
        }

        if case .fail = HSReplayAPI.failedRequestDisposition(.missingToken, hasRenewalHandler: true) {
        } else {
            XCTFail("other failures complete")
        }
    }
}
