//
//  MulliganGuideTrialTests.swift
//  HSTrackerTests
//
//  The trial bookkeeping behind the Mulligan Guide: when the weekly trial status is refetched,
//  when a trial is spent, and when the one-time "trials exhausted" alert may use up its flag.
//  The network calls and the persisted trial record are injected, so nothing here reaches
//  HSReplay or the app's UserDefaults.
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
class MulliganGuideTrialTests: XCTestCase {
    private var fetchCount: Counter!
    private var activateCount: Counter!
    private var clock: Clock!
    private var nextStatus: PlayerTrialStatus?
    private var fetchDelay: UInt64 = 0
    private var storedData: String?

    override func setUp() {
        super.setUp()
        fetchCount = Counter()
        activateCount = Counter()
        clock = Clock()
        nextStatus = nil
        fetchDelay = 0
        storedData = nil
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

    private func makeTrial(cache: PlayerTrialStatusCache, token: String? = "trial-token") -> MulliganGuideTrialState {
        return MulliganGuideTrialState(statusCache: cache, activate: { [unowned self] _, _ in
            self.activateCount.increment()
            if self.fetchDelay > 0 {
                try? await Task.sleep(nanoseconds: self.fetchDelay)
            }
            guard let token else {
                return nil
            }
            return PlayerTrialActivation(trials_remaining: 0, hours_til_next_reset: nil, token: token)
        }, loadData: { [unowned self] in self.storedData }, saveData: { [unowned self] in self.storedData = $0 })
    }

    private func pendingFlag(_ trial: MulliganGuideTrialState) -> Bool {
        return trial.persistedData.lastTrialAlertPending
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

    // MARK: - Activation

    func testNoNewTrialAfterTheMulligan() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 2, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache)

        let result = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: true)

        XCTAssertEqual(result, .pastMulligan)
        XCTAssertEqual(activateCount.value, 0)
    }

    func testTokenForTheSameMatchIsReusedEvenAfterTheMulligan() async {
        let cache = makeCache()
        let trial = makeTrial(cache: cache)
        trial.persistedData = MulliganGuideTrialData(token: "earlier", gameHandle: 42, lastTrialAlertPending: false)

        let result = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: true)

        XCTAssertEqual(result, .reused(token: "earlier"))
        XCTAssertEqual(trial.token, "earlier")
        XCTAssertEqual(activateCount.value, 0)
    }

    func testNoTrialsLeft() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 8)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache)

        let result = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: false)

        XCTAssertEqual(result, .noTrialsRemaining)
        XCTAssertEqual(activateCount.value, 0)
    }

    func testMissingGameHandleOrStatus() async {
        let trial = makeTrial(cache: makeCache())

        let noHandle = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: nil, isPastMulligan: false)
        let noStatus = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: false)

        XCTAssertEqual(noHandle, .noGameHandle)
        XCTAssertEqual(noStatus, .noStatus)
        XCTAssertEqual(activateCount.value, 0)
    }

    func testActivatingTheLastTrialLeavesTheAlertPending() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 1, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache)

        let result = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: false)

        XCTAssertEqual(result, .activated(token: "trial-token", wasLastTrial: true))
        XCTAssertEqual(trial.persistedData, MulliganGuideTrialData(token: "trial-token", gameHandle: 42, lastTrialAlertPending: true))
    }

    func testConcurrentActivationsForOneMatchSpendOneTrial() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 3, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache)
        fetchDelay = 50_000_000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 3 {
                group.addTask { _ = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: false) }
            }
        }

        XCTAssertEqual(activateCount.value, 1)
    }

    func testFailedActivation() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 3, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache, token: nil)

        let result = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: false)

        XCTAssertEqual(result, .requestFailed)
        XCTAssertNil(storedData)
    }

    // MARK: - Trials exhausted alert

    func testStaleCountDoesNotConsumeTheAlertFlag() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 1, hours_til_next_reset: nil)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache)
        _ = await trial.activateOrContinue(hi: 1, lo: 2, gameHandle: 42, isPastMulligan: false)

        // Back in the lobby, before the refreshed status arrives
        XCTAssertFalse(trial.shouldShowTrialsExhaustedAlert(seen: false, isPremium: false))
        XCTAssertTrue(pendingFlag(trial))

        // The match ended (status cleared) and the lobby refresh came back
        trial.clear()
        XCTAssertFalse(trial.shouldShowTrialsExhaustedAlert(seen: false, isPremium: false))
        XCTAssertTrue(pendingFlag(trial))

        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 100)
        await cache.update(hi: 1, lo: 2)
        XCTAssertTrue(trial.shouldShowTrialsExhaustedAlert(seen: false, isPremium: false))
        XCTAssertFalse(pendingFlag(trial))
        XCTAssertFalse(trial.shouldShowTrialsExhaustedAlert(seen: false, isPremium: false))
    }

    func testAlertNotShownWhenSeenOrPremium() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 100)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache)
        trial.persistedData = MulliganGuideTrialData(token: "t", gameHandle: 1, lastTrialAlertPending: true)

        XCTAssertFalse(trial.shouldShowTrialsExhaustedAlert(seen: true, isPremium: false))
        XCTAssertFalse(trial.shouldShowTrialsExhaustedAlert(seen: false, isPremium: true))
        XCTAssertTrue(pendingFlag(trial))
    }

    // MARK: - Premium or trial gate

    func testNoTrialsGateNeedsNoRequest() async {
        let cache = makeCache()
        nextStatus = PlayerTrialStatus(trials_remaining: 0, hours_til_next_reset: 8)
        await cache.update(hi: 1, lo: 2)
        let trial = makeTrial(cache: cache)

        let reason = await trial.premiumOrTrialGate(isPremium: false, signedIn: false, hi: 1, lo: 2)

        XCTAssertEqual(reason, .notPremiumNoTrials(signedIn: false, remainingTrials: 0, hoursUntilReset: 8))
        XCTAssertTrue(reason?.isTrialsExhausted ?? false)
        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(activateCount.value, 0)
    }

    func testGateLoadsAMissingStatusOnce() async {
        let cache = makeCache()
        let trial = makeTrial(cache: cache)
        nextStatus = PlayerTrialStatus(trials_remaining: 2, hours_til_next_reset: nil)

        let reason = await trial.premiumOrTrialGate(isPremium: false, signedIn: true, hi: 1, lo: 2)

        XCTAssertNil(reason)
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testGateWithUnreadableStatusIsNotReportedAsExhausted() async {
        let trial = makeTrial(cache: makeCache())
        nextStatus = nil

        let reason = await trial.premiumOrTrialGate(isPremium: false, signedIn: false, hi: 1, lo: 2)

        XCTAssertEqual(reason, .notPremiumNoTrials(signedIn: false, remainingTrials: nil, hoursUntilReset: nil))
        XCTAssertFalse(reason?.isTrialsExhausted ?? true)
    }

    func testPremiumSkipsTheTrialStatus() async {
        let trial = makeTrial(cache: makeCache())

        let reason = await trial.premiumOrTrialGate(isPremium: true, signedIn: true, hi: 1, lo: 2)

        XCTAssertNil(reason)
        XCTAssertEqual(fetchCount.value, 0)
    }

    // MARK: - Match routing

    func testV2GuideIsStandardRankedOrFriendlyOnly() {
        XCTAssertTrue(Game.isV2MulliganMatch(gameType: .gt_ranked, formatType: .ft_standard))
        XCTAssertTrue(Game.isV2MulliganMatch(gameType: .gt_vs_friend, formatType: .ft_standard))
        XCTAssertFalse(Game.isV2MulliganMatch(gameType: .gt_ranked, formatType: .ft_wild))
        XCTAssertFalse(Game.isV2MulliganMatch(gameType: .gt_ranked, formatType: .ft_twist))
        XCTAssertFalse(Game.isV2MulliganMatch(gameType: .gt_casual, formatType: .ft_standard))
    }

    func testDeckStatusesThatAllowATrial() {
        XCTAssertTrue(ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(.v2_ready))
        XCTAssertTrue(ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(.v2_partial))
        XCTAssertTrue(ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(.v1_ready))
        XCTAssertFalse(ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(.no_data))
        XCTAssertFalse(ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(.loading))
        XCTAssertFalse(ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(nil))
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
