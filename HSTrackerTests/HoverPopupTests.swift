//
//  HoverPopupTests.swift
//  HSTrackerTests
//

import XCTest
import AppKit

@testable import HSTracker

/// The card popup a tracker row puts up has to be on screen, with its image, by the time the
/// hover handler returns - no timer, no main-queue hop, no fade.
class HoverPopupTests: HSTrackerTests {
    private var windows = [NSWindow]()

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        super.tearDown()
    }

    private func makeImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    private func pngData(width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    // An invisible window that still counts as on screen, holding one view at a known place
    private func makeVisibleWindow(with view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        view.frame = NSRect(x: 10, y: 20, width: 50, height: 30)
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    func testPerformOnMainThreadRunsInlineOnTheMainThread() {
        var ran = false
        performOnMainThread { ran = true }
        XCTAssertTrue(ran, "a block started on the main thread must not wait for the next main-queue turn")
    }

    func testPerformOnMainThreadHopsFromABackgroundThread() {
        let done = expectation(description: "ran on main")
        DispatchQueue.global().async {
            performOnMainThread {
                XCTAssertTrue(Thread.isMainThread)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
    }

    func testDecodedImageKeepsTheSizeNSImageWouldGiveIt() throws {
        let data = try XCTUnwrap(pngData(width: 20, height: 30))
        let decoded = try XCTUnwrap(ImageUtils.decodedImage(data: data))
        let plain = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(decoded.size, plain.size)
        XCTAssertEqual(decoded.size, NSSize(width: 20, height: 30))
    }

    func testDecodedImageFallsBackForDataThatIsNotAnImage() {
        XCTAssertNil(ImageUtils.decodedImage(data: Data("<html>404</html>".utf8)))
    }

    func testCachedCardArtIsHandedOverSynchronously() {
        let cardId = "HOVER_TEST_SYNC_\(UUID().uuidString)"
        XCTAssertNil(ImageUtils.cachedCardArt(cardId: cardId))
        let image = makeImage(width: 4, height: 4)
        ImageUtils.store(image, type: .cardArt, cardId: cardId)

        XCTAssertTrue(ImageUtils.cachedCardArt(cardId: cardId) === image)
        var delivered: NSImage?
        ImageUtils.cardArt(for: cardId) { delivered = $0 }
        XCTAssertTrue(delivered === image, "a cache hit must not wait for a later main-queue turn")

        let bgId = "HOVER_TEST_BG_\(UUID().uuidString)"
        let bgImage = makeImage(width: 4, height: 4)
        ImageUtils.store(bgImage, type: .cardArtBG, cardId: "\(bgId)_triple")
        XCTAssertTrue(ImageUtils.cachedCardArtBG(cardId: bgId, baconTriple: true) === bgImage)
        XCTAssertNil(ImageUtils.cachedCardArtBG(cardId: bgId, baconTriple: false))
    }

    func testFloatingCardShowsACachedRenderBeforeItReturns() {
        let first = Card(id: "HOVER_TEST_FIRST_\(UUID().uuidString)")
        let second = Card(id: "HOVER_TEST_SECOND_\(UUID().uuidString)")
        let firstImage = makeImage(width: 4, height: 4)
        let secondImage = makeImage(width: 4, height: 4)
        ImageUtils.store(firstImage, type: .cardArt, cardId: first.id)
        ImageUtils.store(secondImage, type: .cardArt, cardId: second.id)

        let floatingCard = FloatingCard(windowNibName: "FloatingCard")
        _ = floatingCard.window
        floatingCard.set(card: first)
        XCTAssertTrue(floatingCard.imageView.image === firstImage)
        // Moving to the next row swaps the render at once, never showing the previous card
        floatingCard.set(card: second)
        XCTAssertTrue(floatingCard.imageView.image === secondImage)
    }

    func testShowAndHideFloatingCardApplyBeforeReturning() {
        let windowManager = WindowManager()
        let card = Card(id: "HOVER_TEST_SHOW_\(UUID().uuidString)")
        ImageUtils.store(makeImage(width: 4, height: 4), type: .cardArt, cardId: card.id)
        let row = NSView()
        let otherRow = NSView()
        // Far off screen; a subtitle makes it show whatever the card preview setting is
        let userInfo: [String: Any] = [
            "card": card,
            "frame": [CGFloat(-20000), CGFloat(-20000), CGFloat(256), CGFloat(388)],
            "useFrame": true,
            "subtitle": "test",
            "source": row
        ]
        windowManager.showFloatingCard(Notification(name: Notification.Name(Events.show_floating_card),
                                                    object: nil, userInfo: userInfo))
        defer { windowManager.forceHideFloatingCard() }

        XCTAssertEqual(windowManager.floatingCard.card?.id, card.id)
        XCTAssertTrue(windowManager.floatingCardSource === row)
        XCTAssertEqual(windowManager.floatingCard.window?.isVisible, true)
        XCTAssertEqual(windowManager.floatingCard.window?.animationBehavior, NSWindow.AnimationBehavior.none)
        XCTAssertNotNil(windowManager.closeRequestTimer)

        // A late exit from another row, with the same card, leaves this popup alone
        windowManager.hideFloatingCard(Notification(name: Notification.Name(Events.hide_floating_card), object: nil,
                                                    userInfo: ["card": card, "source": otherRow]))
        XCTAssertEqual(windowManager.floatingCard.window?.isVisible, true)

        windowManager.hideFloatingCard(Notification(name: Notification.Name(Events.hide_floating_card), object: nil,
                                                    userInfo: ["card": card, "source": row]))
        XCTAssertEqual(windowManager.floatingCard.window?.isVisible, false)
        XCTAssertNil(windowManager.floatingCardSource)
        XCTAssertNil(windowManager.closeRequestTimer)
    }

    func testFloatingCardOwnershipOnlyBlocksAHideFromAnotherView() {
        let windowManager = WindowManager()
        let row = NSView()
        XCTAssertFalse(windowManager.isFloatingCardOwned(byOtherThan: row), "nothing shown yet")
        XCTAssertFalse(windowManager.isFloatingCardOwned(byOtherThan: nil))
    }

    func testHoverSourceStaysWhileTheCursorIsOverIt() throws {
        let bar = CardBar()
        let window = makeVisibleWindow(with: bar)
        let rect = window.convertToScreen(bar.convert(bar.bounds, to: nil))
        let inside = NSPoint(x: rect.midX, y: rect.midY)
        let outside = NSPoint(x: rect.maxX + 5, y: rect.midY)

        // The bar has not been told the mouse entered, so it is not hovered
        XCTAssertFalse(WindowManager.isHoverSource(bar, stillUnder: inside))

        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             trackingNumber: 0, userData: nil)
        bar.mouseEntered(with: try XCTUnwrap(entered))
        XCTAssertTrue(bar.isHovered)
        XCTAssertTrue(WindowManager.isHoverSource(bar, stillUnder: inside))
        XCTAssertFalse(WindowManager.isHoverSource(bar, stillUnder: outside))

        window.orderOut(nil)
        XCTAssertFalse(WindowManager.isHoverSource(bar, stillUnder: inside), "a tracker ordered out under the cursor")
    }

    private final class RecordingHover: CardCellHover {
        var hovers = [String]()
        var outs = [String]()
        func hover(cell: CardBar, card: Card) { hovers.append(card.id) }
        func out(cell: CardBar, card: Card) { outs.append(card.id) }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue turn")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func testRowHoverIsImmediateAndItsExitLetsTheNextRowTakeOverFirst() throws {
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                         timestamp: 0, windowNumber: 0, context: nil,
                                                         eventNumber: 0, trackingNumber: 0, userData: nil))
        let delegate = RecordingHover()
        let bar = CardBar()
        bar.setDelegate(delegate)
        bar.card = Card(id: "HOVER_TEST_ROW")

        bar.mouseEntered(with: event)
        XCTAssertEqual(delegate.hovers, ["HOVER_TEST_ROW"], "the hover handler runs on the mouseEntered itself")

        bar.mouseExited(with: event)
        XCTAssertEqual(delegate.outs, [], "the exit waits for a queued mouseEntered")
        bar.mouseEntered(with: event)
        drainMainQueue()
        XCTAssertEqual(delegate.outs, [], "back on the row before the exit was handled")

        bar.mouseExited(with: event)
        drainMainQueue()
        XCTAssertEqual(delegate.outs, ["HOVER_TEST_ROW"])
    }

    func testHoverSourceWithoutAWindowIsNotHovered() {
        XCTAssertFalse(WindowManager.isHoverSource(NSView(), stillUnder: .zero))
    }
}
