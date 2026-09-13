/*
* This file is part of the HSTracker package.
* (c) Benjamin Michotte <bmichotte@gmail.com>
*
* For the full copyright and license information, please view the LICENSE
* file that was distributed with this source code.
*
* Created on 15/02/16.
*/

import Cocoa
import RealmSwift

class Tracker: OverWindowController, CardCellHover {

    // UI elements
    @IBOutlet private var cardsView: AnimatedCardList!
    @IBOutlet private var cardCounter: CardCounter!
    @IBOutlet private var playerDrawChance: PlayerDrawChance!
    @IBOutlet private var opponentDrawChance: OpponentDrawChance!
    @IBOutlet private var playerClass: NSView!
    @IBOutlet private var recordTracker: StringTracker!
    @IBOutlet private var graveyardCounter: GraveyardCounter!
    @IBOutlet private var playerBottom: DeckLens!
    @IBOutlet private var playerTop: DeckLens!
    @IBOutlet private var playerSideboards: DeckSideboards!
    @IBOutlet private var opponentRelatedCards: DeckLens!

    private var hero: CardBar?
    private var heroCard: Card?
    
    var bottomY = CGFloat(0.0)

    var hasValidFrame = false
    
    var playerType: PlayerType?
    var showGraveyard: Bool = false
    var proxy: Entity?
    var graveyard: [Entity]?
    
    var playerClassId: String?
    var playerName: String?
    var currentGameMode: GameMode = .none
    var currentFormat: Format = .unknown
    var matchInfo: MatchInfo?
    var recordTrackerMessage: String = ""
    /// "VS <class>: W-L (x%)" under the W-L line; empty hides it.
    var matchupTrackerMessage: String = ""
    /// Built in code rather than in Tracker.xib: it is the same frame as the W-L
    /// line, only with its own text and setting.
    private let matchupTracker: StringTracker = {
        let tracker = StringTracker()
        tracker.shrinksToFit = true
        tracker.isHidden = true
        return tracker
    }()
    var observer: NSObjectProtocol?
    
    private func getTrackingArea() -> NSTrackingArea {
        let frame = window?.frame ?? NSRect.zero
        return NSTrackingArea(rect: NSRect(x: frame.minX, y: bottomY, width: frame.width, height: frame.maxY - bottomY),
                              options: [.activeAlways, .mouseEnteredAndExited],
                              owner: self,
                              userInfo: nil)
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        self.observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: Settings.tracker_opacity), object: nil, queue: OperationQueue.main) { _ in
            self.setOpacity()
        }
        if let playerType = playerType {
            graveyardCounter.playerType = playerType
            cardsView.playerType = playerType
            playerBottom.setPlayerType(playerType: playerType)
            playerTop.setPlayerType(playerType: playerType)
            playerSideboards.setPlayerType(playerType: playerType)
            opponentRelatedCards.setPlayerType(playerType: playerType)
        }
        window?.contentView?.addSubview(matchupTracker)
        cardsView.delegate = self
        playerBottom.setDelegate(delegate: self)
        playerTop.setDelegate(delegate: self)
        playerTop.setLabel(label: String.localizedString("On Top", comment: ""))
        playerBottom.setLabel(label: String.localizedString("On Bottom", comment: ""))
        playerSideboards.setDelegate(delegate: self)
        opponentRelatedCards.setDelegate(delegate: self)
        opponentRelatedCards.setLabel(label: String.localizedString("Related_Cards", comment: ""))
        setOpacity()
        
        if playerType == .opponent {
            window?.contentView?.addTrackingArea(getTrackingArea())
        }
    }
    
    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        if window?.mouseLocationOutsideOfEventStream.y ?? 0 >= bottomY {
            AppDelegate.instance().coreManager.game.windowManager.linkOpponentDeckPanel.showByOpponentStack()
        }
    }

    override func mouseExited(with event: NSEvent) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
            AppDelegate.instance().coreManager.game.windowManager.linkOpponentDeckPanel.hideByOpponentStack()
        })
    }

    func isLoaded() -> Bool {
        return self.isWindowLoaded
    }

    // MARK: - Notifications

    func setOpacity() {
        let alpha = CGFloat(Settings.trackerOpacity / 100.0)
        self.window!.backgroundColor = NSColor(red: 0,
                                               green: 0,
                                               blue: 0,
                                               alpha: alpha)
    }

    // MARK: - Game
    func update(cards: [Card], top: [Card], bottom: [Card], sideboards: [Sideboard], relatedCards: [Card], reset: Bool = false) {
        preloadHoverArt(rows: cards + top + bottom + sideboards.flatMap { $0.cards } + relatedCards, reset: reset)
        cardsView.update(cards: cards, reset: reset)
        playerBottom.update(cards: bottom, reset: reset)
        playerTop.update(cards: top, reset: reset)
        playerSideboards.update(sideboards: sideboards, reset: reset)
        opponentRelatedCards.update(cards: relatedCards, reset: reset)
    }
    
    // The related cards pools last read in, and what they were worked out for
    private var relatedPoolKey: String?
    private var relatedPoolCardIds = [String]()

    // Every row can be hovered the moment it is listed, so what its hover shows is read in ahead
    // of time: the row's own render, and the renders in its related cards grid. A first hover
    // that had to load them showed an empty popup, and a grid of placeholders, until they arrived.
    private func preloadHoverArt(rows: [Card], reset: Bool) {
        let rowIds = rows.map { $0.id }
        var cardIds = Settings.showFloatingCard ? rowIds : []
        cardIds.append(contentsOf: relatedPoolCardIds(rowIds: rowIds, reset: reset))
        ImageUtils.preloadCardArt(cardIds: cardIds, for: self)
    }

    // The cards each listed row's related cards grid would show, as setRelatedCardsTooltip works
    // them out. Working out a pool can mean filtering the whole card database, so it is done again
    // only when the listed cards, the player's class or the game mode change rather than on every
    // refresh; a pool that shifts with the board in between still loads on the hover itself.
    private func relatedPoolCardIds(rowIds: [String], reset: Bool) -> [String] {
        guard #available(macOS 10.15, *), let playerType, let game = AppDelegate.instance().coreManager?.game else {
            return []
        }
        let isPlayer = playerType == .player
        guard isPlayer ? Settings.showPlayerRelatedCards : Settings.showOpponentRelatedCards else {
            relatedPoolKey = nil
            relatedPoolCardIds = []
            return []
        }
        let player: Player = isPlayer ? game.player : game.opponent
        let uniqueIds = Array(Set(rowIds)).sorted()
        // currentFormat rather than currentFormatType: the latter asks the game's memory for the
        // format while it is still unknown, which is not worth doing twice a second for a key
        let key = "\(game.currentGameType.rawValue)|\(game.currentFormat)|"
            + "\(player.currentClass?.rawValue ?? "")|\(Settings.outfinderEnabled)|\(Settings.outfinderInDeck)|"
            + uniqueIds.joined(separator: ",")
        guard reset || key != relatedPoolKey else { return relatedPoolCardIds }

        var poolIds = [String]()
        for cardId in uniqueIds {
            guard !game.relatedCardsManager.isOutfinderSuppressed(cardId: cardId, surfaceEnabled: Settings.outfinderInDeck) else {
                continue
            }
            let pool = game.getRelatedCards(player: player, cardId: cardId).compactMap { $0 }
            // A larger pool of a discover card is not drawn as a grid at all (its summary and the
            // right-click browser take the grid's place), and any larger pool is more renders than
            // are worth holding in memory for one row
            guard pool.count <= RelatedCardsManager.largePoolThreshold else { continue }
            poolIds.append(contentsOf: pool.map { $0.id })
        }
        relatedPoolKey = key
        relatedPoolCardIds = poolIds
        return poolIds
    }

    override func updateFrames() {
        super.updateFrames()
        guard let windowFrame = self.window?.contentView?.frame else { return }
        
        let windowWidth = windowFrame.width
        let windowHeight = windowFrame.height
        
        let ratio: CGFloat
        switch Settings.cardSize {
        case .tiny: ratio = CGFloat(kRowHeight / kTinyRowHeight)
        case .small: ratio = CGFloat(kRowHeight / kSmallRowHeight)
        case .medium: ratio = CGFloat(kRowHeight / kMediumRowHeight)
        case .huge: ratio = CGFloat(kRowHeight / kHighRowHeight)
        case .big: ratio = 1.0
        }
        
        if playerType == .opponent {
            cardCounter.isHidden = !Settings.showOpponentCardCount
            opponentDrawChance.isHidden = !Settings.showOpponentDrawChance
            playerDrawChance.isHidden = true
            playerClass.isHidden = !Settings.showOpponentClassInTracker
            recordTracker.isHidden = true
            matchupTracker.isHidden = true
        } else {
            cardCounter.isHidden = !Settings.showPlayerCardCount
            opponentDrawChance.isHidden = true
            playerDrawChance.isHidden = !Settings.showPlayerDrawChance
            playerClass.isHidden = !Settings.showDeckNameInTracker
            // Empty without a saved deck; HDT hides its W-L label then too.
            recordTracker.isHidden = !Settings.showWinLossRatio || recordTrackerMessage.isEmpty
            matchupTracker.isHidden = !Settings.showMatchupWinRate || matchupTrackerMessage.isEmpty
        }
        
        graveyardCounter.isHidden = !showGraveyard
        
        if !recordTracker.isHidden {
            recordTracker.needsDisplay = true
        }
        
        recordTracker.message = recordTrackerMessage

        matchupTracker.message = matchupTrackerMessage
        if !matchupTracker.isHidden {
            matchupTracker.needsDisplay = true
        }
                
        // map entitiy to card [count]
        var minionmap: [Card: Int] = [:]
        var minions: Int = 0
        var murlocks: Int = 0
        if let graveyard = self.graveyard {
            for e: Entity in graveyard where e.isMinion {
                if let value = minionmap[e.card] {
                    minionmap[e.card] = value + 1
                } else {
                    minionmap[e.card] = 1
                }
                minions += 1
                if e.card.race == .murloc {
                    murlocks += 1
                }
            }
        }
        var graveyardminions: [Card] = []
        for (card, count) in minionmap {
            card.count = count
            graveyardminions.append(card)
        }
        graveyardCounter.graveyard = graveyardminions.sortCardList()
        graveyardCounter.minions = minions
        graveyardCounter.murlocks = murlocks
        
        let bigFrameHeight = round(71 / ratio)
        let smallFrameHeight = round(40 / ratio)
        
        var offsetFrames: CGFloat = 0
        var startHeight: CGFloat = 0
        
        if !playerClass.isHidden && playerType == .opponent {
            if let playerClassId = self.playerClassId {
                offsetFrames += smallFrameHeight
                
                playerClass.frame = NSRect(x: 0,
                                           y: windowHeight - smallFrameHeight,
                                           width: windowHeight,
                                           height: smallFrameHeight)
                startHeight += smallFrameHeight
                
                if hero == nil {
                    hero = CardBar.factory()
                    if let hero = hero {
                        playerClass.addSubview(hero)
                    }
                }
                
                hero?.playerType = .hero
                hero?.card = Cards.hero(byId: playerClassId)
                hero?.card?.count = 1
                hero?.card?.cost = -1
                hero?.playerName = playerName
                hero?.frame = NSRect(x: 0, y: 0,
                                     width: windowWidth,
                                     height: smallFrameHeight)
                hero?.update(highlight: false)
                hero?.needsDisplay = true
            }
        } else if !playerClass.isHidden && playerType == .player {
            
            offsetFrames += smallFrameHeight
            
            playerClass.frame = NSRect(x: 0,
                                       y: windowHeight - smallFrameHeight,
                                       width: windowHeight,
                                       height: smallFrameHeight)
            startHeight += smallFrameHeight
            if hero == nil {
                
                hero = CardBar.factory()
                if let hero = hero {
                    playerClass.addSubview(hero)
                }
            }
            hero?.playerType = .hero
            hero?.card = Cards.hero(byId: self.playerClassId ?? "")

            hero?.card?.count = 1
            hero?.playerName = playerName
            
            hero?.frame = NSRect(x: 0, y: 0,
                                 width: windowWidth,
                                 height: smallFrameHeight)
            hero?.update(highlight: false)
            hero?.needsDisplay = true
            
        }
        
        if !opponentDrawChance.isHidden {
            offsetFrames += bigFrameHeight
        }
        if !playerDrawChance.isHidden {
            offsetFrames += smallFrameHeight
        }
        if !cardCounter.isHidden {
            offsetFrames += smallFrameHeight
        }
        if showGraveyard {
            offsetFrames += smallFrameHeight
        }
        if !recordTracker.isHidden {
            offsetFrames += smallFrameHeight
        }
        if !matchupTracker.isHidden {
            offsetFrames += smallFrameHeight
        }

        var totalCards = cardsView.count

        if playerBottom.count > 0 && Settings.showPlayerCardsBottom {
            offsetFrames += smallFrameHeight
            totalCards += playerBottom.count
        }
        if playerTop.count > 0 && Settings.showPlayerCardsTop {
            offsetFrames += smallFrameHeight
            totalCards += playerTop.count
        }
        if playerSideboards.count > 0 && !Settings.hidePlayerSideboards {
            offsetFrames += smallFrameHeight
            totalCards += playerSideboards.count
        }
        if opponentRelatedCards.count > 0 && Settings.showOpponentRelatedCards {
            offsetFrames += smallFrameHeight
            totalCards += opponentRelatedCards.count
        }

        var cardHeight: CGFloat
        switch Settings.cardSize {
        case .tiny: cardHeight = CGFloat(kTinyRowHeight)
        case .small: cardHeight = CGFloat(kSmallRowHeight)
        case .medium: cardHeight = CGFloat(kMediumRowHeight)
        case .huge: cardHeight = CGFloat(kHighRowHeight)
        case .big: cardHeight = CGFloat(kRowHeight)
        }
        if totalCards > 0 {
            cardHeight = min(cardHeight, (windowHeight - offsetFrames) / CGFloat(totalCards))
        }
        
        let cardViewHeight = CGFloat(cardsView.count) * cardHeight
        var y: CGFloat = windowHeight - startHeight

        if playerTop.count > 0 && Settings.showPlayerCardsTop {
            let playerTopHeight = CGFloat(playerTop.count) * cardHeight + smallFrameHeight + 5
            y -= playerTopHeight
            playerTop.frame = NSRect(x: 0, y: y, width: windowWidth, height: playerTopHeight)
            playerTop.updateFrames(frameHeight: smallFrameHeight)
            playerTop.isHidden = false
        } else {
            playerTop.frame = NSRect.zero
            playerTop.updateFrames(frameHeight: smallFrameHeight)
            playerTop.isHidden = true
        }

        y -= cardViewHeight
        cardsView.cardHeight = cardHeight
        cardsView.frame = NSRect(x: 0,
                                 y: y,
                                 width: windowWidth,
                                 height: cardViewHeight)
        cardsView.updateFrames()
                
        if playerBottom.count > 0 && Settings.showPlayerCardsBottom {
            let playerBottomHeight = CGFloat(playerBottom.count) * cardHeight + smallFrameHeight + 5
            y -= playerBottomHeight
            playerBottom.frame = NSRect(x: 0, y: y, width: windowWidth, height: playerBottomHeight)
            playerBottom.updateFrames(frameHeight: smallFrameHeight)
            playerBottom.isHidden = false
        } else {
            playerBottom.frame = NSRect.zero
            playerBottom.updateFrames(frameHeight: smallFrameHeight)
            playerBottom.isHidden = true
        }
        if playerSideboards.count > 0 && !Settings.hidePlayerSideboards {
            let playerSideboardsHeight = CGFloat(playerSideboards.count) * cardHeight + smallFrameHeight * CGFloat(playerSideboards.sideboardCount)
            y -= playerSideboardsHeight
            playerSideboards.frame = NSRect(x: 0, y: y, width: windowWidth, height: playerSideboardsHeight)
            playerSideboards.cards.cardHeight = cardHeight
            playerSideboards.updateFrames(frameHeight: smallFrameHeight, cardHeight: cardHeight)
        } else {
            playerSideboards.frame = NSRect.zero
            playerSideboards.updateFrames(frameHeight: smallFrameHeight, cardHeight: cardHeight)
            playerSideboards.isHidden = true
        }
        if !cardCounter.isHidden {
            y -= smallFrameHeight
            cardCounter.frame = NSRect(x: 0, y: y, width: windowWidth, height: smallFrameHeight)
        }
        if !opponentDrawChance.isHidden {
            y -= bigFrameHeight
            opponentDrawChance.frame = NSRect(x: 0,
                                              y: y,
                                              width: windowWidth,
                                              height: bigFrameHeight)
        }
        if !playerDrawChance.isHidden {
            y -= smallFrameHeight
            playerDrawChance.frame = NSRect(x: 0,
                                            y: y,
                                            width: windowWidth,
                                            height: smallFrameHeight)
        }
        if opponentRelatedCards.count > 0 && Settings.showOpponentRelatedCards {
            let opponentRelatedCardsHeight = CGFloat(opponentRelatedCards.count) * cardHeight + smallFrameHeight + 5
            y -= opponentRelatedCardsHeight
            opponentRelatedCards.frame = NSRect(x: 0, y: y, width: windowWidth, height: opponentRelatedCardsHeight)
            opponentRelatedCards.updateFrames(frameHeight: smallFrameHeight)
            opponentRelatedCards.isHidden = false
        } else {
            opponentRelatedCards.frame = NSRect.zero
            opponentRelatedCards.updateFrames(frameHeight: smallFrameHeight)
            opponentRelatedCards.isHidden = true
        }
        if !graveyardCounter.isHidden {
            y -= smallFrameHeight
            graveyardCounter?.frame = NSRect(x: 0,
                                             y: y,
                                             width: windowWidth,
                                             height: smallFrameHeight)
            if playerType == .opponent {
                graveyardCounter?.displayDetails = Settings.showOpponentGraveyardDetails
            } else {
                graveyardCounter?.displayDetails = Settings.showPlayerGraveyardDetails
            }
            graveyardCounter?.cardHeight = cardHeight
            graveyardCounter?.needsDisplay = true
        }
        if !recordTracker.isHidden {
            y -= smallFrameHeight
            recordTracker.frame = NSRect(x: 0,
                                         y: y,
                                         width: windowWidth,
                                         height: smallFrameHeight)
        }
        if !matchupTracker.isHidden {
            y -= smallFrameHeight
            matchupTracker.frame = NSRect(x: 0,
                                          y: y,
                                          width: windowWidth,
                                          height: smallFrameHeight)
        }
        
        bottomY = y
        if playerType == .opponent, let cv = window?.contentView {
            for ta in cv.trackingAreas {
                cv.removeTrackingArea(ta)
            }
            cv.addTrackingArea(getTrackingArea())
        }
    }

    func updateCardCounter(deckCount: Int, handCount: Int, hasCoin: Bool, gameStarted: Bool) {
        
        cardCounter?.deckCount = deckCount
        cardCounter?.handCount = handCount
        cardCounter?.needsDisplay = true
        
        if playerType == .opponent {
            var draw1 = 0.0, draw2 = 0.0, hand1 = 0.0, hand2 = 0.0
            if deckCount > 0 {
                draw1 = (1 * 100.0) / Double(deckCount)
                draw2 = (2 * 100.0) / Double(deckCount)
            }
            if gameStarted {
                // opponent's chances of having a particular card (of which they have either one
                // or two in the deck) after the next draw, i.e. at the start of their next turn
                if deckCount <= 1 {
                    // opponent will have drawn all his cards
                    hand1 = 100
                    hand2 = 100
                } else {
                    let maxDeckSize = max(30, deckCount)

                    // Deck size after the opponent draws
                    let nextDeckSize = deckCount - 1

                    // probability a given card has been drawn if there is one copy in the deck
                    hand1 = Double(maxDeckSize - nextDeckSize) / Double(maxDeckSize)

                    // probability a given card has been drawn if there are two copies in the deck
                    let prob2 = Double((maxDeckSize - 1) - nextDeckSize) / Double(maxDeckSize - 1)
                    hand2 = 2 * hand1 - (hand1 * prob2)

                    hand1 *= 100
                    hand2 *= 100
                }
            }
            opponentDrawChance?.drawChance1 = draw1
            opponentDrawChance?.drawChance2 = draw2
            opponentDrawChance?.handChance1 = hand1
            opponentDrawChance?.handChance2 = hand2
            opponentDrawChance?.needsDisplay = true
        } else {
            var draw1 = 0.0, draw2 = 0.0
            if deckCount > 0 {
                draw1 = (1 * 100.0) / Double(deckCount)
                draw2 = (2 * 100.0) / Double(deckCount)
            }

            playerDrawChance?.drawChance1 = draw1
            playerDrawChance?.drawChance2 = draw2
            playerDrawChance?.needsDisplay = true
        }
    }
    
    // MARK: - CardCellHover
    enum HoveredComponent {
        case playerTop,
             playerBottom,
             playerSideboards,
             playerCardView,
             opponentRelatedCards,
             opponentCardView,
             other
    }
    
    private func getHoverComponent(_ cell: CardBar) -> HoveredComponent {
        var view: NSView? = cell
        while view != nil {
            if view == playerTop {
                return .playerTop
            } else if view == playerBottom {
                return .playerBottom
            } else if view == playerSideboards {
                return .playerSideboards
            } else if view == opponentRelatedCards {
                return .opponentRelatedCards
            } else if view == cardsView {
                if playerType == .player {
                    return .playerCardView
                } else {
                    return .opponentCardView
                }
            }
            view = view?.superview
        }
        return .other
    }
    
    func setRelatedCardsTooltip(_ player: Player, _ cardId: String, _ rect: NSRect) {
        guard #available(macOS 10.15, *) else { return }
        let game = AppDelegate.instance().coreManager.game
        let relatedCards = game.getRelatedCards(player: player, cardId: cardId)

        let hearthstoneRect = SizeHelper.hearthstoneWindow.frame
        let tooltipGridCards = game.windowManager.tooltipGridCards
        // The deck-list hover is HDT's Card.UpdateTooltip path, gated on OutfinderInDeck: an
        // Outfinder pool card shows nothing at all when the Outfinder is off for the deck, while a
        // card carrying only a plain related-cards list still shows its grid.
        if relatedCards.count > 0 &&
            !game.relatedCardsManager.isOutfinderSuppressed(cardId: cardId, surfaceEnabled: Settings.outfinderInDeck) {
            let nonNullableRelatedCards = relatedCards.compactMap { $0 }

            tooltipGridCards.setCardIdsFromCards(nonNullableRelatedCards)
            tooltipGridCards.setTitle(String.localizedString("Related_Cards", comment: ""))
            // Passing player (like Game.swift's hover paths already do) so dynamic
            // evolve/devolve pools resolve their live-state summary here too, instead of
            // silently falling through to no summary on a deck-list hover.
            let (statistics, summary, hasLargePool) = game.relatedCardsManager.getPoolStatistics(cardId: cardId, relatedCards: relatedCards, player: player)
            tooltipGridCards.setPoolStatistics(statistics, relatedCardsSummary: summary, hasLargePool: hasLargePool)
            let screen = NSScreen.screens.first { s in s.frame.contains(rect) } ?? NSScreen.main
            var y = rect.minY
            if rect.minY + CGFloat(tooltipGridCards.gridHeight) > screen?.frame.height ?? hearthstoneRect.height {
                y = hearthstoneRect.maxY - CGFloat(tooltipGridCards.gridHeight)
            }

            var x: CGFloat = 0.0
            if rect.minX < hearthstoneRect.width / 2 {
                x = rect.maxX
            } else {
                x = rect.minX - CGFloat(tooltipGridCards.gridWidth)
            }

            let tooltipFrame = NSRect(x: x, y: y, width: CGFloat(tooltipGridCards.gridWidth), height: CGFloat(tooltipGridCards.gridHeight))
            tooltipGridCards.show(frame: tooltipFrame)
            RelatedCardsRightClickMonitor.shared.setHoveredLargePool(
                card: hasLargePool ? Cards.by(cardId: cardId) : nil,
                pool: hasLargePool ? nonNullableRelatedCards : [],
                anchorFrame: tooltipFrame)
        } else {
            tooltipGridCards.hide()
            RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
        }
    }
    
    func highlightPlayerDeckCards(highlightSourceCardId: String?) {
        guard let highlightSourceCardId, !highlightSourceCardId.isEmpty, Settings.showPlayerHighlightSynergies else {
            cardsView?.shouldHighlightCard = nil
            return
        }
        
        let game = AppDelegate.instance().coreManager.game
        let highlightSourceCard = game.relatedCardsManager.getCardWithHighlight(highlightSourceCardId)
        cardsView?.shouldHighlightCard = highlightSourceCard?.shouldHighlight
    }
        
    func hover(cell: CardBar, card: Card) {
        if playerType == .player {
            highlightPlayerDeckCards(highlightSourceCardId: card.id)
        }
        // Shown straight away. It used to wait 0.4 s first, which made the deck list feel slow to
        // read; the popup and the related cards grid now come up on the mouseEntered itself.
        showTooltip(cell: cell, card: card)
    }

    private func showTooltip(cell: CardBar, card: Card) {
        if let window {
            let windowRect = window.frame
            
            let hoverFrame = NSRect(x: 0, y: 0, width: 256, height: 388)
            
            var x: CGFloat
            // decide if the popup window should on the left or right side of the tracker
            if windowRect.origin.x < hoverFrame.size.width {
                x = windowRect.origin.x + windowRect.size.width
            } else {
                x = windowRect.origin.x - hoverFrame.size.width
            }
            
            let cellFrameRelativeToWindow = cell.convert(cell.bounds, to: nil)
            guard let cellFrameRelativeToScreen = cell.window?.convertToScreen(cellFrameRelativeToWindow) else {
                return
            }
            
            let y: CGFloat = cellFrameRelativeToScreen.origin.y - hoverFrame.height / 2.0
            
            let frame = [x, y, hoverFrame.width, hoverFrame.height]
            
            let userinfo = [
                "card": card,
                "frame": frame,
                "useFrame": true,
                "source": cell
            ] as [String: Any]
            
            NotificationCenter.default
                .post(name: Notification.Name(rawValue: Events.show_floating_card),
                      object: nil,
                      userInfo: userinfo)
            
            let hoverLocation = getHoverComponent(cell)
            switch hoverLocation {
            case .opponentRelatedCards, .opponentCardView:
                if Settings.showOpponentRelatedCards {
                    setRelatedCardsTooltip(AppDelegate.instance().coreManager.game.opponent, card.id, NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
                }
            case .playerTop, .playerBottom, .playerSideboards, .playerCardView:
                if Settings.showPlayerRelatedCards {
                    setRelatedCardsTooltip(AppDelegate.instance().coreManager.game.player, card.id, NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
                }
            default:
                break
            }
        }
    }

    func out(cell: CardBar, card: Card) {
        let windowManager = AppDelegate.instance().coreManager.game.windowManager
        // The row being entered already got here first and put up its own popup, grid and
        // highlight; this exit must not clear them.
        guard !windowManager.isFloatingCardOwned(byOtherThan: cell) else { return }
        if playerType == .player {
            highlightPlayerDeckCards(highlightSourceCardId: nil)
        }
        let userinfo = [
            "card": card,
            "source": cell
            ] as [String: Any]
        NotificationCenter.default.post(name: Notification.Name(rawValue: Events.hide_floating_card),
                                        object: nil,
                                        userInfo: userinfo)
        
        if #available(macOS 10.15, *) {
            windowManager.tooltipGridCards.hide()
        }
    }
}
