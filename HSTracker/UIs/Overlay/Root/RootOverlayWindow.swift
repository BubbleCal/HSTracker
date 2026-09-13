//
//  RootOverlayWindow.swift
//  HSTracker
//
//  Created by Francisco Moraes on 8/7/26.
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import SwiftUI
import Combine
import Foundation

@available(macOS 10.15, *)
class RootOverlayWindow: OverWindowController {
    var hostingView: NSHostingView<RootOverlayView>!
    let viewModel = RootOverlayViewModel()

    private var regionSubscription: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localPressMonitor: Any?
    // Whether the left button went down on this canvas and has not come back up yet
    private var pressCaptured = false
    private var fallbackTimer: Timer?
    private var hoveredCardId: String?
    private weak var hoveredView: CardHoverNSView?

    override func windowDidLoad() {
        super.windowDidLoad()
        hostingView = NSHostingView(rootView: RootOverlayView(viewModel: viewModel))
        window?.contentView = hostingView
        window?.isOpaque = false
        window?.backgroundColor = .clear
        // RootOverlay spans the whole Hearthstone client area and stays
        // click-through by default - ignoresMouseEvents is a window-level
        // switch, not per-view, so it can't be flipped wholesale without
        // blocking clicks over the rest of the game window too. Instead we
        // track the live cursor position (installMouseMonitors below) and
        // flip it on/off only while the cursor is actually over a child that
        // reported itself as interactive (see InteractiveRegionPreferenceKey
        // in RootOverlayView) - everywhere else stays click-through down to
        // the pixel, including right up to that child's own edge.
        window?.ignoresMouseEvents = true
        installMouseMonitors()
    }

    // OverWindowController.updateFrames sets ignoresMouseEvents from Settings.windowsLocked, which is
    // right for the tracker windows but not for this canvas: every tracker refresh would make it
    // click-through (or, unlocked, click-catching everywhere) until the next region check. Here the
    // region tracking below owns that switch, so a refresh only re-runs it.
    override func updateFrames() {
        updateMouseThrough()
    }

    deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localPressMonitor {
            NSEvent.removeMonitor(monitor)
        }
        fallbackTimer?.invalidate()
    }

    private func installMouseMonitors() {
        // Global monitor: fires for mouse moves anywhere on screen while this
        // app isn't the event's destination (e.g. cursor is over Hearthstone,
        // or over empty click-through overlay space). This is what detects
        // the cursor entering the interactive region from outside.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateMouseThrough()
        }
        // Local monitor: fires once ignoresMouseEvents is already false and
        // this window is the destination, so the global monitor above no
        // longer sees these moves - needed to detect the cursor leaving the
        // region again.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateMouseThrough()
            return event
        }
        // A press that went down on an interactive child belongs to it until the button comes up.
        // Moves with the button held arrive as drags, which the mouse-moved monitors above never
        // see, and by the time the timer below checks, a panel being dragged can be a step behind
        // the cursor or stopped at the canvas edge while the cursor goes on - dropping the window
        // back to click-through there would end the drag halfway.
        localPressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            self.pressCaptured = OverlayClickThrough.pressCaptured(self.pressCaptured, after: event.type,
                                                                   in: event.window, overlayWindow: self.window)
            if event.type == .leftMouseUp {
                // After the release has been handled: it was routed here already, but the gesture
                // it ends has not seen it yet
                DispatchQueue.main.async { [weak self] in
                    self?.updateMouseThrough()
                }
            } else {
                self.updateMouseThrough()
            }
            return event
        }
        regionSubscription = viewModel.$interactiveRegions.sink { [weak self] _ in
            self?.updateMouseThrough()
        }
        // Backstop: mouse-moved monitors should keep ignoresMouseEvents in
        // sync on their own, but if either failed to register (or events get
        // dropped for some reason) this guarantees convergence within
        // ~150ms instead of the window getting stuck non-click-through.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateMouseThrough()
        }
    }

    private func updateMouseThrough() {
        guard let window = window, let hostingView = hostingView else { return }
        let screenLocation = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenLocation)
        let viewPoint = hostingView.convert(windowPoint, from: nil)

        // Where the opacity mask cuts the overlay away (the friends list, the game menu, a card the
        // game blows up) the canvas is not drawn, so it must not take the clicks or open card
        // tooltips there either - they belong to what Hearthstone shows through the cut-out.
        let isMasked = isMaskedOut(viewPoint)

        updateFilterRegionHover(at: viewPoint)
        updateCounterHover()
        // Above the click-through guard, for the same reason as the counter
        // hover right before it: which card is under the cursor has nothing to
        // do with whether the canvas currently has interactive children. Running
        // it only when it does meant that a card tooltip stayed on screen when
        // the panel holding the hovered card closed and took the last
        // interactive region with it in the same pass - the sweep that would
        // have dismissed it lives at the end of updateCardHover().
        updateCardHover(isMasked: isMasked)

        let decision = OverlayClickThrough.decide(pressCaptured: pressCaptured,
                                                  primaryButtonDown: NSEvent.pressedMouseButtons & 1 != 0,
                                                  isMasked: isMasked,
                                                  regions: viewModel.interactiveRegions,
                                                  point: viewPoint)
        pressCaptured = decision.pressCaptured
        setIgnoresMouseEvents(decision.ignoresMouseEvents)
    }

    // HDT's BgsTopBarMask MouseEnter/MouseLeave handlers, which flip
    // BattlegroundsMinionsVM.IsFilterRegionHovered to slide the minion browser's
    // filter button in and out.
    //
    // Driven from the cursor position tracked here rather than from a SwiftUI
    // .onHover, because the mask deliberately stays click-through
    // (IsHitTestVisible="False" on HDT's side): .onHover only fires once
    // ignoresMouseEvents is already false, so it would never see the cursor over
    // the part of the mask outside the panel - which is exactly where the button
    // slides out to. Called before the interactiveRegion guard below so it keeps
    // running while the overlay is fully click-through.
    private func updateFilterRegionHover(at viewPoint: NSPoint) {
        let hovered = Set(viewModel.hoverRegions.filter { $0.rect.contains(viewPoint) }.map { $0.id })
        if viewModel.hoveredRegionIds != hovered {
            viewModel.hoveredRegionIds = hovered
        }

        let hovering = hovered.contains(HoverRegionID.bgsTopBarMask)
        let minions = viewModel.battlegroundsMinionsGuide
        guard minions.isFilterRegionHovered != hovering else { return }
        // Durations match the tab's own slide storyboard: 0.2s out, 0.4s back.
        withAnimation(.easeOut(duration: hovering ? 0.2 : 0.4)) {
            minions.isFilterRegionHovered = hovering
        }
    }

    // HDT's counters are IsOverlayHoverVisible: hovering one puts up its
    // related-cards grid while clicks over it still fall through to
    // Hearthstone. Matched from the cursor position here rather than from an
    // NSTrackingArea inside the chip for the same reason as the filter region
    // above - a click-through window is delivered no mouse-entered events -
    // and called before the interactive-region guard so it keeps working while
    // the canvas has no interactive children at all, which is the normal case
    // during a constructed match.
    private func updateCounterHover() {
        guard let overlayWindow = window else { return }
        let screenLocation = NSEvent.mouseLocation

        let match = CounterHoverRegistry.shared.entries.last { entry in
            guard let nsView = entry.view,
                  nsView.window === overlayWindow else { return false }
            let rectInWindow = nsView.convert(nsView.bounds, to: nil)
            return overlayWindow.convertToScreen(rectInWindow).contains(screenLocation)
        }

        let anchor = match?.view.map { view in
            overlayWindow.convertToScreen(view.convert(view.bounds, to: nil))
        }
        CounterTooltipController.shared.hover(counter: match?.counter, anchor: anchor)
    }

    private func setIgnoresMouseEvents(_ ignores: Bool) {
        if window?.ignoresMouseEvents != ignores {
            window?.ignoresMouseEvents = ignores
        }
    }

    // Matches the live cursor position (already computed above for the
    // click-through check) against every currently-reported card hover
    // region and drives CardTooltipPanel directly - see the comment atop
    // CardHoverRegionPreferenceKey in CardImageTooltip.swift for why this
    // replaces a per-view hover callback.
    // Matches the live cursor against registered CardHoverNSView instances using
    // CALayer coordinate conversion. layer.convert(bounds, to: rootLayer) goes
    // through the full CALayer transform chain - including SwiftUI's scaleEffect
    // and NSScrollView's scroll offset - giving the correct visual position.
    // The final comparison is in screen coordinates (Y-up, Cocoa convention)
    // using NSEvent.mouseLocation, avoiding any NSView/SwiftUI coordinate space
    // issues entirely.
    private func updateCardHover(isMasked: Bool) {
        guard let overlayWindow = window else { return }
        let screenLocation = NSEvent.mouseLocation

        // `last`, not `first`: the Inspiration board overlaps its tiles by 8pt
        // (HDT's Margin="-4,0"), so two entries can contain the cursor at once.
        // Registration follows view-tree order, and a later sibling draws on
        // top - which is the one WPF's hit-testing would pick. Everywhere else
        // the tiles do not overlap, so at most one entry ever matches and this
        // is the same as before.
        let match = CardHoverRegistry.shared.entries.last { entry in
            guard !isMasked, let nsView = entry.view,
                  nsView.window === overlayWindow else { return false }
            // NSView.convert(to: nil) → window base coordinates (Y-up from
            // window bottom, flips handled by AppKit automatically).
            // convertToScreen → screen coordinates (same Y-up convention).
            // NSEvent.mouseLocation is also Y-up screen coordinates.
            guard let rectInWindow = Self.visibleRectInWindow(nsView) else { return false }
            let screenRect = overlayWindow.convertToScreen(rectInWindow)
            return screenRect.contains(screenLocation)
        }

        if let match = match {
            // Keyed on the matched view as well as the card: an Inspiration board
            // routinely holds two copies of the same minion, and now that the
            // tooltip anchors to the element rather than following the cursor,
            // moving between them has to re-anchor it. HDT gets this for free -
            // each element raises its own MouseLeave/MouseEnter.
            if hoveredCardId != match.cardId || hoveredView !== match.view {
                hoveredCardId = match.cardId
                hoveredView = match.view
                // HDT anchors the tooltip to the hovered element and clamps it to
                // the overlay window (its ActualWidth/ActualHeight), not to the
                // screen - so both rects are handed over here, in the screen
                // coordinates the panel positions itself in.
                let anchor = match.view.flatMap(Self.visibleRectInWindow).map {
                    overlayWindow.convertToScreen($0)
                }
                CardTooltipPanel.shared.show(cardId: match.cardId, showTriple: match.showTriple,
                                             baconTriple: match.baconTriple,
                                             placement: match.placement,
                                             anchor: anchor, bounds: overlayWindow.frame,
                                             baconCard: match.baconCard)
            }
        } else {
            if hoveredCardId != nil {
                hoveredCardId = nil
                hoveredView = nil
                // Unconditional hide: we know no card is under cursor, so we must
                // dismiss regardless of which card (base or golden) is currently shown.
                // Scoped to this source, though - the cursor leaving the canvas is routinely the
                // cursor arriving somewhere that drives the same panel itself.
                CardTooltipPanel.shared.hide(from: .registry)
            }
            // Force-hide if the tooltip's current card is no longer registered.
            // Fires at most every 150ms via the fallback timer and catches the
            // race where hide(ifShowing:) returned early because currentCardId
            // was a different card than the one whose view was removed (e.g.
            // the guide navigated away while a new 300ms show-delay was still
            // in flight for a different hovered card).
            // Scoped the same way: "not in the registry" only means "gone" for a tooltip the
            // registry started.
            let registry = CardHoverRegistry.shared
            if let shown = CardTooltipPanel.shared.currentCardId,
               !registry.entries.contains(where: { $0.cardId == shown && $0.view != nil }) {
                CardTooltipPanel.shared.hide(from: .registry)
            }
        }
    }

    // Whether a point in the hosting view's coordinates lies in a region the opacity mask cuts out.
    // The rects are normalized to the canvas, y down, like the view's own flipped coordinates.
    private func isMaskedOut(_ viewPoint: NSPoint) -> Bool {
        let size = hostingView.bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        let normalized = CGPoint(x: viewPoint.x / size.width,
                                 y: hostingView.isFlipped ? viewPoint.y / size.height : 1 - viewPoint.y / size.height)
        return viewModel.opacityMask.maskedRects.contains { $0.contains(normalized) }
    }

    // The part of a hover view the player can actually see, in window coordinates, or nil when none
    // of it is. A card name scrolled out of the action history's list keeps its frame under the
    // clip view, so matching its full bounds would pop the tooltip over the board below the panel.
    //
    // Only the enclosing clip views are applied, not NSView.visibleRect: SwiftUI's intermediate
    // platform views are not guaranteed to have bounds that contain their children, and a view
    // outside any scroll view must keep matching exactly as before.
    private static func visibleRectInWindow(_ view: NSView) -> NSRect? {
        var rect = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let current = ancestor {
            if let clipView = current as? NSClipView {
                rect = rect.intersection(clipView.convert(clipView.bounds, to: nil))
                if rect.isEmpty {
                    return nil
                }
            }
            ancestor = current.superview
        }
        return rect
    }
}

// Whether the whole-screen RootOverlay canvas takes the mouse, kept apart from the window so the rule
// that has to hand every other click to Hearthstone can be tested without events or a screen.
enum OverlayClickThrough {
    /// Whether a left press is held on the canvas after a mouse event. A press belongs to the canvas
    /// only if it went down there - the window only receives one over an interactive region - and
    /// lets go on the release. Drags change nothing, and neither does anything else.
    static func pressCaptured(_ captured: Bool, after eventType: NSEvent.EventType,
                              in eventWindow: NSWindow?, overlayWindow: NSWindow?) -> Bool {
        switch eventType {
        case .leftMouseDown:
            return eventWindow != nil && eventWindow === overlayWindow
        case .leftMouseUp:
            return false
        default:
            return captured
        }
    }

    /// Whether the canvas should ignore the mouse with the cursor at `point` (the hosting view's
    /// coordinates), and whether a press is still held on it.
    ///
    /// A held press keeps the canvas taking the mouse wherever the cursor is, so a dragged panel that
    /// lags behind it or stops at an edge does not lose the drag. Otherwise the canvas takes the mouse
    /// only over an interactive region that the opacity mask has not cut away.
    ///
    /// - Parameter primaryButtonDown: the left button's live state, which ends a held press whose
    ///   release went somewhere the event monitor never saw - otherwise the canvas would go on
    ///   swallowing Hearthstone's clicks.
    static func decide(pressCaptured: Bool, primaryButtonDown: Bool, isMasked: Bool,
                       regions: [CGRect], point: CGPoint) -> (ignoresMouseEvents: Bool, pressCaptured: Bool) {
        if pressCaptured && primaryButtonDown {
            return (false, true)
        }
        guard !isMasked else {
            return (true, false)
        }
        let inside = regions.contains { $0.contains(point) }
        return (!inside, false)
    }
}
