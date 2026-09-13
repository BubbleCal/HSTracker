//
//  WindowManager.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 20/10/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation
import AppKit

class WindowManager {
	
	var hearthstoneActive = false
	
    static let cardWidth: CGFloat = {
        switch Settings.cardSize {
        case .tiny: return CGFloat(kTinyFrameWidth)
        case .small: return CGFloat(kSmallFrameWidth)
        case .medium: return CGFloat(kMediumFrameWidth)
        case .big: return CGFloat(kFrameWidth)
        case .huge: return CGFloat(kHighRowFrameWidth)
        }
    }()
    static let screenFrame: NSRect = {
        return NSScreen.main!.frame
    }()
    static let top: CGFloat = {
        return screenFrame.height - 50
    }()

    var playerTracker: Tracker = {
        $0.playerType = .player
        return $0
    }(Tracker(windowNibName: "Tracker"))

    var opponentTracker: Tracker = {
        $0.playerType = .opponent
        return $0
    }(Tracker(windowNibName: "Tracker"))
    
    var linkOpponentDeckPanel: LinkOpponentDeckPanel = {
        return $0
    }(LinkOpponentDeckPanel(windowNibName: "LinkOpponentDeckPanel"))

    var secretTracker: CardList = {
        return $0
    }(CardList(windowNibName: "CardList"))
	
    var playerBoardDamage: BoardDamage = {
        $0.player = .player
        return $0
    }(BoardDamage(windowNibName: "BoardDamage"))

    var opponentBoardDamage: BoardDamage = {
        $0.player = .opponent
        return $0
    }(BoardDamage(windowNibName: "BoardDamage"))

    var timerHud: TimerHud = {
        return $0
    }(TimerHud(windowNibName: "TimerHud"))

    var experiencePanel: ExperienceOverlay = {
        return $0
    }(ExperienceOverlay(windowNibName: "ExperienceOverlay"))
    
    var opponentBoardOverlay: BoardOverlay = {
        $0.setPlayerType(playerType: .opponent)
        return $0
    }(BoardOverlay(windowNibName: "BoardOverlay"))
    
    var playerBoardOverlay: BoardOverlay = {
        $0.setPlayerType(playerType: .player)
        return $0
    }(BoardOverlay(windowNibName: "BoardOverlay"))
    
    var mercenariesTaskListButton: MercenariesTaskListButton = {
        return $0
    }(MercenariesTaskListButton(windowNibName: "MercenariesTaskListButton"))

    var mercenariesTaskListView: MercenariesTaskListView = {
        return $0
    }(MercenariesTaskListView(windowNibName: "MercenariesTaskListView"))
    
    var constructedMulliganGuide: ConstructedMulliganGuide = {
        return $0
    }(ConstructedMulliganGuide(windowNibName: "ConstructedMulliganGuide"))
    
    var constructedMulliganGuidePreLobby: ConstructedMulliganGuidePreLobby = {
        return $0
    }(ConstructedMulliganGuidePreLobby(windowNibName: "ConstructedMulliganGuidePreLobby"))
    
    var flavorText: FlavorText = {
        return $0
    }(FlavorText(windowNibName: "FlavorText"))
    
    var playerActiveEffectsOverlay: ActiveEffectsOverlay = {
        $0.isPlayer = true
        return $0
    }(ActiveEffectsOverlay(windowNibName: "ActiveEffectsOverlay"))

    var opponentActiveEffectsOverlay: ActiveEffectsOverlay = {
        $0.isPlayer = false
        return $0
    }(ActiveEffectsOverlay(windowNibName: "ActiveEffectsOverlay"))

    private var _playerPlayerResourcesOverlay: Any?
    @available(OSX 10.15, *)
    var playerPlayerResourcesOverlay: PlayerResourcesWindow? {
        if _playerPlayerResourcesOverlay == nil {
            _playerPlayerResourcesOverlay = PlayerResourcesWindow(windowNibName: "PlayerResourcesWindow")
        }
        return (_playerPlayerResourcesOverlay as? PlayerResourcesWindow)
    }
    
    private var _opponentPlayerResourcesOverlay: Any?
    @available(OSX 10.15, *)
    var opponentPlayerResourcesOverlay: PlayerResourcesWindow? {
        if _opponentPlayerResourcesOverlay == nil {
            _opponentPlayerResourcesOverlay = PlayerResourcesWindow(windowNibName: "PlayerResourcesWindow")
        }
        return (_opponentPlayerResourcesOverlay as? PlayerResourcesWindow)
    }

    private var _rootOverlay: Any?
    @available(OSX 10.15, *)
    var rootOverlay: RootOverlayWindow? {
        if _rootOverlay == nil {
            _rootOverlay = RootOverlayWindow(windowNibName: "RootOverlayWindow")
        }
        return (_rootOverlay as? RootOverlayWindow)
    }

    var floatingCard: FloatingCard = {
        if let fWindow = $0.window {
            
            fWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.mainMenuWindow)) - 1)
            
            if Settings.canJoinFullscreen {
                fWindow.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.fullScreenAuxiliary]
            } else {
                fWindow.collectionBehavior = []
            }
            
            fWindow.styleMask = [.borderless, .nonactivatingPanel]
            fWindow.ignoresMouseEvents = true
            // Shown and hidden on every row the cursor crosses; any window animation is lag
            fWindow.animationBehavior = .none
            
            fWindow.orderFront(nil)
			fWindow.orderOut(nil)
        }
        return $0
    }(FloatingCard(windowNibName: "FloatingCard"))
    
    var floatingCard3: FloatingCard = {
        if let fWindow = $0.window {
            
            fWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.mainMenuWindow)) - 1)
            
            if Settings.canJoinFullscreen {
                fWindow.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.fullScreenAuxiliary]
            } else {
                fWindow.collectionBehavior = []
            }
            
            fWindow.styleMask = [.borderless, .nonactivatingPanel]
            fWindow.ignoresMouseEvents = true
            // Shown and hidden on every row the cursor crosses; any window animation is lag
            fWindow.animationBehavior = .none
            
            fWindow.orderFront(nil)
            fWindow.orderOut(nil)
        }
        return $0
    }(FloatingCard(windowNibName: "FloatingCard"))

    var floatingCard2: FloatingCard = {
        if let fWindow = $0.window {
            
            fWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.mainMenuWindow)) - 1)
            
            if Settings.canJoinFullscreen {
                fWindow.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.fullScreenAuxiliary]
            } else {
                fWindow.collectionBehavior = []
            }
            
            fWindow.styleMask = [.borderless, .nonactivatingPanel]
            fWindow.ignoresMouseEvents = true
            // Shown and hidden on every row the cursor crosses; any window animation is lag
            fWindow.animationBehavior = .none
            
            fWindow.orderFront(nil)
            fWindow.orderOut(nil)
        }
        return $0
    }(FloatingCard(windowNibName: "FloatingCard"))

    var cardHudContainer: CardHudContainer = {
        return $0
    }(CardHudContainer(windowNibName: "CardHudContainer"))
    
    @available(macOS 10.15, *)
    var tooltipGridCards: RelatedCardsTooltipPanel {
        RelatedCardsTooltipPanel.shared
    }

    private var lastCardsUpdateRequest = Date.distantPast.timeIntervalSince1970

    var triggers: [NSObjectProtocol] = []
    
    func startManager() {
        secretTracker.isSecretPanel = true
        if triggers.count == 0 {
            let events = [
                Events.show_floating_card: self.showFloatingCard,
                Events.hide_floating_card: self.hideFloatingCard
            ]
            for (event, trigger) in events {
                let observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: event), object: nil, queue: OperationQueue.main) { note in
                    trigger(note)
                }
                triggers.append(observer)
            }
        }
    }
    
    deinit {
        for observer in triggers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
	
	private func setHearthstoneActive() { hearthstoneActive = true }
	private func setHearthstoneBackground() { hearthstoneActive = false }

    func hideGameTrackers() {
		// TODO: use not defered gui instead
        DispatchQueue.main.async { [weak self] in
            self?.secretTracker.window?.orderOut(nil)
            self?.timerHud.window?.orderOut(nil)
            self?.playerBoardDamage.window?.orderOut(nil)
            self?.opponentBoardDamage.window?.orderOut(nil)
            self?.cardHudContainer.reset()
            self?.playerBoardOverlay.window?.orderOut(nil)
            self?.opponentBoardOverlay.window?.orderOut(nil)
            self?.flavorText.window?.orderOut(nil)
            self?.playerActiveEffectsOverlay.window?.orderOut(nil)
            self?.opponentActiveEffectsOverlay.window?.orderOut(nil)
            if #available(macOS 10.15, *) {
                self?.tooltipGridCards.hide()
                RelatedCardsBrowserPanel.shared.hide()
            }
        }
    }

    // MARK: - Floating card
    var closeRequestTimer: Timer?
    // The auto-hide is a safety net for a hover whose end never arrives (the tracker was ordered
    // out under the cursor, say), not a limit on how long a card can be looked at.
    static let floatingCardTimeout: TimeInterval = 3
    /// The view whose hover put the floating card up, when the caller names one - the tracker and
    /// secret helper rows do. Lets a hide from one row leave alone the popup the next row put up,
    /// and lets the auto-hide tell a hover that is still going on from a stuck one.
    private(set) weak var floatingCardSource: NSView?

    func showFloatingCard(_ notification: Notification) {
        // Straight through on the main thread: the observer is already there, and the hop this
        // used to take put every hover popup a main-queue turn behind the mouse - and behind a
        // hide queued the same way, so which of the two won depended on the order they arrived.
        performOnMainThread { [weak self] in
            self?.presentFloatingCard(notification.userInfo)
        }
    }

    private func presentFloatingCard(_ userInfo: [AnyHashable: Any]?) {
        guard let card = userInfo?["card"] as? Card,
            let arrayFrame = userInfo?["frame"] as? [CGFloat] else {
                return
        }
        let index = userInfo?["index"] as? Int
        if index == nil {
            floatingCardSource = userInfo?["source"] as? NSView
        }
        // With card previews off, a note such as why a secret was ruled out still shows, alone
        let subtitle = userInfo?["subtitle"] as? String
        let useFrame = userInfo?["useFrame"] as? Bool ?? false
        let showsImage = Settings.showFloatingCard
        guard showsImage || (useFrame && subtitle?.isEmpty == false) else {
            // Nothing to show for this card, so the previous row's subtitle-only popup goes: its
            // own exit is ignored once this row owns the popup.
            if index == nil {
                closeRequestTimer?.invalidate()
                closeRequestTimer = nil
                floatingCard.window?.orderOut(nil)
            }
            return
        }

        var floatingCard = self.floatingCard
        if let index {
            if index == 1 {
                floatingCard = self.floatingCard2
            } else if index == 2 {
                floatingCard = self.floatingCard3
            }
        }

        if let bgs = userInfo?["battlegrounds"] as? Bool, bgs {
            floatingCard.isBattlegrounds = true
        } else {
            floatingCard.isBattlegrounds = false
        }
        closeRequestTimer?.invalidate()
        closeRequestTimer = nil

        floatingCard.set(card: card, subtitle: subtitle, showsImage: showsImage)

        if let fWindow = floatingCard.window {
            if !useFrame {
                fWindow.setFrameOrigin(NSPoint(x: arrayFrame[0],
                                               y: arrayFrame[1] - fWindow.frame.size.height/2))
            }

            fWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.mainMenuWindow)) - 1)

            if Settings.canJoinFullscreen {
                fWindow.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.fullScreenAuxiliary]
            } else {
                fWindow.collectionBehavior = []
            }

            // Assigned only when it differs: this runs for every row the cursor crosses, and
            // a style mask assignment can have AppKit rebuild the window's frame view.
            let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
            if fWindow.styleMask != styleMask {
                fWindow.styleMask = styleMask
            }
            fWindow.ignoresMouseEvents = true
            fWindow.animationBehavior = .none

            if useFrame {
                // The caller's frame fits the image alone; a subtitle hangs below it, or takes the
                // middle of that frame when there is no image
                let extra = floatingCard.subtitleHeight(width: arrayFrame[2])
                let frame = floatingCard.showsImage
                    ? NSRect(x: arrayFrame[0], y: arrayFrame[1] - extra, width: arrayFrame[2], height: arrayFrame[3] + extra)
                    : NSRect(x: arrayFrame[0], y: arrayFrame[1] + (arrayFrame[3] - extra) / 2, width: arrayFrame[2], height: extra)
                fWindow.setFrame(frame, display: true, animate: false)
                floatingCard.updateSubtitleLayout()
            }

            fWindow.orderFront(nil)
        }

        var disableTimeout = false
        if let dt = userInfo?["disableTimeout"] as? Bool, dt {
            disableTimeout = true
        }
        if !disableTimeout {
            scheduleCloseRequestTimer()
        }
    }

    private func scheduleCloseRequestTimer() {
        closeRequestTimer?.invalidate()
        closeRequestTimer = Timer.scheduledTimer(
            timeInterval: WindowManager.floatingCardTimeout,
            target: self,
            selector: #selector(self.closeRequestTimerFired),
            userInfo: nil,
            repeats: false)
    }

    @objc private func closeRequestTimerFired() {
        closeRequestTimer = nil
        // HDT keeps a card's tooltip up for as long as the row is hovered. Now that the popup
        // opens the moment the cursor lands, having it vanish under a cursor that never moved
        // reads as a glitch, so a row that still has the mouse gets another round instead.
        if let source = floatingCardSource,
           WindowManager.isHoverSource(source, stillUnder: NSEvent.mouseLocation) {
            scheduleCloseRequestTimer()
            return
        }
        forceHideFloatingCard()
    }

    /// Whether `view` is still on screen with the cursor, given in screen coordinates, inside it.
    /// A CardBar also has to agree it is hovered, which its tracking area keeps up to date.
    static func isHoverSource(_ view: NSView, stillUnder mouseLocation: NSPoint) -> Bool {
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else {
            return false
        }
        if let bar = view as? CardBar, !bar.isHovered {
            return false
        }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return rect.contains(mouseLocation)
    }

    /// Whether a hide coming from `source` should be ignored because the popup now belongs to a
    /// different view. AppKit does not promise to deliver the old row's mouseExited before the
    /// new row's mouseEntered, and the popup is now put up synchronously, so without this a late
    /// exit from the row just left could take down the card of the row just entered.
    func isFloatingCardOwned(byOtherThan source: NSView?) -> Bool {
        guard let source, let current = floatingCardSource else { return false }
        return source !== current
    }

    func hideFloatingCard(_ notification: Notification) {
        guard !isFloatingCardOwned(byOtherThan: notification.userInfo?["source"] as? NSView) else { return }
        // A subtitle-only card shows with previews off too
        guard Settings.showFloatingCard || (floatingCard.isWindowLoaded && floatingCard.window?.isVisible == true) else { return }
        
        // hide popup
        guard let card = notification.userInfo?["card"] as? Card
            else {
                return
        }

        if card.id == floatingCard.card?.id {
            forceHideFloatingCard()
        }
    }
    
    @objc func forceHideFloatingCard() {
        performOnMainThread { [weak self] in
            guard let self else {
                return
            }
            self.floatingCard.window?.orderOut(self)
            self.floatingCard2.window?.orderOut(self)
            self.floatingCard3.window?.orderOut(self)
            self.closeRequestTimer?.invalidate()
            self.closeRequestTimer = nil
            self.floatingCardSource = nil
            if #available(macOS 10.15, *) {
                self.tooltipGridCards.hide()
            }
        }
    }

    // MARK: - Utility functions
    @MainActor
    func show(controller: OverWindowController, show: Bool,
              frame: NSRect? = nil, title: String? = nil, overlay: Bool = true) {
        // Unit tests drive a bare Game inside the inert test host, where there is no
        // CoreManager behind AppDelegate.instance() for the overlay views to read, and
        // nothing should appear on screen anyway. Never load or order in a window there.
        if AppDelegate.isRunningUnitTests {
            return
        }
        // `controller.window` loads the nib on first access, so the hop has to
        // happen before it is touched, not after.
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.show(controller: controller, show: show, frame: frame, title: title, overlay: overlay)
            }
            return
        }

        guard let window = controller.window else { return }
        
        if show {
            // add the window in the "windows menu"
            if let title = title {
                NSApp.addWindowsItem(window,
                                     title: String.localizedString(title, comment: ""),
                                     filename: false)
                window.title = String.localizedString(title, comment: "")
            }

            // update gui elements
            controller.updateFrames()
            
            // show window and set size
            if let frame = frame {
                if frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width.isFinite && frame.size.height.isFinite {
                    window.setFrame(frame, display: true, animate: false)
                }
            }

            // Place overlays just above Hearthstone (normal level) but below
            // any system UI level so macOS Notification Center, menu bar, and
            // status items can render above them.
            let level: Int
            if overlay {
                level = Int(CGWindowLevelForKey(CGWindowLevelKey.normalWindow)) + 1
            } else {
                level = Int(CGWindowLevelForKey(CGWindowLevelKey.normalWindow))
            }
            window.level = NSWindow.Level(rawValue: level)

            // if the setting is on, set the window behavior to join all workspaces
            if Settings.canJoinFullscreen {
                window.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.fullScreenAuxiliary]
            } else {
                window.collectionBehavior = []
            }

            let locked = Settings.windowsLocked || controller.alwaysLocked
            if locked {
                window.styleMask = [.borderless, .nonactivatingPanel]
            } else {
                window.styleMask = [.titled, .miniaturizable,
                                    .resizable, .borderless,
                                    .nonactivatingPanel]
            }

            window.orderFront(nil)
        } else {
            if title != nil {
                NSApp.removeWindowsItem(window)
            }
            window.orderOut(nil)
        }
    }
}

