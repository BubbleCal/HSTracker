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

    func testCardArtCacheKeepsListedRendersAndOnlyTheMostRecentOthers() {
        let cache = CardArtCache(recentLimit: 2)
        let tracker = NSObject()
        cache.setListed(["a", "b", "c"], for: tracker)
        for key in ["a", "b", "c", "d", "e", "f"] {
            cache[key] = makeImage(width: 1, height: 1)
        }
        // Everything listed, plus the two most recently used of the rest
        XCTAssertEqual(cache.count, 5)
        XCTAssertFalse(cache.contains("d"))

        // Reading a render counts as using it
        XCTAssertNotNil(cache["e"])
        cache["g"] = makeImage(width: 1, height: 1)
        XCTAssertTrue(cache.contains("e"))
        XCTAssertFalse(cache.contains("f"))

        // A second list keeps its renders too, however many the two list together
        let secrets = NSObject()
        cache.setListed(["e", "g"], for: secrets)
        cache["h"] = makeImage(width: 1, height: 1)
        cache["i"] = makeImage(width: 1, height: 1)
        cache["j"] = makeImage(width: 1, height: 1)
        XCTAssertEqual(cache.count, 7)
        XCTAssertFalse(cache.contains("h"))

        // Once nothing lists them, a finished game's cards are let go down to the recent limit
        cache.setListed([], for: tracker)
        cache.setListed([], for: secrets)
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(cache.contains("i"))
        XCTAssertTrue(cache.contains("j"))

        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testPreloadRetriesARenderThatFailedToLoadOnceTheRetryIntervalPasses() {
        let cardId = "HOVER_TEST_RETRY_\(UUID().uuidString)"
        let now: TimeInterval = 1000
        XCTAssertEqual(ImageUtils.preloadCandidates(cardIds: [cardId, "", cardId], now: now), [cardId])

        // Offline, say: the pre-load stops asking on every refresh...
        ImageUtils.noteLoadResult(type: .cardArt, cardId: cardId, succeeded: false, now: now)
        XCTAssertEqual(ImageUtils.preloadCandidates(cardIds: [cardId], now: now + 1), [])
        // ...but not for the rest of the session
        XCTAssertEqual(ImageUtils.preloadCandidates(cardIds: [cardId], now: now + ImageUtils.preloadRetryInterval),
                       [cardId])

        ImageUtils.noteLoadResult(type: .cardArt, cardId: cardId, succeeded: true, now: now + 1)
        XCTAssertEqual(ImageUtils.preloadCandidates(cardIds: [cardId], now: now + 2), [cardId])
        // A render already in memory is not loaded again
        ImageUtils.store(makeImage(width: 1, height: 1), type: .cardArt, cardId: cardId)
        XCTAssertEqual(ImageUtils.preloadCandidates(cardIds: [cardId], now: now + 2), [])
    }

    func testEveryCardTypeHasALoadingPlaceholder() {
        XCTAssertEqual(ImageUtils.loadingImageName(for: .minion), "loading_minion")
        XCTAssertEqual(ImageUtils.loadingImageName(for: .spell), "loading_spell")
        for type in CardType.allCases {
            XCTAssertNotNil(NSImage(named: ImageUtils.loadingImageName(for: type)), "\(type)")
        }
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes, and says which.
    private func spin(for timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    func testTrackerRowPreviewHasNoShowDelay() throws {
        guard #available(macOS 10.15, *) else { return }
        let card = Card(id: "HOVER_TEST_ROW_PREVIEW_\(UUID().uuidString)")
        ImageUtils.store(makeImage(width: 4, height: 4), type: .cardArt, cardId: card.id)
        let row = NSView()
        _ = makeVisibleWindow(with: row)
        let panel = CardTooltipPanel.shared
        defer { panel.hide() }
        // Far off screen
        let anchor = NSRect(x: -20000, y: -20000, width: 217, height: 34)
        let request = CardTooltipRequest(cardId: card.id, showTriple: false)

        // HDT's own 300ms show delay: nothing yet after 100ms
        panel.show(request, anchor: anchor, source: .trackingArea, sourceView: row, baconCard: false)
        XCTAssertFalse(spin(for: 0.1) { panel.currentCardId == card.id })
        panel.hide()

        // The deck trackers' and the secret helper's rows: up at once, with the cached render
        panel.show(request, anchor: anchor, source: .trackingArea, sourceView: row, baconCard: false, showDelay: 0)
        XCTAssertTrue(spin(for: 0.1) { panel.currentCardId == card.id && panel.isVisible })
        XCTAssertEqual(panel.animationBehavior, NSWindow.AnimationBehavior.none)
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

}
