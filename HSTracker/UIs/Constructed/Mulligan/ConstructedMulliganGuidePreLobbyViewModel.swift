//
//  ConstructedMulliganGuidePreLobbyViewModel.swift
//  HSTracker
//
//  Created by Francisco Moraes on 2/29/24.
//  Copyright © 2024 Benjamin Michotte. All rights reserved.
//

import Foundation

enum SingleDeckState {
    case invalid,
         loading, // indicates that a task is currently fetching some
         no_data,
         v1_ready,
         v2_ready,
         v2_partial
}

class SingleDeckStatus {
    private(set) var visibility: Bool
    private(set) var state: SingleDeckState
    private(set) var hasRunes: Bool
    private(set) var isFocused: Bool
    var padding: Int {
        return hasRunes ? 29 : 15
    }
    
    init() {
        visibility = false
        state = .invalid
        hasRunes = false
        isFocused = false
    }
    
    init(state: SingleDeckState, hasRunes: Bool, isFocused: Bool) {
        self.visibility = true
        self.state = state
        self.hasRunes = hasRunes
        self.isFocused = isFocused
    }
    
    var iconVisibility: Bool {
        return switch state {
        case .v1_ready, .v2_ready, .v2_partial, .no_data, .loading:
            true
        default:
            false
        }
    }

    var iconSource: NSImage? {
        return switch state {
        case .no_data:
            NSImage(named: "mulligan-guide-no-data")
        default:
            NSImage(named: "mulligan-guide-data")
        }
    }

    var borderBrush: String {
        return switch state {
        case .no_data:
            "#CCE3D000"
        case .v2_partial:
            "#CCE0A200"
        default:
            "#CC00AA00"
        }
    }

    var background: String {
        return switch state {
        case .no_data:
            "#CC1A1100"
        case .v2_partial:
            "#CC221900"
        default:
            "#CC002200"
        }
    }

    var label: String {
        return switch state {
        case .loading:
            String.localizedString("ConstructedMulliganGuidePreLobby_Status_Loading", comment: "")
        case .no_data:
            String.localizedString("ConstructedMulliganGuidePreLobby_Status_NoData", comment: "")
        case .v1_ready:
            String.localizedString("ConstructedMulliganGuidePreLobby_Status_V1Ready", comment: "")
        case .v2_ready:
            String.localizedString("ConstructedMulliganGuidePreLobby_Status_V2Ready", comment: "")
        case .v2_partial:
            String.localizedString("ConstructedMulliganGuidePreLobby_Status_Partial", comment: "")
        default:
            "\(state)"
        }
    }
    
    var labelVisibility: Bool {
        return isFocused
    }
}

class ConstructedMulliganGuidePreLobbyViewModel: ViewModel {
    private var _deckStatusByDeckstring = [BnetGameType: [String: SingleDeckState]]()

    // _deckStatusByDeckstring and _decksByFormatAndDeckId are touched from
    // several threads at once: the deck picker watcher polls every 200ms and
    // any change (down to a deck box gaining focus under the mouse) spawns a
    // detached ensureLoaded(), while scene transitions call invlidateAllDecks()
    // and stopTracking() calls reset() from their own threads. Swift
    // dictionaries are not safe under concurrent mutation, so every access to
    // those two goes through this lock.
    private let _lock = UnfairLock()

    // Serializes ensureLoaded(): while one pass is running, a second caller
    // only asks for one more pass afterwards instead of running in parallel.
    private var _updateInFlight = false
    private var _updateRequested = false

    // A status request that failed is not an answer about coverage, so its
    // decks are left unknown rather than recorded as NO_DATA - which used to
    // stick for the whole session, and made the game refuse to spend a trial
    // on those decks until HSTracker was restarted. The lobby waits this long
    // before asking again for a game type whose request failed, since any
    // deck picker change (down to a deck box gaining focus) starts a pass.
    static let statusRetryDelay: TimeInterval = 60
    private var _statusRetryAfter = [BnetGameType: Date]()
    var now: () -> Date = { Date() }
    // A StatusLoader; stored untyped because async function types need
    // macOS 10.15 and a stored property cannot be marked available.
    private var _statusLoader: Any?
    
    override init() {
        // TODO: HSReplayNetOAuth.AccountDataUpdated += () => Core.Overlay.UpdateMulliganGuidePreLobby();
        // TODO: HSReplayNetOAuth.LoggedOut += () => Core.Overlay.UpdateMulliganGuidePreLobby();
    }
    
    // MARK: - Pagination
    var decksOnPage: [CollectionDeckBoxVisual?]? {
        get {
            return getProp(nil)
        }
        set {
            setProp(newValue)
            onPropertyChanged("pageStatus")
            onPropertyChanged("pageStatusRows")
            onPropertyChanged("validDecksOnPage")
        }
    }
 
    var validDecksOnPage: [CollectionDeckBoxVisual?]? {
        return decksOnPage?.map { x in
            guard let x else {
                return nil
            }
            if x.isShowingInvalidCardCount || x.invalidSideboardCardCount > 0 || x.missingSideboardCardCount > 0 {
                return nil
            }
            return x
        }
    }
    
    // MARK: - Deckstrings
    
    struct DeckData {
        var deckstring: String
        var hasRunes: Bool
        var dbfIds: [Int]
    }
    
    private var _decksByFormatAndDeckId = [FormatType: [Int64: DeckData]]()
    
    private static func isElligibleForFormat(deck: MirrorDeck, formatType: FormatType) -> Bool {
        let deckFormat = FormatType(rawValue: deck.formatType.intValue) ?? FormatType.ft_unknown
        return switch formatType {
        case .ft_standard:
            deckFormat == .ft_standard
        case .ft_wild:
            deckFormat == .ft_standard || deckFormat == .ft_wild
        case .ft_classic:
            deckFormat == .ft_classic
        case .ft_twist:
            deckFormat == .ft_twist
        default:
            false
        }
    }
    
    private static func getDeckDataByDeckId(formatType: FormatType) -> [Int64: DeckData] {
        var cache = [Int64: DeckData]()
        
        guard let decks = MirrorHelper.getDecks() else {
            return cache
        }
        for deck in decks {
            if !isElligibleForFormat(deck: deck, formatType: formatType) {
                continue
            }
            
            guard let hearthDbDeck = HearthDbConverter.toHearthDbDeck(deck: deck, format: formatType) else {
                continue
            }
            let dbfIds = hearthDbDeck.cards.flatMap { card in Array(repeating: card.dbfId, count: max(card.count, 1)) }
            let deckData = DeckData(deckstring: DeckSerializer.serialize(deck: hearthDbDeck) ?? "", hasRunes: hearthDbDeck.getHero()?.playerClass == .deathknight || hearthDbDeck.cards.any { x in x.tourist == CardClass.allCases.firstIndex(of: .deathknight) }, dbfIds: dbfIds)
            cache[deck.id.int64Value] = deckData
        }
        return cache
    }
    
    private func cachedDecks(formatType: FormatType) -> [Int64: DeckData] {
        if let cached = _lock.around({ _decksByFormatAndDeckId[formatType] }) {
            return cached
        }
        // getDeckDataByDeckId() reads the whole collection through the mirror,
        // so it runs outside the lock.
        let cache = ConstructedMulliganGuidePreLobbyViewModel.getDeckDataByDeckId(formatType: formatType)
        _lock.around {
            _decksByFormatAndDeckId[formatType] = cache
        }
        return cache
    }
    
    // MARK: - VisualsFormatType
    
    var visualsFormatType: VisualsFormatType {
        get {
            return getProp(.vft_unknown)
        }
        set {
            setProp(newValue)
            onPropertyChanged("gameType")
            onPropertyChanged("formatType")
            onPropertyChanged("pageStatus")
            onPropertyChanged("pageStatusRows")
            if #available(macOS 10.15.0, *) {
                Task.detached {
                    await self.ensureLoaded()
                }
            }
        }
    }
    
    private var gameType: BnetGameType {
        return ConstructedMulliganGuidePreLobbyViewModel.gameType(for: visualsFormatType)
    }

    private static func gameType(for visualsFormatType: VisualsFormatType) -> BnetGameType {
        return switch visualsFormatType {
        case .vft_standard:
            BnetGameType.bgt_ranked_standard
        case .vft_wild:
            BnetGameType.bgt_ranked_wild
        case .vft_twist:
            BnetGameType.bgt_ranked_twist
        case .vft_casual:
            BnetGameType.bgt_casual_wild
        default:
            BnetGameType.bgt_unknown
        }
    }
    
    var formatType: FormatType {
        return ConstructedMulliganGuidePreLobbyViewModel.formatType(for: visualsFormatType)
    }

    private static func formatType(for visualsFormatType: VisualsFormatType) -> FormatType {
        return switch visualsFormatType {
        case .vft_standard:
            FormatType.ft_standard
        case .vft_wild:
            FormatType.ft_wild
        case .vft_twist:
            FormatType.ft_twist
        case .vft_casual:
            FormatType.ft_wild
        default:
            FormatType.ft_unknown
        }
    }
    
    // MARK: - Visibility
    var isModalOpen: Bool {
        get {
            return getProp(false)
        }
        set {
            setProp(newValue)
            onPropertyChanged("visibility")
        }
    }
    
    var isInQueue: Bool {
        get {
            return getProp(false)
        }
        set {
            setProp(newValue)
            onPropertyChanged("visibility")
        }
    }
    
    var visibility: Bool {
        return isModalOpen || isInQueue ? false : true
    }
    
    // MARK: -

    // Single entry point for the status lookup, matching HDT's
    // LoadMulliganGuideStatus(): it dedupes the decks before picking the V1 or
    // V2 endpoint. Two different deck ids can carry the same deckstring - most
    // easily when DeckSerializer.serialize() fails and getDeckDataByDeckId()
    // falls back to "", but also for a plain duplicate deck in the collection -
    // and update()'s "already loading" guard can miss those, so the deckstrings
    // reaching the request are made distinct here rather than trusted. Decks
    // with no deckstring at all are dropped: the API has nothing to say about
    // them and they would only ever come back NO_DATA.
    // Returns nil when the request failed, as opposed to an answer of no data.
    @available(macOS 10.15.0, *)
    typealias StatusLoader = (_ gameType: BnetGameType, _ starLevel: Int?, _ decks: [DeckData]) async -> [String: SingleDeckState]?

    // Replaced in tests.
    @available(macOS 10.15.0, *)
    var statusLoader: StatusLoader {
        get {
            return (_statusLoader as? StatusLoader) ?? { gameType, starLevel, decks in
                await ConstructedMulliganGuidePreLobbyViewModel.loadStatus(gameType: gameType, starLevel: starLevel, decks: decks)
            }
        }
        set {
            _statusLoader = newValue
        }
    }

    @available(macOS 10.15.0, *)
    private static func loadStatus(gameType: BnetGameType, starLevel: Int?, decks: [DeckData]) async -> [String: SingleDeckState]? {
        var seen = Set<String>()
        let distinctDecks = decks.filter { deck in
            !deck.deckstring.isEmpty && seen.insert(deck.deckstring).inserted
        }
        if distinctDecks.count == 0 {
            return [String: SingleDeckState]()
        }
        return gameType == .bgt_ranked_standard
            ? await loadMulliganV2Status(gameType: gameType, starLevel: starLevel, decks: distinctDecks)
            : await loadMulliganGuideStatus(gameType: gameType, starLevel: starLevel, decks: distinctDecks)
    }

    @available(macOS 10.15.0, *)
    private static func loadMulliganGuideStatus(gameType: BnetGameType, starLevel: Int?, decks: [DeckData]) async -> [String: SingleDeckState]? {
        if decks.count == 0 {
            return [String: SingleDeckState]()
        }

        let deckstrings = decks.map { $0.deckstring }
        let parameters = MulliganGuideStatusParams(decks: deckstrings, game_type: gameType.rawValue, star_level: starLevel)
        guard let result = await HSReplayAPI.getMulliganGuideStatus(parameters: parameters) else {
            return nil
        }
        // uniquingKeysWith rather than uniqueKeysWithValues: the latter traps
        // at runtime on a repeated key, and nothing here can guarantee the
        // deckstrings are distinct (see loadStatus()).
        return Dictionary(deckstrings.map { x in
            let status = result.decks[x].map { MulliganGuideStatusData.Status(rawValue: $0.status) ?? .NO_DATA } ?? .NO_DATA
            return (x, status == .READY ? SingleDeckState.v1_ready : SingleDeckState.no_data)
        }, uniquingKeysWith: { first, _ in first })
    }

    // Standard Ranked/Friendly decks are checked against the Mulligan G-V2
    // status endpoint instead, which needs each deck's dbfIds (not just its
    // deckstring) to evaluate partial coverage card-by-card.
    @available(macOS 10.15.0, *)
    private static func loadMulliganV2Status(gameType: BnetGameType, starLevel: Int?, decks: [DeckData]) async -> [String: SingleDeckState]? {
        if decks.count == 0 {
            return [String: SingleDeckState]()
        }

        // AppDelegate.instance().coreManager.game.currentRegion is a plain
        // cached property read (populated once, non-blocking, at tracking
        // startup - see CoreManager.swift) rather than calling
        // Helper.getCurrentRegion() directly here, which does its own
        // blocking retry loop (up to 10 * 2s sleeps) and would stall this
        // status refresh.
        let parameters = MulliganV2StatusParams(
            deck_boxes: decks.map { MulliganV2StatusParams.Deck(deckstring: $0.deckstring, dbf_ids: $0.dbfIds) },
            game_type: gameType.rawValue,
            star_level: starLevel,
            player_region: Region.toBnetRegion(region: AppDelegate.instance().coreManager.game.currentRegion)
        )
        guard let result = await HSReplayAPI.getMulliganV2Status(parameters: parameters) else {
            return nil
        }
        // The response is not guaranteed to carry each deckstring only once,
        // so both of these dictionaries are built with uniquingKeysWith -
        // uniqueKeysWithValues would trap on a repeat.
        let statusByDeckstring = Dictionary(result.data.map { ($0.deckstring, $0.status) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(decks.map { deck in
            let status = statusByDeckstring[deck.deckstring].map { MulliganV2StatusData.Status(rawValue: $0) ?? .NONE } ?? .NONE
            let state: SingleDeckState = switch status {
            case .SUPPORTED: .v2_ready
            case .PARTIAL: .v2_partial
            case .NONE: .no_data
            }
            return (deck.deckstring, state)
        }, uniquingKeysWith: { first, _ in first })
    }
    
    @available(macOS 10.15.0, *)
    func ensureLoaded() async {
        let alreadyRunning = _lock.around { () -> Bool in
            if _updateInFlight {
                _updateRequested = true
                return true
            }
            _updateInFlight = true
            return false
        }
        if alreadyRunning {
            return
        }
        while true {
            await update(true)
            await update()
            let runAgain = _lock.around { () -> Bool in
                if _updateRequested {
                    _updateRequested = false
                    return true
                }
                _updateInFlight = false
                return false
            }
            if !runAgain {
                break
            }
        }
    }
    
    @available(macOS 10.15.0, *)
    private func update(_ onlyVisibilePage: Bool = false) async {
        // visualsFormatType is snapshotted once here, and gameType/formatType
        // derived from that snapshot, because the deck picker watcher can
        // change it from its own thread at any point. Re-reading the computed
        // properties as the pass went along used to let gameType flip to a key
        // with no entry in _deckStatusByDeckstring yet, which silently turned
        // the "already loading" marker writes into no-ops and let the same
        // deckstring be queued twice.
        let theVisualsFormatType = visualsFormatType
        let theGameType = ConstructedMulliganGuidePreLobbyViewModel.gameType(for: theVisualsFormatType)
        let theFormatType = ConstructedMulliganGuidePreLobbyViewModel.formatType(for: theVisualsFormatType)

        if theGameType == .bgt_unknown || theFormatType == .ft_unknown {
            return
        }
        
        // Generate the deckstrings for the current format
        
        let deckboxes = cachedDecks(formatType: theFormatType)
        
        // Assemble the deck strings that are not known yet
        var candidates = [DeckData]()
        if onlyVisibilePage {
            guard let validDecksOnPage else {
                return
            }
            for box in validDecksOnPage {
                guard let box, let deckId = box.deckid, let deckData = deckboxes[deckId] else {
                    continue
                }
                candidates.append(deckData)
            }
        } else {
            candidates = [DeckData](deckboxes.values)
        }

        // Claim the decks whose status isn't known (or already being fetched)
        // yet. Marking them .loading under the lock is what keeps a concurrent
        // pass from claiming the same deck, and the statuses are updated as one
        // local copy so a claim can never be lost to optional chaining on a
        // missing gameType entry.
        let toLoad = claimDecksToLoad(gameType: theGameType, candidates: candidates)
        
        onPropertyChanged("pageStatus")
        onPropertyChanged("pageStatusRows")
        
        // Assemble the request
        if toLoad.count > 0 {
            let medalInfo = MirrorHelper.getMedalData()
            var starLevel: Int?
            if let medalInfo {
                let medalInfoData: MirrorMedalInfo? = switch theVisualsFormatType {
                case .vft_standard:
                    medalInfo.standard
                case .vft_wild:
                    medalInfo.wild
                case .vft_classic:
                    medalInfo.classic
                case .vft_twist:
                    medalInfo.twist
                default:
                    nil
                }
                starLevel = medalInfoData?.starLevel.intValue
            }
            // theGameType was copied out above, because it can change while
            // awaiting the mulligan guide status => this would lead to a "miscache"
            let results = await statusLoader(theGameType, starLevel, toLoad)
            finishLoading(gameType: theGameType, claimed: toLoad, results: results)
            
            onPropertyChanged("pageStatus")
            onPropertyChanged("pageStatusRows")
        }
    }
    
    func claimDecksToLoad(gameType: BnetGameType, candidates: [DeckData]) -> [DeckData] {
        return _lock.around { () -> [DeckData] in
            var claimed = [DeckData]()
            var statuses = _deckStatusByDeckstring[gameType] ?? [String: SingleDeckState]()
            let retryAfter = _statusRetryAfter[gameType]
            let canRequest = retryAfter.map { now() >= $0 } ?? true
            for deck in candidates where statuses[deck.deckstring] == nil {
                // A deck DeckSerializer.serialize() could not encode has no
                // deckstring to ask the API about: record it as no data rather
                // than queueing it (several such decks would otherwise all
                // queue under the same empty deckstring).
                if deck.deckstring.isEmpty {
                    statuses[deck.deckstring] = .no_data
                    continue
                }
                if !canRequest {
                    continue
                }
                claimed.append(deck)
                statuses[deck.deckstring] = .loading
            }
            _deckStatusByDeckstring[gameType] = statuses
            return claimed
        }
    }

    func finishLoading(gameType: BnetGameType, claimed: [DeckData], results: [String: SingleDeckState]?) {
        guard let results else {
            logger.warning("MulliganGuide: deck status request failed for gameType=\(gameType), \(claimed.count) decks left unknown")
            _lock.around {
                _statusRetryAfter[gameType] = now().addingTimeInterval(ConstructedMulliganGuidePreLobbyViewModel.statusRetryDelay)
                for deck in claimed where _deckStatusByDeckstring[gameType]?[deck.deckstring] == .loading {
                    _deckStatusByDeckstring[gameType]?.removeValue(forKey: deck.deckstring)
                }
            }
            return
        }
        _lock.around {
            _statusRetryAfter.removeValue(forKey: gameType)
            for result in results {
                _deckStatusByDeckstring[gameType]?[result.key] = result.value
            }
        }
    }

    var pageStatus: [SingleDeckStatus] {
        let theVisualsFormatType = visualsFormatType
        let theGameType = ConstructedMulliganGuidePreLobbyViewModel.gameType(for: theVisualsFormatType)
        let theFormatType = ConstructedMulliganGuidePreLobbyViewModel.formatType(for: theVisualsFormatType)
        let snapshot = _lock.around { (_decksByFormatAndDeckId[theFormatType], _deckStatusByDeckstring[theGameType]) }
        guard let validDecksOnPage, theFormatType != .ft_unknown, let deckMap = snapshot.0, let allDecks = snapshot.1 else {
            return [SingleDeckStatus]()
        }
        return validDecksOnPage.compactMap { x in
            if let box = x, let deckId = box.deckid, let deckData = deckMap[deckId] {
                // At this point we know the deck is valid for this format, so either fetch the API status or show NO_DATA
                if let state = allDecks[deckData.deckstring] {
                    return SingleDeckStatus(state: state, hasRunes: deckData.hasRunes, isFocused: box.isFocused || box.isSelected)
                }
                return SingleDeckStatus(state: .no_data, hasRunes: deckData.hasRunes, isFocused: box.isSelected)
            }
            return SingleDeckStatus()
        }
    }
    
    // PageStatus, but grouped into 3 rows of 3 cols
    var pageStatusRows: [[SingleDeckStatus]] {

        return pageStatus.chunks(3)
    }
    
    func invalidateDeck(deckId: Int64) {
        // Clear from deckId -> deckstring mapping
        _lock.around {
            for formatType in _decksByFormatAndDeckId.keys {
                _decksByFormatAndDeckId[formatType]?.removeValue(forKey: deckId)
            }
        }
    }
    
    func invlidateAllDecks() {
        _lock.around {
            _decksByFormatAndDeckId.removeAll()
        }
    }

    // Matches HDT's GameEventHandler.IsDeckAvailableForMulliganGuide(): reuses
    // this same badge-grid status cache to decide whether a non-premium
    // player's trial should even be spent on this deck - only decks the
    // status check already confirmed have real (or partial) coverage are
    // worth burning a trial on.
    func isDeckAvailableForMulliganGuide(gameType: BnetGameType, deckstring: String) -> Bool {
        return ConstructedMulliganGuidePreLobbyViewModel.isAvailableForMulliganGuide(_lock.around({ _deckStatusByDeckstring[gameType]?[deckstring] }))
    }

    static func isAvailableForMulliganGuide(_ state: SingleDeckState?) -> Bool {
        switch state {
        case .v1_ready, .v2_ready, .v2_partial:
            return true
        default:
            return false
        }
    }

    // The game types the deck picker itself asks about (see gameType(for:)).
    private static let lobbyGameTypes: Set<BnetGameType> = [.bgt_ranked_standard, .bgt_ranked_wild, .bgt_ranked_twist, .bgt_casual_wild]

    // The cached status for the deck being played, fetched for that one deck
    // when the lobby never cached it. The lobby builds its keys from the
    // mirror's deck list while the game builds them from the tracked deck, and
    // the two deckstrings can differ (sideboards, a hero skin changed after
    // the deck was imported); a miss used to mean a trial was never spent on a
    // deck that has coverage, without a word in the log. HDT has no fallback.
    @available(macOS 10.15.0, *)
    func deckStatusForMulliganGuide(gameType: BnetGameType, deckstring: String, dbfIds: [Int], starLevel: Int?) async -> SingleDeckState? {
        if deckstring.isEmpty {
            return nil
        }
        // A lobby pass may be fetching this deck right now; give it a moment
        // rather than asking twice.
        for _ in 0 ..< 30 {
            let cached = _lock.around { _deckStatusByDeckstring[gameType]?[deckstring] }
            if let cached, cached != .loading {
                return cached
            }
            if cached == nil {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let cachedCount = _lock.around { _deckStatusByDeckstring[gameType]?.count ?? 0 }
        logger.info("MulliganGuide: deck status not cached for gameType=\(gameType) deckstring=\(deckstring) (\(cachedCount) decks cached for it)")
        guard ConstructedMulliganGuidePreLobbyViewModel.lobbyGameTypes.contains(gameType) else {
            return nil
        }
        // Asked once per game whatever the lobby's retry delay: this is the
        // request that decides whether this game gets its guide.
        guard let results = await statusLoader(gameType, starLevel, [DeckData(deckstring: deckstring, hasRunes: false, dbfIds: dbfIds)]) else {
            logger.info("MulliganGuide: deck status request failed, not cached so the next game asks again")
            return nil
        }
        guard let state = results[deckstring] else {
            return nil
        }
        _lock.around {
            _deckStatusByDeckstring[gameType, default: [String: SingleDeckState]()][deckstring] = state
        }
        logger.info("MulliganGuide: fetched deck status \(state) for the active deck")
        return state
    }

    func reset() {
        _lock.around {
            _decksByFormatAndDeckId.removeAll()
            _deckStatusByDeckstring.removeAll()
            _statusRetryAfter.removeAll()
        }
    }
}
