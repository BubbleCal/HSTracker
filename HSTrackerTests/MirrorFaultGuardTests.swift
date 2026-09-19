//
//  MirrorFaultGuardTests.swift
//  HSTrackerTests
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import XCTest
@testable import HSTracker

/// HearthMirror dereferences objects it reads out of Hearthstone's memory without checking them,
/// and a null one faulted inside getMatchInfo on every game start. The guard has to turn such a
/// fault into "no data" and leave the process - and the next guarded call - working.
class MirrorFaultGuardTests: XCTestCase {

    func testAFaultInsideTheGuardIsReportedInsteadOfCrashing() throws {
        var reached = false
        let signal = HSTRunGuardingMemoryFaults {
            // The first page is never mapped, as for the null object HearthMirror read through
            let pointer = try? XCTUnwrap(UnsafeMutablePointer<Int>(bitPattern: 8))
            reached = (pointer?.pointee ?? 0) >= 0
        }
        XCTAssertEqual(signal, SIGSEGV)
        XCTAssertFalse(reached, "the block is abandoned at the fault")
    }

    func testAGuardedBlockThatDoesNotFaultRunsToCompletion() {
        var ran = false
        XCTAssertEqual(HSTRunGuardingMemoryFaults { ran = true }, 0)
        XCTAssertTrue(ran)
    }

    func testTheGuardStillWorksAfterAFault() {
        // The value is kept, or the load is dropped and nothing faults
        var value = 0
        XCTAssertEqual(HSTRunGuardingMemoryFaults {
            value = UnsafeMutablePointer<Int>(bitPattern: 8)?.pointee ?? -1
        }, SIGSEGV)
        XCTAssertEqual(HSTRunGuardingMemoryFaults {
            value = UnsafeMutablePointer<Int>(bitPattern: 16)?.pointee ?? -1
        }, SIGSEGV)
        XCTAssertEqual(value, 0, "neither load completed")
        var ran = false
        XCTAssertEqual(HSTRunGuardingMemoryFaults { ran = true }, 0)
        XCTAssertTrue(ran)
    }
}
