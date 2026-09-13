//
//  OverlayClickThroughTests.swift
//  HSTrackerTests
//
//  When the whole-screen RootOverlay canvas takes the mouse (OverlayClickThrough). Everywhere it does
//  not, Hearthstone gets the clicks, so a press held on a dragged panel must not outlast the button.
//

import XCTest
import AppKit

@testable import HSTracker

class OverlayClickThroughTests: XCTestCase {
    private let panel = CGRect(x: 100, y: 100, width: 280, height: 300)
    private let insidePanel = CGPoint(x: 150, y: 110)
    private let outsidePanel = CGPoint(x: 900, y: 700)

    private func decide(captured: Bool, buttonDown: Bool, masked: Bool = false, regions: [CGRect]? = nil,
                        at point: CGPoint) -> (ignoresMouseEvents: Bool, pressCaptured: Bool) {
        return OverlayClickThrough.decide(pressCaptured: captured, primaryButtonDown: buttonDown, isMasked: masked,
                                          regions: regions ?? [panel], point: point)
    }

    func testThePanelTakesTheMouseAndEverywhereElseClicksThrough() {
        XCTAssertFalse(decide(captured: false, buttonDown: false, at: insidePanel).ignoresMouseEvents)
        XCTAssertTrue(decide(captured: false, buttonDown: false, at: outsidePanel).ignoresMouseEvents)
        XCTAssertTrue(decide(captured: false, buttonDown: false, regions: [], at: insidePanel).ignoresMouseEvents)
        // Where Hearthstone's own menus cut the overlay away, even over the panel
        XCTAssertTrue(decide(captured: false, buttonDown: false, masked: true, at: insidePanel).ignoresMouseEvents)
    }

    func testAPressOnTheCanvasHoldsItUntilTheRelease() {
        let overlay = NSWindow()
        var captured = OverlayClickThrough.pressCaptured(false, after: .leftMouseDown, in: overlay, overlayWindow: overlay)
        XCTAssertTrue(captured)

        // Dragged past the panel's rect, where it lags behind or stops at the canvas edge
        captured = OverlayClickThrough.pressCaptured(captured, after: .leftMouseDragged, in: overlay, overlayWindow: overlay)
        XCTAssertTrue(captured)
        let dragging = decide(captured: captured, buttonDown: true, at: outsidePanel)
        XCTAssertFalse(dragging.ignoresMouseEvents)
        XCTAssertTrue(dragging.pressCaptured)
        // Even into a masked-out spot, or with the panel's region gone for a moment
        XCTAssertFalse(decide(captured: captured, buttonDown: true, masked: true, at: outsidePanel).ignoresMouseEvents)
        XCTAssertFalse(decide(captured: captured, buttonDown: true, regions: [], at: outsidePanel).ignoresMouseEvents)

        // Released outside the panel: click-through again at once
        captured = OverlayClickThrough.pressCaptured(captured, after: .leftMouseUp, in: overlay, overlayWindow: overlay)
        XCTAssertFalse(captured)
        let released = decide(captured: captured, buttonDown: false, at: outsidePanel)
        XCTAssertTrue(released.ignoresMouseEvents)
        XCTAssertFalse(released.pressCaptured)
        // Released over a masked-out spot of the panel
        XCTAssertTrue(decide(captured: captured, buttonDown: false, masked: true, at: insidePanel).ignoresMouseEvents)
    }

    func testAReleaseTheMonitorMissedEndsThePressFromTheButtonState() {
        // Still marked as held, but the button is up
        let missed = decide(captured: true, buttonDown: false, at: outsidePanel)
        XCTAssertTrue(missed.ignoresMouseEvents)
        XCTAssertFalse(missed.pressCaptured, "a later press elsewhere must not find it still held")
        XCTAssertTrue(decide(captured: missed.pressCaptured, buttonDown: true, at: outsidePanel).ignoresMouseEvents)

        // Over the panel it keeps taking the mouse, for hovering and the next click, but holds nothing
        let overPanel = decide(captured: true, buttonDown: false, at: insidePanel)
        XCTAssertFalse(overPanel.ignoresMouseEvents)
        XCTAssertFalse(overPanel.pressCaptured)
    }

    func testAPressThatStartedElsewhereIsNotHeld() {
        let overlay = NSWindow()
        let other = NSWindow()
        // Another HSTracker window, such as a tracker or the secret helper, or no window at all
        XCTAssertFalse(OverlayClickThrough.pressCaptured(false, after: .leftMouseDown, in: other, overlayWindow: overlay))
        XCTAssertFalse(OverlayClickThrough.pressCaptured(true, after: .leftMouseDown, in: other, overlayWindow: overlay))
        XCTAssertFalse(OverlayClickThrough.pressCaptured(false, after: .leftMouseDown, in: nil, overlayWindow: overlay))
        XCTAssertFalse(OverlayClickThrough.pressCaptured(false, after: .leftMouseDown, in: nil, overlayWindow: nil))
        // A drag or release of that press does not start holding the canvas
        XCTAssertFalse(OverlayClickThrough.pressCaptured(false, after: .leftMouseDragged, in: overlay, overlayWindow: overlay))
        XCTAssertFalse(OverlayClickThrough.pressCaptured(false, after: .leftMouseUp, in: overlay, overlayWindow: overlay))
        // So the cursor pressed down outside the panel stays click-through
        XCTAssertTrue(decide(captured: false, buttonDown: true, at: outsidePanel).ignoresMouseEvents)
    }
}
