/*
* This file is part of the HSTracker package.
* (c) Benjamin Michotte <bmichotte@gmail.com>
*
* For the full copyright and license information, please view the LICENSE
* file that was distributed with this source code.
*
* Created on 13/02/16.
*/

import Foundation
import RealmSwift
import HearthMirror
import Mixpanel

struct Sideboard {
    let ownerCardId: String
    let cards: [Card]
}

struct PlayingDeck {
    let id: String
    let name: String
    let hsDeckId: Int64?
    let playerClass: CardClass
    let heroId: String
    let cards: [Card]
    let isArena: Bool
    let shortid: String
    let sideboards: [Sideboard]
}

/**
 * Game object represents the current state of the tracker
 */
class Game: NSObject, PowerEventHandler {
	/**
	 * View controller of this game object
	 */
    internal let windowManager = WindowManager()
	
    static let guiUpdateDelay: TimeInterval = 0.5
	
	private let turnTimer: TurnTimer
    
    private var _mulliganState: MulliganState?
    /// The local player's mulligan and draws for the game's MulliganRecord.
    let mulliganRecorder = MulliganRecorder()
    private var mulliganState: MulliganState {
        if let _mulliganState {
            return _mulliganState
        }
        let res = MulliganState(game: self)
        _mulliganState = res
        return res
    }
    
    private var battlegroundsTrinketPickStates = [BattlegroundsTrinketPickState]()
    
	private var hearthstoneRunState: HearthstoneRunState {
		didSet {
			if hearthstoneRunState.isRunning {
				// delay update as game might not have a proper window
				DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1), execute: { [weak self] in
					self?.updateTrackers()
                    self?.updateBattlegroundsOverlays()
                    self?.updateConstructedMulliganOverlays()
                    self?.updateActiveEffects()
                    if #available(macOS 10.15, *) {
                        self?.updateMaxResourcesWidget()
                        self?.updateRootOverlay()
                    }
                    self?.updateCounters()
				})
			} else {
				self.updateTrackers()
                self.updateBattlegroundsOverlays()
                self.updateConstructedMulliganOverlays()
                self.updateActiveEffects()
                if #available(macOS 10.15, *) {
                    self.updateMaxResourcesWidget()
                    self.updateRootOverlay()
                }
                self.updateCounters()
			}
		}
	}
    
    var isRunning: Bool {
        return hearthstoneRunState.isRunning
    }
    
    private var selfAppActive: Bool = true
    
    lazy var queueEvents: QueueEvents = QueueEvents(game: self)
    
    var _mulliganGuideParams: MulliganGuideParams?
    var _mulliganV2Params: MulliganV2Params?

    // Mulligan G-V2 (HDT GameV2.IsMulliganGV2Match) is Standard Ranked/Friendly
    // only. The format check had been left out, so Wild and Twist games took
    // the V2 path too - spending a V2 trial on a Wild game type instead of
    // getting HDT's V1 guide.
    var isV2Mulligan: Bool {
        Game.isV2MulliganMatch(gameType: currentGameType, formatType: currentFormatType)
    }

    static func isV2MulliganMatch(gameType: GameType, formatType: FormatType) -> Bool {
        (gameType == .gt_ranked || gameType == .gt_vs_friend) && formatType == .ft_standard
    }

    private var mulliganLivePollingActive = false

    // ~16ms poll of the live per-card mulligan selection state (HearthMirror),
    // matching HDT's MulliganStateWatcher cadence, feeding the gauge's live
    // confidence recalculation while the player is choosing what to keep.
    @available(macOS 10.15, *)
    func startMulliganLivePolling() {
        guard !mulliganLivePollingActive else { return }
        mulliganLivePollingActive = true
        pollMulliganLiveState()
    }

    @available(macOS 10.15, *)
    func stopMulliganLivePolling() {
        mulliganLivePollingActive = false
    }

    @available(macOS 10.15, *)
    private func pollMulliganLiveState() {
        guard mulliganLivePollingActive else { return }

        let liveState = MirrorHelper.getMulliganLiveState()
        DispatchQueue.main.async {
            self.windowManager.rootOverlay?.viewModel.mulliganGuideV2.updateLiveMulliganState(liveState)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            self?.pollMulliganLiveState()
        }
    }

    let activeEffects: ActiveEffects
    let counterManager: CounterManager
    let relatedCardsManager: RelatedCardsManager
    // Fed by PowerGameStateParser and TagChangeHandler on the log reader queue
    let actionHistory = ActionHistoryRecorder()
    var isBattlegroundsCombatPhase = false
    // Raw controller tag (not player/opponent side, which aren't resolved yet during CREATE_GAME) of
    // any side whose deck was half-copied from their enemy's (Azalina Soulsever).
    var controllersWithDeckCopiedFromEnemy = Set<Int>()
    var accountId: MirrorAccountId?
    var battlegroundsDetails: UploadMetaData.BattlegroundsLobbyDetails?
	
    func setHearthstoneRunning(flag: Bool) {
        hearthstoneRunState.isRunning = flag
    }
    
    func setHearthstoneActived(flag: Bool) {
        hearthstoneRunState.isActive = flag
        if currentMode == .bacon || isBattlegroundsMatch() {
            if flag, #available(macOS 10.15, *) {
                windowManager.rootOverlay?.viewModel.tier7PreLobby.onFocus()
            }
            updateBattlegroundsSessionVisibility()
        }
        if flag, #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.constructedMulliganPreLobbyWidget.onFocus()
        }
    }
	
	func setSelfActivated(flag: Bool) {
		self.selfAppActive = flag
        self.updateTrackers()
	}
    
    func getBattlegroundsBoardStateFor(id: Int) -> BoardSnapshot? {
        return _battlegroundsBoardState?.getSnapshot(entityId: id)
    }
    
    var gameId = ""
    
    var starshipLaunchBlockIds = SynchronizedArray<Int?>()
    
    var minionsInPlay = SynchronizedArray<String>()
    
    var minionsInPlayByPlayer = SynchronizedDictionary<Int, SynchronizedArray<String>>()
        
    //We do count+1 because the friendly hero is not in setaside
    func battlegroundsHeroCount() -> Int {
        return entities.values.filter { x in x.isHero && x.isInSetAside && (x.has(tag: .bacon_hero_can_be_drafted) || x.has(tag: .bacon_skin) || x.has(tag: .player_tech_level)) }.count + 1 }
    
    func snapshotBattlegroundsBoardState() {
        _battlegroundsBoardState?.snapshotCurrentBoard()
    }
    
    var battlegroundsBuddiesEnabled: Bool {
        return gameEntity?[.bacon_buddy_enabled] ?? 0 > 0
    }
    
    var battlegroundsLobbyInfo: MirrorBattlegroundsLobbyInfo?
	
	// MARK: - PowerEventHandler protocol
	
	func handleEntitiesChange(changed: [(old: Entity, new: Entity)]) {
	}
	
	func add(entity: Entity) {
		if entities[entity.id] == .none {
			entities[entity.id] = entity
		}
	}
	
	func determinedPlayers() -> Bool {
        return player.id > 0 && opponent.id > 0
	}
	
	private var guiNeedsUpdate = false
	private var boardDamageNeedsUpdate = false
	private var guiUpdateResets = false
	private let _queue = DispatchQueue(label: "net.hearthsim.hstracker.guiupdate", attributes: [])
	
    private func updateAllTrackers() {
		SizeHelper.hearthstoneWindow.reload()
		
		self.updatePlayerTracker(reset: guiUpdateResets)
		self.updateOpponentTracker(reset: guiUpdateResets)
        self.updateCardHud()
        self.updateTurnTimer()
        self.updateBoardStateTrackers()
        self.updateSecretTracker()
        self.updateBattlegroundsOverlay()
        self.updateBobsBuddyOverlay()
        self.updateTurnCounterOverlay()
        self.updateExperienceOverlay()
        self.updateMercenariesTaskListButton()
        self.updateBoardOverlay()
        self.updateConstructedMulliganOverlays()
        self.updateActiveEffects()
        if #available(macOS 10.15, *) {
            self.updateMaxResourcesWidget()
            self.updateRootOverlay()
        }
        self.updateCounters()
        self.updateActionHistory()
	}
	
    // MARK: - GUI calls
    var shouldShowGUIElement: Bool {
        return
            // do not show gui while spectating
            !(Settings.dontTrackWhileSpectating && self.spectator) &&
                // do not show gui while game is in background
                !((Settings.hideAllWhenGameInBackground || Settings.hideAllWhenGameInBackground) && !self.hearthstoneRunState.isActive)
    }
    
    var shouldShowTracker: Bool {
        return ((Settings.hideAllTrackersWhenNotInGame && !self.gameEnded) || (!Settings.hideAllTrackersWhenNotInGame) || self.selfAppActive ) && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground || self.selfAppActive)
    }
    
    func updateTrackers(reset: Bool = false) {
        _queue.async {
            self.guiNeedsUpdate = true
            self.guiUpdateResets = reset || self.guiUpdateResets
        }
    }
	
	@objc func updateOpponentTracker(reset: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
			
            let tracker = self.windowManager.opponentTracker
            if Settings.showOpponentTracker &&
                (!self.isBattlegroundsMatch() && !self.isMercenariesMatch() && self.currentGameType != .gt_unknown) &&
            !(Settings.dontTrackWhileSpectating && self.spectator) &&
                ((Settings.hideAllTrackersWhenNotInGame && !self.gameEnded)
                    || (!Settings.hideAllTrackersWhenNotInGame) || self.selfAppActive ) &&
                ((Settings.hideAllWhenGameInBackground &&
                    self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground || self.selfAppActive) {
                
                // update cards
                if self.gameEnded && Settings.clearTrackersOnGameEnd {
                    tracker.update(cards: [], top: [], bottom: [], sideboards: [], relatedCards: [], reset: reset)
                } else {
                    let cardWithRelatedCards = relatedCardsManager.getCardsOpponentMayHave(opponent, currentGameType, currentFormatType)
                    cardWithRelatedCards.forEach({
                        $0.count = 1
                    })
                    tracker.update(cards: self.opponent.opponentCardList, top: [], bottom: [], sideboards: [], relatedCards: cardWithRelatedCards, reset: reset)
                }
                
                let gameStarted = !self.isInMenu && self.entities.count >= 67
                tracker.updateCardCounter(deckCount: !gameStarted || !isMulliganDone() ? 30 - self.opponent.handCount : self.opponent.deckCount,
                                          handCount: !gameStarted ? 0 : self.opponent.handCount,
                                          hasCoin: self.opponent.hasCoin,
                                          gameStarted: gameStarted)

                tracker.showGraveyard = Settings.showOpponentGraveyard
                
                if let fullname = self.opponent.name {
                    let names = fullname.components(separatedBy: "#")
                    tracker.playerName = names[0]
                }
                
                tracker.graveyard = self.opponent.graveyard
                tracker.playerClassId = self.opponent.playerClassId
                
                tracker.currentFormat = self.currentFormat
                tracker.currentGameMode = self.currentGameMode
                tracker.matchInfo = self.matchInfo
                
                tracker.setWindowSizes()
                var rect: NSRect?
                
                if Settings.autoPositionTrackers && self.hearthstoneRunState.isRunning {
                    rect = SizeHelper.opponentTrackerFrame()
                } else {
                    rect = Settings.opponentTrackerFrame
                    if rect == nil {
                        let x = WindowManager.screenFrame.origin.x + 50
                        rect = NSRect(x: x,
                                      y: WindowManager.top + WindowManager.screenFrame.origin.y,
                                      width: WindowManager.cardWidth,
                                      height: WindowManager.top)
                    }
                }
                tracker.hasValidFrame = true
                self.windowManager.show(controller: tracker, show: true,
                                        frame: rect, title: "Opponent tracker",
                                        overlay: self.hearthstoneRunState.isActive)
                if self.windowManager.linkOpponentDeckPanel.isShowing {
                    self.windowManager.linkOpponentDeckPanel.show()
                }
            } else {
                self.windowManager.show(controller: tracker, show: false)
                self.windowManager.show(controller: self.windowManager.linkOpponentDeckPanel, show: false)
            }
		}
	}
    
    @objc func updatePlayerTracker(reset: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            let tracker = self.windowManager.playerTracker
            if Settings.showPlayerTracker &&
                !(Settings.dontTrackWhileSpectating && self.spectator) &&
                (!self.isBattlegroundsMatch() && !self.isMercenariesMatch() && self.currentGameType != .gt_unknown) &&
                ( (Settings.hideAllTrackersWhenNotInGame && !self.gameEnded)
                    || (!Settings.hideAllTrackersWhenNotInGame) || self.selfAppActive ) &&
                ((Settings.hideAllWhenGameInBackground &&
                    self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground || self.selfAppActive) {
                
                // update cards
                let dredged = player.deck.filter { x in x.info.deckIndex != 0 }.sorted(by: { x, y in x.info.deckIndex > y.info.deckIndex })
                let top = dredged.filter { x in x.info.deckIndex > 0 }.compactMap { (x) -> Card in
                    let card = x.card.copy()
                    card.deckListIndex = x.info.deckIndex
                    card.count = 1
                    return card
                }
                let bottom = dredged.filter { x in x.info.deckIndex < 0 }.compactMap { (x) -> Card in
                    let card = x.card.copy()
                    card.deckListIndex = x.info.deckIndex
                    card.count = 1
                    return card
                }

                tracker.update(cards: self.player.playerCardList, top: top, bottom: bottom, sideboards: self.player.playerSideboardsDict, relatedCards: [], reset: reset)
                
                // update card counter values
                let gameStarted = !self.isInMenu && self.entities.count >= 67
                tracker.updateCardCounter(deckCount: !gameStarted ? 30 : self.player.deckCount,
                                          handCount: !gameStarted ? 0 : self.player.handCount,
                                          hasCoin: self.player.hasCoin,
                                          gameStarted: gameStarted)
                
                tracker.showGraveyard = Settings.showPlayerGraveyard
                                
                if let currentDeck = self.currentDeck {
                    if let deck = RealmHelper.getDeck(with: currentDeck.id) {
                        tracker.recordTrackerMessage = StatsHelper
                            .getDeckManagerRecordLabel(deck: deck,
                                                       mode: .all)
                        // HDT's LblWinRateAgainst. The opponent's class stays set
                        // until the next game resets it, so the line is still there
                        // on the end screen, already counting the game just played
                        // (game_stats_changed refreshes this tracker after the main
                        // thread's Realm has been refreshed to include it). HDT only
                        // shows it on the in-game overlay, so it goes once the player
                        // is back in the menu, where it would otherwise pair a newly
                        // selected deck with the last game's opponent.
                        if Settings.showMatchupWinRate, !self.isInMenu,
                           let opponentClass = self.opponent.originalClass,
                           let record = StatsHelper.matchupTrackerRecord(deck: deck,
                                                                         opponentClass: opponentClass) {
                            tracker.matchupTrackerMessage = StatsHelper
                                .matchupTrackerLabel(opponentClass: opponentClass, record: record)
                        } else {
                            tracker.matchupTrackerMessage = ""
                        }
                    } else {
                        // An unsaved deck has no record; without this the line kept
                        // showing the previous deck's W-L.
                        tracker.recordTrackerMessage = ""
                        tracker.matchupTrackerMessage = ""
                    }
                    tracker.playerName = currentDeck.name
                    if !currentDeck.heroId.isEmpty {
                        tracker.playerClassId = currentDeck.heroId
                    } else {
                        tracker.playerClassId = currentDeck.playerClass.defaultHeroCardId
                    }
                } else {
                    tracker.recordTrackerMessage = ""
                    tracker.matchupTrackerMessage = ""
                    tracker.playerName = player.name
                    tracker.playerClassId = playerHeroId
                }
                
                tracker.graveyard = self.player.graveyard
                
                tracker.currentFormat = self.currentFormat 
                tracker.currentGameMode = self.currentGameMode
                tracker.matchInfo = self.matchInfo
                
                tracker.setWindowSizes()
                
                var rect: NSRect?
                
                if Settings.autoPositionTrackers && self.hearthstoneRunState.isRunning {
                    rect = SizeHelper.playerTrackerFrame()
                } else {
                    rect = Settings.playerTrackerFrame
                    if rect == nil {
                        let x = WindowManager.screenFrame.width - WindowManager.cardWidth
                            + WindowManager.screenFrame.origin.x
                        rect = NSRect(x: x,
                                      y: WindowManager.top + WindowManager.screenFrame.origin.y,
                                      width: WindowManager.cardWidth,
                                      height: WindowManager.top)
                    }
                }
                tracker.hasValidFrame = true
                self.windowManager.show(controller: tracker, show: true,
                                   frame: rect, title: "Player tracker",
                                   overlay: self.hearthstoneRunState.isActive)
            } else {
                self.windowManager.show(controller: tracker, show: false)
            }
        }
    }
    
    func updateTurnCounter(turn: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if #available(macOS 10.15, *) {
                self.windowManager.rootOverlay?.viewModel.battlegroundsTurnCounter
                    .update(turn: turn, isShown: self.isTurnCounterVisible)
            }
        }
    }

    // The counter lives in RootOverlay now, so it no longer needs the
    // hideAllWhenGameInBackground check the AppKit window carried -
    // updateRootOverlay already hides the whole overlay in that case.
    private var isTurnCounterVisible: Bool {
        isBattlegroundsMatch() && !gameEnded && Settings.showTurnCounter && !hideBattlegroundsTurn
    }

    func updateTurnTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if Settings.showTimer && !self.gameEnded && self.shouldShowGUIElement && !isBattlegroundsMatch() && !isMercenariesMatch() {
                var rect: NSRect?
                if Settings.autoPositionTrackers {
                    rect = SizeHelper.timerHudFrame()
                } else {
                    rect = Settings.timerHudFrame
                    if rect == nil {
                        rect = SizeHelper.timerHudFrame()
                    }
                }
                if let timerHud = self.turnTimer.timerHud {
                    timerHud.hasValidFrame = true
                    self.windowManager.show(controller: timerHud, show: true, frame: rect, title: nil, overlay: self.hearthstoneRunState.isActive)
                }
            } else {
                if let timerHud = self.turnTimer.timerHud {
                    self.windowManager.show(controller: timerHud, show: false)
                }
            }
            
        }
    }
    
    func updateSecretTracker(cards: [Card]) {
        self.windowManager.secretTracker.set(cards: cards)
        self.updateSecretTracker()
    }
    
    // Rebuilds the panel for settings that change what it lists or whether it shows at all
    func refreshSecretHelper() {
        updateSecretTracker(cards: secretsManager?.getSecretList() ?? [])
    }
    
    func updateSecretTracker() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            
            let tracker = self.windowManager.secretTracker
            // Where the helper ends on the Hearthstone window, top down, so the action history panel can stay clear of it
            var helperBottom: CGFloat = 0
            
            if Settings.showSecretHelper && !self.gameEnded &&
                ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
                    || !Settings.hideAllWhenGameInBackground) && !isBattlegroundsMatch() {
                if tracker.cardCount() > 0 {
                    tracker.setWindowSizes()
                    let rect = SizeHelper.secretTrackerFrame(height: tracker.frameHeight)
                    tracker.contentViewController?.preferredContentSize = rect.size
                    self.windowManager.show(controller: tracker, show: true,
                                            frame: rect,
                                            title: nil, overlay: self.hearthstoneRunState.isActive)
                    helperBottom = SizeHelper.hearthstoneWindow.frame.maxY - rect.minY
                } else {
                    self.windowManager.show(controller: tracker, show: false)
                }
            } else {
                self.windowManager.show(controller: tracker, show: false)
            }
            if #available(macOS 10.15, *), let actionHistory = self.windowManager.rootOverlay?.viewModel.actionHistory,
               actionHistory.secretHelperBottom != helperBottom {
                actionHistory.secretHelperBottom = helperBottom
            }
        }
    }
    
    func updateActiveEffects() {
        DispatchQueue.main.async { [self] in
            let hsActive = hearthstoneRunState.isActive

            if isInMenu || !isMulliganDone() || isBattlegroundsMatch() {
                windowManager.playerActiveEffectsOverlay.visibility = false
                windowManager.opponentActiveEffectsOverlay.visibility = false
            } else {
                windowManager.playerActiveEffectsOverlay.visibility = Settings.showPlayerActiveEffects
                windowManager.opponentActiveEffectsOverlay.visibility = Settings.showOpponentActiveEffects
            }
            
            if windowManager.playerActiveEffectsOverlay.visibility && windowManager.playerActiveEffectsOverlay.visibleEffects.count > 0 {
                if (Settings.hideAllWhenGameInBackground && hsActive) || !Settings.hideAllWhenGameInBackground {
                    windowManager.show(controller: windowManager.playerActiveEffectsOverlay, show: true, frame: SizeHelper.playerActiveEffectsFrame(), overlay: true)
                    windowManager.playerActiveEffectsOverlay.updateGrid()
                } else {
                    windowManager.show(controller: windowManager.playerActiveEffectsOverlay, show: false)
                }
            }

            if windowManager.opponentActiveEffectsOverlay.visibility && windowManager.opponentActiveEffectsOverlay.visibleEffects.count > 0 {
                if (Settings.hideAllWhenGameInBackground && hsActive) || !Settings.hideAllWhenGameInBackground {
                    windowManager.show(controller: windowManager.opponentActiveEffectsOverlay, show: true, frame: SizeHelper.opponentActiveEffectsFrame(), overlay: true)
                    windowManager.opponentActiveEffectsOverlay.updateGrid()
                } else {
                    windowManager.show(controller: windowManager.opponentActiveEffectsOverlay, show: false)
                }
            }

        }
    }
    
    // The counters live on the RootOverlay canvas, so there is no window of
    // their own left to frame, show or hide: a side with nothing to show
    // renders nothing, and hideAllWhenGameInBackground is already handled once
    // for the whole canvas in updateRootOverlay().
    func updateCounters() {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async { [self] in
                guard let viewModel = windowManager.rootOverlay?.viewModel else { return }

                if isInMenu || !isMulliganDone() || !shouldShowTracker {
                    viewModel.playerCounters.isShown = false
                    viewModel.opponentCounters.isShown = false
                } else {
                    viewModel.playerCounters.isShown = Settings.showPlayerCounters
                    viewModel.opponentCounters.isShown = Settings.showOpponentCounters
                }
            }
        }
    }

    // The action history panel is a RootOverlay child too. Battlegrounds and
    // Mercenaries have no history (the recorder skips them), and the panel stays
    // up on the end screen until the next game resets it.
    var shouldShowActionHistory: Bool {
        return Settings.showActionHistory && !isInMenu && isTraditionalHearthstoneMatch && shouldShowGUIElement && shouldShowTracker
    }

    func updateActionHistory() {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async { [self] in
                guard let viewModel = windowManager.rootOverlay?.viewModel else { return }
                viewModel.actionHistory.isShown = shouldShowActionHistory
            }
        }
    }

    // The player's counters are a RootOverlay child rather than a window of
    // their own, so refreshing them is a view-model call - wrapped here because
    // the callers are not themselves gated on the SwiftUI baseline.
    func updatePlayerCounters() {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.rootOverlay?.viewModel.playerCounters.updateVisibleCounters()
            }
        }
    }
    
    func updateConstructedMulliganOverlays() {
        DispatchQueue.main.async {
            let hsActive = self.hearthstoneRunState.isActive
            
            if self.windowManager.constructedMulliganGuide.viewModel.visibility {
                if (Settings.hideAllWhenGameInBackground && hsActive) || !Settings.hideAllWhenGameInBackground {
                    self.windowManager.show(controller: self.windowManager.constructedMulliganGuide, show: true, frame: SizeHelper.hearthstoneWindow.frame, overlay: true)
                    DispatchQueue.main.async {
                        self.windowManager.constructedMulliganGuide.updateScaling()
                    }
                } else {
                    self.windowManager.show(controller: self.windowManager.constructedMulliganGuide, show: false)
                }
            }

            if self.windowManager.constructedMulliganGuidePreLobby.isVisible {
                if ((Settings.hideAllWhenGameInBackground && hsActive) || !Settings.hideAllWhenGameInBackground) && Settings.showMulliganGuidePreLobby {
                    self.windowManager.show(controller: self.windowManager.constructedMulliganGuidePreLobby, show: true, frame: SizeHelper.constructedMulliganGuidePreLobbyFrame(), overlay: true)
                    DispatchQueue.main.async {
                        self.windowManager.constructedMulliganGuidePreLobby.updateScaling()
                    }
                } else {
                    self.windowManager.show(controller: self.windowManager.constructedMulliganGuidePreLobby, show: false)
                }
            } else {
                self.windowManager.show(controller: self.windowManager.constructedMulliganGuidePreLobby, show: false)
            }
        }
    }
    
    @available(macOS 10.15, *)
    func updateMaxResourcesWidget() {
        DispatchQueue.main.async { [self] in
            updatePlayerResorucesWidgetVisibility()
            let hsActive = hearthstoneRunState.isActive

            if let win =  windowManager.playerPlayerResourcesOverlay {
                if ((Settings.hideAllWhenGameInBackground && hsActive) || !Settings.hideAllWhenGameInBackground) && win.viewModel.visibility && shouldShowTracker {
                    windowManager.show(controller: win, show: true, frame: SizeHelper.playerMaxResourcesFrame(), overlay: true)
                } else {
                    windowManager.show(controller: win, show: false)
                }
            }
            if let win =  windowManager.opponentPlayerResourcesOverlay {
                if ((Settings.hideAllWhenGameInBackground && hsActive) || !Settings.hideAllWhenGameInBackground) && win.viewModel.visibility && shouldShowTracker {
                    windowManager.show(controller: win, show: true, frame: SizeHelper.opponentMaxResourcesFrame(), overlay: true)
                } else {
                    windowManager.show(controller: win, show: false)
                }
            }
        }
    }

    // Refreshes the single scaled SwiftUI overlay window new overlay features
    // (starting with Mulligan Guide V2) attach to as children.
    //
    // This window is kept shown continuously whenever Hearthstone is running,
    // the same way every other overlay (trackers, the V1 mulligan guide) is -
    // rather than being hidden and shown again specifically when mulligan
    // starts. Toggling it on the mulligan-start transition was consistently
    // invisible until an unrelated focus change forced the window server to
    // recomposite (orderFrontRegardless()/displayIfNeeded()/layout invalidation
    // didn't help), while windows that are already on screen continuously
    // before mulligan begins never hit that problem. Content is naturally
    // empty outside mulligan (ConstructedMulliganGuideV2View draws nothing
    // without an error or card stats), so there's nothing to see when idle -
    // this just avoids the hidden->visible transition that was glitching.
    private var rootOverlayLastFullscreenState: Bool?

    @available(macOS 10.15, *)
    func updateRootOverlay() {
        DispatchQueue.main.async { [self] in
            guard let win = windowManager.rootOverlay else { return }
            let hsActive = hearthstoneRunState.isActive

            if (Settings.hideAllWhenGameInBackground && hsActive) || !Settings.hideAllWhenGameInBackground {
                let frame = SizeHelper.overHearthstoneFrame()
                let isFullscreen = SizeHelper.hearthstoneWindow.isFullscreen()
                let fullscreenChanged = rootOverlayLastFullscreenState != nil && rootOverlayLastFullscreenState != isFullscreen
                rootOverlayLastFullscreenState = isFullscreen

                if fullscreenChanged {
                    // Entering/leaving fullscreen moves Hearthstone to a different
                    // macOS Space. A window that was already shown before the
                    // transition doesn't automatically get recomposited into the
                    // new Space - same class of problem as the old hidden->visible
                    // glitch on mulligan start (see the comment above), just
                    // triggered by a Space change instead of a focus change. An
                    // explicit hide+reshow forces the window server to
                    // re-evaluate Space membership for the new frame/collectionBehavior.
                    windowManager.show(controller: win, show: false)
                }

                windowManager.show(controller: win, show: true, frame: frame, overlay: true)
                if fullscreenChanged {
                    win.window?.orderFrontRegardless()
                }
            } else {
                windowManager.show(controller: win, show: false)
            }
        }
    }

    func updateBattlegroundsOverlays() {
        DispatchQueue.main.async {
            // Every Battlegrounds overlay is a RootOverlay child now, and
            // unlike the AppKit windows they replaced none of them needs a
            // frame or a window level from here: Game.updateRootOverlay hides
            // the whole canvas when Hearthstone goes to the background. Only
            // the session panel has visibility rules of its own to re-run.
            self.updateBattlegroundsSessionVisibility()
        }
    }
    
    func updateBattlegroundsOverlay() {
        DispatchQueue.main.async {
            let isBG = self.isBattlegroundsMatch() && !self.gameEnded

            // GuidesTabsView gates on this rather than calling isBattlegroundsMatch()
            // from its body, which gave SwiftUI nothing to invalidate on - see
            // BattlegroundsGuidesTabsViewModel.isInMatch. Pushed outside the isBG
            // branch below precisely so the false edge lands too.
            if #available(macOS 10.15, *) {
                self.windowManager.rootOverlay?.viewModel.battlegroundsGuidesTabs.setInMatch(isBG)
            }

            // HDT refreshes the minion browser's lobby state from ShowBgsTopBar,
            // which this is the analogue of. The available races are not readable
            // from the mirror yet at gameStart, so they have to be picked up here.
            if #available(macOS 10.15, *), isBG {
                // The real match takes over the same panel the pre-lobby was
                // showing - HDT's LeaveBgsGuidesPreLobby, called from this
                // function's HDT analogue (ShowBgsTopBar).
                self.windowManager.rootOverlay?.viewModel.battlegroundsGuidesTabs.isPreLobby = false
                self.windowManager.rootOverlay?.viewModel.battlegroundsMinionsGuide.updateLobby()
                // OverlayWindow.Update re-pushes AvailableRaces on the same
                // tick, because the lobby's races are not settled at match
                // start.
                self.windowManager.rootOverlay?.viewModel.battlegroundsMinionPinning.updateLobby()
            }

            // Outside the isBG branch for the same reason setInMatch is: the
            // Tavern Pinning panel has to be taken down when a match ends
            // however it ended, not only on the handleEndGame path. Its own
            // predicate carries the match term - see updateVisibility().
            if #available(macOS 10.15, *) {
                self.windowManager.rootOverlay?.viewModel.battlegroundsMinionPinning.updateVisibility()
            }

        }
    }
    
    func updateTurnCounterOverlay() {
        DispatchQueue.main.async {
            if #available(macOS 10.15, *) {
                self.windowManager.rootOverlay?.viewModel.battlegroundsTurnCounter
                    .update(turn: self.turnNumber(), isShown: self.isTurnCounterVisible)
            }
        }
    }

    func updateBobsBuddyOverlay() {
        DispatchQueue.main.async {
            // The game type outlives the match, and the two signals for leaving it (the scene and the
            // log) do not arrive in a fixed order, so the match is over as soon as either one says so.
            // A scene we cannot read is not one of them, or a stalled watcher would keep the panel down.
            let leftViaScene = SceneHandler.scene != nil && SceneHandler.scene != .gameplay
            let isBG = self.isBattlegroundsMatch() && !self.isInMenu && !leftViaScene && !self.gameEnded
            let show = isBG && Settings.showBobsBuddy &&
                ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
                    || !Settings.hideAllWhenGameInBackground) && !self.hideBobsBuddy
            if #available(macOS 10.15, *) {
                self.windowManager.rootOverlay?.viewModel.bobsBuddy.isShown = show
            }
        }
    }
    
    func updateExperienceOverlay() {
        let rect = SizeHelper.experienceOverlayFrame()
        
        DispatchQueue.main.async {
            let experiencePanel = self.windowManager.experiencePanel
            if Settings.showExperienceCounter && experiencePanel.visible && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground) {
                self.windowManager.show(controller: experiencePanel, show: true, frame: rect, title: nil, overlay: true)
            } else {
                self.windowManager.show(controller: experiencePanel, show: false)
            }
        }
    }
    
    static let experienceFadeDelay = 6.0
    
    func experienceChangedAsync(experience: Int, experienceNeeded: Int, level: Int, levelChange: Int, animate: Bool) {
        let currentMode = self.currentMode ?? .invalid
        let previousMode = self.previousMode ?? .invalid
        
        logger.debug("Experience changed. Current mode \(currentMode), previous \(previousMode)")
        
        while let cm = self.currentMode, let pm = self.previousMode, cm == Mode.gameplay && pm == Mode.bacon {
            Thread.sleep(forTimeInterval: 0.500)
        }
        logger.debug("Showing experience counter now")
        let experienceCounter = windowManager.experiencePanel.experienceTracker
        experienceCounter.xpDisplay = "\(experience)/\(experienceNeeded)"
        experienceCounter.levelDisplay = "\(level+1)"
        experienceCounter.xpPercentage = (Double(experience) / Double(experienceNeeded))
        if animate {
            DispatchQueue.main.async {
                experienceCounter.needsDisplay = true
                self.windowManager.experiencePanel.visible = true
                self.updateExperienceOverlay()
                self.guiNeedsUpdate = true
            }
            Thread.sleep(forTimeInterval: Game.experienceFadeDelay)
        } else {
            DispatchQueue.main.async {
                experienceCounter.needsDisplay = true
                
            }
        }
        if currentMode != Mode.hub {
            windowManager.experiencePanel.visible = false
            guiNeedsUpdate = true
        }
    }

    func updateCardHud() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            
            let tracker = self.windowManager.cardHudContainer
            
            if Settings.showCardHuds && self.shouldShowGUIElement && !self.gameEnded && !self.isBattlegroundsMatch() {
                tracker.update(entities: self.opponent.hand,
                               cardCount: self.opponent.handCount, game: self)
                self.windowManager.show(controller: tracker, show: true,
                     frame: SizeHelper.cardHudContainerFrame(), title: nil,
                     overlay: self.hearthstoneRunState.isActive)
            } else {
                self.windowManager.show(controller: tracker, show: false)
            }
        }
    }
    
    func updateBoardStateTrackers() {
        DispatchQueue.main.async {
            let playerBoardDamage = self.windowManager.playerBoardDamage
            let opponentBoardDamage = self.windowManager.opponentBoardDamage

            let visible = self.shouldShowGUIElement
                && self.currentGameMode != .battlegrounds && self.currentGameMode != .mercenaries
                && self.isMulliganDone() && !self.gameEnded
            let showPlayer = Settings.playerBoardDamage && visible
            let showOpponent = Settings.opponentBoardDamage && visible
            // Nothing to compute while both counters are hidden
            let board = showPlayer || showOpponent ? BoardState(game: self) : nil

            if showPlayer, let board = board {
                playerBoardDamage.update(now: board.player.hasInfiniteDamageNow ? Int.max : board.player.damageNow,
                                         nextTurn: board.player.hasInfiniteDamageNextTurn ? Int.max : board.player.damageNextTurn)
                var rect: NSRect?
                if !Settings.autoPositionTrackers {
                    rect = Settings.playerBoardDamageFrame
                }
                playerBoardDamage.hasValidFrame = true
                self.windowManager.show(controller: playerBoardDamage, show: true,
                                        frame: rect ?? SizeHelper.playerBoardDamageFrame(), title: nil,
                                        overlay: self.hearthstoneRunState.isActive)
            } else {
                self.windowManager.show(controller: playerBoardDamage, show: false)
            }

            if showOpponent, let board = board {
                opponentBoardDamage.update(now: board.opponent.hasInfiniteDamageNow ? Int.max : board.opponent.damageNow,
                                           nextTurn: board.opponent.hasInfiniteDamageNextTurn ? Int.max : board.opponent.damageNextTurn)
                var rect: NSRect?
                if !Settings.autoPositionTrackers {
                    rect = Settings.opponentBoardDamageFrame
                }
                opponentBoardDamage.hasValidFrame = true
                // This used to pass the default frame whatever was saved, so a moved opponent counter
                // jumped back on every refresh.
                self.windowManager.show(controller: opponentBoardDamage, show: true,
                                        frame: rect ?? SizeHelper.opponentBoardDamageFrame(), title: nil,
                                        overlay: self.hearthstoneRunState.isActive)
            } else {
                self.windowManager.show(controller: opponentBoardDamage, show: false)
            }
        }
    }

    /// Asks for the board damage counters to be recomputed on the next GUI update tick, for tag
    /// changes (attacks, freezes, Attack changes, steps) that don't refresh the trackers otherwise.
    /// Coalesced, since these tags change many times per turn.
    func updateBoardDamage() {
        _queue.async {
            self.boardDamageNeedsUpdate = true
        }
    }
	
    func updateBoardOverlay() {
        // WindowManager.show never orders a window in the unit test host, but the frames handed to it
        // are worked out first, and SizeHelper reads them through the CoreManager the host never
        // creates. Any Game a test makes gets here through updateAllTrackers, and with Show flavor text
        // at its default (on) that crashed the test host.
        guard !AppDelegate.isRunningUnitTests else {
            return
        }
        DispatchQueue.main.async {
            let oppTracker = self.windowManager.opponentBoardOverlay
            let playerTracker = self.windowManager.playerBoardOverlay

            let show = (!self.isMercenariesMatch() && Settings.showFlavorText) || (self.isMercenariesMatch())
            if !self.isInMenu && show || (self.isMulliganDone() || self.isMercenariesMatch()) && !self.gameEnded && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground) {
                self.windowManager.show(controller: oppTracker, show: true, frame: SizeHelper.opponentBoardOverlay(), title: nil, overlay: self.hearthstoneRunState.isActive)
                oppTracker.updateBoardState(player: self.opponent)
                self.windowManager.show(controller: playerTracker, show: true, frame: SizeHelper.playerBoardOverlay(), title: nil, overlay: self.hearthstoneRunState.isActive)
                playerTracker.updateBoardState(player: self.player)
            } else {
                self.windowManager.show(controller: oppTracker, show: false)
                self.windowManager.show(controller: playerTracker, show: false)
            }
        }
    }
	
    func updateMercenariesTaskListButton() {
        DispatchQueue.main.async {
          let merc = self.windowManager.mercenariesTaskListButton
            if Settings.showMercsTasks && merc.visible && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground) {
                let rect = SizeHelper.mercenariesTaskListButton()
                self.windowManager.show(controller: merc, show: true, frame: rect, title: nil, overlay: true)
            } else {
                self.windowManager.show(controller: self.windowManager.mercenariesTaskListView, show: false)
                self.windowManager.show(controller: merc, show: false)
            }
        }
    }
        
    func setBaconState(_ mode: SelectedBattlegroundsGameMode, _ isAnyOpen: Bool) {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.tier7PreLobby.battlegroundsGameMode = mode
            windowManager.rootOverlay?.viewModel.tier7PreLobby.isModalOpen = !queueEvents.isInQueue && isAnyOpen
            windowManager.rootOverlay?.viewModel.battlegroundsSession.battlegroundsGameMode = mode
        }
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.updateTier7PreLobbyVisibility()
                self.updateBattlegroundsGuidesPreLobbyVisibility()
            }
        }
    }

    func setBaconQueue(_ isAnyOpen: Bool) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.updateTier7PreLobbyVisibility()
                self.updateBattlegroundsGuidesPreLobbyVisibility()
            }
        }
    }
        
    @available(macOS 10.15, *)
    @MainActor
    func updateTier7PreLobbyVisibility() {
        guard let viewModel = windowManager.rootOverlay?.viewModel.tier7PreLobby else {
            return
        }

        // Hearthstone being in the background isn't a term here, exactly as in
        // HDT: the whole RootOverlay window is hidden for that
        // (Game.updateRootOverlay), so folding it in would only make the panel
        // reset itself every time the user alt-tabbed.
        let show = isRunning && isInMenu && !queueEvents.isInQueue && SceneHandler.scene == .bacon && Settings.enableTier7Overlay && Settings.showBattlegroundsTier7PreLobby && (viewModel.battlegroundsGameMode == .solo || viewModel.battlegroundsGameMode == .duos) && viewModel.visibility
        if show {
            Task.init {
                await viewModel.update()
            }
        } else if viewModel.isShown {
            // HDT's _tier7PreLobbyBehavior.HideCallback. Gated on the
            // shown -> hidden transition because that is the only time
            // OverlayElementBehavior.Hide() fires it - it early-returns when
            // the element is already collapsed - and this runs on every lobby
            // tick. reset() clears battlegroundsGameMode along with the rest,
            // as HDT's Reset() does; BaconWatcher re-supplies it on its next
            // change (queueing blurs the lobby, so cancelling one always
            // produces one), and re-entering BACON restarts the watcher with a
            // cleared _prev so it reports unconditionally.
            viewModel.reset()
        }
        viewModel.isShown = show
    }

    // Mirrors HDT's InBattlegroundsScene: true while sitting in the Battlegrounds
    // lobby, or transitioning between it and a match in either direction. The
    // scene goes nil for the duration of a transition, so BACON -> GAMEPLAY (a
    // match starting) must be told apart from BACON -> anything else (leaving to
    // the main menu) purely from lastScene/nextScene.
    private var isBaconSceneOrTransitioningToFromMatch: Bool {
        if SceneHandler.scene == .bacon {
            return true
        }
        guard SceneHandler.scene == nil else {
            return false
        }
        return (SceneHandler.lastScene == .bacon && SceneHandler.nextScene == .gameplay)
            || (SceneHandler.lastScene == .gameplay && SceneHandler.nextScene == .bacon)
    }

    // Mirrors HDT's ShouldShowBattlegroundsGuidesPreLobby/UpdateBattlegroundsGuidesPreLobbyVisibility.
    // Unlike Tier7PreLobby this stays up while queued (only the meta snapshot
    // promo hides then) - HDT's own panel does the same, since browsing guides
    // while waiting in queue is the point.
    //
    // Safe to call from the leave-BACON transition as well as the enter-BACON
    // one (see SceneHandler.swift): isBaconSceneOrTransitioningToFromMatch keeps
    // this true through a BACON -> GAMEPLAY transition, so isPreLobby is not
    // cleared out from under a match that is about to take the panel over via
    // updateBattlegroundsOverlay()'s hand-off - only a genuine leave (back to the
    // main menu, say) clears it here.
    @available(macOS 10.15, *)
    @MainActor
    func updateBattlegroundsGuidesPreLobbyVisibility() {
        guard let guidesTabs = windowManager.rootOverlay?.viewModel.battlegroundsGuidesTabs else {
            return
        }

        guidesTabs.isInQueue = queueEvents.isInQueue

        let show = isRunning && isBaconSceneOrTransitioningToFromMatch && Settings.showBattlegroundsBrowser && Settings.showBattlegroundsGuidesPreLobby
        if show {
            if !guidesTabs.isPreLobby {
                let mode = windowManager.rootOverlay?.viewModel.tier7PreLobby.battlegroundsGameMode
                windowManager.rootOverlay?.viewModel.battlegroundsMinionsGuide.enterPreLobby(isDuos: mode == .duos)
                guidesTabs.activeTab = nil
                guidesTabs.isPreLobby = true
                // HDT's BattlegroundsCompsGuidesVM.OnPreLobby(): the comp
                // guides have no other trigger in the lobby, so without this
                // the tab stays stuck on its loading state until a match
                // starts.
                if let comps = windowManager.rootOverlay?.viewModel.battlegroundsCompsGuides {
                    Task {
                        await comps.onPreLobby()
                    }
                }
            }
        } else {
            guidesTabs.isPreLobby = false
        }
    }
    
    func updateVisibilities() {
        updateBattlegroundsSessionVisibility()
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.updateTier7PreLobbyVisibility()
            }
        }
//        updateMulliganGuidePreLobbyVisibility()
    }
    
    // The session panel is a RootOverlay child rather than a window of its own,
    // so refreshing it is a view-model call - wrapped here because the callers
    // are not themselves gated on the SwiftUI baseline.
    func updateBattlegroundsSessionPanel() {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.battlegroundsSession.update()
        }
    }

    func updateBattlegroundsSessionVisibility(_ isFriendsListOpen: Bool = false) {
        let show = isRunning && ((Settings.hideAllWhenGameInBackground && hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground) && Settings.showSessionRecap
                && (
                    (
                        // Scene is not transitioning
                        SceneHandler.scene != nil &&
                        (SceneHandler.scene == .bacon || (SceneHandler.scene == .gameplay && isBattlegroundsMatch()))
                    )
                    || (
                        // Scene is transitioning - do not check for IsBattlegroundsMatch because that might not be set yet/still
                        SceneHandler.scene == nil &&
                        (
                            // Start of Match
                            (SceneHandler.lastScene == .bacon && SceneHandler.nextScene == .gameplay)
                            // End of Match
                            || (SceneHandler.lastScene == .gameplay && SceneHandler.nextScene == .bacon)
                        )
                    )
                ) && !isFriendsListOpen

        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.rootOverlay?.viewModel.battlegroundsSession.setShown(show)
            }
        }
    }

    // MARK: - Vars
    
    var buildNumber: Int = 0
    var playerIDNameMapping = SynchronizedDictionary<Int, String>()
    var playerIdsByPlayerName = SynchronizedDictionary<String, Int>()
    
    var choicesById = SynchronizedDictionary<Int, IHsChoice>()
    var choicesByTaskList = SynchronizedDictionary<Int, [IHsChoice]>()
    
    var triangulatePlayed = false
    
	var startTime: Date?
    var currentTurn = 0
    var lastId = 0
    var gameTriggerCount = 0
    var playerDeckAutodetected: Bool = false
    private var hasValidDeck = false
    private var powerLog: [LogLine] = []
    func add(powerLog: LogLine) {
        self.powerLog.append(powerLog)
    }
    
    var playedCards: [PlayedCard] = []
    var proposedAttackerEntityId: Int = 0
    var proposedDefenderEntityId: Int = 0
	var player: Player!
    var opponent: Player!
    var currentMode: Mode? = .invalid
    var previousMode: Mode? = .invalid
    private var _battlegroundsBoardState: BattlegroundsBoardState?
    var primaryPlayerId = 0
    
    private var _brawlInfo: BrawlInfo?
	
	var gameResult: GameResult = .unknown
	var wasConceded: Bool = false

    private var _spectator: Bool?
    var spectator: Bool {
        if _spectator == nil {
            _spectator = MirrorHelper.isSpectating()
        }
        return _spectator ?? false
	}

    private var _currentGameMode: GameMode = .none
    var currentGameMode: GameMode {
        if spectator {
            return .spectator
        }

        if _currentGameMode == .none {
            _currentGameMode = GameMode(gameType: currentGameType)
        }
        return _currentGameMode
    }

    private var _currentGameType: GameType = .gt_unknown
    private var _gameTypeDuosCorrectionCheckCompleted = false
    var currentGameType: GameType {
        if _currentGameType != .gt_unknown {
            if _gameTypeDuosCorrectionCheckCompleted {
                return _currentGameType
            }
            if isSoloBattlegroundsGameType(_currentGameType) {
                tryCorrectMisreadSoloGameType()
            }
            return _currentGameType
        }
        return .gt_unknown
    }
    
    /// <summary>
    /// The mirror can report a stale solo game type for a Duos game (confirmed to be a longstanding issue
    /// via Sentry). The likely cause, the previous game's game_type was read during the menu-to-gameplay
    /// transition, which then locks the game into solo mode.
    /// The fix: check all player entities for any nonzero BACON_DUO_TEAM_ID tag.
    /// </summary>
    private func tryCorrectMisreadSoloGameType() {
        // swiftlint:disable switch_case_alignment
        let duoGameTypeEquivalent = switch _currentGameType {
            case GameType.gt_battlegrounds: GameType.gt_battlegrounds_duo
            case GameType.gt_battlegrounds_friendly: GameType.gt_battlegrounds_duo_friendly
            case GameType.gt_battlegrounds_ai_vs_ai: GameType.gt_battlegrounds_duo_ai_vs_ai
            case GameType.gt_battlegrounds_player_vs_ai: GameType.gt_battlegrounds_duo_vs_ai
            default: GameType.gt_unknown
        }
        // swiftlint:enable switch_case_alignment
        let hasDuoTeamId = entities.values
            .any({ e in e.has(tag: GameTag.player_id) && e[GameTag.bacon_duo_team_id] > 0 })
        if hasDuoTeamId {
            logger.warning("Correcting misread solo game type \(_currentGameType) to \(duoGameTypeEquivalent) (player entity has BACON_DUO_TEAM_ID)")
            _currentGameType = duoGameTypeEquivalent
            _gameTypeDuosCorrectionCheckCompleted = true
        } else if setupDone {  // All player entities now exist, the game is genuinely solo.
            _gameTypeDuosCorrectionCheckCompleted = true
        }
    }

    private var _serverInfo: MirrorGameServerInfo?
    var serverInfo: MirrorGameServerInfo? {
        if _serverInfo == nil {
            _serverInfo = MirrorHelper.getGameServerInfo()
        }
        return _serverInfo
    }

	var entities =  SynchronizedDictionary<Int, Entity>()
    
    // swiftlint:disable large_tuple
    var knownCardIds = SynchronizedDictionary<Int, [(String, DeckLocation, String?, EntityInfo?)]>()
    // swiftlint:enable large_tuple
    var joustReveals = 0
    var dredgeCounter = 0

    var lastCardPlayed = 0
    var lastEntityChosenOnDiscover = 0
    var gameEnded = true
    internal private(set) var currentDeck: PlayingDeck?

    var currentEntityHasCardId = false
    var playerUsedHeroPower = false
    private var hasCoin = false
    var currentEntityZone: Zone = .invalid
    var currentRegion = Region.unknown
    var opponentUsedHeroPower = false
	var wasInProgress = false
    var setupDone = false
    var secretsManager: SecretsManager?
    var proposedAttacker = 0
    var proposedDefender = 0
    var isDungeonMatch: Bool = false
    private var defendingEntity: Entity?
    private var attackingEntity: Entity?
    private var avengeDeathRattleCount = 0
    private var awaitingAvenge = false
    var isInMenu = true
    private var handledGameEnd = false
    private var _pendingBattlegroundsGame: PendingBattlegroundsGame?
    
	var enqueueTime = LogDate(date: Date.distantPast)
    private var lastTurnStart: [Int] = [0, 0]
    private var turnQueue: ConcurrentSet<PlayerTurn> = ConcurrentSet()
    
	fileprivate var lastGameStartTimestamp: LogDate = LogDate(date: Date.distantPast)

    private var _matchInfoCacheInvalid = true
    private var _matchInfo: MatchInfo?
    
    private var _battlegroundsRatingInfo: MirrorBattlegroundRatingInfo?
    
    private var _mercenariesRating: Int?
    
    private var isReconnect = false
    var shouldSuppressLog: Bool {
        return isBattlegroundsMatch() && isReconnect
    }
    
    var mercenariesRating: Int? {
        if _mercenariesRating == nil {
            if let rating = MirrorHelper.getMercenariesRating() {
                _mercenariesRating = rating
            }
        }
        return _mercenariesRating
    }
    
    var mercenariesMapInfo: MirrorMercenariesMapInfo? {
        return MirrorHelper.getMercenariesMapInfo()
    }
    
    private var _availableRaces: [Race]?
    
    private var _unavailableRaces: [Race]?
    
    var adventureOpponentId: String?
    
    var hideBobsBuddy = false
    var hideBattlegroundsTurn = false
    
    var availableRaces: [Race]? {
        if _availableRaces == nil {
            if let races = MirrorHelper.getAvailableBattlegroundsRaces() {
                let newRaces = races.compactMap({ x in x.intValue > 0 && x.intValue < Race.allCases.count ? Race.allCases[x.intValue] : nil })
                logger.info("Battlegrounds available races: \(newRaces) - from mirror \(races)")
                if newRaces.count > 0 && newRaces.count == races.count {
                    _availableRaces = newRaces
                    return _availableRaces
                }
            }
        }
        return _availableRaces
    }
    
    var unavailableRaces: [Race]? {
        if _unavailableRaces == nil {
            if let races = availableRaces, races.count > 0 && races[0] != .invalid {
                var newRaces = [Race]()
                for race in Database.battlegroundRaces where !races.contains(race) {
                    newRaces.append(race)
                }
                if newRaces.count > 0 {
                    logger.info("Battlegrounds unavailable races: \(newRaces) - all races \(races)")
                    _unavailableRaces = newRaces
                    return _unavailableRaces
                } else {
                    return nil
                }
            }
        }
        return _unavailableRaces
    }

    var battlegroundsRatingInfo: MirrorBattlegroundRatingInfo? {
        if let info = _battlegroundsRatingInfo {
            return info
        }
        
        _battlegroundsRatingInfo = MirrorHelper.getBattlegroundsRatingInfo()
        
        logger.debug("Got battlegroundsRatingInfo=\(_battlegroundsRatingInfo ?? MirrorBattlegroundRatingInfo())")
        return _battlegroundsRatingInfo
    }
    
    var matchInfo: MatchInfo? {
        
        if _matchInfo != nil {
            return _matchInfo
        }
        
        if !self.gameEnded, let mInfo = MirrorHelper.getMatchInfo() {
            let matchInfo = MatchInfo(info: mInfo)
            logger.info("\(matchInfo.localPlayer.name)"
                + " vs \(matchInfo.opposingPlayer.name)"
                + " matchInfo: \(matchInfo)")            
            self.player.name = matchInfo.localPlayer.name
            self.opponent.name = matchInfo.opposingPlayer.name
            self.player.id = matchInfo.localPlayer.playerId
            self.opponent.id = matchInfo.opposingPlayer.playerId
            self._currentGameType = matchInfo.gameType

            let opponentStarLevel = matchInfo.opposingPlayer.standardMedalInfo.starLevel
            logger.info("LADDER opponentStarLevel=\(opponentStarLevel)")
            return matchInfo
        }
        return nil
    }
    
    var playerMedalInfo: MatchInfo.MedalInfo? {
        guard let localPlayer = matchInfo?.localPlayer, currentGameType == .gt_ranked else {
            return nil
        }
        switch currentFormat {
        case .standard:
            return localPlayer.standardMedalInfo
        case .wild:
            return localPlayer.wildMedalInfo
        case .classic:
            return localPlayer.classicMedalInfo
        case .twist:
            return localPlayer.twistMedalInfo
        default:
            return nil
        }
    }
	
    var arenaInfo: ArenaInfo? {
        if let _arenaInfo = MirrorHelper.getArenaInfo() {
            return ArenaInfo(info: _arenaInfo)
        }
        return nil
    }

    var brawlInfo: BrawlInfo? {
        if let brawlInfo = _brawlInfo {
            return brawlInfo
        }
        if let _brawlInfo = MirrorHelper.getBrawlInfo() {
            return BrawlInfo(info: _brawlInfo)
        }
        return nil
    }

    var playerEntity: Entity? {
        return entities.values.filter { $0[.player_id] == self.player.id }.sorted { $0.id < $1.id }.first
    }

    var opponentEntity: Entity? {
        return entities.values.filter { $0.has(tag: .player_id) && !$0.isPlayer(eventHandler: self) }.sorted { $0.id < $1.id }.first
    }

    var gameEntity: Entity? {
        return entities.values.first { $0.name == "GameEntity" }
    }

    var isMinionInPlay: Bool {
        return entities.values.first { $0.isInPlay && $0.isMinion } != nil
    }

    var isOpponentMinionInPlay: Bool {
        return entities.values
            .first { $0.isInPlay && $0.isMinion
                && $0.isControlled(by: self.opponent.id) } != nil
    }

    var opponentMinionCount: Int {
        return entities.values
            .filter { $0.isInPlay && $0.isMinion && !$0.has(tag: .untouchable)
                && $0.isControlled(by: self.opponent.id) }.count }
    
    var opponentBoardCount: Int {
        return entities.values
            .filter { $0.isInPlay && $0.takesBoardSlot
                && $0.isControlled(by: self.opponent.id) }.count
    }

    var playerMinionCount: Int {
        return entities.values
            .filter { $0.isInPlay && $0.isMinion
                && $0.isControlled(by: self.player.id) }.count }

    var playerBoardCount: Int {
        return entities.values
            .filter { $0.isInPlay && $0.takesBoardSlot
                && $0.isControlled(by: self.player.id) }.count }

    var opponentHandCount: Int {
        return entities.values
            .filter { $0.isInHand && $0.isControlled(by: self.opponent.id) }.count }
    
    var opponentSecretCount: Int {
        // Revealed secrets keep the SECRET tag in the graveyard, setaside and hand (HDT GameV2 checks IsInSecret)
        return entities.values
            .filter { $0.isInSecret && $0.isSecret && $0.isControlled(by: self.opponent.id) }.count
    }
    
    var playerHandCount: Int {
        return entities.values
            .filter { $0.isInHand && $0.isControlled(by: self.player.id) }.count }

    var inAiMatch: Bool {
        return currentMode == Mode.gameplay && currentGameType == GameType.gt_vs_ai
    }
    
    var inAdventureScreen: Bool {
        return currentMode == Mode.adventure
    }
    
    var inPVPDungeonRunScreen: Bool {
        return currentMode == Mode.pvp_dungeon_run
    }
    
    var inPVPDungeonRunMatch: Bool {
        return currentMode == Mode.gameplay && previousMode == Mode.pvp_dungeon_run
    }
    
    var playerHeroId: String {
        return player.hero?.cardId ?? ""
    }

    var opponentHeroId: String {
        return opponent.hero?.cardId ?? ""
    }
    
    var opponentHeroHealth: Int {
        return opponent.hero?[.health] ?? 0
    }

    private var _currentFormatType = FormatType.ft_unknown
    var currentFormatType: FormatType {
        if _currentFormatType == .ft_unknown, let ft = FormatType(rawValue: MirrorHelper.getFormat() ?? 0) {
            _currentFormatType =  ft
        }
        return _currentFormatType
    }
    var currentFormat: Format {
        return Format(formatType: _currentFormatType) 
    }

    /// Sets the game type and format HearthMirror reports for a live game, for a game played without
    /// Hearthstone to read them from: the unit tests, where the mirror is never queried.
    func setGameType(_ gameType: GameType, formatType: FormatType) {
        _currentGameType = gameType
        _currentFormatType = formatType
        _currentGameMode = .none
    }
    
    var lastPlagueDrawn = Stack<String>()

	// MARK: - Lifecycle
    private var observers: [NSObjectProtocol] = []
    
    init(hearthstoneRunState: HearthstoneRunState) {
        self.hearthstoneRunState = hearthstoneRunState
		turnTimer = TurnTimer(gui: windowManager.timerHud)
        activeEffects = ActiveEffects()
        counterManager = CounterManager()
        relatedCardsManager = RelatedCardsManager()
        super.init()
        counterManager.initialize(game: self)
        actionHistory.gameTypeProvider = { [weak self] in
            return self?.currentGameType ?? .gt_unknown
        }
        // Already on the main thread and coalesced by the recorder
        actionHistory.onChanged = { [weak self] in
            guard let self else { return }
            if #available(macOS 10.15, *) {
                let snapshot = self.actionHistory.snapshot()
                self.onMainOverlay { $0.actionHistory.apply(snapshot) }
            }
        }
        _battlegroundsBoardState = BattlegroundsBoardState(game: self)
		player = Player(local: true, game: self)
        opponent = Player(local: false, game: self)
        secretsManager = SecretsManager(game: self, availableSecrets: RemoteArenaSettings(), relatedCardsManager: relatedCardsManager)
        secretsManager?.onChanged = { [weak self] cards in
            self?.updateSecretTracker(cards: cards)
        }
		
		windowManager.startManager()
        windowManager.playerTracker.window?.delegate = self
        windowManager.opponentTracker.window?.delegate = self
		
		let center = NotificationCenter.default
		
		// events that should update the player tracker
		let playerTrackerUpdateEvents = [Settings.show_player_tracker, Settings.rarity_colors, Settings.remove_cards_from_deck,
		                                 Settings.highlight_last_drawn, Settings.highlight_cards_in_hand, Settings.highlight_discarded,
		                                 Settings.show_player_get, Settings.player_draw_chance, Settings.player_card_count,
                                         Settings.player_deathrattle_frame,
		                                 Settings.show_win_loss_ratio, Settings.player_in_hand_color, Settings.show_deck_name,
		                                 Settings.player_graveyard_details_frame, Settings.player_graveyard_frame,
                                         Settings.player_cards_top, Settings.player_cards_bottom, Settings.player_cards_top,
                                         Settings.player_cards_bottom, Settings.hide_player_sideboards,
                                         Settings.show_matchup_win_rate, Events.game_stats_changed]
		
		// events that should update the opponent's tracker
		let opponentTrackerUpdateEvents = [Settings.show_opponent_tracker, Settings.opponent_card_count, Settings.opponent_draw_chance,
		                                   Settings.opponent_deathrattle_frame,
		                                   Settings.show_opponent_class, Settings.opponent_graveyard_frame,
		                                   Settings.opponent_graveyard_details_frame,
                                           Settings.opponent_related_cards]
		
		// events that should update all trackers
		let allTrackerUpdateEvents = [Settings.rarity_colors, Events.reload_decks, Settings.window_locked, Settings.auto_position_trackers,
		                              Events.space_changed, Events.hearthstone_closed, Events.hearthstone_running,
		                              Events.hearthstone_active, Events.hearthstone_deactived, Settings.can_join_fullscreen,
		                              Settings.hide_all_trackers_when_not_in_game, Settings.hide_all_trackers_when_game_in_background,
		                              Settings.card_size, Settings.theme_token, Settings.show_action_history]
        
        // Toggling Show secret helper used to wait for the next secret change to take effect
        for option in [Settings.show_secret_helper, Settings.auto_grayout_secrets, Settings.remove_secrets_from_list] {
            let observer = center.addObserver(forName: NSNotification.Name(rawValue: option), object: nil, queue: OperationQueue.main) { [weak self] _ in
                self?.refreshSecretHelper()
            }
            self.observers.append(observer)
        }
        
        for option in playerTrackerUpdateEvents {
            let observer = center.addObserver(forName: NSNotification.Name(rawValue: option), object: nil, queue: OperationQueue.main) { _ in
                self.updatePlayerTracker()
            }
            self.observers.append(observer)
        }
        
        for option in opponentTrackerUpdateEvents {
            let observer = center.addObserver(forName: NSNotification.Name(rawValue: option), object: nil, queue: OperationQueue.main) { _ in
                self.updateOpponentTracker()
            }
            self.observers.append(observer)
        }
		
		for option in allTrackerUpdateEvents {
            let observer = center.addObserver(forName: NSNotification.Name(rawValue: option), object: nil, queue: OperationQueue.main) { _ in
                self.updateAllTrackers()
            }
            self.observers.append(observer)
		}
		
		// start gui updater thread
		_queue.async {
//			while true {
            self.internalUpdateCheck()
//				Thread.sleep(forTimeInterval: Game.guiUpdateDelay)
//			}
		}
    }
    
    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private var counter = 0
    
    private func internalUpdateCheck() {
        if self.guiNeedsUpdate {
            self.guiNeedsUpdate = false
            self.boardDamageNeedsUpdate = false
            self.updateAllTrackers()
            self.guiUpdateResets = false
            self.counter = 0
        } else if self.counter > 3 {
            let rect = SizeHelper.hearthstoneWindow.frame
            // fullscreen-flag flips can leave _frame unchanged but still shift the 50px game-menu offset
            let wasFullscreen = SizeHelper.hearthstoneWindow.isFullscreen()
            SizeHelper.hearthstoneWindow.reload()
            if rect != SizeHelper.hearthstoneWindow.frame || wasFullscreen != SizeHelper.hearthstoneWindow.isFullscreen() {
                self.updateAllTrackers()
                self.updateBattlegroundsOverlays()
                self.updateConstructedMulliganOverlays()
                self.updateActiveEffects()
                if #available(macOS 10.15, *) {
                    self.updateMaxResourcesWidget()
                    self.updateRootOverlay()
                }
            }
            self.counter = 0
        } else {
            self.counter += 1
        }
        
        // updateAllTrackers above already refreshes the board damage
        if self.boardDamageNeedsUpdate {
            self.boardDamageNeedsUpdate = false
            self.updateBoardStateTrackers()
        }
        self.updateBoardOverlay()

        _queue.asyncAfter(deadline: DispatchTime.now() + Game.guiUpdateDelay, execute: {
            self.internalUpdateCheck()
        })
    }

    func reset() {
        logger.verbose("Reseting Game")
        currentTurn = 0
        hasValidDeck = false
        gameId = UUID.init().uuidString

        playedCards.removeAll()
		
		self.gameResult = .unknown
		self.wasConceded = false

        lastId = 0
        gameTriggerCount = 0

        _matchInfo = nil
        _currentFormatType = .ft_unknown
        _currentGameType = .gt_unknown
        _gameTypeDuosCorrectionCheckCompleted = false
		_currentGameMode = .none
        _serverInfo = nil

        // Before opponent.reset() clears the name: an unfinished game is kept in case this is a reconnect
        actionHistory.reset(opponentName: opponent?.name)
        entities.removeAll()
        isBattlegroundsCombatPhase = false
        controllersWithDeckCopiedFromEnemy.removeAll()
        knownCardIds.removeAll()
        joustReveals = 0
        lastPlagueDrawn.clear()
		
        lastCardPlayed = 0
        lastEntityChosenOnDiscover = 0
        
        currentEntityHasCardId = false
        playerUsedHeroPower = false
        hasCoin = false
        currentEntityZone = .invalid
        opponentUsedHeroPower = false
        setupDone = false
        secretsManager?.reset()
        proposedAttacker = 0
        proposedDefender = 0
        defendingEntity = nil
        attackingEntity = nil
        avengeDeathRattleCount = 0
        awaitingAvenge = false
        lastTurnStart = [0, 0]
        
        playerIDNameMapping.removeAll()
        playerIdsByPlayerName.removeAll()
        choicesById.removeAll()
        choicesByTaskList.removeAll()

        player.reset()
        if let currentdeck = self.currentDeck {
            player.originalClass = currentdeck.playerClass
            player.currentClass = player.originalClass
        }
        opponent.reset()
        activeEffects.reset()
        relatedCardsManager.reset()
        updateSecretTracker(cards: [])
        resetPlayerResourcesWidgets()
        windowManager.hideGameTrackers()
		
		_spectator = nil
        _availableRaces = nil
        _unavailableRaces = nil
        _brawlInfo = nil
        _battlegroundsBoardState?.reset()
        _battlegroundsHeroPickStatsParams = nil
        _battlegroundsHeroPickState = nil
        _mulliganGuideParams = nil
        _mulliganV2Params = nil
        _mulliganState = nil
        mulliganRecorder.reset()
        mulliganCardStats = nil
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.battlegroundsOpponentInfo.reset()
        }
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.bobsBuddy.resetDisplays()
        }
        updateTurnCounter(turn: 1)
        
        hideBobsBuddy = false
        hideBattlegroundsTurn = false
        
        adventureOpponentId = nil
        dredgeCounter = 0
        
        triangulatePlayed = false
        
        OpponentDeadForTracker.reset()
        
        starshipLaunchBlockIds.removeAll()
        
        minionsInPlay.removeAll()
        minionsInPlayByPlayer.removeAll()
        resetPlayerResourcesWidgets()
    }
    
    func cacheBrawlInfo() {
        if let info = MirrorHelper.getBrawlInfo() {
            _brawlInfo = BrawlInfo(info: info)
        }
    }
    
    func cacheBattlegroundRatingInfo() {
        _battlegroundsRatingInfo = MirrorHelper.getBattlegroundsRatingInfo()
    }
    
    func cacheMercenariesRatingInfo() {
        if let rating = MirrorHelper.getMercenariesRating() {
            _mercenariesRating = rating
        }
    }
    
    func cacheSpectator() {
        _spectator = MirrorHelper.isSpectating()
    }
    
    func cacheGameType() {
        if let currentGameType = MirrorHelper.getGameType(), currentGameType != GameType.gt_unknown.rawValue {
            if !_gameTypeDuosCorrectionCheckCompleted { // Do not let a late mirror overwrite a bg game type already corrected by TryCorrectMisreadSoloGameType.
                _currentGameType = GameType(rawValue: currentGameType) ?? .gt_unknown
            }
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.cacheGameType()
            }
        }
    }

	func set(activeDeckId: String?, autoDetected: Bool) {
		if let id = activeDeckId, let deck = RealmHelper.getDeck(with: id) {
			set(activeDeck: deck, autoDetected: autoDetected)
            hasValidDeck = true
            logger.info("has Valid Mirror Deck: \(deck.cards.count) cards")
		} else {
            currentDeck = nil
            player.originalClass = nil
            player.currentClass = nil
            updateTrackers(reset: true)
            logger.info("no Valid Mirror Deck")
		}
	}
	
    func set(activeDeck deck: Deck, autoDetected: Bool) {
        Settings.activeDeck = deck.deckId
        playerDeckAutodetected = autoDetected
		
        var cards: [Card] = []
        for deckCard in deck.cards {
            if let card = Cards.by(cardId: deckCard.id) {
                card.count = deckCard.count
                cards.append(card)
            }
        }
        let deckId = deck.deckId
        let name = deck.name
        let hsDeckId = deck.hsDeckId.value
        let playerClass = deck.playerClass
        let heroId = deck.heroId
        let isArena = deck.isArena
        var sideboards = [Sideboard]()
        
        for sideboard in deck.sideboards {
            let s = Sideboard(ownerCardId: sideboard.ownerCardId, cards: sideboard.cards.compactMap { y in
                let card = Cards.by(cardId: y.id)
                card?.count = y.count
                return card
            })
            sideboards.append(s)
        }
        
        let shortid = DeckSerializer.serialize(deck: HearthDbConverter.toHearthDbDeck(deck: deck))
        DispatchQueue.main.async {
            cards = cards.sortCardList()
            self.currentDeck = PlayingDeck(id: deckId,
                                      name: name,
                                      hsDeckId: hsDeckId,
                                      playerClass: playerClass,
                                      heroId: heroId,
                                      cards: cards.sortCardList(),
                                      isArena: isArena,
                                      shortid: shortid ?? "",
                                      sideboards: sideboards)
            self.player.originalClass = self.currentDeck?.playerClass
            self.player.currentClass = self.player.originalClass
            self.updateTrackers(reset: true)
        }
    }

    func removeActiveDeck() {
        currentDeck = nil
        Settings.activeDeck = nil
        updateTrackers(reset: true)
    }

    private func isValidPlayerInfo(playerInfo: MatchInfo.Player?, allowMissing: Bool = true) -> Bool {
        let name = playerInfo?.name ?? ""
        let valid = allowMissing || !name.isBlank
        logger.debug("valid=\(valid), gameMode=\(currentGameMode), player=\(name), starLevel=\(playerInfo?.standardMedalInfo.starLevel ?? 0)")
        return valid
    }
    
    private func isMedalInfoPresent(_ playerInfo: MatchInfo.Player?) -> Bool {
        return playerInfo?.standardMedalInfo != nil || playerInfo?.wildMedalInfo != nil || playerInfo?.classicMedalInfo != nil || playerInfo?.twistMedalInfo != nil
    }

    func invalidateMatchInfoCache() {
        _matchInfoCacheInvalid = true
    }

    // MARK: - game state
    private func cacheMatchInfo() {
        if !_matchInfoCacheInvalid {
            return
        }
        DispatchQueue.global().async {
            var matchInfo: MatchInfo?
            for i in 0...30 {
                if i > 0 {
                    logger.info("Waiting for matchInfo... (matchInfo=\(String(describing: matchInfo)), localPlayer=\(matchInfo?.localPlayer.name ?? "Unknown"), opposingPlayer=\(matchInfo?.opposingPlayer.name ?? "Unknown"))")
                    Thread.sleep(forTimeInterval: 1)
                }
                matchInfo = self.matchInfo
                guard let matchInfo else {
                    continue
                }
                
                // the player info will probably arrive shortly
                if !self.isValidPlayerInfo(playerInfo: matchInfo.localPlayer) || !self.isValidPlayerInfo(playerInfo: matchInfo.opposingPlayer, allowMissing: self.isMercenariesMatch()) {
                    continue
                }
                
                // wait for some medal info to be present.
                // opponent may not have medal info in case of UNKNOWN HUMAN PLAYER
                if !self.isMedalInfoPresent(matchInfo.localPlayer) && !self.isMedalInfoPresent(matchInfo.opposingPlayer) {
                    continue
                }
                    
                // looking good
                break
            }
            guard let matchInfo else {
                logger.info("Giving up waiting for matchInfo")
                return
            }
            self._matchInfo = matchInfo
            self.updatePlayers(matchInfo: matchInfo)
            self._matchInfoCacheInvalid = false
        }
    }
    
    private func updatePlayers(matchInfo: MatchInfo) {
        func getName(player: MatchInfo.Player) -> String {
            if let btag = player.battleTag {
                return btag
            }
            return player.name
        }
        let pname = getName(player: matchInfo.localPlayer)
        player.name = pname
        let oname = getName(player: matchInfo.opposingPlayer)
        opponent.name = oname
        player.id = matchInfo.localPlayer.playerId
        opponent.id = matchInfo.opposingPlayer.playerId
        logger.info("\(pname) [PlayerId=\(player.id)] vs \(oname) [PlayerId=\(opponent.id)]")
        // A Power.log replayed before the mirror answered was recorded without knowing whose cards were whose
        actionHistory.localPlayerDetermined(player.id)
    }
    
    private func getCurrentDeckIdIfAppropriate() -> String {
        if isTraditionalHearthstoneMatch {
            return currentDeck?.shortid ?? ""
        }
        return ""
    }
    
    private var lastGameStart = Date.distantPast
    func gameStart(at timestamp: LogDate) {
        invalidateMatchInfoCache()
        if currentGameMode == .practice && !isInMenu && !handledGameEnd
			&& lastGameStartTimestamp > LogDate(date: Date.distantPast)
            && timestamp > lastGameStartTimestamp {
            adventureRestart()
        }

        lastGameStartTimestamp = timestamp
        if lastGameStart > Date.distantPast
            && (abs(lastGameStart.timeIntervalSinceNow) < 5) {
            // game already started
            return
        }

        lastGameStart = Date()
        
        // remove every line before _last_ create game
        if let index = self.powerLog.reversed().firstIndex(where: { $0.line.contains("CREATE_GAME") }) {
            self.powerLog = self.powerLog.reversed()[...index].reversed() as [LogLine]
        } else {
            self.powerLog = []
        }
        
		gameEnded = false
        isInMenu = false
        handledGameEnd = false

        cacheMatchInfo()
        cacheGameType()
        cacheSpectator()
        
        accountId = MirrorHelper.getAccountId()

        logger.info("----- Game Started -----")
        logger.info("currentGameMode: \(currentGameMode), isInMenu: \(isInMenu), "
            + "handledGameEnd: \(handledGameEnd), "
            + "lastGameStartTimestamp: \(lastGameStartTimestamp), " +
            "timestamp: \(timestamp)")
        AppHealth.instance.setHearthstoneGameRunning(flag: true)

        NotificationManager.showNotification(type: .gameStart)

        if Settings.showTimer {
            self.turnTimer.start()
        }
        
        counterManager.reset()
        
        if isTraditionalHearthstoneMatch {
            CardLegalityChecker.loadCardsByFormat(gameType: currentGameType, format: currentFormatType)
            if #available(macOS 10.15, *) {
                RelatedCardsManager.loadRelatedCardsSummaryKeywords()
            }
        }

		// update spectator information
        if spectator || currentGameMode == .mercenaries { // no deck for mercenaries
            set(activeDeckId: nil, autoDetected: false)
        }
        
        if isMercenariesPveMatch() {
            _ = MercenariesCoins.update()
        }
        
        if isBattlegroundsMatch() {
            battlegroundsDetails = UploadMetaData.BattlegroundsLobbyDetails()
            DispatchQueue.main.async {
                self.updateBattlegroundsSessionPanel()
            }
        }
		
        updateTrackers(reset: true)

        self.startTime = Date()
        
        Influx.breadcrumb(eventName: "match_start", 
                          withProperties: ["gameMode": "\(self.currentGameMode)",
                                           "gameType": "\(self.currentGameType)",
                                           "spectator": "\(self.spectator)",
                                           "deckId": "\(self.getCurrentDeckIdIfAppropriate())"],
                          level: .info)
        
        windowManager.linkOpponentDeckPanel.isFriendlyMatch = isFriendlyMatch
        
        if isBattlegroundsMatch() && currentGameMode == .spectator, #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.tier7PreLobby.reset()
        }
        
        if isFriendlyMatch {
            if !Settings.interactedWithLinkOpponentDeck {
                windowManager.linkOpponentDeckPanel.autoShown = true
                windowManager.linkOpponentDeckPanel.show()
            }
        }
        
        if isBattlegroundsMatch() {
            updateBattlegroundsSessionPanel()
            if #available(macOS 10.15, *) {
                Task.detached {
                    await self.windowManager.rootOverlay?.viewModel.battlegroundsSession.updateCompositionStatsVisibility()
                }
                Task.detached {
                    await self.windowManager.rootOverlay?.viewModel.battlegroundsCompsGuides.onMatchStart()
                }
                Task.detached {
                    await self.windowManager.rootOverlay?.viewModel.battlegroundsHeroGuides.update()
                }
                Task.detached {
                    await self.windowManager.rootOverlay?.viewModel.battlegroundsTrinketGuides.update()
                }
                Task.detached {
                    await self.windowManager.rootOverlay?.viewModel.battlegroundsAnomalyGuides.update()
                }
                Task.detached {
                    await self.windowManager.rootOverlay?.viewModel.battlegroundsQuestGuides.update()
                }
                DispatchQueue.main.async {
                    self.windowManager.rootOverlay?.viewModel.battlegroundsMinionsGuide.onMatchStart()
                    // GameEventHandler's HandleGameStart calls
                    // BattlegroundsMinionPinningViewModel.Reset(), which re-arms
                    // the key-piece recommendations from the auto-enable setting.
                    self.windowManager.rootOverlay?.viewModel.battlegroundsMinionPinning.reset()
                }
            }
        }
    }

    private var _lastReconnectStartTimestamp: Date = Date.distantPast
    func handleGameReconnect(timestamp: Date) {
        // Before the async hop, so a game that ends right after the reconnect is still flagged
        mulliganRecorder.gameReconnected()
        DispatchQueue.global().async {
            logger.info("Joined after mulligan, assuming reconnect.")
            
            if DateInterval(start: self._lastReconnectStartTimestamp, end: Date()).duration < 5.0 { // game already started
                return
            }
            self._lastReconnectStartTimestamp = timestamp
            
            for _ in 0 ..< 20 where self.gameEntity == nil || self.currentMode != .gameplay {
                Thread.sleep(forTimeInterval: 0.5)
            }
            
            if self.gameEntity == nil || self.currentMode != .gameplay {
                return
            }

            self.restoreActionHistoryAfterReconnect()
            
            if self.isTraditionalHearthstoneMatch {
                CardLegalityChecker.loadCardsByFormat(gameType: self.currentGameType, format: self.currentFormatType)
                if #available(macOS 10.15, *) {
                    RelatedCardsManager.loadRelatedCardsSummaryKeywords()
                }
            }
            
            if self.isBattlegroundsMatch() {
                if (self.gameEntity?[.step] ?? 0) > Step.begin_mulligan.rawValue {
                    self.isReconnect = true
                    DispatchQueue.main.async {
                        self.updateBattlegroundsSessionPanel()
                    }
                    Watchers.battlegroundsLeaderboardWatcher.run()
                    Watchers.battlegroundsLobbyInfoWatcher.run()
                    if self.isBattlegroundsDuosMatch() {
                        Watchers.battlegroundsTeammateBoardStateWatcher.run()
                    }
                    self.updateBattlegroundsOverlays()
                }
            }
        }
    }

    // Hearthstone reset the game when it reconnected, which put the turns recorded so far aside.
    // The recorder matches them by opponent name, which is known only once the match info has been
    // read (updatePlayers) - the same source the name came from when the game was reset. That can
    // take as long as cacheMatchInfo keeps retrying (31 s), so this waits a little longer than it
    // does. A name that is still unknown leaves the saved turns in place rather than dropping them.
    private func restoreActionHistoryAfterReconnect() {
        DispatchQueue.global().async {
            for _ in 0 ..< 80 where self._matchInfoCacheInvalid || self._matchInfo == nil || (self.opponent.name ?? "").isBlank {
                Thread.sleep(forTimeInterval: 0.5)
            }
            self.actionHistory.restoreInterruptedIfReconnect(opponentName: self.opponent.name)
        }
    }

    private func adventureRestart() {
        // The game end is not logged in PowerTaskList
        logger.info("Adventure was restarted. Simulating game end.")
        concede()
        loss()
        gameEnd()
        inMenu()
    }

    func gameEnd() {
        logger.info("----- Game End -----")
        Influx.breadcrumb(eventName: "match_ended")
        AppHealth.instance.setHearthstoneGameRunning(flag: false)
		
        handleEndGame()
        self.powerLog = []

        isReconnect = false
        secretsManager?.reset()
        // Mirrors HDT clearing RelatedCardsSummaryKeywords at the end of a match, so entitlement
        // is re-checked next game rather than carrying stale keyword data forward.
        RelatedCardsManager.clearRelatedCardsSummaryKeywords()
        windowManager.hideGameTrackers()
        turnTimer.stop()
        updateTrackers(reset: true)
    }

    func inMenu() {
        if isInMenu {
            return
        }
        logger.verbose("Game is now in menu")

        turnTimer.stop()

        isInMenu = true
        updateActionHistory()
        // Drops the tracker's matchup line, which belongs to the match just left
        updateTrackers()
        
        DispatchQueue.main.async {
            self.updateMulliganGuidePreLobby()
        }
    }
	
	private func generateEndgameStatistics() -> InternalGameStats? {
		let result = InternalGameStats()
		
		result.startTime = self.startTime ?? Date()
		result.endTime = Date()
		
		result.playerHero = currentDeck?.playerClass ?? player.originalClass ?? .neutral
		result.opponentHero = opponent.originalClass ?? .neutral
        
        let oppHero = entities.values.first(where: { x in x[.player_id] == opponent.id && x.isHero })

        result.opponentHeroCardId = oppHero?.cardId
		
		result.wasConceded = self.wasConceded
		result.result = self.gameResult
		
        result.hearthstoneBuild = self.buildNumber
		result.season = Database.currentSeason
		
		if let name = self.player.name {
			result.playerName = name
		}
		// HDT sets Coin = !player.HasTag(FIRST_PLAYER). When the player entity is not
		// found, or neither player carries the tag, the turn order is unknown rather
		// than "went first". opponentEntity is only trustworthy once playerEntity is.
		let playerIsFirst = playerEntity.map { $0.has(tag: .first_player) }
		let opponentIsFirst = playerIsFirst == nil ? nil : opponentEntity.map { $0.has(tag: .first_player) }
		if let coin = StatsHelper.coin(playerIsFirst: playerIsFirst, opponentIsFirst: opponentIsFirst) {
			result.coin = coin
			result.coinKnown = true
		}
		
		if let name = self.opponent.name {
			result.opponentName = name
		} else if result.opponentHero != .neutral {
			result.opponentName = result.opponentHero.rawValue
		}
		
		result.turns = self.turnNumber()
		
		result.gameMode = self.currentGameMode
		result.format = self.currentFormat
		
		if let matchInfo = self.matchInfo, self.currentGameMode == .ranked {
			let wild = self.currentFormat == .wild
            let classic = self.currentFormat == .classic
            let twist = self.currentFormat == .twist
            
            let localPlayer = matchInfo.localPlayer
            let opposingPlayer = matchInfo.opposingPlayer
            
            let playerInfo = classic ? localPlayer.classicMedalInfo : wild ? localPlayer.wildMedalInfo : twist ? localPlayer.twistMedalInfo : localPlayer.standardMedalInfo
            let opponentInfo = classic ? opposingPlayer.classicMedalInfo : wild ? opposingPlayer.wildMedalInfo : twist ? opposingPlayer.twistMedalInfo : opposingPlayer.standardMedalInfo
            result.leagueId = playerInfo.leagueId
            if playerInfo.leagueId < 5 {
                result.rank = classic ? localPlayer.classicRank : wild ? localPlayer.wildRank : twist ? localPlayer.twistRank : localPlayer.standardRank
                result.opponentRank = classic ? opposingPlayer.classicRank : wild ? opposingPlayer.wildRank : twist ? opposingPlayer.twistRank : opposingPlayer.standardRank
            }
            result.starLevel = playerInfo.starLevel
            result.starMultiplier = playerInfo.starsPerWin
            result.stars = playerInfo.stars
            result.opponentStarLevel = opponentInfo.starLevel
            result.legendRank = playerInfo.legendRank
            result.opponentLegendRank = opponentInfo.legendRank
		} else if self.currentGameMode == .arena {
			result.arenaLosses = self.arenaInfo?.losses ?? 0
			result.arenaWins = self.arenaInfo?.wins ?? 0
		} else if self.currentGameMode == .brawl, let brawlInfo = self.brawlInfo {
			result.brawlWins = brawlInfo.wins
			result.brawlLosses = brawlInfo.losses
        } else if isBattlegroundsMatch(), let rating = self.currentBattlegroundsRating {
            result.battlegroundsRating = rating
        } else if isMercenariesMatch() {
            if isMercenariesPvpMatch(), let rating = self.mercenariesRating {
                result.mercenariesRating = rating
            }
            if isMercenariesPveMatch() {
                if let mapInfo = self.mercenariesMapInfo {
                    result.mercenariesBountyRunId = String(mapInfo.seed.intValue)
                    result.mercenariesBountyRunTurnsTaken = mapInfo.turnsTaken.intValue
                    result.mercenariesBountyRunCompletedNodes = mapInfo.completedNodes.intValue
                }
            }
            let delta = MercenariesCoins.update()
            if delta.count > 0 {
                result.mercenariesBountyRunRewards = delta
            }
        }
		
		result.gameType = self.currentGameType
		if let serverInfo = self.serverInfo {
			result.serverInfo = ServerInfo(info: serverInfo)
		}
		result.playerCardbackId = self.matchInfo?.localPlayer.cardBackId ?? 0
		result.opponentCardbackId = self.matchInfo?.opposingPlayer.cardBackId ?? 0
		result.friendlyPlayerId = self.matchInfo?.localPlayer.playerId ?? 0
        result.opposingPlayerId = self.matchInfo?.opposingPlayer.playerId ?? 0
		result.scenarioId = self.matchInfo?.missionId ?? 0
		result.brawlSeasonId = self.matchInfo?.brawlSeasonId ?? 0
		result.rankedSeasonId = self.matchInfo?.rankedSeasonId ?? 0
        
        let confirmedCards = self.player.revealedCards.filter { x in x.collectible } + self.player.knownCardsInDeck.filter { x in x.collectible && !x.isCreated }
        if let currentDeck, currentDeck.hsDeckId ?? 0 > 0 {
            result.hsDeckId = self.currentDeck?.hsDeckId
            result.setPlayerCards(currentDeck, confirmedCards)
            result.setPlayerSideboards(currentDeck.sideboards)
        }
        result.setOpponentCards(opponent.opponentCardList.filter { x in !x.isCreated })
		
        result.deckId = currentDeck?.id ?? ""
        result.mulligan = buildMulliganRecord()
        
        if isBattlegroundsMatch() {
            if let accountId {
                result.accountId = AccountId(hi: accountId.hi.int64Value, lo: accountId.lo.int64Value)
            }
            
            result.gameDurationSeconds = Int(result.endTime.timeIntervalSince(result.startTime))
            let hero = (playerEntity?[.hero_entity]).flatMap { entities[$0] }
            
            let finalPlacement = hero?[.player_leaderboard_place] ?? 0
            if battlegroundsDetails != nil {
                battlegroundsDetails?.anomaly_dbf_id = gameEntity?[.bacon_global_anomaly_dbid]
                battlegroundsDetails?.final_placement = finalPlacement
                
                battlegroundsDetails?.friendly_hero_raw_dbf_id = hero?.card.dbfId
                battlegroundsDetails?.friendly_player_entity_id = hero?.id
                
                let allHeroes = entities.values.filter { x in x.has(tag: .player_leaderboard_place) }
                for lobbyHero in allHeroes {
                    if battlegroundsDetails?.lobby_hero_dbf_ids == nil {
                        battlegroundsDetails?.lobby_hero_dbf_ids = [Int]()
                    }
                    battlegroundsDetails?.lobby_hero_dbf_ids?.append(lobbyHero.card.dbfId)
                }
                result.battlegroundsDetails = battlegroundsDetails
                result.battlegroundsDetails?.game_uuid = battlegroundsLobbyInfo?.gameUuid
                result.battlegroundsDetails?.lobby_players = battlegroundsLobbyInfo?.players.compactMap({ p in UploadMetaData.BattlegroundsLobbyStatePlayer(hero_card_id: p.heroCardId, player_name: p.name, account_hi: p.accountId.hi.int64Value, account_lo: p.accountId.lo.int64Value) })
            }
            result.battlegroundsRaces = self.availableRaces?.compactMap({ x in Race.allCases.firstIndex(of: x)}) ?? []

        }
		
		return result
	}

    /// Always consumes what the recorder collected, so the next game starts clean, but
    /// only constructed games keep it: Battlegrounds and Mercenaries have no mulligan of
    /// this kind, and a spectated game is not the user's (recordGame drops those anyway).
    func buildMulliganRecord() -> MulliganRecord? {
        let record = mulliganRecorder.buildRecord(localPlayerId: player.id) { id in entities[id] }
        guard !spectator && currentGameMode != .spectator && !isBattlegroundsMatch() && !isMercenariesMatch() else {
            return nil
        }
        if let currentDeck {
            // PlayingDeck.shortid holds DeckSerializer's deckstring, despite its name
            record.deckstring = currentDeck.shortid
            if currentDeck.shortid.isEmpty {
                for card in currentDeck.cards {
                    record.deckCards.append(RealmCard(id: card.id, count: card.count))
                }
            }
        }
        let offered: [String] = record.offered.map { "\($0.cardId)\($0.forced ? "(forced)" : "")\($0.kept ? "" : "(replaced)")" }
        logger.info("Mulligan record: status=\(record.status) offered=\(offered) replacements=\(Array(record.replacementCardIds)) draws=\(record.draws.count)")
        return record
    }

    func trackGameEnd() {
        if !(isConstructedMatch() || isBattlegroundsMatch() || isArenaMatch) {
            return
        }

        var properties: Properties = [
            "franchise": isBattlegroundsMatch() ? "Battlegrounds" : "HS-Constructed",
            "game_type": currentGameType.rawValue,
            // TODO: If we want to add more event tracking to HSTracker
            // move these into super properties that apply to every event
            // and are updated whenever they change
            "is_authenticated": HSReplayAPI.isFullyAuthenticated,
            "card_language": Settings.hearthstoneLanguage?.rawValue
        ]

        if isArenaMatch {
            properties["sub_franchise"] = ["Arena"]
        }

        MixpanelEvents.sendEvent(event: .EndMatch, properties: properties)
    }

    func handleEndGame() {
        // First, so an ended game is never mistaken for an interrupted one, even when no stats can be saved
        actionHistory.gameEnded()
		
		if self.handledGameEnd {
			logger.warning("HandleGameEnd was already called.")
			return
		}

		guard let currentGameStats = generateEndgameStatistics() else {
			logger.error("Error: could not generate endgame statistics")
			return
		}
		
		logger.verbose("currentGameStats: \(currentGameStats), "
			+ "handledGameEnd: \(self.handledGameEnd)")
		
        self.handledGameEnd = true
                
        // clear any left over hover
        DispatchQueue.main.async {
            self.windowManager.forceHideFloatingCard()
        }
        if currentGameStats.gameMode == .ranked {
            updatePostGameRanks(gameStats: currentGameStats)
        }
        logger.verbose("End game: \(currentGameStats)")
        let stats = currentGameStats.toGameStats()
        currentGameStats.withholdStalePostGameRank()
        invalidateMatchInfoCache()
        // reset the turn counter
        updateTurnCounter(turn: 1)
        
        trackGameEnd()

        if isMercenariesMatch() {
            updatePostGameMercenariesRating(gameStats: currentGameStats)
        }
        
        if isBattlegroundsMatch() {
            BobsBuddyInvoker.instance(gameId: gameId, turn: turnNumber())?.startShopping(isGameOver: true)
            OpponentDeadForTracker.reset()
            updatePostGameBattlegroundsRating(gameStats: currentGameStats)
            captureBattlegroundsGame(stats: currentGameStats)
            if #available(macOS 10.15, *) {
                windowManager.rootOverlay?.viewModel.battlegroundsHeroPicking.reset()
                windowManager.rootOverlay?.viewModel.battlegroundsQuestPicking.reset()
                windowManager.rootOverlay?.viewModel.battlegroundsTrinketPicking.reset()
                // GameEventHandler's IsBattlegroundsMatch branch clears the trial
                // once the match it was activated for is over, so the next game
                // has to spend a trial of its own rather than riding this token.
                Tier7Trial.clear()
                // These mutate @Published properties on ObservableObjects
                // (unlike the legacy KVO-based ViewModel.reset() calls
                // above), which Combine requires happen on the main thread.
                DispatchQueue.main.async {
                    // Drops the top bar itself, not just its contents: without this
                    // the guides panel survived the game-over screen and followed
                    // the player back to the main menu.
                    self.windowManager.rootOverlay?.viewModel.battlegroundsGuidesTabs.onMatchEnd()
                    self.windowManager.rootOverlay?.viewModel.battlegroundsCompsGuides.onMatchEnd()
                    self.windowManager.rootOverlay?.viewModel.battlegroundsHeroGuides.onMatchEnd()
                    self.windowManager.rootOverlay?.viewModel.battlegroundsQuestGuides.onMatchEnd()
                    self.windowManager.rootOverlay?.viewModel.battlegroundsMinionsGuide.onMatchEnd()
                    // HideBgsTopBar resets the Inspiration panel alongside the
                    // rest of the top bar, so it never carries a lineup - or its
                    // open state - into the next match.
                    self.windowManager.rootOverlay?.viewModel.battlegroundsInspiration.reset()
                    // HideBgsMinionPinning: pins never survive a match, and the
                    // panel goes with them.
                    self.windowManager.rootOverlay?.viewModel.battlegroundsMinionPinning.onMatchEnd()
                }
            }
            hideBattlegroundsHeroPanel()
            hideBattlegroundsTimewarpPanel()
        }
        if isTraditionalHearthstoneMatch {
            hideMulliganToast()
            DispatchQueue.main.async {
                self.player.mulliganCardStats = nil
                self.hideMulliganGuideStats()
            }
            if #available(macOS 10.15, *) {
                // Covers game-end paths that skip handlePlayerMulliganDone() entirely,
                // e.g. conceding mid-mulligan (mulligan_state never reaches .done, so
                // that cleanup never runs and the guide/live polling would otherwise
                // keep running with stale data after the match is over).
                stopMulliganLivePolling()
                DispatchQueue.main.async {
                    self.windowManager.rootOverlay?.viewModel.mulliganGuideV2.reset()
                }
                // HDT GameEventHandler.HandleGameEnd clears the trial status once a
                // constructed or arena match is over. Without it the count read
                // before the match (which activateOrContinue never decrements)
                // was all the lobby had, so the "trials exhausted" alert checked
                // a stale 1 and never showed.
                if isConstructedMatch() || isArenaMatch {
                    MulliganGuideTrial.clear()
                }
            }
            opponent.isPlayingWhizbang = false
            Player.knownOpponentDeck = nil
        }

        recordGame(stats: stats, gameStats: currentGameStats)
		
        if currentGameMode == .spectator && currentGameStats.result == .unknown {
            logger.info("Game was spectator mode without a game result."
                + " Probably exited spectator mode early.")
            return
        }

		self.syncStats(logLines: self.powerLog, stats: currentGameStats)
        
        if isBattlegroundsMatch() {
            recordBattlegroundsGame()
            if #available(macOS 10.15, *) {
                windowManager.rootOverlay?.viewModel.battlegroundsSession.onGameEnd()
            }
        }
        
        activeEffects.reset()
        counterManager.reset()
    }
    
    private func recordGame(stats: GameStats, gameStats: InternalGameStats) {
        var skip = false
        if previousMode == Mode.adventure {
            let heroId = adventureOpponentId
            // don't add the result to statistics for Bob encounters
            if heroId == CardIds.NonCollectible.Neutral.BartenderBob || heroId == CardIds.NonCollectible.Neutral.BazaarBob {
                skip = true
            }
        }
        // The game type is the reliable signal for Battlegrounds and Mercenaries; the
        // mode also covers spectating.
        let mode: GameMode = isBattlegroundsMatch() ? .battlegrounds : isMercenariesMatch() ? .mercenaries : gameStats.gameMode
        let persisted = currentDeck.flatMap { RealmHelper.getDeck(with: $0.id) }

        switch StatsHelper.recordDestination(mode: mode, isBobEncounter: skip,
                                             persistedDeckId: persisted?.deckId,
                                             playerClass: stats.playerHero) {
        case .deck:
            guard let deck = persisted else { return }
            stats.mulligan?.deckId = deck.deckId
            RealmHelper.addStatistics(to: deck, stats: stats)
            if Settings.autoArchiveArenaDeck &&
                self.currentGameMode == .arena && deck.isArena && deck.arenaFinished() {
                RealmHelper.set(deck: deck, active: false)
            }
        case .defaultDeck(let playerClass):
            // HDT GameEventHandler: no deck assigned -> DefaultDeckStats of the class.
            RealmHelper.addStatistics(toDefaultDeckFor: playerClass, stats: stats)
            logger.info("Recorded game without a saved deck as \(playerClass)")
        case .none:
            logger.info("Not recording game (mode \(mode), Bob encounter \(skip), class \(stats.playerHero))")
            return
        }
        RealmHelper.postGameStatsChanged()

        if StatsHelper.postGameRankLooksStale(result: stats.result, before: stats.rankBefore, after: stats.rankAfter) {
            recheckPostGameRank(statId: stats.statId, result: stats.result, format: gameStats.format,
                                before: stats.rankBefore, stored: stats.rankAfter)
        }
    }

    /// HDT UpdatePostGameRanks: once the game is over (STATE COMPLETE, where
    /// handleEndGame runs) Hearthstone's MedalInfo holds the post-game position.
    private func updatePostGameRanks(gameStats: InternalGameStats) {
        guard let after = readPostGameRank(format: gameStats.format) else {
            logger.warning("Could not get MedalInfo")
            return
        }
        gameStats.starLevelAfter = after.starLevel
        gameStats.starsAfter = after.stars
        gameStats.legendRankAfter = after.legendRank
    }

    private func readPostGameRank(format: Format?) -> RankSnapshot? {
        guard let medalData = UploadMetaData.retryWhileNull(f: MirrorHelper.getMedalData) else {
            return nil
        }
        let mirrorInfo: MirrorMedalInfo
        switch format {
        case .wild: mirrorInfo = medalData.wild
        case .classic: mirrorInfo = medalData.classic
        case .twist: mirrorInfo = medalData.twist
        default: mirrorInfo = medalData.standard
        }
        let info = MatchInfo.MedalInfo(mirrorMedalInfo: mirrorInfo)
        guard info.starLevel > 0 else {
            return nil
        }
        return RankSnapshot(leagueId: info.leagueId, starLevel: info.starLevel,
                            stars: info.stars, legendRank: info.legendRank)
    }

    /// The read in updatePostGameRanks can come back before the server's MedalInfo
    /// update has arrived. Keep reading for a few seconds off the log-reader queue
    /// and fix the stored game once the position moves, instead of holding up the
    /// end of the game.
    private func recheckPostGameRank(statId: String, result: GameResult, format: Format?, before: RankSnapshot?,
                                     stored: RankSnapshot?) {
        DispatchQueue.global(qos: .utility).async {
            var latest: RankSnapshot?
            for _ in 0 ..< 8 {
                Thread.sleep(forTimeInterval: 0.5)
                if let after = self.readPostGameRank(format: format) {
                    latest = after
                    if !StatsHelper.postGameRankLooksStale(result: result, before: before, after: after) {
                        break
                    }
                }
            }
            // Nothing to fix when the position never moved (a loss on a rank floor).
            guard let after = latest, after != stored else {
                return
            }
            logger.info("Post-game rank re-read: \(after)")
            RealmHelper.updateRankAfter(statId: statId, after: after)
            RealmHelper.postGameStatsChanged()
        }
    }

    private func updatePostGameBattlegroundsRating(gameStats: InternalGameStats) {
        if let data = UploadMetaData.retryWhileNull(f: MirrorHelper.getBattlegroundsRatingChange, tries: 5, delay: 500) {
            gameStats.battlegroundsRatingAfter = data.ratingNew.intValue
        } else {
            logger.warning("Could not get battlegrounds rating")
        }
    }

    private func updatePostGameMercenariesRating(gameStats: InternalGameStats) {
        if let data = UploadMetaData.retryWhileNull(f: MirrorHelper.getMercenariesRating) {
            gameStats.mercenariesRating = data
        } else {
            logger.warning("Could not get mercenaries rating")
        }
    }

    private func syncStats(logLines: [LogLine], stats: InternalGameStats) {

        guard currentGameMode != .practice && currentGameMode != .none && currentGameMode != .spectator else {
            logger.info("Game was in \(currentGameMode), don't send to third-party")
            return
        }

        if Settings.hsReplaySynchronizeMatches && (
            (stats.gameMode == .ranked &&
                Settings.hsReplayUploadRankedMatches) ||
            (stats.gameMode == .casual &&
                Settings.hsReplayUploadCasualMatches) ||
            (stats.gameMode == .arena &&
                Settings.hsReplayUploadArenaMatches) ||
            (stats.gameMode == .brawl &&
                Settings.hsReplayUploadBrawlMatches) ||
            (stats.gameMode == .practice &&
                Settings.hsReplayUploadAdventureMatches) ||
            (stats.gameMode == .friendly &&
                Settings.hsReplayUploadFriendlyMatches) ||
            (stats.gameMode == .spectator &&
                Settings.hsReplayUploadFriendlyMatches) ||
            (isBattlegroundsMatch() &&
                Settings.hsReplayUploadBattlegroundsMatches) ||
            (stats.gameMode == .duels &&
                Settings.hsReplayUploadDuelsMatches) ||
            (stats.gameMode == .mercenaries && Settings.hsReplayUploadMercenariesMatches)) {
            
            if shouldSuppressLog {
                logger.info("Reconnected Battlegrounds game detected; this log will likely be invalid.")
            }
			
            let (uploadMetaData, statId) = UploadMetaData.generate(stats: stats, buildNumber: self.buildNumber,
                                                                   game: self )
			
            let showUploadNotification = stats.gameMode == .practice || stats.gameMode == .arena || stats.gameMode == .brawl || stats.gameMode == .ranked || stats.gameMode == .friendly || stats.gameMode == .casual || stats.gameMode == .spectator || stats.gameMode == .duels
            HSReplayAPI.getUploadToken { _ in
                
                LogUploader.upload(logLines: logLines, buildNumber: self.buildNumber,
                                   metaData: (uploadMetaData, statId)) { result in
                    if case UploadResult.successful(let replayId) = result {
                        if stats.gameMode == .battlegrounds {
                            Sentry.sendQueuedBobsBuddyEvents(shortId: replayId)
                        }
                        if showUploadNotification {
                            NotificationManager.showNotification(type: .hsReplayPush(replayId: replayId))
                        }
                        NotificationCenter.default
                            .post(name: Notification.Name(rawValue: Events.reload_decks), object: nil)
                    } else if case UploadResult.failed(let error) = result {
                        if stats.gameMode == .battlegrounds {
                            Sentry.sendQueuedBobsBuddyEvents(shortId: nil)
                        }
                        if showUploadNotification {
                            NotificationManager.showNotification(type: .hsReplayUploadFailed(error: error))
                        }
                    }
                }
            }
        } else {
            if stats.gameMode == .battlegrounds {
                Sentry.sendQueuedBobsBuddyEvents(shortId: nil)
            }
        }
    }
    
    private class PendingBattlegroundsGame {
        init(stats: InternalGameStats, heroCardId: String, placement: Int, finalBoard: [Entity], friendlyGame: Bool, duos: Bool) {
            self.stats = stats
            self.heroCardId = heroCardId
            self.placement = placement
            self.finalBoard = finalBoard
            self.friendlyGame = friendlyGame
            self.duos = duos
        }
        
        let stats: InternalGameStats
        let heroCardId: String
        let placement: Int
        let finalBoard: [Entity]
        let friendlyGame: Bool
        let duos: Bool
    }

    // Capture entity-derived data before the SaveReplays await, since a return to menu or
    // the next game start can clear _game.Entities (and reset the game type) meanwhile.
    private func captureBattlegroundsGame(stats: InternalGameStats) {
        _pendingBattlegroundsGame = nil
        
        if spectator {
            return
        }
        
        let hero = (playerEntity?[.hero_entity]).flatMap { entities[$0] }
        let heroCardId = hero?.cardId != nil ? BattlegroundsUtils.getOriginalHeroId(heroId: hero?.cardId ?? "") : nil
        let duos = isBattlegroundsDuosMatch()
        let placement = min(hero?[.player_leaderboard_place] ?? 0, duos ? 4 : 8)
        guard let heroCardId, placement > 0 else {
            logger.error("Missing data while trying to record battleground game")
            return
        }
        let finalBoard = entities.values.filter({ x in x.isMinion && x.isInZone(zone: .play) && x.isControlled(by: player.id)}).compactMap({ x in x.copy() }).sorted(by: { x, y in
            x[.zone_position] < y[.zone_position]
        })
        let friendlyGame = currentGameType == .gt_battlegrounds_friendly || currentGameType == .gt_battlegrounds_duo_friendly
        _pendingBattlegroundsGame = PendingBattlegroundsGame(stats: stats, heroCardId: heroCardId, placement: placement, finalBoard: finalBoard, friendlyGame: friendlyGame, duos: duos)
    }
    
    // Persist the captured game once SaveReplays has populated the post-game rating.
    func recordBattlegroundsGame() {
        guard let pending = _pendingBattlegroundsGame else {
            return
        }
        _pendingBattlegroundsGame = nil
        BattlegroundsLastGames.instance.addGame(startTime: pending.stats.startTime, endTime: pending.stats.endTime, hero: pending.heroCardId, rating: pending.stats.battlegroundsRating, ratingAfter: pending.stats.battlegroundsRatingAfter, placement: pending.placement, finalBoard: pending.finalBoard, friendlyGame: pending.friendlyGame, duos: pending.duos)
        updateBattlegroundsSessionPanel()
    }

    func turnNumber() -> Int {
        if !isMulliganDone() {
            return 0
        }
        if let gameEntity = self.gameEntity {
            return (gameEntity[.turn] + 1) / 2
        }
        return 0
    }
    
    // return raw turn number, needed for BG
    func turn() -> Int {
        if let gameEntity = self.gameEntity {
            return gameEntity[.turn]
        }
        return 0
    }
    
    var currentTurnActivePlayer: PlayerType {playerEntity?.isCurrentPlayer == true ? PlayerType.player : PlayerType.opponent }

    func turnsInPlayChange(entity: Entity, turn: Int) {
        if playerEntity == nil {
            return
        }

        if entity.isHero {
            let player = currentTurnActivePlayer
            if lastTurnStart[player.rawValue] >= turn {
                return
            }
            lastTurnStart[player.rawValue] = turn
            turnStart(player: player, turn: turn)
            return
        }
        secretsManager?.handleTurnsInPlayChange(entity: entity, turn: turn)
    }

    func turnStart(player: PlayerType, turn: Int) {
        if !isMulliganDone() {
            logger.info("--- Mulligan ---")
        }
        var turnNumber = turn
        if turnNumber == 0 {
            turnNumber += 1
        }
        turnQueue.insert(PlayerTurn(player: player, turn: turn))

        DispatchQueue.global().async {
            while !self.isMulliganDone() {
                Thread.sleep(forTimeInterval: 0.1)
            }
            while let playerTurn = self.turnQueue.popFirst() {
                self.handleTurnStart(playerTurn: playerTurn)
            }
        }
    }

    func handleTurnStart(playerTurn: PlayerTurn) {
        let player = playerTurn.player
        if Settings.fullGameLog {
            logger.info("Turn \(playerTurn.turn) start for player \(player) ")
        }

        if player == .player {
            handleOpponentEndOfTurn(playerTurn.turn - 1)
            opponent.onTurnEnd()
            secretsManager?.handlePlayerTurnStart()
        } else {
            handlePlayerEndOfTurn(playerTurn.turn - 1)
            self.player.onTurnEnd()
            secretsManager?.handleOpponentTurnStart()
        }

        if turnQueue.count > 0 {
            return
        }

        var timeout = -1
        if player == .player && ((playerEntity?.has(tag: .timeout)) != nil) {
            timeout = playerEntity![.timeout]
        } else if player == .opponent && ((opponentEntity?.has(tag: .timeout)) != nil) {
            timeout = opponentEntity![.timeout]
        }
		
        turnTimer.startTurn(for: player, timeout: timeout)

        if player == .player && !isInMenu {
            // Clear some state that should never be active at the start of a turn in case another hiding mechanism fails
            DispatchQueue.main.async {
                // Clear some state that should never be active at the start of a turn in case another hiding mechanism fails
                self.hideMulliganGuideStats()
                self.player.mulliganCardStats = nil
                
                if #available(macOS 10.15, *) {
                    self.windowManager.rootOverlay?.viewModel.battlegroundsHeroPicking.reset()
                    self.windowManager.rootOverlay?.viewModel.battlegroundsQuestPicking.reset()
                    self.windowManager.rootOverlay?.viewModel.battlegroundsTrinketPicking.reset()
                }
                self.hideBattlegroundsHeroPanel()
                self.hideBattlegroundsTimewarpPanel()
                self.updateBattlegroundsSessionPanel()
            }
            
            if isBattlegroundsMatch() {
                DispatchQueue.main.async { [self] in
                    self.primaryPlayerId = self.player.id
                    self.isBattlegroundsCombatPhase = false
                    self.onBattlegroundsShoppingStart()
                    OpponentDeadForTracker.shoppingStarted(game: self)
                    BobsBuddyInvoker.instance(gameId: self.gameId, turn: self.turnNumber() - 1)?.startShopping()
                    let heroPowerIds = self.player.board.filter { x in x.isHeroPower }.compactMap { x in x.cardId }
                    let trinketIds = self.player.trinkets.compactMap({ x in x.cardId })
                    self.battlegroundsMinionsOnHeroPowers(heroPowerIds)
                    self.battlegroundsMinionsOnTrinkets(trinketIds)
                    if #available(macOS 10.15, *) {
                        // From here until combat, the board the Inspiration panel
                        // sends alongside a key minion is the live one.
                        self.windowManager.rootOverlay?.viewModel.battlegroundsInspiration.onShoppingStart()
                        // OnBattlegroundsShoppingStart also reveals the Tavern
                        // Pinning shop markers; both combat-setup transitions
                        // hide them again (see TagChangeActions).
                        self.windowManager.rootOverlay?.viewModel.battlegroundsMinionPinning.setShopVisible(true)
                    }
                }
            }

            NotificationManager.showNotification(type: .turnStart)
        }
        
        // GameEventHandler's opponent-turn branch: shopping is over, so the
        // Inspiration panel freezes the board it will keep sending for the rest
        // of this turn. Solo only, as in HDT - a duos board changes hands.
        if player == .opponent && !isInMenu && isBattlegroundsSoloMatch() {
            if #available(macOS 10.15, *) {
                DispatchQueue.main.async {
                    self.windowManager.rootOverlay?.viewModel.battlegroundsInspiration.onShoppingEnd()
                }
            }
        }

        updateTurnCounter(turn: turnNumber())
        
        updateTrackers()
    }
    
    private func handlePlayerEndOfTurn(_ turn: Int) {
        handleIncidiusEndOfTurn(isOpponent: false, turn: turn)
    }
    
    private func handleOpponentEndOfTurn(_  turn: Int) {
        handleThaurissanCostReduction()
        handleIncidiusEndOfTurn(isOpponent: true, turn: turn)
    }
    
    func handleThaurissanCostReduction() {
        let thaurissans = opponent.board.filter { x in
            (x.cardId == CardIds.Collectible.Neutral.EmperorThaurissan || x.cardId == CardIds.Collectible.Neutral.EmperorThaurissanWONDERS) && !x.has(tag: .silenced)
        }
        if thaurissans.isEmpty {
            return
        }

        handleOpponentHandCostReduction(value: thaurissans.count)
    }
    
    private func handleIncidiusEndOfTurn(isOpponent: Bool, turn: Int) {
        let player = isOpponent ? opponent : player
        guard let incidiusEntities = player?.board.filter({ x in x.cardId == CardIds.Collectible.Neutral.Incindius }), incidiusEntities.count > 0 else {
            return
        }
        
        guard let eruptions = player?.deck.filter({ x in x.cardId == CardIds.NonCollectible.Neutral.Incindius_EruptionToken }), eruptions.count > 0 else {
            return
        }
        
        for _ in incidiusEntities {
            for entity in eruptions {
                if let counter = entity.info.extraInfo as? IncindiusCounter {
                    counter.counter += 1
                } else {
                    entity.info.extraInfo = IncindiusCounter(turn)
                }
            }
        }
        
        if isOpponent {
            updateOpponentTracker()
        } else {
            updatePlayerTracker()
        }
    }

    func concede() {
        logger.info("Game has been conceded : (")
        self.wasConceded = true
    }

    func win() {
        logger.info("You win ¯\\_(ツ) _ / ¯")
        self.gameResult = .win

        if self.wasConceded {
            NotificationManager.showNotification(type: .opponentConcede)
        }
    }

    func loss() {
        logger.info("You lose : (")
        self.gameResult = .loss
    }

    func tied() {
        logger.info("You lose : ( / game tied: (")
        self.gameResult = .draw
    }

    func isBattlegroundsMatch() -> Bool {
        return isBattlegroundsSoloMatch() || isBattlegroundsDuosMatch()
    }
    
    func isBattlegroundsSoloMatch() -> Bool {
        return isSoloBattlegroundsGameType(currentGameType)
    }
    
    func isSoloBattlegroundsGameType(_ currentGameType: GameType) -> Bool {
        return currentGameType == .gt_battlegrounds || currentGameType == .gt_battlegrounds_friendly || currentGameType == .gt_battlegrounds_ai_vs_ai || currentGameType == .gt_battlegrounds_player_vs_ai
    }
    
    func isBattlegroundsDuosMatch() -> Bool {
        return currentGameType == .gt_battlegrounds_duo || currentGameType == .gt_battlegrounds_duo_vs_ai || currentGameType == .gt_battlegrounds_duo_friendly || currentGameType == .gt_battlegrounds_duo_ai_vs_ai
    }
    
    var isTraditionalHearthstoneMatch: Bool {
        return currentGameType != .gt_unknown && !isBattlegroundsMatch() && !isMercenariesMatch()
    }
    
    var currentBattlegroundsRating: Int? {
        return isBattlegroundsMatch() ? isBattlegroundsDuosMatch() ? battlegroundsRatingInfo?.duosRating.intValue : battlegroundsRatingInfo?.rating.intValue : nil
    }
    
    var isFriendlyMatch: Bool { return currentGameType == .gt_vs_friend }
    
    var isArenaMatch: Bool { return currentGameType == .gt_arena || currentGameType == .gt_underground_arena }
    
    func isAnyBattlegroundsSessionSettingActive() -> Bool {
        return Settings.showMinionsSection || Settings.showMMR || Settings.showLatestGames
    }
    
    func isMercenariesMatch() -> Bool {
        return currentGameType == .gt_mercenaries_ai_vs_ai || currentGameType == .gt_mercenaries_friendly || currentGameType == .gt_mercenaries_pve || currentGameType == .gt_mercenaries_pvp || currentGameType == .gt_mercenaries_pve_coop
    }
    
    func isMercenariesPvpMatch() -> Bool {
        return currentGameType == .gt_mercenaries_pvp
    }
    
    func isMercenariesPveMatch() -> Bool {
        return currentGameType == .gt_mercenaries_pve || currentGameType == .gt_mercenaries_pve_coop
    }
    
    func isConstructedMatch() -> Bool {
        return currentGameType == .gt_ranked || currentGameType == .gt_casual || currentGameType == .gt_vs_friend || currentGameType == .gt_vs_ai 
    }
    
    // Mirrors HDT's GameV2.IsBattlegroundsHeroPickingDone: the player's own
    // mulligan (which in Battlegrounds is the hero pick) has resolved. Unlike
    // isMulliganDone below it deliberately ignores the opponent, who in
    // Battlegrounds is Bob.
    var isBattlegroundsHeroPickingDone: Bool {
        guard isBattlegroundsMatch() else { return false }
        guard let player = entities.map({ $0.1 })
            .filter({ $0.isPlayer(eventHandler: self) })
            .sorted(by: { $0.id < $1.id }).first else { return false }
        return player[.mulligan_state] == Mulligan.done.rawValue
    }

    func isMulliganDone() -> Bool {
        if isBattlegroundsMatch() {
                return true
        }
        let player = entities.map { $0.1 }.filter { $0.isPlayer(eventHandler: self) }.sorted(by: { $0.id < $1.id }).first
        let opponent = entities.map { $0.1 }
            .filter { $0.has(tag: .player_id) && !$0.isPlayer(eventHandler: self) }.sorted(by: { $0.id < $1.id }).first

        if let player = player, let opponent = opponent {
            return player[.mulligan_state] == Mulligan.done.rawValue
                && opponent[.mulligan_state] == Mulligan.done.rawValue
        }
        return false
    }

    func handlePlayerDredge() {
        updatePlayerTracker()
    }
    
    func handlePlayerUnknownCardAddedToDeck() {
        for card in player.deck {
            card.info.deckIndex = 0
        }
    }
    
    func handlePlayerHandCostReduction(value: Int) {
        for card in player.hand {
            card.info.costReduction += value
        }
    }
    
    func handleOpponentHandCostReduction(value: Int) {
        for card in opponent.hand {
            card.info.costReduction += value
        }
    }
    
    func handleChameleosReveal(cardId: String) {
        self.opponent.predictUniqueCardInDeck(cardId: cardId, isCreated: false)
        self.updateOpponentTracker()
    }
    
    func handleEntityLostArmor(entity: Entity, value: Int) {
        if playerEntity?.isCurrentPlayer ?? false {
            secretsManager?.handleEntityLostArmor(entity: entity, value: value)
        }
    }
    
    func handleMercenariesStateChange() {
        updateBoardOverlay()
    }
    
    func handleCardCopy() {
        self.updateOpponentTracker()
    }
    
    func set(buildNumber: Int) {
        self.buildNumber = buildNumber
    }
    
    func add(playerName: String, for ID: Int) {
        self.playerIDNameMapping[ID] = playerName
    }
    
    func playerName(for ID: Int) -> String? {
        return self.playerIDNameMapping[ID]
    }
    
    // MARK: - player
    func set(playerHero cardId: String) {
        if let card = Cards.hero(byId: cardId) {
            player.originalClass = card.playerClass
            player.currentClass = player.originalClass
            player.playerClassId = cardId
            
            if player.isPlayingWhizbang && currentDeck == nil, let whizbangDeck = WhizbangDecks.splendiferousWhizbangDecks[card.playerClass] {
                    let ret = Deck()
                    ret.name = "\(card.playerClass.rawValue) Splendiferous Whizbang Deck"
                    ret.heroId = card.playerClass.defaultHeroCardId
                    
                    let counts = whizbangDeck.reduce(into: [:]) { counts, element in
                        counts[element, default: 0] += 1
                    }
                    let tmpCards = counts.compactMap { (key: String, value: Int) -> RealmCard? in
                        guard let card = Cards.any(byId: key) else {
                            return nil
                        }
                        let res = RealmCard()
                        res.id = card.id
                        res.count = value
                        return res
                    }
                    for tmpCard in tmpCards {
                        ret.cards.append(tmpCard)
                    }
                    set(activeDeck: ret, autoDetected: true)
            }
            if Settings.fullGameLog {
                logger.info("Player class is \(card) ")
            }
        }
    }

    func set(playerName name: String) {
        player.name = name
    }

    func playerGet(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        player.createInHand(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerBackToHand(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        updateTrackers()
        player.boardToHand(entity: entity, turn: turn)
    }

    func playerPlayToDeck(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        player.boardToDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerPlay(entity: Entity, cardId: String?, turn: Int, parentCardId: String, targetEntityId: Int?) {
        if cardId.isBlank {
            return
        }
        
        player.play(entity: entity, turn: turn)
        if let cardId = cardId, !cardId.isEmpty {
            playedCards.append(PlayedCard(player: .player, cardId: cardId, turn: turn))
        }

        secretsManager?.handleCardPlayed(entity: entity, parentCardId: parentCardId, targetEntityId: targetEntityId)
        updateTrackers()
    }
    
    func playerSecretTrigger(entity: Entity, cardId: String?, turn: Int, otherId: Int) {
        if !entity.isSecret {
            return
        }
        player.secretTriggered(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerHandDiscard(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        player.handDiscard(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerSecretPlayed(entity: Entity, cardId: String?, turn: Int, fromZone: Zone, parentCardId: String) {
        if cardId.isBlank { return }

        if !entity.isSecret {
            if entity.isQuest  && !entity.isQuestlinePart || entity.isSideQuest {
                player.questPlayedFromHand(entity: entity, turn: turn)
            } else if entity.isSigil {
                player.sigilPlayedFromHand(entity: entity, turn: turn)
            } else if entity.isObjective {
                player.objectivePlayedFromHand(entity: entity, turn: turn)
            }
            // HDT returns here, but these are played cards for the "three cards" secrets and Azerite Vein
            if fromZone == .hand {
                secretsManager?.handleQuestPlayed(entity: entity)
            }
            return
        }

        switch fromZone {
        case .deck:
            player.secretPlayedFromDeck(entity: entity, turn: turn)
        case .hand:
            player.secretPlayedFromHand(entity: entity, turn: turn)
            secretsManager?.handleCardPlayed(entity: entity, parentCardId: parentCardId)
        default:
            player.createInSecret(entity: entity, turn: turn)
            return
        }
        updateTrackers()
    }
    
    func handlePlayerLibramReduction(change: Int) {
        player.updateLibramReduction(change: change)
    }
    
    func handleOpponentLibramReduction(change: Int) {
        opponent.updateLibramReduction(change: change)
    }
    
    func resetOpponentHandCostReduction() {
        for card in opponent.hand {
            card.info.costReduction = 0
        }
    }
    
    func handlePlayerAbyssalCurse(value: Int) {
        player.updateAbyssalCurse(value: value)
    }
    
    func handleOpponentAbyssalCurse(value: Int) {
        opponent.updateAbyssalCurse(value: value)
    }
    
    func handlePlayerTechLevel(entity: Entity, techLevel: Int) {
        guard techLevel >= 1 && techLevel <= 6 else { return }
        
        let playerId = entity[.player_id]
        
        if playerId > 0 {
            _battlegroundsBoardState?.handlePlayerTechLevel(playerId, techLevel)
        }
    }
    
    func handlePlayerTriples(entity: Entity, triples: Int) {
        guard triples > 0 else { return }
        let techLevel = entity[.player_tech_level]
        guard techLevel >= 1 && techLevel <= 6 else { return }
        
        let playerId = entity[.player_id]
        
        if playerId > 0 {
            _battlegroundsBoardState?.handlePlayerTriples(playerId, techLevel, triples)
        }
    }
    
    func handlePlayerBuddiesGained(entity: Entity, num: Int) {
        guard num > 0 else { return }
        
        let playerId = entity[.player_id]
        
        if playerId > 0 {
            _battlegroundsBoardState?.handlePlayerBuddiesGained(playerId, num)
        }
    }
    
    func handlePlayerHeroPowerQuestRewardDatabaseId(entity: Entity, num: Int) {
        guard num > 0 else { return }

        let playerId = entity[.player_id]
        
        if playerId > 0 {
            _battlegroundsBoardState?.handlePlayerHeroPowerQuestRewardDatabaseId(playerId, num)
        }
    }
    
    func handlePlayerHeroPowerQuestRewardCompleted(entity: Entity, num: Int) {
        guard num > 0 else { return }

        let playerId = entity[.player_id]

        if playerId > 0 {
            _battlegroundsBoardState?.handlePlayerHeroPowerQuestRewardCompleted(playerId)
        }
    }
    
    func handlePlayerHeroQuestRewardDatabaseId(entity: Entity, num: Int) {
        guard num > 0 else { return }
        
        let playerId = entity[.player_id]
        
        if playerId > 0 {
            _battlegroundsBoardState?.handlePlayerHeroQuestRewardDatabaseId(playerId, num)
        }
    }
    
    func handlePlayerHeroQuestRewardCompleted(entity: Entity, num: Int) {
        guard num > 0 else { return }
        
        let playerId = entity[.player_id]
        
        if playerId > 0 {
            _battlegroundsBoardState?.handlePlayerHeroQuestRewardCompleted(playerId)
        }
    }
    
    @available(macOS 10.15.0, *)
    private func getBattlegroundsHeroPickStats() async -> BattlegroundsHeroPickStats? {
        if spectator {
            return nil
        }

        if !Settings.enableTier7Overlay {
            return nil
        }

        if RemoteConfig.data?.tier7?.disabled ?? false {
            // TODO: fix me
            //throw new HeroPickingDisabledException("Hero picking remotely disabled")
            return nil
        }

        let userOwnsTier7 = HSReplayAPI.accountData?.is_tier7 ?? false
        if !userOwnsTier7 && (Tier7Trial.remainingTrials ?? 0) == 0 {
            return nil
        }

        let parameters = getBattlegroundsHeroPickParams()

        // Avoid using a trial when we can't get the api params anyway.
        guard let parameters else {
            // FIXME: todo 
            //throw new HeroPickingException("Unable to get API parameters")
            return nil
        }

        // Use a trial if we can
        var token: String?
        if !userOwnsTier7 {
            if let acc = MirrorHelper.getAccountId() {
                token = await Tier7Trial.activate(hi: acc.hi.int64Value, lo: acc.lo.int64Value)
            }
            if token == nil {
                // FIXME: add
                //throw new HeroPickingException("Unable to get trial token")
                return nil
            }
        }

#if(DEBUG)
        logger.debug("Fetching Battlegrounds Hero Pick stats with parameters=\(parameters)...")
#endif

        // At this point the user either owns tier7 or has an active trial!

        let isDuos = isBattlegroundsDuosMatch()
        
        let stats = (token != nil && !userOwnsTier7) ?
            // trial
            isDuos ? await HSReplayAPI.getTier7DuosHeroPickStats(token: token, parameters: parameters) : await HSReplayAPI.getTier7HeroPickStats(token: token, parameters: parameters) :
            // tier 7
            isDuos ? await HSReplayAPI.getTier7DuosHeroPickStats(parameters: parameters) : await HSReplayAPI.getTier7HeroPickStats(parameters: parameters)

        if stats == nil {
            // FIXME: add
            //throw new HeroPickingException("Invalid server response")
        }

        return stats
    }
    
    private var battlegroundsHeroPickingLatch = 0
    
    @available(macOS 10.15.0, *) @MainActor
    private func refreshBattlegroundsHeroPickStats() async {
        let heroes = player.playerEntities.filter { x in x.isHero && (x.has(tag: .bacon_hero_can_be_drafted) || x.has(tag: .bacon_skin)) && !x.has(tag: .bacon_locked_mulligan_hero) }

        // refresh the offered heroes
        snapshotBattlegroundsOfferedHeroes(heroes)
        cacheBattlegroundsHeroPickParams(true)

        defer {
            battlegroundsHeroPickingLatch -= 1
        }
        
        battlegroundsHeroPickingLatch += 1
        let latchOut = battlegroundsHeroPickingLatch
        var battlegroundsHeroPickStats: BattlegroundsHeroPickStats?
        battlegroundsHeroPickStats = await getBattlegroundsHeroPickStats()

        // another task has updated them since (fast reroll)
        if latchOut != battlegroundsHeroPickingLatch {
            return
        }

        // the stats are no longer relevant
        if gameEntity?[.step] ?? 0 > Step.begin_mulligan.rawValue || isInMenu || windowManager.rootOverlay?.viewModel.battlegroundsHeroPicking.heroStats == nil {
            return
        }

        if let stats = battlegroundsHeroPickStats {
            let heroIds = heroes.sorted(by: { (a, b) -> Bool in return a.zonePosition < b.zonePosition }).compactMap { x in x.card.dbfId }
            DispatchQueue.main.async { [self] in
                self.showBattlegroundsHeroPickingStats(heroIds.compactMap({ dbfId in stats.data.first { x in x.hero_dbf_id == dbfId }}), stats.toast.parameters, stats.toast.min_mmr, stats.toast.anomaly_adjusted ?? false)
                self.showBattlegroundsHeroPanel(heroIds, self.isBattlegroundsDuosMatch(), stats.toast.parameters)
            }
        }
    }
    
    public func handleBattlegroundsHeroReroll(entity: Entity, oldCardId: String?) {
        if isBattlegroundsMatch() {
            if #available(macOS 10.15, *) {
                Task.detached { @MainActor in
                    if let cardId = oldCardId, let theDbfId = Cards.by(cardId: cardId)?.dbfId {
                        self.windowManager.rootOverlay?.viewModel.battlegroundsHeroPicking.invalidateSingleHeroStats(theDbfId)
                    }
                    await self.refreshBattlegroundsHeroPickStats()
                }
            }
        }
    }
    
    private var _battlegroundsHeroPickStatsParams: BattlegroundsHeroPickStatsParams?
    
    func cacheBattlegroundsHeroPickParams(_ isReroll: Bool) {
        if let _battlegroundsHeroPickStatsParams {
            // Already set? Probably a reroll - just update the hero dbf ids
            guard let newHeroDbfIds = battlegroundsHeroPickState.offeredHeroDbfIds else {
                return
            }

            self._battlegroundsHeroPickStatsParams = BattlegroundsHeroPickStatsParams(hero_dbf_ids: newHeroDbfIds, minion_types: _battlegroundsHeroPickStatsParams.minion_types, anomaly_dbf_id: BattlegroundsUtils.getBattlegroundsAnomalyDbfId(game: gameEntity), game_language: "\(Settings.hearthstoneLanguage ?? .enUS)", battlegrounds_rating: battlegroundsRatingInfo?.rating.intValue, is_reroll: isReroll)
            return
        }

        guard let availableRaces else {
            return
        }

        guard let heroDbfIds = battlegroundsHeroPickState.offeredHeroDbfIds else {
            return
        }

        _battlegroundsHeroPickStatsParams = BattlegroundsHeroPickStatsParams(hero_dbf_ids: heroDbfIds, minion_types: availableRaces.compactMap { x in Int(Race.allCases.firstIndex(of: x)!) }, anomaly_dbf_id: BattlegroundsUtils.getBattlegroundsAnomalyDbfId(game: gameEntity), game_language: "\(Settings.hearthstoneLanguage ?? .enUS)", battlegrounds_rating: battlegroundsRatingInfo?.rating.intValue, is_reroll: isReroll)
    }
    
    private func getBattlegroundsHeroPickParams() -> BattlegroundsHeroPickStatsParams? {
        return _battlegroundsHeroPickStatsParams
    }
    
    private var _battlegroundsHeroPickState: BattlegroundsHeroPickState?
    private var battlegroundsHeroPickState: BattlegroundsHeroPickState {
        if let state = _battlegroundsHeroPickState {
            return state
        }
        let state = BattlegroundsHeroPickState(self)
        _battlegroundsHeroPickState = state

        return state
    }
    
    func snapshotBattlegroundsOfferedHeroes(_ heroes: [Entity]) {
        _ = battlegroundsHeroPickState.snapshotOfferedHeroes(heroes)
    }
    @discardableResult
    func snapshotBattlegroundsHeroPick() -> Int? {
        return battlegroundsHeroPickState.snapshotPickedHero()
    }
    
    @MainActor
    private func showBattlegroundsHeroPickingStats(_ heroStats: [BattlegroundsHeroPickStats.BattlegroundsSingleHeroPickStats], _ parameters: [String: String]?, _ minMmr: Int?, _ anomalyAdjusted: Bool) {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.battlegroundsHeroPicking.setHeroStats(stats: heroStats, parameters: parameters, minMmr: minMmr, anomalyadjusted: anomalyAdjusted)
        }
    }
    
    @available(macOS 10.15.0, *)
    private func waitForMulliganStart(_ timeout: Int = 60) async {
        for _ in 0 ..< 16*60*timeout {
            if isInMenu || (gameEntity?[.step] ?? 0) > Step.begin_mulligan.rawValue {
                return
            }
            if MirrorHelper.isMulliganWaitingForUserInput() {
                break
            }
            do {
                try await Task.sleep(nanoseconds: 16_000_000)
            } catch {
                logger.error(error)
            }
        }
    }
    
    @available(macOS 10.15.0, *) @MainActor
    private func handleBattlegroundsStart() async {
        Watchers.battlegroundsLeaderboardWatcher.run()
        Watchers.battlegroundsLobbyInfoWatcher.run()
        OpponentDeadForTracker.reset()
        if #available(macOS 10.15, *) {
            await MainActor.run {
                self.windowManager.rootOverlay?.viewModel.battlegroundsInspiration.reset()
            }
        }
        var heroes = [Entity]()
        for _ in 0 ..< 10 {
            await Task.sleep(milliseconds: 500)
            heroes = player.playerEntities.filter { x in x.isHero && (x.has(tag: .bacon_hero_can_be_drafted) || x.has(tag: .bacon_skin)) && !x.has(tag: .bacon_locked_mulligan_hero)}
            if heroes.count >= 2 {
                break
            }
        }

        await Task.sleep(milliseconds: 500)
        
        var counter = 0
        while availableRaces == nil && counter < 5 {
            await Task.sleep(milliseconds: 500)
            counter += 1
        }
        
        updateBattlegroundsSessionPanel()
        
        if isBattlegroundsDuosMatch() {
            Watchers.battlegroundsTeammateBoardStateWatcher.run()
        }
        
        if gameEntity?[.step] != Step.begin_mulligan.rawValue {
            return
        }

        snapshotBattlegroundsOfferedHeroes(heroes)
        cacheBattlegroundsHeroPickParams(false)

        let heroIds = heroes.sorted(by: { (a, b) -> Bool in a.zonePosition < b.zonePosition }).compactMap { x in x.card.dbfId }
            
        async let statsTask = getBattlegroundsHeroPickStats()
                
        // Wait for the mulligan to be ready
        await waitForMulliganStart()
        
        async let waitAndAppear: () = Task.sleep(milliseconds: 500)
        
        var battlegroundsHeroPickStats: BattlegroundsHeroPickStats?
        
        let (finalResults, _) = await (statsTask, waitAndAppear)
        battlegroundsHeroPickStats = finalResults
            
        var toastParams: [String: String]?
            
        if let stats = battlegroundsHeroPickStats {
            toastParams = stats.toast.parameters
            DispatchQueue.main.async {
                self.showBattlegroundsHeroPickingStats(heroIds.compactMap { dbfId in stats.data.first { x in x.hero_dbf_id == dbfId }}, stats.toast.parameters, stats.toast.min_mmr, stats.toast.anomaly_adjusted ?? false)
            }
        }
        // TODO: handle errors, exceptions
            
        if Settings.showHeroToast {
            showBattlegroundsHeroPanel(heroIds, isBattlegroundsDuosMatch(), toastParams)
        }
    }

    func playerMulligan(entity: Entity, cardId: String?) {
        if cardId.isBlank {
            return
        }

        player.mulligan(entity: entity)
        updateTrackers()
    }
    
    func handlePlayerHandToDeck(entity: Entity, cardId: String?) {
        if cardId.isBlank {
            return
        }
        
        if AppDelegate.instance().coreManager.logReaderManager.powerGameStateParser.currentBlock?.cardId == CardIds.Collectible.Neutral.SirFinleySeaGuide {
            dredgeCounter += 1
            let newIndex = dredgeCounter
            entity.info.deckIndex = -newIndex
        }

        updateTrackers()
    }

    func playerDraw(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        mulliganRecorder.cardDrawn(playerId: player.id, entityId: entity.id, cardId: cardId ?? "", turn: turn)
        if cardId == CardIds.NonCollectible.Neutral.TheCoinBasic {
            playerGet(entity: entity, cardId: cardId, turn: turn)
        } else {
            player.draw(entity: entity, turn: turn)
            updateTrackers()
        }
        secretsManager?.handleCardDrawn(entity: entity)
    }

    func playerRemoveFromDeck(entity: Entity, turn: Int) {
        player.removeFromDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerDeckDiscard(entity: Entity, cardId: String?, turn: Int) {
        player.deckDiscard(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerDeckToPlay(entity: Entity, cardId: String?, turn: Int) {
        player.deckToPlay(entity: entity, turn: turn)
        updateTrackers()
    }
    
    func handlePlayerHandToPlay(entity: Entity, cardId: String?, turn: Int) {
        player.handToPlay(entity: entity, turn: turn)
        updateTrackers()
    }
    
    func handleOpponentHandToPlay(entity: Entity, cardId: String?, turn: Int) {
        opponent.handToPlay(entity: entity, turn: turn)
        
        predictFabled(entity)
        
        updateTrackers()
    }

    func playerPlayToGraveyard(entity: Entity, cardId: String?, turn: Int, playersTurn: Bool) {
        if entity.isEnchantment {
            activeEffects.tryRemoveEffect(sourceEntity: entity, controlledByPlayer: true)
        }
        player.playToGraveyard(entity: entity, turn: turn)
        if playersTurn && entity.isMinion {
            playerMinionDeath(entity: entity)
        }
        
        updateTrackers()
    }

    func playerJoust(entity: Entity, cardId: String?, turn: Int) {
        player.joustReveal(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerGetToDeck(entity: Entity, cardId: String?, turn: Int) {
        player.createInDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerFatigue(value: Int) {
        if Settings.fullGameLog {
            logger.info("Player get \(value) fatigue")
        }
        player.fatigue = value
        updateTrackers()
    }

    func playerCreateInPlay(entity: Entity, cardId: String?, turn: Int) {
        if entity.isEnchantment {
            activeEffects.tryAddEffect(sourceEntity: entity, controlledByPlayer: true)
        }
        player.createInPlay(entity: entity, turn: turn)
    }

    func playerStolen(entity: Entity, cardId: String?, turn: Int) {
        player.stolenByOpponent(entity: entity, turn: turn)
        opponent.stolenFromOpponent(entity: entity, turn: turn)

        if entity.isSecret {
            var heroClass: CardClass?
            var className = "\(entity[.class])"
            if !className.isBlank {
                className = className.lowercased()
                heroClass = CardClass(rawValue: className)
                if heroClass == .none {
                    if let playerClass = opponent.originalClass {
                        heroClass = playerClass
                    }
                }
            } else {
                if let playerClass = opponent.originalClass {
                    heroClass = playerClass
                }
            }
            guard heroClass != nil else { return }
            secretsManager?.newSecret(entity: entity)
        }
    }

    func playerRemoveFromPlay(entity: Entity, turn: Int) {
        if entity.isEnchantment {
            activeEffects.tryRemoveEffect(sourceEntity: entity, controlledByPlayer: true)
        }
        player.removeFromPlay(entity: entity, turn: turn)
    }

    func playerCreateInSetAside(entity: Entity, turn: Int) {
        player.createInSetAside(entity: entity, turn: turn)
    }

    func playerHeroPower(cardId: String, turn: Int) {
        player.heroPower(turn: turn)
        if Settings.fullGameLog {
            logger.info("Player Hero Power \(cardId) \(turn) ")
        }

        secretsManager?.handleHeroPower()
    }

    // MARK: - Opponent actions
    func set(opponentHero cardId: String) {
        if let card = Cards.hero(byId: cardId) {
            opponent.originalClass = card.playerClass
            opponent.currentClass = opponent.originalClass
            opponent.playerClassId = cardId
            updateTrackers()
            if Settings.fullGameLog {
                logger.info("Opponent class is \(card) ")
            }
        }
    }

    func set(opponentName name: String) {
        opponent.name = name
        updateTrackers()
    }

    func opponentGet(entity: Entity, turn: Int, id: Int) {
        if !isMulliganDone() && entity[.zone_position] == 5 {
            entity.cardId = CardIds.NonCollectible.Neutral.TheCoinBasic
        }

        opponent.createInHand(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentPlayToHand(entity: Entity, cardId: String?, turn: Int, id: Int) {
        opponent.boardToHand(entity: entity, turn: turn)
        updateTrackers()
    }
    
    func opponentHandToDeck(entity: Entity, cardId: String?, turn: Int) {
        if cardId != nil && cardId != "" && entity.has(tag: .is_using_trade_option) {
            opponent.predictUniqueCardInDeck(cardId: cardId ?? "", isCreated: entity.info.created)
            entity.info.guessedCardState = .none
            entity.info.hidden = true
            if let currentBlock = AppDelegate.instance().coreManager.logReaderManager.powerGameStateParser.currentBlock {
                currentBlock.isTradeableAction = true
            }
            predictFabled(entity)
        }
        opponent.handToDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentPlayToDeck(entity: Entity, cardId: String?, turn: Int) {
        opponent.boardToDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentPlay(entity: Entity, cardId: String?, from: Int, turn: Int) {
        opponent.play(entity: entity, turn: turn)
        
        predictFabled(entity)

        if let cardId = cardId, !cardId.isEmpty {
            playedCards.append(PlayedCard(player: .opponent, cardId: cardId, turn: turn))
        }

        if entity.has(tag: .ritual) {
            // if this entity has the RITUAL tag, it will trigger some C'Thun change
            // we wait 300ms so the proxy have the time to be updated
            let when = DispatchTime.now() + DispatchTimeInterval.milliseconds(300)
            DispatchQueue.main.asyncAfter(deadline: when) { [weak self] in
                self?.updateTrackers()
            }
        }
        updateTrackers()
    }

    func opponentHandDiscard(entity: Entity, cardId: String?, from: Int, turn: Int) {
        opponent.handDiscard(entity: entity, turn: turn)
        predictFabled(entity)
        updateTrackers()
    }

    func opponentSecretPlayed(entity: Entity, cardId: String?,
                              from: Int, turn: Int,
                              fromZone: Zone, otherId: Int, creatorId: Int? = nil) {
        if !entity.isSecret {
            if entity.isQuest && !entity.isQuestlinePart || entity.isSideQuest {
                opponent.questPlayedFromHand(entity: entity, turn: turn)
            } else if entity.isSigil {
                opponent.sigilPlayedFromHand(entity: entity, turn: turn)
            } else if entity.isObjective {
                opponent.objectivePlayedFromHand(entity: entity, turn: turn)
            }
            updateTrackers()
            return
        }

        switch fromZone {
        case .deck:
            opponent.secretPlayedFromDeck(entity: entity, turn: turn)
        case .hand:
            opponent.secretPlayedFromHand(entity: entity, turn: turn)
        default:
            opponent.createInSecret(entity: entity, turn: turn, creatorId: creatorId)
        }

        var heroClass: CardClass?
        let className = "\(entity[.class])".lowercased()
        if let tagClass = TagClass(rawValue: entity[.class]) {
            heroClass = tagClass.cardClassValue
        } else if let _heroClass = CardClass(rawValue: className), !className.isBlank {
            heroClass = _heroClass
        } else if let playerClass = opponent.originalClass {
            heroClass = playerClass
        }

        if Settings.fullGameLog {
            logger.info("Secret played by \(entity[.class])"
                + " -> \(String(describing: heroClass)) "
                + "-> \(String(describing: opponent.originalClass))")
        }
        if heroClass != nil {
            secretsManager?.newSecret(entity: entity)
        }
        updateTrackers()
    }

    func opponentMulligan(entity: Entity, from: Int) {
        opponent.mulligan(entity: entity)
        updateTrackers()
    }

    func opponentDraw(entity: Entity, turn: Int, cardId: String, drawerId: Int?) {
        //swiftlint:disable inclusive_language
        let blacklist = RemoteConfig.data?.draw_card_blacklist?.compactMap({ obj in obj.dbf_id}) ?? [Int]()
        //swiftlint:enable inclusive_language
        if drawerId ?? 0 > 0, let drawer = entities[drawerId ?? 0] {
            if !blacklist.contains(drawer.card.dbfId) {
                entity.info.drawerId = drawerId
            }
        }
        opponent.draw(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentRemoveFromDeck(entity: Entity, turn: Int) {
        opponent.removeFromDeck(entity: entity, turn: turn)
        
        predictFabled(entity)
        
        updateTrackers()
    }

    func opponentDeckDiscard(entity: Entity, cardId: String?, turn: Int) {
        opponent.deckDiscard(entity: entity, turn: turn)
        predictFabled(entity)
        updateTrackers()
    }

    func opponentDeckToPlay(entity: Entity, cardId: String?, turn: Int) {
        opponent.deckToPlay(entity: entity, turn: turn)
        
        predictFabled(entity)
        
        updateTrackers()
    }

    func opponentPlayToGraveyard(entity: Entity, cardId: String?,
                                 turn: Int, playersTurn: Bool) {
        if entity.isEnchantment {
            activeEffects.tryRemoveEffect(sourceEntity: entity, controlledByPlayer: false)
        }
        opponent.playToGraveyard(entity: entity, turn: turn)
        if playersTurn && entity.isMinion {
            opponentMinionDeath(entity: entity, turn: turn)
        }
        if !playersTurn && entity.info.wasTransformed {
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 3.0)
                if let transformedSecret = self.secretsManager?.secrets.filter({ x in x.entity.id == entity.id }).first {
                    self.secretsManager?.removeSecret(entity: transformedSecret.entity)
                }
            }
        }
        updateTrackers()
    }
    
    func getMaestraDbfid() -> Int {
        return Cards.by(cardId: CardIds.NonCollectible.Neutral.MaestraoftheMasquerade_DisguiseEnchantment)?.dbfId ?? -1
    }
    
    func isMaestraHero(entity: Entity) -> Bool {
        return entity.isHero && entity[GameTag.creator_dbid] == getMaestraDbfid()
    }

    func OpponentIsDisguisedRogue() {
        set(opponentHero: CardIds.Collectible.Rogue.ValeeraSanguinar)
        //Core.Overlay.SetWinRates()
        opponent.predictUniqueCardInDeck(cardId: CardIds.Collectible.Rogue.MaestraOfTheMasquerade, isCreated: false)
        updateOpponentTracker()
    }
    
    func opponentJoust(entity: Entity, cardId: String?, turn: Int) {
        opponent.joustReveal(entity: entity, turn: turn)
        predictFabled(entity)
        updateTrackers()
    }

    func opponentGetToDeck(entity: Entity, turn: Int) {
        opponent.createInDeck(entity: entity, turn: turn)
        
        if !entity.info.created && !entity.cardId.isEmpty, let cardIds = CardIds.fabledDict[entity.cardId] {
            for cardId in cardIds {
                opponent.predictUniqueCardInDeck(cardId: cardId, isCreated: false)
            }
        }
        updateTrackers()
    }
    
    func handleOpponentSecretRemove(entity: Entity, cardId: String?, turn: Int) {
        if !entity.isSecret {
            return
        }
        opponent.removeFromPlay(entity: entity, turn: turn)
        secretsManager?.removeSecret(entity: entity)
        updateOpponentTracker()
    }

    func opponentSecretTrigger(entity: Entity, cardId: String?, turn: Int, otherId: Int) {
        if !entity.isSecret { return }

        opponent.secretTriggered(entity: entity, turn: turn)
        opponent.opponentSecretTriggered(entity: entity, turn: turn)
        secretsManager?.removeSecret(entity: entity)
        
        if isBattlegroundsMatch() && Settings.showBobsBuddy {
            BobsBuddyInvoker.instance(gameId: gameId, turn: turnNumber())?.updateOpponentSecret(entity: entity)
        }
    }

    func opponentFatigue(value: Int) {
        opponent.fatigue = value
        updateTrackers()
    }

    func opponentCreateInPlay(entity: Entity, cardId: String?, turn: Int) {
        if entity.isEnchantment {
            activeEffects.tryAddEffect(sourceEntity: entity, controlledByPlayer: false)
        }
        if isMaestraHero(entity: entity) {
            OpponentIsDisguisedRogue()
        }
        opponent.createInPlay(entity: entity, turn: turn)
    }

    func opponentStolen(entity: Entity, cardId: String?, turn: Int) {
        opponent.stolenByOpponent(entity: entity, turn: turn)
        player.stolenFromOpponent(entity: entity, turn: turn)

        if entity.isSecret {
            secretsManager?.removeSecret(entity: entity)
        }
    }

    func opponentRemoveFromPlay(entity: Entity, turn: Int) {
        if entity.isEnchantment {
            activeEffects.tryRemoveEffect(sourceEntity: entity, controlledByPlayer: false)
        }
        player.removeFromPlay(entity: entity, turn: turn)
    }

    func opponentCreateInSetAside(entity: Entity, turn: Int) {
        opponent.createInSetAside(entity: entity, turn: turn)
    }

    func opponentHeroPower(cardId: String, turn: Int) {
        opponent.heroPower(turn: turn)
        if Settings.fullGameLog {
            logger.info("Opponent Hero Power \(cardId) \(turn) ")
        }
        updateTrackers()
    }
    
    private func predictFabled(_ entity: Entity) {
        guard !entity.info.created, entity.hasCardId, let cardIds = CardIds.fabledDict[entity.cardId] else {
            return
        }
        
        for id in cardIds where id != entity.cardId && opponent.revealedEntities.all({ x in x.cardId != id }) {
            opponent.predictUniqueCardInDeck(cardId: id, isCreated: false)
        }
    }
    
    func handleQuestRewardDatabaseId(id: Int, value: Int) {
        if isBattlegroundsMatch(), let entity = entities[id], entity.isControlled(by: player.id) {
            if #available(macOS 10.15, *) {
                Task.detached {
                    await self.windowManager.rootOverlay?.viewModel.battlegroundsQuestPicking.onBattlegroundsQuest(questEntity: entity)
                }
            }
        }
    }

    // MARK: - Game actions
    func defending(entity: Entity?) {
        self.defendingEntity = entity
        guard let attackingEntity = self.attackingEntity, let defendingEntity = self.defendingEntity, let entity = entity else {
            return
        }
        if entity.isControlled(by: opponent.id) {
            secretsManager?.handleAttack(attacker: attackingEntity, defender: defendingEntity)
        }
        attackEvent()
    }

    func attacking(entity: Entity?) {
        self.attackingEntity = entity
        guard let attackingEntity = self.attackingEntity, let defendingEntity = self.defendingEntity, let entity = entity else {
            return
        }
        if entity.isControlled(by: player.id) {
            secretsManager?.handleAttack(attacker: attackingEntity, defender: defendingEntity)
        }
        attackEvent()
    }
    
    private func attackEvent() {
        if isBattlegroundsMatch() && Settings.showBobsBuddy, let attackingEntity = attackingEntity, let defendingEntity = defendingEntity {
            BobsBuddyInvoker.instance(gameId: gameId, turn: turnNumber())?.updateAttackingEntities(attacker: attackingEntity, defender: defendingEntity)
        }
    }
    
    func handleProposedAttackerChange(entity: Entity) {
        if isBattlegroundsMatch() && Settings.showBobsBuddy {
            BobsBuddyInvoker.instance(gameId: gameId, turn: turnNumber())?.handleNewAttackingEntity(newAttacker: entity)
        }
    }

    func playerMinionPlayed(entity: Entity) {
        secretsManager?.handleMinionPlayed(entity: entity)
    }
    
    func playerMinionDeath(entity: Entity) {
        secretsManager?.handlePlayerMinionDeath(entity: entity)
    }

    func opponentMinionDeath(entity: Entity, turn: Int) {
        secretsManager?.handleOpponentMinionDeath(entity: entity)
    }

    func opponentTurnStart(entity: Entity) {

    }
    
    func entityPredamage(entity: Entity, damage: Int) {
        if player.entity?.isCurrentPlayer ?? false {
            secretsManager?.handleEntityPredamage(entity: entity)
        }
    }
    
    func entityDamage(dealer: Entity?, entity: Entity, damage: Int) {
        if player.entity?.isCurrentPlayer ?? false {
            secretsManager?.entityDamage(dealer: dealer, target: entity, damage: damage)
        }
    }

    var chameleosReveal: (Int, String)?
	
    // MARK: - Mulligan
    
    @MainActor
    func showMulliganGuideStats(stats: [SingleCardStats], maxRank: Int, selectedParams: [String: String?]?) {
        windowManager.constructedMulliganGuide.viewModel.setMulliganData(stats: stats, maxRank: maxRank, selectedParams: selectedParams)
    }
    
    @MainActor
    func hideMulliganGuideStats() {
        windowManager.constructedMulliganGuide.viewModel.reset()
    }
    
    func handleBeginMulligan() {
        if isBattlegroundsMatch() {
            if #available(macOS 10.15, *) {
                Task.detached {
                    await self.handleBattlegroundsStart()
                }
            }
        } else if isConstructedMatch() || isFriendlyMatch || isArenaMatch {
            logger.info("Mulligan: BEGIN_MULLIGAN gameType=\(currentGameType) format=\(currentFormatType) spectator=\(spectator) v2=\(isV2Mulligan)")
            if #available(macOS 10.15, *) {
                Task.detached {
                    await self.handleHearthstoneMulliganPhase()
                }
            }
        } else {
            logger.info("Mulligan: BEGIN_MULLIGAN ignored for gameType=\(currentGameType)")
        }
    }
    
    @available(macOS 10.15.0, *) @MainActor
    func handlePlayerMulliganDone() async {
        if isBattlegroundsMatch() {
            let pickedHeroDbfId = snapshotBattlegroundsHeroPick()
            windowManager.rootOverlay?.viewModel.battlegroundsHeroGuides.selectHero(dbfId: pickedHeroDbfId)
            hideBattlegroundsHeroPanel()
            hideBattlegroundsTimewarpPanel()
            windowManager.rootOverlay?.viewModel.battlegroundsHeroPicking.reset()
            if #available(macOS 10.15, *) {
                windowManager.rootOverlay?.viewModel.battlegroundsSession.hideCompStatsOnError()
            }
        } else if isConstructedMatch() || isFriendlyMatch || isArenaMatch {
            hideMulliganToast()
            
            let openingHand = snapshotOpeningHand()

            if isV2Mulligan {
                if Settings.enableMulliganGV2 {
                    let numSwappedCards = self.getMulliganSwappedCards()?.count ?? 0
                    let guideV2 = windowManager.rootOverlay?.viewModel.mulliganGuideV2
                    // The reason shown in place of the stats only helps while
                    // the player is choosing.
                    guideV2?.error = nil

                    // HDT GameEventHandler.HandlePlayerMulliganDone asks again
                    // only when cards were swapped, and with the kept hand as
                    // the offered cards. Asking regardless meant a match whose
                    // first request had come back empty could activate a trial
                    // here, after the mulligan, where nothing can be shown.
                    if numSwappedCards > 0, let guideV2, !guideV2.cardStats.isEmpty {
                        _mulliganV2Params?.offered_cards = openingHand.map { x in x.card.deckbuildingCard.dbfId }
                        let result = await getMulliganV2Data(isMulliganDone: true)
                        DispatchQueue.main.async {
                            guideV2.updateMulliganDataAfterMulligan(result.data)
                        }
                    } else {
                        logger.debug("MulliganV2: no post-mulligan request (swapped=\(numSwappedCards), stats shown=\(!(guideV2?.cardStats.isEmpty ?? true)))")
                    }

                    // Delay until the cards fly away
                    do {
                        try await Task.sleep(nanoseconds: 2_375_000_000 + UInt64(max(1, numSwappedCards)) * 475_000_000)
                    } catch {
                        logger.error(error)
                    }

                    // Wait for the mulligan to be complete (component or animation)
                    for _ in 0 ..< 7_500 { // 2 minutes
                        if isInMenu || (gameEntity?[.step] ?? 0) > Step.begin_mulligan.rawValue {
                            break
                        }
                        if (playerEntity?[.mulligan_state] ?? 0) >= Mulligan.done.rawValue && (opponentEntity?[.mulligan_state] ?? 0) >= Mulligan.done.rawValue {
                            break
                        }
                        do {
                            try await Task.sleep(nanoseconds: 16_000_000)
                        } catch {
                            logger.error(error)
                        }
                    }
                    stopMulliganLivePolling()
                    DispatchQueue.main.async {
                        self.windowManager.rootOverlay?.viewModel.mulliganGuideV2.reset()
                    }
                }
            } else if let mulliganCardStats, Settings.enableMulliganGuide {
                let numSwappedCards = self.getMulliganSwappedCards()?.count ?? 0
                if numSwappedCards > 0 {
                    // show the updated cards
                    let dbfIds = openingHand.compactMap { x in x.card.deckbuildingCard.dbfId }
                    if dbfIds.count > 0 {
                        DispatchQueue.main.async {
                            self.showMulliganGuideStats(stats: dbfIds.compactMap { dbfId in
                                if let l = mulliganCardStats[dbfId] {
                                    return l
                                } else {
                                    return SingleCardStats(dbf_id: dbfId)
                                }
                            }, maxRank: mulliganCardStats.count, selectedParams: nil)
                        }
                    }
                }
                // Delay until the cards fly away
                do {
                    try await Task.sleep(nanoseconds: 2_375_000_000 + UInt64(max(1, numSwappedCards)) * 475_000_000)
                } catch {
                    logger.error(error)
                }
                
                // Wait for the mulligan to be complete (component or animation)
                for _ in 0 ..< 7_500 { // 2 minutes
                    if isInMenu || (gameEntity?[.step] ?? 0) > Step.begin_mulligan.rawValue {
                        DispatchQueue.main.async {
                            self.hideMulliganGuideStats()
                            self.player.mulliganCardStats = nil
                        }
                        return
                    }
                    if (playerEntity?[.mulligan_state] ?? 0) >= Mulligan.done.rawValue && (opponentEntity?[.mulligan_state] ?? 0) >= Mulligan.done.rawValue {
                        break
                    }
                    do {
                        try await Task.sleep(nanoseconds: 16_000_000)
                    } catch {
                        logger.error(error)
                    }
                }
                DispatchQueue.main.async {
                    self.hideMulliganGuideStats()
                    self.player.mulliganCardStats = nil
                }
            }
        }
    }
    
    func handlePlayerEntityChoices(choice: IHsChoice) {
        if choice.choiceType == ChoiceType.general && isBattlegroundsMatch() {
            let offeredEntities = choice.offeredEntityIds?.compactMap { id in entities[id] } ?? [Entity]()
            
            // trinket picking
            if let source = entities[choice.sourceEntityId], source[.bacon_is_magic_item_discover] > 0 && offeredEntities.all({ x in x.isBattlegroundsTrinket }) {
                if #available(macOS 10.15.0, *) {
                    Task.detached {
                        await self.handleBattlegroundsTrinketChoice(choice: choice)
                    }
                }
            } else if offeredEntities.all({ x in x.isHeroPower }) { // hero power choice
                let offered = offeredEntities.filter { x in x.isHeroPower }
                let heroPowerIds = (player.board.filter({ x in x.isHeroPower }) + offered).compactMap({ x in x.card.id })
                battlegroundsMinionsOnHeroPowers(heroPowerIds)
            }
        }
        player.offeredEntityIds = choice.offeredEntityIds ?? [Int]()
        updatePlayerCounters()
    }
    
    // MARK: - Battlegrounds tier 7 sources
    //
    // The Minions tab tracks tier 7 itself (BattlegroundsMinionsViewModel's
    // onHeroPowers / onTrinkets / onQuests), so every site that tells the AppKit
    // tier overlay about a hero power, trinket or quest reward tells the view
    // model too - matching HDT, whose GameEventHandler calls
    // BattlegroundsMinionsVM.On* at these exact same points.
    //
    // Deliberately not forwarded from inside the tier overlay's own methods:
    // `tierOverlay` is an @IBOutlet that stays nil until its nib is first
    // loaded, which would silently drop these for the Minions tab.
    //
    // Always hops to main - these mutate @Published state and several callers
    // run on the log-parsing thread rather than main.
    func battlegroundsMinionsOnHeroPowers(_ heroPowers: [String]) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.rootOverlay?.viewModel.battlegroundsMinionsGuide.onHeroPowers(heroPowers)
            }
        }
    }

    func battlegroundsMinionsOnTrinkets(_ trinkets: [String]) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.rootOverlay?.viewModel.battlegroundsMinionsGuide.onTrinkets(trinkets)
            }
        }
    }

    func battlegroundsMinionsOnQuests(_ quests: [String]) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.rootOverlay?.viewModel.battlegroundsMinionsGuide.onQuests(quests)
            }
        }
    }

    @available(macOS 10.15.0, *) @MainActor
    func handleBattlegroundsTrinketChoice(choice: IHsChoice) async {
        let offeredEntities = choice.offeredEntityIds?.compactMap { id in entities[id] } ?? [Entity]()

        let offered = offeredEntities.filter { x in x.isBattlegroundsTrinket }
        let trinkets = (player.trinkets + offered).compactMap({ x in x.card.id })
        battlegroundsMinionsOnTrinkets(trinkets)
        
        let result = await getTrinketPickStats(choice: choice)
        if let result, !isTrinketChoiceComplete(choiceId: choice.id) {
            let data = offeredEntities.compactMap({ entity in result.data?.first { x in x.trinket_dbf_id == entity.card.dbfId }})
            windowManager.rootOverlay?.viewModel.battlegroundsTrinketPicking.setTrinketStats(data)
        }
        player.offeredEntityIds = choice.offeredEntityIds ?? [Int]()
        updatePlayerCounters()

    }
    
    func isTrinketChoiceComplete(choiceId: Int) -> Bool {
        guard let state = battlegroundsTrinketPickStates.last else {
            return false
        }
        
        if choiceId > state.choiceId {
            return false
        }
        if choiceId < state.choiceId {
            return true
        }
        return state.chosenTrinketDbfId != nil
    }
    
    @available(macOS 10.15.0, *)
    private func getTrinketPickStats(choice: IHsChoice) async -> BattlegroundsTrinketPickStats? {
        if spectator {
            return nil
        }
        
        if !Settings.enableTier7Overlay {
            return nil
        }
        
        if RemoteConfig.data?.tier7?.disabled ?? false {
            return nil
        }
        
        guard let requestParams = snapshotOfferedTrinkets(choice: choice) else {
            return nil
        }
        
        let userOwnsTier7 = HSReplayAPI.accountData?.is_tier7 ?? false
        if !userOwnsTier7 && Tier7Trial.token == nil {
            return nil
        }
        
        if let token = Tier7Trial.token {
            return await HSReplayAPI.getTier7TrinketPickStats(token: token, parameters: requestParams)
        } else {
            return await HSReplayAPI.getTier7TrinketPickStats(parameters: requestParams)
        }
    }
    
    func snapshotOfferedTrinkets(choice: IHsChoice) -> BattlegroundsTrinketPickParams? {
        guard let availableRaces else {
            return nil
        }
        
        let hero = player.hero
        let heroCardId = hero?.cardId != nil ? BattlegroundsUtils.getOriginalHeroId(heroId: hero?.cardId ?? "") : nil
        guard let heroCard = heroCardId != nil ? Cards.by(cardId: heroCardId ?? "") : nil else {
            return nil
        }
        
        guard let sourceEntity = entities[choice.sourceEntityId] else {
            return nil
        }
        
        let offeredTrinkets = choice.offeredEntityIds?.compactMap({ id in entities[id] }).compactMap({ entity in BattlegroundsTrinketPickParams.OfferedTrinket(trinket_dbf_id: entity.card.dbfId, extra_data: entity[.tag_script_data_num_1])}) ?? [BattlegroundsTrinketPickParams.OfferedTrinket]()
        if offeredTrinkets.count == 0 {
            return nil
        }
        
        let parameters = BattlegroundsTrinketPickParams(hero_dbf_id: heroCard.dbfId, hero_power_dbf_ids: player.pastHeroPowers.compactMap({ x in Cards.by(cardId: x)?.dbfId }), minion_types: availableRaces.compactMap { x in Int(Race.allCases.firstIndex(of: x)!) }, anomaly_dbf_id: BattlegroundsUtils.getBattlegroundsAnomalyDbfId(game: gameEntity), turn: turnNumber(), source_dbf_id: sourceEntity.card.dbfId, offered_trinkets: offeredTrinkets, game_language: "\(Settings.hearthstoneLanguage ?? .enUS)", game_type: BnetGameType.getBnetGameType(gameType: currentGameType, format: currentFormat).rawValue, battlegrounds_rating: currentBattlegroundsRating)
        return parameters
    }
    
    func snapshotChosenTrinket(choice: IHsCompletedChoice) {
        guard let state = battlegroundsTrinketPickStates.last else {
            return
        }
        
        if state.choiceId != choice.id {
            return
        }
        
        guard choice.chosenEntityIds?.count == 1, let chosen = entities[choice.chosenEntityIds?[0] ?? 0] else {
            return
        }
        
        state.pickTrinket(trinket: chosen)
    }
    
    // The Battlegrounds choices whose mask is waiting for shopping to start -
    // see setChoicesVisible below.
    private var pendingBgsCombatChoices: [String]?

    func setChoicesVisible(_ choicesVisible: Bool, _ cardIds: [String]?) {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.battlegroundsTrinketPicking.choicesVisible = choicesVisible
        }

        guard isBattlegroundsMatch() else { return }

        let cardIdList = cardIds ?? [String]()
        if !choicesVisible || cardIdList.isEmpty {
            pendingBgsCombatChoices = nil
            if #available(macOS 10.15, *) {
                onMainOverlay { $0.opacityMask.removeMaskedRegion("DiscoverCard") }
            }
            return
        }

        // The choices can already be readable while the combat that precedes
        // them is still playing out, and the game does not draw them until
        // shopping opens - so the cut-out waits for that (HDT's
        // OnBattlegroundsShoppingStart).
        if isBattlegroundsCombatPhase {
            pendingBgsCombatChoices = cardIdList
            return
        }

        pendingBgsCombatChoices = nil
        applyDiscoverCardMask(cardIdList)
    }

    func onBattlegroundsShoppingStart() {
        if let pending = pendingBgsCombatChoices {
            pendingBgsCombatChoices = nil
            applyDiscoverCardMask(pending)
        }
    }

    private func applyDiscoverCardMask(_ cardIds: [String]) {
        let cards = cardIds.compactMap { Cards.by(cardId: $0) }
        guard #available(macOS 10.15, *) else { return }

        if cards.all({ $0.type == .battleground_trinket }) {
            let count = cards.count
            onMainOverlay { $0.setTrinketPickingOpacityMask(zoneSize: count) }
        } else if cards.all({ $0.type == .minion || $0.type == .battleground_spell || $0.type == .spell }) {
            let count = cards.count
            let hasDarkGifts = player.offeredEntities.any { $0[.dark_gift_entity] > 0 }
            onMainOverlay { $0.setDiscoverCardOpacityMask(zoneSize: count, hasDarkGifts: hasDarkGifts) }
        }
    }

    // The opacity mask lives on RootOverlay's view model and is main-thread
    // only; every caller here arrives off a watcher or the log reader.
    @available(macOS 10.15, *)
    func onMainOverlay(_ block: @escaping (RootOverlayViewModel) -> Void) {
        let run = { [weak self] in
            guard let viewModel = self?.windowManager.rootOverlay?.viewModel else { return }
            block(viewModel)
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    // HDT's Watchers.OnUiChange -> OverlayWindow.SetFriendListOpacityMask. The
    // friends list slides in over the right of the client, under the overlay.
    func setFriendListOpacityMask(_ visible: Bool) {
        guard #available(macOS 10.15, *) else { return }
        onMainOverlay { $0.setFriendListOpacityMask(visible) }
    }

    // HDT's Watchers.OnUiChange -> OverlayWindow.SetGameMenuOpacityMask. The
    // escape menu is drawn centred over the board, under the overlay.
    func setGameMenuOpacityMask(_ visible: Bool) {
        guard #available(macOS 10.15, *) else { return }
        onMainOverlay { $0.setGameMenuOpacityMask(visible) }
    }

    // HDT's Watchers.OnMulliganTooltipChange ->
    // OverlayWindow.SetHeroPickingTooltipMask.
    func setHeroPickingTooltipMask(zoneSize: Int, zonePosition: Int, tooltipOnRight: Bool,
                                   numCards: Int, buddiesEnabled: Bool) {
        guard #available(macOS 10.15, *) else { return }
        onMainOverlay {
            $0.setHeroPickingTooltipMask(zoneSize: zoneSize, zonePosition: zonePosition,
                                         tooltipOnRight: tooltipOnRight, numCards: numCards,
                                         buddiesEnabled: buddiesEnabled)
        }
    }

    // HDT's Watchers.OnDiscoverStateChange -> OverlayWindow.SetTrinketGuidesTrigger.
    //
    // Called before setQuestGuidesTrigger below, as in HDT, and it is this one
    // that resets the shared trigger: the two write the same element there, so
    // a discover state that is neither leaves it cleared.
    func setTrinketGuidesTrigger(zoneSize: Int, zonePosition: Int, cardId: String) {
        guard #available(macOS 10.15, *) else { return }

        guard !cardId.isEmpty,
              let card = Cards.by(cardId: cardId),
              card.type == .battleground_trinket else {
            onMainOverlay { $0.battlegroundsDiscoveryGuides.trigger = nil }
            return
        }

        let trinketPickWidth = 0.192
        let leftEdge = 0.122
        let trinketX = leftEdge + Double(zonePosition) * trinketPickWidth

        let trigger = BattlegroundsDiscoveryGuideTrigger(
            content: .trinket(dbfId: card.dbfId),
            x: trinketX,
            top: 0.28,
            width: 0.25,
            height: 0.35,
            placement: .bottom,
            verticalOffset: 10,
            alignsToStart: false)
        onMainOverlay { $0.battlegroundsDiscoveryGuides.trigger = trigger }
    }

    // HDT's Watchers.OnDiscoverStateChange -> OverlayWindow.SetQuestGuidesTrigger.
    //
    // The entity resolution happens here rather than in the view model because
    // it reads the game's own entities, as HDT's does from OverlayWindow. Like
    // HDT's, it leaves the shared trigger alone when it does not apply - the
    // trinket path above has already cleared it.
    func setQuestGuidesTrigger(_ state: DiscoverStateArgs) {
        guard #available(macOS 10.15, *) else { return }

        guard let entityId = state.entityId, entityId != 0,
              let entity = entities[entityId] else { return }

        let questRewardCardId = entity[.quest_reward_database_id]
        guard let questRewardCard = Cards.by(dbfId: questRewardCardId, collectible: false),
              questRewardCard.type == .battleground_quest_reward else { return }

        let questPickWidth = 0.270
        let leftEdge = 0.117
        let questX = leftEdge + Double(state.zonePosition) * questPickWidth

        // A reward card shown alongside the quest shifts which side the game
        // puts its own tooltip on.
        let isRewardCardPresent = Cards.by(dbfId: entity[.bacon_card_dbid_reward], collectible: false) != nil
        let isGameTooltipRight = isRewardCardPresent
            ? state.zonePosition + 1 == state.zoneSize
            : state.zonePosition == 0

        let trigger = BattlegroundsDiscoveryGuideTrigger(
            content: .questReward(dbfId: questRewardCard.dbfId),
            x: questX,
            top: 0.22,
            width: 0.30,
            height: 0.55,
            placement: isGameTooltipRight ? .right : .left,
            verticalOffset: 32,
            alignsToStart: true)
        onMainOverlay { $0.battlegroundsDiscoveryGuides.trigger = trigger }
    }

    // HDT's Watchers.OnMulliganTooltipChange ->
    // OverlayWindow.SetHeroGuidesTrigger.
    func setHeroGuidesTrigger(zoneSize: Int, zonePosition: Int, tooltipOnRight: Bool,
                              cards: [String], buddiesEnabled: Bool) {
        guard #available(macOS 10.15, *) else { return }
        onMainOverlay {
            $0.battlegroundsHeroGuides.setTrigger(zoneSize: zoneSize, zonePosition: zonePosition,
                                                  tooltipOnRight: tooltipOnRight, cards: cards,
                                                  buddiesEnabled: buddiesEnabled)
        }
    }
    
    func handleSpecialShop(_ args: SpecialShopChoicesArgs) {
        guard isBattlegroundsMatch() else {
            return
        }
        
        let boardCards = args.boardCards
        let userHasTier7 = HSReplayAPI.accountData?.is_tier7 ?? false // TODO: trial active
        let currentPeriod = RemoteConfig.metaPeriods?.sorted(by: { $0.period_start > $1.period_start }).first
        let hasTimewarpMechanic = currentPeriod?.mechanics.firstIndex(of: "timewarp") != nil
        
        if args.isActive && boardCards.count > 0 && userHasTier7 && hasTimewarpMechanic {
            showBattlegroundsTimewarpPanel(boardCards)
        } else {
            hideBattlegroundsTimewarpPanel()
        }

        // HDT calls OnShopChange from here as well as from OnPlayZoneChange, so
        // the Tavern Pinning markers follow the Timewarp "compare cards" shop
        // (ChoiceCardMgr's m_shopChoice zone) while it is up, not just Bob's own
        // tavern. When that zone is empty this hands over an empty list, which
        // clears the markers until the next play-zone tick refills them - the
        // same brief handover HDT has.
        handleShopBoardState(boardCards: boardCards, mousedOverSlot: args.mousedOverSlot)
    }

    // The single entry point both shop feeds share: PlayZoneWatcher's opposing
    // zone (Bob's shop, HDT's Watchers.OnPlayZoneChange) and the special-shop
    // watcher above. Mirrors HDT's BattlegroundsMinionPinningViewModel.OnShopChange
    // call sites.
    func handleShopBoardState(boardCards: [MirrorBoardCard], mousedOverSlot: Int) {
        guard #available(macOS 10.15, *) else { return }
        DispatchQueue.main.async {
            self.windowManager.rootOverlay?.viewModel.battlegroundsMinionPinning
                .onShopChange(boardCards: boardCards, mousedOverSlot: mousedOverSlot)
        }
    }

    func handleOpponentEntitiesChosen(choice: IHsCompletedChoice) {
        if choice.choiceType == .general {
            counterManager.handleChoicePicked(choice: choice)
            lastEntityChosenOnDiscover = choice.chosenEntityIds?.first ?? 0
        }
    }
    
    func handlePlayerEntitiesChosen(choice: IHsCompletedChoice) {
        let chosen = choice.chosenEntityIds?.compactMap { id in entities[id] } ?? [Entity]()
        let source = entities[choice.sourceEntityId]
        switch choice.choiceType {
        case ChoiceType.mulligan:
            if isBattlegroundsMatch() {
                if chosen.count == 1 {
                    let hero = chosen.first
                    var heroPowers = [String]()
                    let heroPower = Cards.by(dbfId: hero?[.hero_power], collectible: false)?.id
                    if let hp = heroPower {
                        heroPowers.append(hp)
                    }
                    let additionalHeroPowerId = hero?[GameTag.additional_hero_power_entity_1] ?? 0
                    if additionalHeroPowerId > 0, let additionalHeroPower =  entities[additionalHeroPowerId] {
                        heroPowers.append(additionalHeroPower.card.id)
                    }
                    battlegroundsMinionsOnHeroPowers(heroPowers)
                } else {
                    logger.error("Could not reliably determine Battlegrounds hero power. \(chosen.count) hero(es) chosen.")
                }
                if #available(macOS 10.15, *) {
                    self.windowManager.rootOverlay?.viewModel.battlegroundsQuestPicking.reset()
                }
            } else if isConstructedMatch() || isFriendlyMatch || isArenaMatch {
                _ = snapshotMulliganChoices(choice: choice)
            }
        case ChoiceType.general:
            counterManager.handleChoicePicked(choice: choice)
            handleSphereOfSapienceChosen(choice, chosen, source)
            if isBattlegroundsMatch() {
                if #available(macOS 10.15, *) {
                    windowManager.rootOverlay?.viewModel.battlegroundsQuestPicking.reset()
                    windowManager.rootOverlay?.viewModel.battlegroundsTrinketPicking.reset()
                }
                if source?[.bacon_is_magic_item_discover] ?? 0 > 0 {
                    let chosenTrinketIds = (self.player.trinkets + chosen).compactMap({ x in x.cardId })
                    battlegroundsMinionsOnTrinkets(chosenTrinketIds)
                }
                // the entity of a chosen hero power is only created after the choice completes, concat the chosen one
                let chosenHeroPowerIds = player.board.filter({ x in x.isHeroPower }).compactMap({ x in x.card.id }) + chosen.filter({ x in x.isHeroPower }).compactMap({ x in x.card.id })
                battlegroundsMinionsOnHeroPowers(chosenHeroPowerIds)
                
                // quest choice
                if let chosenEntity = chosen.first {
                    let questRewardDbfId = chosenEntity[.quest_reward_database_id]
                    if questRewardDbfId > 0 {
                        if let questReward = Cards.by(dbfId: questRewardDbfId, collectible: false) {
                            battlegroundsMinionsOnQuests([questReward.id])
                            if #available(macOS 10.15, *) {
                                // Mutates an @Published property - this
                                // handler runs off the log-parsing thread
                                // (ChoicesHandler), not guaranteed main.
                                DispatchQueue.main.async {
                                    self.windowManager.rootOverlay?.viewModel.battlegroundsQuestGuides.selectQuest(card: questReward)
                                }
                            }
                        }
                    }
                }
            }
        default: break
        }
    }
    
    // Sphere of Sapience offers the top card of the deck, or "A New Fate" to put it on the
    // bottom. The card in the deck never changes zone, and the offered card is only a copy of
    // it, so the choice is the only signal we get about the new position.
    private func handleSphereOfSapienceChosen(_ choice: IHsCompletedChoice, _ chosen: [Entity], _ source: Entity?) {
        if source?.cardId != CardIds.Collectible.Neutral.SphereOfSapience {
            return
        }

        let offeredCopy = choice.offeredEntityIds?
            .compactMap { id in entities[id] }
            .first { x in x.cardId != CardIds.NonCollectible.Neutral.SphereofSapience_ANewFateToken }
        guard let offeredCopy else {
            return
        }

        var linkedId = offeredCopy[GameTag.linked_entity]
        if linkedId == 0 {
            linkedId = offeredCopy[GameTag.copied_from_entity_id]
        }
        guard let topCard = entities[linkedId], !topCard.isInDeck else {
            return
        }

        let putOnBottom = chosen.any({ x in x.cardId == CardIds.NonCollectible.Neutral.SphereofSapience_ANewFateToken })
        dredgeCounter += 1
        let newIndex = dredgeCounter
        topCard.info.deckIndex = putOnBottom ? -newIndex : newIndex
        logger.info("Sphere of Sapience \(putOnBottom ? "Bottom" : "Top"): \(topCard)")
        updatePlayerTracker()
    }
    
    // Whether the player has finished choosing, so a guide result that only
    // arrives now has nothing left to explain. waitForMulliganStart returns
    // early in exactly these cases, and handlePlayerMulliganDone, which
    // clears the overlay, runs once the player's MULLIGAN_STATE is DONE -
    // anything applied after that would stay on the board (or over the menu)
    // until the game ends.
    static func isPastMulliganChoice(inMenu: Bool, step: Int, playerMulliganState: Int) -> Bool {
        return inMenu || step > Step.begin_mulligan.rawValue || playerMulliganState >= Mulligan.done.rawValue
    }

    private var isPastMulliganChoice: Bool {
        return Game.isPastMulliganChoice(inMenu: isInMenu, step: gameEntity?[.step] ?? 0, playerMulliganState: playerEntity?[.mulligan_state] ?? 0)
    }

    struct MulliganV2Presentation: Equatable {
        var showTrialsExhausted: Bool
        var showLocalToast: Bool
        var pollLiveState: Bool
    }

    // What the V2 branch shows for a guide result. HDT's V2 branch never shows
    // the "What should I keep?" toast, and neither does HSTracker once the V2
    // stats are on screen. Without data, though, HDT leaves the player with
    // nothing at all, while HSTracker used to show the toast on every
    // Standard game; it stays as the fallback so a request that failed (a
    // hsreplay.net timeout, a deck without coverage, an unreadable trial
    // status) still leaves a way to the deck's mulligan page. It is shown
    // alongside the used-up trials notice too, since the website is then the
    // only place the guide can still be looked at.
    static func mulliganV2Presentation(hasData: Bool, unavailable: MulliganGuideUnavailableReason?, showToast: Bool) -> MulliganV2Presentation {
        return MulliganV2Presentation(showTrialsExhausted: !hasData && (unavailable?.isTrialsExhausted ?? false),
                                      showLocalToast: showToast && !hasData,
                                      pollLiveState: hasData)
    }

    @available(macOS 10.15.0, *) @MainActor
    func handleHearthstoneMulliganPhase() async {
        var sawStep = false
        for _ in 0 ..< 10 {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                logger.error(error)
            }
            let step = gameEntity?[.step] ?? 0
            if step == 0 {
                continue
            }
            sawStep = true
            if step > Step.begin_mulligan.rawValue {
                logger.info("Mulligan: STEP already past BEGIN_MULLIGAN (step=\(step)), guide skipped")
                break
            }
            
            _ = snapshotMulligan()

            let cards = player.playerEntities.filter { x in x.isInHand && !x.has(tag: GameTag.coin_card) }
            let dbfIds = cards.sorted(by: { (a, b) in a.zonePosition < b.zonePosition }).compactMap { x in x.card.deckbuildingCard.dbfId }

            if isV2Mulligan {
                cacheMulliganV2Params(offeredDbfIds: dbfIds)
            } else {
                cacheMulliganGuideParams()
            }

            var showToast = Settings.showMulliganToast && !isArenaMatch
            let isV2 = isV2Mulligan
            logger.info("Mulligan: branch=\(isV2 ? "V2" : "V1") deck=\(currentDeck?.name ?? "nil") shortid=\(currentDeck?.shortid.prefix(24) ?? "nil") offered=\(dbfIds) showToast=\(showToast) enableGuide=\(Settings.enableMulliganGuide) enableGV2=\(Settings.enableMulliganGV2)")
            // HDT only looks at the setting of the guide this match would use.
            if showToast || (isV2 && Settings.enableMulliganGV2) || (!isV2 && Settings.enableMulliganGuide) {
                if let currentDeck = currentDeck {
                    // Show Mulligan Guide Elements (Overlay and/or Toast)
                    let shortId = currentDeck.shortid
                    if !shortId.isEmpty {
                        if isV2 {
                            var result = MulliganGuideResult<MulliganV2Data>(unavailable: .disabledBySetting)
                            if Settings.enableMulliganGV2 {
                                result = await getMulliganV2Data()
                            }

                            await waitForMulliganStart()

                            // The trial status, deck status and activation
                            // are all awaited above, and hsreplay.net can be
                            // slow to answer from some regions.
                            if isPastMulliganChoice {
                                logger.info("MulliganV2: result arrived after the mulligan or in the menu, not shown")
                                break
                            }

                            let opponentClass = opponent.playerEntities.first { x in x.isHero && x.isInPlay }?.card.playerClass ?? CardClass.invalid
                            let isFirst = playerEntity?[.first_player] == 1
                            // HDT draws nothing when there is no data. When the
                            // reason is a used-up weekly allowance, say so over
                            // the cards instead: an empty overlay looks exactly
                            // like a tracker that stopped working.
                            let presentation = Game.mulliganV2Presentation(hasData: result.data != nil, unavailable: result.unavailable, showToast: showToast)
                            let timeRemaining = MulliganGuideTrial.timeRemaining

                            DispatchQueue.main.async {
                                if self.isPastMulliganChoice {
                                    logger.info("MulliganV2: mulligan ended before the result was applied, not shown")
                                    return
                                }
                                let guideV2 = self.windowManager.rootOverlay?.viewModel.mulliganGuideV2
                                guideV2?.scopeMessage(opponentClass: opponentClass, isFirst: isFirst)
                                guideV2?.setMulliganData(result.data, isFirst: isFirst)
                                if presentation.showTrialsExhausted {
                                    guideV2?.showTrialsExhausted(timeRemaining: timeRemaining)
                                }
                                if presentation.showLocalToast {
                                    self.showMulliganToast(shortId, dbfIds, self.localMulliganToastParameters(opponentClass: opponentClass, isFirst: isFirst))
                                }
                                if presentation.pollLiveState {
                                    self.startMulliganLivePolling()
                                }
                            }
                        } else {
                            var result = MulliganGuideResult<MulliganGuideData>(unavailable: .disabledBySetting)

                            if Settings.enableMulliganGuide {
                                result = await getMulliganGuideData()
                            }

                            if let data = result.data {
                                // Show mulligan guide with parameters as selected by the API
                                if showToast {
                                    showMulliganToast(shortId, dbfIds, data.toast?.parameters, true)
                                    showToast = false
                                }

                                await waitForMulliganStart()

                                if isPastMulliganChoice {
                                    logger.info("MulliganV1: result arrived after the mulligan or in the menu, not shown")
                                    break
                                }

                                var cardStats: [Int: SingleCardStats]?
                                // GroupBy before ToDictionary to deal with (unsupported) dbfId duplicates from the server
                                let grouped = Dictionary(uniqueKeysWithValues: data.deck_dbf_id_list.group({ x in x.dbf_id }).compactMap { x in (x.key, x.value[0])})

                                cardStats = SingleCardStats.groupCardStats(stats: grouped, baseWinRate: data.base_winrate)
                                if let cardStats {
                                    mulliganCardStats = cardStats
                                    player.mulliganCardStats = Array(cardStats.values)
                                    DispatchQueue.main.async {
                                        self.showMulliganGuideStats(stats: dbfIds.compactMap({ dbfId in
                                            if let stats = cardStats[dbfId] {
                                                return stats
                                            }
                                            return SingleCardStats(dbf_id: dbfId)
                                        }), maxRank: cardStats.count, selectedParams: data.selected_params)
                                    }
                                }
                                // Something went wrong generating the card stats, continue to locally generated toast (if enabled)
                            }

                            if showToast && isPastMulliganChoice {
                                logger.info("MulliganV1: mulligan ended before the toast, not shown")
                            } else if showToast {
                                let opponentClass = opponent.playerEntities.first { x in x.isHero && x.isInPlay }?.card.playerClass ?? CardClass.invalid
                                let isFirst = playerEntity?[.first_player] == 1
                                showMulliganToast(shortId, dbfIds, localMulliganToastParameters(opponentClass: opponentClass, isFirst: isFirst))
                            }
                        }
                    }
                } else {
                    logger.info("Mulligan: no active deck, nothing to look up")
                }
            }
            break
        }
        if !sawStep {
            logger.info("Mulligan: STEP never set within 5 s, guide skipped")
        }
    }

    // The toast's own parameters when no guide chose them: the website
    // filters by them itself, and falls back for players without Premium.
    private func localMulliganToastParameters(opponentClass: CardClass, isFirst: Bool) -> [String: String] {
        var parameters: [String: String] = [
            "opponentClasses": opponentClass.rawValue.uppercased(),
            "playerInitiative": isFirst ? "FIRST" : "COIN"
        ]
        let playerStarLevel = playerMedalInfo?.starLevel ?? 0
        if playerStarLevel > 0 {
            parameters["mulliganPlayerStarLevel"] = String(playerStarLevel)
        }
        parameters["mulliganAutoFilter"] = "yes"
        return parameters
    }
    
    func getMulliganSwappedCards() -> [Entity]? {
        let offered = mulliganState.offeredCards
        let kept = mulliganState.keptCards

        // assemble a list of cards that were
        var retval = [Entity]()
        for card in offered where !kept.contains(card) {
            retval.append(card)
        }

        return retval
    }

    var mulliganCardStats: [Int: SingleCardStats]?

    func snapshotOpeningHand() -> [Entity] {
        return mulliganState.snapshotOpeningHand()
    }
    
    func snapshotMulliganChoices(choice: IHsCompletedChoice) -> [Entity] {
        return mulliganState.snapshotMulliganChoices(choice: choice)
    }
    
    func snapshotMulligan() -> [Entity] {
        return mulliganState.snapshotMulligan()
    }
    
    func cacheMulliganGuideParams() {
        if _mulliganGuideParams != nil {
            return
        }
        
        guard let activeDeck = currentDeck else {
            return
        }

        let opponentClass = opponent.playerEntities.first { x in x.isHero && x.isInPlay }?.card.playerClass ?? CardClass.invalid
        let starLevel = playerMedalInfo?.starLevel ?? 0
        let starsPerWin = playerMedalInfo?.starsPerWin ?? 0

        _mulliganGuideParams = MulliganGuideParams(deckstring: activeDeck.shortid, game_type: BnetGameType.getBnetGameType(gameType: currentGameType, format: Format(formatType: currentFormatType)).rawValue, format_type: currentFormatType.rawValue, opponent_class: opponentClass.rawValue.uppercased(), player_initiative: playerEntity?[.first_player] == 1 ? "FIRST" : "COIN", player_star_level: starLevel > 0 ? starLevel : nil, player_star_multiplier: starsPerWin > 0 ? starsPerWin : nil, player_region: Region.toBnetRegion(region: currentRegion))
    }
    
    @available(macOS 10.15.0, *)
    func getMulliganGuideData() async -> MulliganGuideResult<MulliganGuideData> {
        let result = await fetchMulliganGuideData()
        if let reason = result.unavailable {
            logger.info("MulliganV1: no data - \(reason)")
        }
        return result
    }

    // HDT GameEventHandler.GetMulliganGuideData. The port had the remote kill
    // switch commented out and no trial support ("No trial support yet"), so a
    // player without Premium never got a guide in Wild, Twist or Casual.
    @available(macOS 10.15.0, *) @MainActor
    private func fetchMulliganGuideData() async -> MulliganGuideResult<MulliganGuideData> {
        if spectator {
            return MulliganGuideResult(unavailable: .spectator)
        }
        guard Settings.enableMulliganGuide else {
            return MulliganGuideResult(unavailable: .disabledBySetting)
        }
        guard !(RemoteConfig.data?.mulligan_guide?.disabled ?? false) else {
            return MulliganGuideResult(unavailable: .disabledRemotely)
        }
        let userOwnsPremium = HSReplayAPI.accountData?.is_premium ?? false
        if let reason = await mulliganGuidePremiumOrTrialGate(isPremium: userOwnsPremium) {
            return MulliganGuideResult(unavailable: reason)
        }
        // Assemble request
        guard let parameters = getMulliganGuideParams() else {
            return MulliganGuideResult(unavailable: .noParams)
        }

        var token: String?
        if !userOwnsPremium {
            let deckCards = currentDeck?.cards.flatMap { card in Array(repeating: card.dbfId, count: max(card.count, 1)) } ?? []
            let trial = await activateMulliganGuideTrial(gameType: parameters.game_type, deckstring: parameters.deckstring, deckCards: deckCards, starLevel: parameters.player_star_level, isMulliganDone: false)
            if let reason = trial.unavailable {
                return MulliganGuideResult(unavailable: reason)
            }
            token = trial.data
        }

        let data = token != nil
            ? await HSReplayAPI.getMulliganGuideData(token: token, parameters: parameters)
            : await HSReplayAPI.getMulliganGuideData(parameters: parameters)
        guard let data else {
            return MulliganGuideResult(unavailable: .requestFailed)
        }
        return MulliganGuideResult(data: data)
    }

    // The part of HDT's premium-or-trials check both guide versions share.
    @available(macOS 10.15.0, *) @MainActor
    private func mulliganGuidePremiumOrTrialGate(isPremium: Bool) async -> MulliganGuideUnavailableReason? {
        let acc = isPremium ? nil : MirrorHelper.getAccountId()
        return await MulliganGuideTrial.shared.premiumOrTrialGate(isPremium: isPremium, signedIn: HSReplayAPI.isFullyAuthenticated, hi: acc?.hi.int64Value, lo: acc?.lo.int64Value)
    }

    // HDT spends a trial only on a deck the pre-lobby status check found
    // coverage for (IsDeckAvailableForMulliganGuide), then ActivateOrContinue.
    @available(macOS 10.15.0, *) @MainActor
    private func activateMulliganGuideTrial(gameType: Int, deckstring: String, deckCards: [Int], starLevel: Int?, isMulliganDone: Bool) async -> MulliganGuideResult<String> {
        guard let bnetGameType = BnetGameType(rawValue: gameType) else {
            return MulliganGuideResult(unavailable: .deckNotAvailable(gameType: gameType, state: "unknown game type"))
        }
        let preLobby = windowManager.constructedMulliganGuidePreLobby.viewModel
        let state = await preLobby.deckStatusForMulliganGuide(gameType: bnetGameType, deckstring: deckstring, dbfIds: deckCards, starLevel: starLevel)
        guard ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(state) else {
            return MulliganGuideResult(unavailable: .deckNotAvailable(gameType: gameType, state: state.map { "\($0)" } ?? "nil"))
        }
        guard let acc = MirrorHelper.getAccountId() else {
            return MulliganGuideResult(unavailable: .noAccountId)
        }
        let isPastMulligan = isMulliganDone || (gameEntity?[.step] ?? 0) > Step.begin_mulligan.rawValue
        let activation = await MulliganGuideTrial.activateOrContinue(hi: acc.hi.int64Value, lo: acc.lo.int64Value, gameHandle: serverInfo?.gameHandle as? Int, isPastMulligan: isPastMulligan)
        guard let token = activation.token else {
            return MulliganGuideResult(unavailable: .trialNotActivated(activation))
        }
        return MulliganGuideResult(data: token)
    }

    func cacheMulliganV2Params(offeredDbfIds: [Int]) {
        if _mulliganV2Params != nil {
            return
        }

        guard let activeDeck = currentDeck else {
            return
        }

        let deckCards = activeDeck.cards.flatMap { card in Array(repeating: card.dbfId, count: max(card.count, 1)) }
        let opponentClass = opponent.playerEntities.first { x in x.isHero && x.isInPlay }?.card.playerClass ?? CardClass.invalid
        let starLevel = playerMedalInfo?.starLevel ?? 0
        let starsPerWin = playerMedalInfo?.starsPerWin ?? 0

        _mulliganV2Params = MulliganV2Params(deckstring: activeDeck.shortid, player_class: activeDeck.playerClass.rawValue.uppercased(), deck_cards: deckCards, opponent_class: opponentClass.rawValue.uppercased(), player_initiative: playerEntity?[.first_player] == 1 ? "FIRST" : "COIN", player_region: Region.toBnetRegion(region: currentRegion), player_star_level: starLevel > 0 ? starLevel : nil, player_star_multiplier: starsPerWin > 0 ? starsPerWin : nil, game_type: BnetGameType.getBnetGameType(gameType: currentGameType, format: Format(formatType: currentFormatType)).rawValue, format_type: currentFormatType.rawValue, offered_cards: offeredDbfIds, mulligan_state: Mulligan.input.rawValue)
        if let params = _mulliganV2Params {
            // HDT CacheMulliganV2Params logs the same line.
            logger.info("--- Caching Mulligan V2 Params --- game_type=\(params.game_type) format_type=\(params.format_type) star_level=\(params.player_star_level.map(String.init) ?? "nil") region=\(params.player_region ?? "nil") player_class=\(params.player_class) opponent_class=\(params.opponent_class) initiative=\(params.player_initiative) deckstring=\(params.deckstring) offered=\(params.offered_cards ?? [])")
        }
    }

    func getMulliganV2Params() -> MulliganV2Params? {
        return _mulliganV2Params
    }

    @available(macOS 10.15.0, *)
    func getMulliganV2Data(isMulliganDone: Bool = false) async -> MulliganGuideResult<MulliganV2Data> {
        let result = await fetchMulliganV2Data(isMulliganDone: isMulliganDone)
        if let reason = result.unavailable {
            logger.info("MulliganV2: no data\(isMulliganDone ? " after mulligan" : "") - \(reason)")
        }
        return result
    }

    // Matches HDT's GameEventHandler.GetMulliganV2Data(): non-premium
    // players spend a trial (reusing one already activated for this
    // same match, via MulliganGuideTrial.activateOrContinue) instead of
    // using the OAuth session, and only for a deck the pre-lobby status
    // check already confirmed has coverage worth spending a trial on.
    @available(macOS 10.15.0, *) @MainActor
    private func fetchMulliganV2Data(isMulliganDone: Bool) async -> MulliganGuideResult<MulliganV2Data> {
        if spectator {
            return MulliganGuideResult(unavailable: .spectator)
        }
        guard Settings.enableMulliganGV2 else {
            return MulliganGuideResult(unavailable: .disabledBySetting)
        }
        guard !(RemoteConfig.data?.mulligan_guide?.disabled ?? false) else {
            return MulliganGuideResult(unavailable: .disabledRemotely)
        }
        let userOwnsPremium = HSReplayAPI.accountData?.is_premium ?? false
        if let reason = await mulliganGuidePremiumOrTrialGate(isPremium: userOwnsPremium) {
            return MulliganGuideResult(unavailable: reason)
        }
        guard let parameters = getMulliganV2Params() else {
            return MulliganGuideResult(unavailable: .noParams)
        }
        parameters.mulligan_state = isMulliganDone ? Mulligan.done.rawValue : Mulligan.input.rawValue

        var token: String?
        if !userOwnsPremium {
            let trial = await activateMulliganGuideTrial(gameType: parameters.game_type, deckstring: parameters.deckstring, deckCards: parameters.deck_cards, starLevel: parameters.player_star_level, isMulliganDone: isMulliganDone)
            if let reason = trial.unavailable {
                return MulliganGuideResult(unavailable: reason)
            }
            token = trial.data
        }

        let data = token != nil
            ? await HSReplayAPI.getConstructedMulliganV2(token: token, parameters: parameters)
            : await HSReplayAPI.getConstructedMulliganV2(parameters: parameters)
        guard let data else {
            return MulliganGuideResult(unavailable: .requestFailed)
        }
        return MulliganGuideResult(data: data)
    }
    
    private func getMulliganGuideParams() -> MulliganGuideParams? {
        return _mulliganGuideParams
    }
    
    @MainActor
    private func showMulliganGuidePreLobby() {
        windowManager.constructedMulliganGuidePreLobby.isVisible = true
        let frame = SizeHelper.constructedMulliganGuidePreLobbyFrame()
        windowManager.show(controller: windowManager.constructedMulliganGuidePreLobby, show: true, frame: frame)
        DispatchQueue.main.async {
            self.windowManager.constructedMulliganGuidePreLobby.updateScaling()
        }
    }
    
    @MainActor
    private func hideMulliganGuidePreLobby() {
        windowManager.constructedMulliganGuidePreLobby.isVisible = false
        windowManager.show(controller: windowManager.constructedMulliganGuidePreLobby, show: false)
    }
    
    @MainActor
    private func showMulliganPreLobbyWidget() {
        guard #available(macOS 10.15, *) else { return }
        windowManager.rootOverlay?.viewModel.constructedMulliganPreLobbyWidget.isShown = true
    }

    @MainActor
    private func hideMulliganPreLobbyWidget() {
        guard #available(macOS 10.15, *) else { return }
        windowManager.rootOverlay?.viewModel.constructedMulliganPreLobbyWidget.isShown = false
    }

    // Matches HDT's UpdateMulliganGuideTrialsExhausted(): a one-time
    // heads-up (never a recurring reminder - Settings.seenMulliganGuideTrialsExhausted
    // gates that) shown exactly when the player's most recent trial
    // activation consumed their last one (MulliganGuideTrial.consumePendingLastTrialAlert,
    // a persisted flag set by Game.getMulliganV2Data's trial activation) and
    // they still have zero remaining and aren't premium by the time they're
    // back in the lobby.
    @available(macOS 10.15, *)
    @MainActor
    private func updateMulliganGuideTrialsExhausted() {
        guard MulliganGuideTrial.shared.shouldShowTrialsExhaustedAlert(seen: Settings.seenMulliganGuideTrialsExhausted, isPremium: HSReplayAPI.accountData?.is_premium ?? false) else {
            return
        }

        Settings.seenMulliganGuideTrialsExhausted = true

        guard let alert = windowManager.rootOverlay?.viewModel.mulliganGuideTrialsExhausted else {
            return
        }
        logger.info("MulliganGuideTrial: showing the one-time trials exhausted alert")
        alert.trialTimeRemaining = MulliganGuideTrial.timeRemaining
        alert.isShown = true
    }

    @available(macOS 10.15, *)
    @MainActor
    private func hideMulliganGuideTrialsExhausted() {
        windowManager.rootOverlay?.viewModel.mulliganGuideTrialsExhausted.isShown = false
    }

    @MainActor
    func updateMulliganGuidePreLobby() {
        applyMulliganGuidePreLobbyVisibility()

        // HDT's UpdateMulliganGuidePreLobbyVisibility awaits
        // MulliganGuideTrial.Update before deciding anything. The port started
        // the refresh detached and decided at once, on the count from before
        // the match. Visibility is applied right away with what is known (so
        // leaving the lobby never waits on the network) and again once the
        // refresh is in; the exhausted alert only fires on a known zero, so
        // the first pass cannot use up its one-time flag.
        if #available(macOS 10.15, *), let acc = MirrorHelper.getAccountId() {
            Task { @MainActor in
                await MulliganGuideTrial.update(hi: acc.hi.int64Value, lo: acc.lo.int64Value)
                self.applyMulliganGuidePreLobbyVisibility()
            }
        }
    }

    @MainActor
    private func applyMulliganGuidePreLobbyVisibility() {
        let inConstructedLobby = isInMenu && SceneHandler.scene == .tournament

        var mulliganGuideTrialsExhaustedVisible = false
        if #available(macOS 10.15, *) {
            if inConstructedLobby {
                updateMulliganGuideTrialsExhausted()
            } else {
                hideMulliganGuideTrialsExhausted()
            }
            mulliganGuideTrialsExhaustedVisible = windowManager.rootOverlay?.viewModel.mulliganGuideTrialsExhausted.isShown ?? false
        }

        // Matches HDT's OverlayWindow.Update.cs UpdateMulliganGuidePreLobbyVisibility():
        // both the badge grid and the widget are gated by the single
        // ShowMulliganGuidePreLobby toggle (not EnableMulliganGuide/
        // EnableMulliganGV2, which HDT doesn't check here at all), ANDed
        // with the trials-exhausted alert taking precedence while it's up.
        // The badge grid used to also require Premium, which HDT does not:
        // players on trials are the ones who need to see which decks have
        // coverage before spending one.
        let show = inConstructedLobby && Settings.showMulliganGuidePreLobby && !mulliganGuideTrialsExhaustedVisible

        if show {
            showMulliganGuidePreLobby()
            if #available(macOS 10.15.0, *) {
                Task.detached { [self] in
                    await windowManager.constructedMulliganGuidePreLobby.viewModel.ensureLoaded()
                }
            }
        } else {
            hideMulliganGuidePreLobby()
        }

        if show {
            showMulliganPreLobbyWidget()
        } else {
            hideMulliganPreLobbyWidget()
        }
    }

    func setDeckPickerState(_ vft: VisualsFormatType, _ decksList: [CollectionDeckBoxVisual?], _ isModalOpen: Bool) {
        let vm = windowManager.constructedMulliganGuidePreLobby.viewModel
        if vm.decksOnPage == nil || decksList != vm.decksOnPage {
            vm.decksOnPage = decksList
        }
        vm.visualsFormatType = vft
        vm.isModalOpen = isModalOpen

        if #available(macOS 10.15, *), let widgetVm = windowManager.rootOverlay?.viewModel.constructedMulliganPreLobbyWidget {
            widgetVm.isModalOpen = isModalOpen
            widgetVm.visualsFormatType = vft
        }
    }

    func setConstructedQueue(_ inQueue: Bool) {
        windowManager.constructedMulliganGuidePreLobby.viewModel.isInQueue = inQueue
        if #available(macOS 10.15, *), let widgetVm = windowManager.rootOverlay?.viewModel.constructedMulliganPreLobbyWidget {
            widgetVm.isInQueue = inQueue
        }
    }
    
    func showMulliganToast(_ shortId: String, _ dbfIds: [Int], _ parameters: [String: String]?, _ showingMulliganStats: Bool = false) {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.mulliganToast
                .show(shortId: shortId, dbfIds: dbfIds, parameters: parameters, showingMulliganStats: showingMulliganStats)
        }
    }
    
    func showBattlegroundsHeroPanel(_ heroIds: [Int], _ duos: Bool, _ parameters: [String: String]?) {
        if #available(macOS 10.15, *) {
            let anomalyDbfId = BattlegroundsUtils.getBattlegroundsAnomalyDbfId(game: gameEntity)
            windowManager.rootOverlay?.viewModel.battlegroundsNotifications
                .showHeroPick(heroIds: heroIds, duos: duos, anomalyDbfId: anomalyDbfId, parameters: parameters)
        }
    }
    
    func hideBattlegroundsHeroPanel() {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.battlegroundsNotifications.hideHeroPick()
        }
    }

    // OverlayWindow._tavernMarkersPanelExpandedBeforeTimewarp.
    private var tavernMarkersPanelExpandedBeforeTimewarp: Bool?

    func showBattlegroundsTimewarpPanel(_ boardCards: [MirrorBoardCard]) {
        if #available(macOS 10.15, *) {
            guard let viewModel = windowManager.rootOverlay?.viewModel else {
                return
            }
            // HDT collapses the Tavern Pinning panel while the Timewarp shop is
            // up and puts it back the way it found it afterwards - the panel
            // shares that corner with the compare-cards shop.
            if !viewModel.battlegroundsNotifications.timewarpIsShown {
                tavernMarkersPanelExpandedBeforeTimewarp = viewModel.battlegroundsMinionPinning.isExpanded
                viewModel.battlegroundsMinionPinning.isExpanded = false
            }
            viewModel.battlegroundsNotifications.showTimewarp(boardCards: boardCards)
        }
    }

    func hideBattlegroundsTimewarpPanel() {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.battlegroundsNotifications.hideTimewarp()

            if let expanded = tavernMarkersPanelExpandedBeforeTimewarp {
                windowManager.rootOverlay?.viewModel.battlegroundsMinionPinning.isExpanded = expanded
                tavernMarkersPanelExpandedBeforeTimewarp = nil
            }
        }
    }

    func hideMulliganToast() {
        if #available(macOS 10.15, *) {
            windowManager.rootOverlay?.viewModel.mulliganToast.hide()
        }
    }
    
    private(set) var duosWasPlayerHeroModified: Bool = false
    private(set) var duosWasOpponentHeroModified: Bool = false

    func duosSetHeroModified(_ isPlayer: Bool) {
        if isPlayer {
            duosWasPlayerHeroModified = true
        } else {
            duosWasOpponentHeroModified = true
        }
    }

    func duosResetHeroTracking() {
        duosWasPlayerHeroModified = false
        duosWasOpponentHeroModified = false
    }
    
    // objectiveEntity identifies a hovered secret/objective-zone entity (e.g. an active
    // Bamboozle on the board) - it stands in for both the hand-hover hoveredEntity (so
    // dynamic pools see the right per-copy state) and the entity fallback (so a card with
    // no pool registered still falls back to its own storedCardIds instead of the deck's).
    func getRelatedCards(player: Player, cardId: String, inHand: Bool = false, handPosition: Int? = nil, objectiveEntity: Entity? = nil) -> [Card?] {
        var relatedCards: [Card?]
        // Dynamic pools (evolve/devolve-style effects) take the hovered entity so per-copy
        // state (upgrade tags, discounted costs) picks the right pool when multiple copies
        // are in hand.
        if let dynamicCard = relatedCardsManager.getCardWithDynamicRelatedCardsSummary(cardId) {
            let hoveredEntity = objectiveEntity ?? (inHand
                ? (handPosition != nil ? player.hand.first { $0.zonePosition == handPosition } : player.hand.first { $0.cardId == cardId })
                : nil)
            let pool = dynamicCard.getPool(player: player, hoveredEntity: hoveredEntity)
            relatedCards = dynamicCard.getRelatedCards(player: player, hoveredEntity: hoveredEntity, pool: pool)
        } else {
            relatedCards = relatedCardsManager.getCardWithRelatedCards(cardId)?.getRelatedCards(player: player) ?? [Card?]()
        }
        // Get related cards from Entity
        if relatedCards.count == 0 {
            var entities = [Entity]()
            if let objectiveEntity {
                entities = [objectiveEntity]
            } else if inHand {
                entities = handPosition != nil ? player.hand.filter { e in e.zonePosition == handPosition } : player.hand.filter { e in e.cardId == cardId }
            } else {
                entities = player.deck.filter { e in e.cardId == cardId }
            }

            for entity in entities {
                relatedCards.append(contentsOf: entity.info.storedCardIds.compactMap { id in Cards.by(cardId: id) })
            }
        }

        return relatedCards
    }
    
    private(set) var hoveredCard: BigCardArgs?
    
    private var delayedTooltip: DelayedTooltip?
    
    @MainActor
    private func updateTooltips() {
        guard #available(macOS 10.15, *) else { return }
        delayedTooltip?.cancel()
        if hoveredCard != nil {
            delayedTooltip = DelayedTooltip(handler: tooltipDisplay, 0.400, nil)
        } else {
            delayedTooltip = nil
            windowManager.tooltipGridCards.hide()
            RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
        }
    }

    @MainActor
    private func tooltipDisplay(_ userInfo: Any?) {
        guard #available(macOS 10.15, *) else { return }
        if let hoveredCard {
            // player hand
            if hoveredCard.isHand && isTraditionalHearthstoneMatch {
                let relatedCards = getRelatedCards(player: player, cardId: hoveredCard.cardId, inHand: true, handPosition: hoveredCard.zonePosition)
                // HDT's SetRelatedCardsTrigger(BigCardState): OutfinderInHand gates the hand hover.
                if relatedCards.count > 0 && Settings.showPlayerRelatedCards &&
                    !relatedCardsManager.isOutfinderSuppressed(cardId: hoveredCard.cardId, surfaceEnabled: Settings.outfinderInHand) {
                    let nonNullableRelatedCards = relatedCards.compactMap { x in x }
                    
                    let tooltipGridCards = windowManager.tooltipGridCards
                    tooltipGridCards.setTitle(String.localizedString("Related_Cards", comment: ""))
                    tooltipGridCards.setCardIdsFromCards(nonNullableRelatedCards, 470)
                    let hoveredEntity = player.hand.first { $0.zonePosition == hoveredCard.zonePosition }
                    let (statistics, summary, hasLargePool) = relatedCardsManager.getPoolStatistics(cardId: hoveredCard.cardId, relatedCards: relatedCards, player: player, hoveredEntity: hoveredEntity)
                    tooltipGridCards.setPoolStatistics(statistics, relatedCardsSummary: summary, hasLargePool: hasLargePool)

                    let frame = SizeHelper.hearthstoneWindow.frame
                    let y = frame.maxY - 480
                    // find the left of the card
                    let cardTotal = hoveredCard.zoneSize > 10 ? hoveredCard.zoneSize : 10
                    let baseOffsetX = 0.34
                    let centerPosition = Double(hoveredCard.zoneSize + 1) / 2.0
                    let relativePosition = Double(hoveredCard.zonePosition) - centerPosition
                    let offsetXScale = hoveredCard.zoneSize > 3 ? Double(cardTotal / hoveredCard.zoneSize) * 0.037 : 0.098
                    let offsetX = baseOffsetX + relativePosition * offsetXScale
                    let correctedOffsetX = SizeHelper.getScaledXPos(offsetX, width: frame.width, ratio: SizeHelper.screenRatio)
                    
                    // find the center of the card
                    let cardHeight = 0.5
                    let cardHeightInPixels = cardHeight * frame.height
                    let cardWidth = cardHeightInPixels * 34 / (cardHeight * 100)
                    let x = correctedOffsetX + cardWidth / 2 - Double(tooltipGridCards.gridWidth) / 2.0
                    let tooltipFrame = NSRect(x: Int(x), y: Int(y), width: tooltipGridCards.gridWidth, height: tooltipGridCards.gridHeight)
                    tooltipGridCards.show(frame: tooltipFrame)
                    RelatedCardsRightClickMonitor.shared.setHoveredLargePool(
                        card: hasLargePool ? Cards.by(cardId: hoveredCard.cardId) : nil,
                        pool: hasLargePool ? nonNullableRelatedCards : [],
                        anchorFrame: tooltipFrame)
                } else {
                    windowManager.tooltipGridCards.hide()
                    RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
                }
                // player secrets/objective zone
            } else if hoveredCard.zonePosition > 0 && hoveredCard.isHand == false && hoveredCard.side == PlayerSide.friendly.rawValue {
                var relatedCards: [Card?] = []
                var hoveredEntity: Entity?
                if let entity = hoveredCard.zonePosition >= 0 && hoveredCard.zonePosition - 1 < player.objectives.count ? player.objectives[hoveredCard.zonePosition - 1] : nil, entity.cardId == hoveredCard.cardId {
                    hoveredEntity = entity
                    relatedCards = getRelatedCards(player: player, cardId: hoveredCard.cardId, objectiveEntity: entity)
                }
                // HSTracker's own zone, with no HDT counterpart; it reaches the tooltip through the
                // same big-card hover trigger as the hand, so it follows that trigger's setting.
                if relatedCards.count > 0 && Settings.showPlayerRelatedCards &&
                    !relatedCardsManager.isOutfinderSuppressed(cardId: hoveredCard.cardId, surfaceEnabled: Settings.outfinderInHand) {
                    let nonNullableRelatedCards = relatedCards.compactMap { $0 }
                    let tooltipGridCards = windowManager.tooltipGridCards
                    tooltipGridCards.setTitle(String.localizedString("Related_Cards", comment: ""))
                    tooltipGridCards.setCardIdsFromCards(nonNullableRelatedCards, 470)
                    let (statistics, summary, hasLargePool) = relatedCardsManager.getPoolStatistics(cardId: hoveredCard.cardId, relatedCards: relatedCards, player: player, hoveredEntity: hoveredEntity)
                    tooltipGridCards.setPoolStatistics(statistics, relatedCardsSummary: summary, hasLargePool: hasLargePool)

                    let frame = SizeHelper.hearthstoneWindow.frame
                    let y = frame.maxY - 480

                    // find the left of the card
                    let baseOffsetX = 0.57
                    let leftOffsetXByLayer =  [ 0.0, 0.037, 0.062 ]
                    let rightOffsetXByLayer =  [ 0.0, 0.034, 0.059 ]
                    let relativePosition = hoveredCard.zonePosition
                    let isLeftSide = relativePosition % 2 != 0
                    let layer = Int(ceil(Double(relativePosition) / 2.0))
                    let offsetX = isLeftSide ? baseOffsetX - leftOffsetXByLayer[layer] : baseOffsetX + rightOffsetXByLayer[layer]
                    let correctedOffsetX = SizeHelper.getScaledXPos(offsetX, width: frame.width, ratio: SizeHelper.screenRatio)

                    // find the center of the card
                    let cardHeight = 0.43
                    let cardHeightInPixels = cardHeight * frame.height
                    let cardWidth = cardHeightInPixels * 31 / (cardHeight * 100)

                    let x = correctedOffsetX + cardWidth / 2 - Double(tooltipGridCards.gridWidth) / 2.0
                    let tooltipFrame = NSRect(x: Int(x), y: Int(y), width: tooltipGridCards.gridWidth, height: tooltipGridCards.gridHeight)
                    tooltipGridCards.show(frame: tooltipFrame)
                    RelatedCardsRightClickMonitor.shared.setHoveredLargePool(
                        card: hasLargePool ? Cards.by(cardId: hoveredCard.cardId) : nil,
                        pool: hasLargePool ? nonNullableRelatedCards : [],
                        anchorFrame: tooltipFrame)
                } else {
                    // Without this the panel keeps whatever the last hover put in
                    // it, so moving onto a card with no related cards reads as
                    // that card having the previous card's pool.
                    windowManager.tooltipGridCards.hide()
                    RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
                }
                // opponent secrets/objective zone
            } else if hoveredCard.zonePosition > 0 && hoveredCard.isHand == false && hoveredCard.side != PlayerSide.friendly.rawValue {
                var relatedCards: [Card?] = []
                var hoveredEntity: Entity?
                if let entity = hoveredCard.zonePosition >= 0 && hoveredCard.zonePosition - 1 < opponent.objectives.count ? opponent.objectives[hoveredCard.zonePosition - 1] : nil, entity.cardId == hoveredCard.cardId {
                    hoveredEntity = entity
                    relatedCards = getRelatedCards(player: opponent, cardId: hoveredCard.cardId, objectiveEntity: entity)
                }
                // As above: the opponent's secrets/objective zone rides the same hover trigger.
                if relatedCards.count > 0 && Settings.showPlayerRelatedCards &&
                    !relatedCardsManager.isOutfinderSuppressed(cardId: hoveredCard.cardId, surfaceEnabled: Settings.outfinderInHand) {
                    let nonNullableRelatedCards = relatedCards.compactMap { $0 }
                    let tooltipGridCards = windowManager.tooltipGridCards
                    tooltipGridCards.setTitle(String.localizedString("Related_Cards", comment: ""))
                    tooltipGridCards.setCardIdsFromCards(nonNullableRelatedCards, 470)
                    let (statistics, summary, hasLargePool) = relatedCardsManager.getPoolStatistics(cardId: hoveredCard.cardId, relatedCards: relatedCards, player: opponent, hoveredEntity: hoveredEntity)
                    tooltipGridCards.setPoolStatistics(statistics, relatedCardsSummary: summary, hasLargePool: hasLargePool)

                    let frame = SizeHelper.hearthstoneWindow.frame
                    let y = frame.maxY - 480
                    
                    // find the left of the card
                    let baseOffsetX = 0.57
                    let leftOffsetXByLayer =  [ 0.0, 0.037, 0.062 ]
                    let rightOffsetXByLayer =  [ 0.0, 0.034, 0.059 ]
                    let relativePosition = hoveredCard.zonePosition
                    let isLeftSide = relativePosition % 2 != 0
                    let layer = Int(ceil(Double(relativePosition) / 2.0))
                    let offsetX = isLeftSide ? baseOffsetX - leftOffsetXByLayer[layer] : baseOffsetX + rightOffsetXByLayer[layer]
                    let correctedOffsetX = SizeHelper.getScaledXPos(offsetX, width: frame.width, ratio: SizeHelper.screenRatio)
                    
                    // find the center of the card
                    let cardHeight = 0.43
                    let cardHeightInPixels = cardHeight * frame.height
                    let cardWidth = cardHeightInPixels * 31 / (cardHeight * 100)
                    
                    let x = correctedOffsetX + cardWidth / 2 - Double(tooltipGridCards.gridWidth) / 2.0
                    let tooltipFrame = NSRect(x: Int(x), y: Int(y), width: tooltipGridCards.gridWidth, height: tooltipGridCards.gridHeight)
                    tooltipGridCards.show(frame: tooltipFrame)
                    RelatedCardsRightClickMonitor.shared.setHoveredLargePool(
                        card: hasLargePool ? Cards.by(cardId: hoveredCard.cardId) : nil,
                        pool: hasLargePool ? nonNullableRelatedCards : [],
                        anchorFrame: tooltipFrame)
                } else {
                    // Same as the friendly zone above: no fresh content means
                    // the panel has to come down, not keep the last card's.
                    windowManager.tooltipGridCards.hide()
                    RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
                }
            } else {
                windowManager.tooltipGridCards.hide()
                RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
            }
        } else {
            windowManager.tooltipGridCards.hide()
            RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
        }
        delayedTooltip = nil
    }
    
    func onBigCardChange(_ state: BigCardArgs) {
        DispatchQueue.main.async {
            // Assigned here rather than on the watcher queue this is called
            // from: everything that reads hoveredCard (updateTooltips and the
            // tooltipDisplay it schedules) is main-thread only, so writing it
            // from the watcher was an unsynchronised write to a shared optional
            // struct - a data race, and one that could hand tooltipDisplay a
            // half-updated hover.
            self.hoveredCard = state
            // HDT's Watchers.OnBigCardChange calls SetCardOpacityMask first:
            // the game is drawing the hovered card blown up, with its tooltips
            // and enchantment list, and the overlay has to get out of the way.
            if #available(macOS 10.15, *) {
                self.windowManager.rootOverlay?.viewModel.setCardOpacityMask(state)
            }
            if self.isTraditionalHearthstoneMatch {
                let isFriendlyCard = state.side == PlayerSide.friendly.rawValue

                self.windowManager.playerTracker.highlightPlayerDeckCards(highlightSourceCardId: isFriendlyCard ? state.cardId : nil)
            }
            self.updateTooltips()
            // Mirrors HDT's SetAnomalyGuidesTrigger(string cardId), called
            // from the same memory-read big-card-hover callback as
            // SetRelatedCardsTrigger - shows the anomaly guide tooltip
            // whenever the currently-hovered card (per the mirror) is the
            // battleground anomaly badge.
            if #available(macOS 10.15, *) {
                self.windowManager.rootOverlay?.viewModel.battlegroundsAnomalyGuides.updateHoveredCard(cardId: state.cardId)
            }
        }
    }
    
    func setRelatedCardsTrigger(_ state: DiscoverStateArgs) {
        // Note: To debug behavior here and/or implement new triggers set a translucent
        // Background (e.g. #40FF0000) on the RelatedCardsTrigger Grid in Overlay.xaml.
        guard #available(macOS 10.15, *) else { return }

        // This runs on the DiscoverStateWatcher queue. windowManager.tooltipGridCards
        // resolves to RelatedCardsTooltipPanel.shared, whose lazy init instantiates an
        // NSPanel, so every access to the panel - reads included - has to be on the main
        // thread.
        if state.cardId == "" {
            DispatchQueue.main.async {
                let vm = self.windowManager.tooltipGridCards
                if vm.cards.count > 0 {
                    vm.hide()
                }
                RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
            }
            return
        }

        // Not ideal. Maybe we re-position the tooltip on size change and canvas.top/left change?

        // HDT's SetRelatedCardsTrigger(DiscoverState) gates this one on OutfinderInDeck.
        // Anything that is not a tooltip to show has to take the current one
        // down: this used to just return, leaving the previously hovered card's
        // pool on screen as if it belonged to the card now under the cursor.
        guard Settings.showPlayerRelatedCards,
              !relatedCardsManager.isOutfinderSuppressed(cardId: state.cardId, surfaceEnabled: Settings.outfinderInDeck) else {
            hideRelatedCardsTooltip()
            return
        }
        let relatedCards = getRelatedCards(player: player, cardId: state.cardId)
        guard relatedCards.count > 0 else {
            hideRelatedCardsTooltip()
            return
        }
        
        let frame = SizeHelper.hearthstoneWindow.frame
        
        let top = frame.height * 0.2
        let height = frame.height * 0.53
        let width = frame.height * 0.3
        var left = 0.0
        var tooltipPlacement = PlacementMode.right
        
        switch state.zoneSize {
        case 4:
            left = (0.116 + Double(state.zonePosition) * 0.2) * frame.width
            tooltipPlacement = state.zonePosition < 2 ? PlacementMode.right : PlacementMode.left
        case 3:
            let centerPosition = 1
            let offsetXScale = 0.2
            
            let relativePosition = state.zonePosition - centerPosition
            let offsetX = 0.5 - 0.088 + Double(relativePosition) * offsetXScale
            left = offsetX * frame.width
            tooltipPlacement = PlacementMode.right
        case 2:
            left = state.zonePosition == 0 ? 0.318 * frame.width : 0.518 * frame.width
            tooltipPlacement = state.zonePosition == 0 ? PlacementMode.left : PlacementMode.right
        case 1:
            left = (0.5 - 0.088) * frame.width
            tooltipPlacement = PlacementMode.left
        default:
            break
        }
        
        DispatchQueue.main.async {
            let vm = self.windowManager.tooltipGridCards
            let nonNullableRelatedCards = relatedCards.compactMap({ $0 })
            vm.setTitle(String.localizedString("Related_Cards", comment: ""))
            // Content first, then measure. Reading gridWidth/gridHeight
            // before handing the panel its new cards sized this tooltip from
            // the *previous* one, which put it on the wrong side of the
            // card - and off screen entirely when the pools differed a lot.
            vm.setCardIdsFromCards(nonNullableRelatedCards)
            let (statistics, summary, hasLargePool) = self.relatedCardsManager.getPoolStatistics(cardId: state.cardId, relatedCards: relatedCards, player: self.player)
            vm.setPoolStatistics(statistics, relatedCardsSummary: summary, hasLargePool: hasLargePool)

            let tooltipWidth = CGFloat(vm.gridWidth)
            let tooltipHeight = CGFloat(vm.gridHeight)

            // Correct placement if tooltip would go outside of window, and it fit on the other side
            switch tooltipPlacement {
            case PlacementMode.top:
                if top - tooltipHeight < 0.0 && top + height + tooltipHeight <= frame.height {
                    tooltipPlacement = PlacementMode.bottom
                }
            case PlacementMode.bottom:
                if top + height + tooltipHeight > frame.height && top - tooltipHeight >= 0.0 {
                    tooltipPlacement = PlacementMode.top
                }
            case PlacementMode.left:
                if left - tooltipWidth < 0.0 && left + width + tooltipWidth <= frame.width {
                    tooltipPlacement = PlacementMode.right
                }
            case PlacementMode.right:
                if left + width + tooltipWidth > frame.width && left - tooltipWidth >= 0.0 {
                    tooltipPlacement = PlacementMode.left
                }
            }

            let tooltipFrame = NSRect(x: left, y: frame.height - top - tooltipHeight, width: tooltipWidth, height: tooltipHeight)
            vm.show(frame: tooltipFrame)
            RelatedCardsRightClickMonitor.shared.setHoveredLargePool(
                card: hasLargePool ? Cards.by(cardId: state.cardId) : nil,
                pool: hasLargePool ? nonNullableRelatedCards : [],
                anchorFrame: tooltipFrame)
        }
    }

    /// Takes the shared related-cards panel down, from any thread.
    @available(macOS 10.15, *)
    private func hideRelatedCardsTooltip() {
        DispatchQueue.main.async {
            self.windowManager.tooltipGridCards.hide()
            RelatedCardsRightClickMonitor.shared.clearHoveredLargePool()
        }
    }
    
    func handlePlayerMaxHealthChange(_ value: Int) {
        player.maxHealth = value
        updatePlayerResourcesWidget()
    }
    
    func handleOpponentMaxHealthChange(_ value: Int) {
        opponent.maxHealth = value
        updateOpponentResourcesWidget()
    }
    
    func handlePlayerMaxManaChange(_ value: Int) {
        player.maxMana = value
        updatePlayerResourcesWidget()
    }
    
    func handleOpponentMaxManaChange(_ value: Int) {
        opponent.maxMana = value
        updateOpponentResourcesWidget()
    }
    
    func handlePlayerMaxHandSizeChange(_ value: Int) {
        player.maxHandSize = value
        updatePlayerResourcesWidget()
    }
    
    func handleOpponentMaxHandSizeChange(_ value: Int) {
        opponent.maxHandSize = value
        updateOpponentResourcesWidget()
    }

    func handlePlayerCorpsesLeftChange(_ value: Int) {
        player.corpsesLeft = value
        updatePlayerResourcesWidget()
    }

    func handleOpponentCorpsesLeftChange(_ value: Int) {
        opponent.corpsesLeft = value
        updateOpponentResourcesWidget()
    }

    func resetPlayerResourcesWidgets() {
        resetPlayerResourcesWidgets(player.maxHealth, player.maxMana, player.maxHandSize)
    }

    func updatePlayerResourcesWidget() {
        let shouldShowCorpsesLeft = Settings.showPlayerCorpsesCounter
        updatePlayerResourcesWidget(player.maxHealth, player.maxMana, player.maxHandSize, shouldShowCorpsesLeft ? player.corpsesLeft : nil)
    }

    func updateOpponentResourcesWidget() {
        let shouldShowCorpsesLeft = Settings.showOpponentCorpsesCounter && opponent.hasDeathKnightTourist
        updateOpponentResourcesWidget(opponent.maxHealth, opponent.maxMana, opponent.maxHandSize, shouldShowCorpsesLeft ? opponent.corpsesLeft : nil)
    }

    func resetPlayerResourcesWidgets(_ maxHealth: Int, _ maxMana: Int, _ maxHandSize: Int) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.playerPlayerResourcesOverlay?.viewModel.initialize(maxHealth, maxMana, maxHandSize)
                self.windowManager.opponentPlayerResourcesOverlay?.viewModel.initialize(maxHealth, maxMana, maxHandSize)
            }
        }
    }

    func updatePlayerResourcesWidget(_ maxHealth: Int, _ maxMana: Int, _ maxHandSize: Int, _ corpsesLeft: Int? = nil) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.playerPlayerResourcesOverlay?.viewModel.updatePlayerResourcesWidget(maxHealth, maxMana, maxHandSize, corpsesLeft)
            }
        }
    }
    
    func updateOpponentResourcesWidget(_ maxHealth: Int, _ maxMana: Int, _ maxHandSize: Int, _ corpsesLeft: Int?) {
        if #available(macOS 10.15, *) {
            DispatchQueue.main.async {
                self.windowManager.opponentPlayerResourcesOverlay?.viewModel.updatePlayerResourcesWidget(maxHealth, maxMana, maxHandSize, corpsesLeft)
            }
        }
    }
    
    func updatePlayerResorucesWidgetVisibility() {
        if #available(macOS 10.15, *) {
            if isInMenu || !isMulliganDone() || isBattlegroundsMatch() {
                windowManager.playerPlayerResourcesOverlay?.viewModel.visibility = false
                windowManager.opponentPlayerResourcesOverlay?.viewModel.visibility = false
            } else {
                windowManager.playerPlayerResourcesOverlay?.viewModel.visibility = Settings.showPlayerMaxResources
                windowManager.opponentPlayerResourcesOverlay?.viewModel.visibility = Settings.showOpponentMaxResources
            }
        }
    }
}

// MARK: NSWindowDelegate functions
extension Game: NSWindowDelegate {
    
    func windowDidResize(_ notification: Notification) {
        
        guard let window = notification.object as? NSWindow else { return }
        
        if window == self.windowManager.playerTracker.window {
            self.updatePlayerTracker(reset: false)
            onWindowMove(tracker: self.windowManager.playerTracker)
        } else if window == self.windowManager.opponentTracker.window {
            self.updateOpponentTracker(reset: false)
            onWindowMove(tracker: self.windowManager.opponentTracker)
        }
    }
    
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == self.windowManager.playerTracker.window {
            onWindowMove(tracker: self.windowManager.playerTracker)
        } else if window == self.windowManager.opponentTracker.window {
            onWindowMove(tracker: self.windowManager.opponentTracker)
        }
    }
    
    private func onWindowMove(tracker: Tracker) {
        if !tracker.isWindowLoaded || !tracker.hasValidFrame {return}
        if tracker.playerType == .player {
            Settings.playerTrackerFrame = tracker.window?.frame
        } else {
            Settings.opponentTrackerFrame = tracker.window?.frame
        }
    }
}
