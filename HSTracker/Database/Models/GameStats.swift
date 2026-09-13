//
//  GameStats.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 29/12/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation
import RealmSwift

class InternalGameStats {
    var statId: String = generateId()
    var accountId: AccountId?
    var playerHero: CardClass = .neutral
    var opponentHero: CardClass = .neutral
    var coin = false
    /// Whether `coin` was read from a FIRST_PLAYER tag. `coin` alone cannot tell
    /// "went first" from "never found the player entities" (both leave it false).
    var coinKnown = false
    var gameMode: GameMode = .none
    var result: GameResult = .unknown
    var turns = -1
    var startTime = Date()
    var endTime = Date()
    var note = ""
    var playerName = ""
    var opponentName = ""
    var wasConceded = false
    var rank = 0
    var opponentRank = 0
    var leagueId = 0
    var starLevel = 0
    var starLevelAfter = 0
    var starMultiplier = 0
    var stars = 0
    var starsAfter = 0
    var opponentStarLevel = 0
    var legendRank = 0
    var legendRankAfter = 0
    var opponentLegendRank = 0
    var hearthstoneBuild: Int?
    var playerCardbackId = -1
    var opponentCardbackId = -1
    var friendlyPlayerId = -1
    var opposingPlayerId = -1
    var scenarioId = -1
    var serverInfo: ServerInfo?
    var season = 0
    var gameType: GameType = .gt_unknown
    var hsDeckId: Int64?
    var brawlSeasonId = -1
    var rankedSeasonId = -1
    var arenaWins = 0
    var arenaLosses = 0
    var brawlWins = 0
    var brawlLosses = 0
    var battlegroundsRating = 0
    var battlegroundsRatingAfter = 0
    var battlegroundsRaces: [Int] = []
    var mercenariesRating = 0
    var mercenariesRatingAfter = 0
    var mercenariesBountyRunId = ""
    var mercenariesBountyRunTurnsTaken = 0
    var mercenariesBountyRunCompletedNodes = 0
    var mercenariesBountyRunRewards: [MercenaryCoinsEntry]?
    var playerCards = [TrackedCard]()
    var opponentCards = [TrackedCard]()
    var sideboards = [Sideboard]()
    var opponentHeroCardId: String?
    var deckId = ""
    var gameDurationSeconds: Int?
    var battlegroundsDetails: UploadMetaData.BattlegroundsLobbyDetails?
    private var _format: Format?
    
    var format: Format? {
        get {
            return gameMode == .ranked || gameMode == .casual ? _format : nil
        }
        set {
            _format = newValue
        }
    }
    var hsReplayId: String?
    var revealedCards: [Card] = []
    /// Constructed games only; see Game.buildMulliganRecord.
    var mulligan: MulliganRecord?
    
    var isDungeonMatch: Bool {
        return gameType == .gt_vs_ai && DefaultDecks.DungeonRun.isDungeonBoss(opponentHeroCardId)
    }
    var isPVPDungeonMatch: Bool {
        return gameType == .gt_pvpdr || gameType == .gt_pvpdr_paid
    }
    
    func setPlayerCards(_ deck: PlayingDeck?, _ revealedCards: [Card]) {
        setPlayerCards(deck?.cards, revealedCards)
    }
    
    func setPlayerCards(_ deck: [Card]?, _ revealedCards: [Card]) {
        playerCards.removeAll()
        for c in revealedCards {
            let card = playerCards.first { x in x.id == c.id }
            if let card {
                card.count += 1
            } else {
                playerCards.append(TrackedCard(c.id, c.count))
            }
        }
        if let deck {
            for c in deck {
                let e = playerCards.first { x in x.id == c.id }
                if e == nil {
                    playerCards.append(TrackedCard(c.id, c.count, c.count))
                } else if let e, c.count > e.count {
                    e.unconfirmed = c.count - e.count
                    e.count = c.count
                }
            }
        }
    }
    
    func setOpponentCards(_ revealedCards: [Card]) {
        opponentCards.removeAll()
        for c in revealedCards {
            if let card = opponentCards.first(where: { x in x.id == c.id }) {
                card.count += 1
            } else {
                opponentCards.append(TrackedCard(c.id, c.count))
            }
        }
    }
    
    func setPlayerSideboards(_ sideboards: [Sideboard]) {
        self.sideboards = sideboards
    }

    /// Game.syncStats uploads this object to HSReplay straight after the game,
    /// while Game.recheckPostGameRank only corrects the recorded row seconds later.
    /// When the post-game medal read may still be the pre-game position, leave the
    /// "after" side out of the upload instead of reporting a won or lost game as no
    /// rank change. Call it after toGameStats so the recorded game keeps the read.
    func withholdStalePostGameRank() {
        guard gameMode == .ranked, starLevel > 0 else {
            return
        }
        let before = RankSnapshot(leagueId: leagueId, starLevel: starLevel,
                                  stars: max(stars, 0), legendRank: max(legendRank, 0))
        let after = starLevelAfter > 0
            ? RankSnapshot(leagueId: leagueId, starLevel: starLevelAfter,
                           stars: max(starsAfter, 0), legendRank: max(legendRankAfter, 0))
            : nil
        guard StatsHelper.postGameRankLooksStale(result: result, before: before, after: after) else {
            return
        }
        starLevelAfter = 0
        starsAfter = 0
        legendRankAfter = 0
    }

    func toGameStats() -> GameStats {
        let gameStats = GameStats()
        gameStats.statId = statId
        gameStats.hearthstoneBuild.value = hearthstoneBuild
        gameStats.playerCardbackId = playerCardbackId
        gameStats.opponentCardbackId = opponentCardbackId
        gameStats.opponentHero = opponentHero
        gameStats.friendlyPlayerId = friendlyPlayerId
        gameStats.opponentName = opponentName
        gameStats.opponentLegendRank = opponentLegendRank
        gameStats.playerName = playerName
        gameStats.legendRank = legendRank
        gameStats.stars = stars
        gameStats.wasConceded = wasConceded
        gameStats.turns = turns
        gameStats.scenarioId = scenarioId
        gameStats.serverInfo = serverInfo
        gameStats.season = season
        gameStats.gameMode = gameMode
        gameStats.gameType = gameType
        gameStats.hsDeckId.value = hsDeckId
        gameStats.brawlSeasonId = brawlSeasonId
        gameStats.rankedSeasonId = rankedSeasonId
        gameStats.arenaWins = arenaWins
        gameStats.arenaLosses = arenaLosses
        gameStats.brawlWins = brawlWins
        gameStats.brawlLosses = brawlLosses
        gameStats.format = format
        gameStats.hsReplayId = hsReplayId
        gameStats.result = result
        // These existed on GameStats from the start but were never copied, so every
        // stored game had coin=false, playerHero=neutral and a zero duration.
        gameStats.playerHero = playerHero
        gameStats.coin = coin
        gameStats.coinKnown = coinKnown
        gameStats.startTime = startTime
        gameStats.endTime = endTime
        gameStats.note = note
        // rank/opponentRank stay at GameStats' -1 ("unknown"): InternalGameStats
        // defaults them to 0, which StatsHelper.guessRank would read as a real rank.
        if gameMode == .ranked && starLevel > 0 {
            gameStats.leagueId = leagueId
            gameStats.starLevel = starLevel
            gameStats.starMultiplier = starMultiplier
            if opponentStarLevel > 0 {
                gameStats.opponentStarLevel = opponentStarLevel
            }
            // Only filled when the post-game medal read succeeded (HDT
            // UpdatePostGameRanks); otherwise the "after" side stays unknown.
            if starLevelAfter > 0 {
                gameStats.starLevelAfter = starLevelAfter
                gameStats.starsAfter = starsAfter
                gameStats.legendRankAfter = legendRankAfter
            }
        }
        gameStats.recordVersion = GameStats.currentRecordVersion
        gameStats.mulligan = mulligan
        for c in opponentCards {
            if let id = c.id {
                let card = RealmCard(id: id, count: c.count)
                gameStats.opponentCards.append(card)
            }
        }
        for c in revealedCards {
            let card = RealmCard(id: c.id, count: c.count)
            gameStats.revealedCards.append(card)
        }
        return gameStats
    }
}

extension InternalGameStats: CustomStringConvertible {
    var description: String {
        return "playerHero: \(playerHero), " +
            "opponentHero: \(opponentHero), " +
            "coin: \(coin), " +
            "coinKnown: \(coinKnown), " +
            "gameMode: \(gameMode), " +
            "result: \(result), " +
            "turns: \(turns), " +
            "startTime: \(startTime), " +
            "endTime: \(endTime), " +
            "note: \(note), " +
            "playerName: \(playerName), " +
            "opponentName: \(opponentName), " +
            "wasConceded: \(wasConceded), " +
            "hearthstoneBuild: \(String(describing: hearthstoneBuild)), " +
            "playerCardbackId: \(playerCardbackId), " +
            "opponentCardbackId: \(opponentCardbackId), " +
            "friendlyPlayerId: \(friendlyPlayerId), " +
            "scenarioId: \(scenarioId), " +
            "serverInfo: \(String(describing: serverInfo)), " +
            "season: \(season), " +
            "gameType: \(gameType), " +
            "hsDeckId: \(String(describing: hsDeckId)), " +
            "brawlSeasonId: \(brawlSeasonId), " +
            "rankedSeasonId: \(rankedSeasonId), " +
            "arenaWins: \(arenaWins), " +
            "arenaLosses: \(arenaLosses), " +
            "brawlWins: \(brawlWins), " +
            "brawlLosses: \(brawlLosses), " +
            "leagueId: \(leagueId), " +
            "starLevel: \(starLevel), " +
            "stars: \(stars), " +
            "legendRank: \(legendRank), " +
            "starLevelAfter: \(starLevelAfter), " +
            "starsAfter: \(starsAfter), " +
            "legendRankAfter: \(legendRankAfter), " +
            "format: \(String(describing: format)), " +
            "hsReplayId: \(String(describing: hsReplayId)), " +
            "opponentCards: \(opponentCards), " +
            "revealedCards: \(revealedCards), " +
            "mulligan: \(mulligan.map { "\($0.status)" } ?? "none")"
    }
}

/// A player's ladder position as Hearthstone's MedalInfo reports it.
struct RankSnapshot: Equatable {
    /// NetCache league id (5 = the current star-level ladder).
    let leagueId: Int
    /// 1 = Bronze 10 ... 50 = Diamond 1, 51 = Legend.
    let starLevel: Int
    /// Stars inside the current star level.
    let stars: Int
    /// Legend position, 0 when not in Legend.
    let legendRank: Int

    var isLegend: Bool { return legendRank > 0 }
}

/// One recorded game. GameStats is embedded in either `Deck.gameStats` or
/// `DefaultDeckStats.gameStats`.
///
/// When adding a persisted property, also copy it in `detachedCopy()`: that copy is
/// how a deleted deck's games move into the per-class bucket, and a field missing
/// there is silently lost.
class GameStats: EmbeddedObject {
    /// Bumped when the recording code starts storing something older rows lack.
    /// 1: playerHero, coin/coinKnown, start and end time, note and the rank
    ///    before/after fields are copied from InternalGameStats.
    /// 2: constructed games carry a MulliganRecord in `mulligan`.
    static let currentRecordVersion = 2

    @objc dynamic var statId = ""

    @objc private dynamic var _playerHero = CardClass.neutral.rawValue
    var playerHero: CardClass {
        get { return CardClass(rawValue: _playerHero)! }
        set { _playerHero = newValue.rawValue }
    }

    @objc private dynamic var _opponentHero = CardClass.neutral.rawValue
    var opponentHero: CardClass {
        get { return CardClass(rawValue: _opponentHero)! }
        set { _opponentHero = newValue.rawValue }
    }

    @objc dynamic var coin = false
    /// False for games whose turn order was never read, including every game recorded
    /// before recordVersion 1: their `coin` is a meaningless false.
    @objc dynamic var coinKnown = false

    @objc private dynamic var _gameMode = GameMode.none.rawValue
    var gameMode: GameMode {
        get { return GameMode(rawValue: _gameMode)! }
        set { _gameMode = newValue.rawValue }
    }

    @objc private dynamic var _result = GameResult.unknown.rawValue
    var result: GameResult {
        get { return GameResult(rawValue: _result)! }
        set { _result = newValue.rawValue }
    }

    @objc dynamic var turns = -1
    @objc dynamic var startTime = Date()
    @objc dynamic var endTime = Date()
    @objc dynamic var note = ""
    @objc dynamic var playerName = ""
    @objc dynamic var opponentName = ""
    @objc dynamic var wasConceded = false
    @objc dynamic var rank = -1
    @objc dynamic var stars = -1
    @objc dynamic var legendRank = -1
    @objc dynamic var opponentLegendRank = -1
    @objc dynamic var opponentRank = -1
    // Ladder position before and after the game, ranked only. `stars` and `legendRank`
    // above are the "before" values of the same MedalInfo. A side is unknown unless its
    // star level is above zero: new games default to -1, but rows that existed before
    // schema 9 read 0 because Realm fills migrated columns with zero.
    @objc dynamic var leagueId = -1
    @objc dynamic var starLevel = -1
    @objc dynamic var starMultiplier = -1
    @objc dynamic var starLevelAfter = -1
    @objc dynamic var starsAfter = -1
    @objc dynamic var legendRankAfter = -1
    @objc dynamic var opponentStarLevel = -1
    @objc dynamic var recordVersion = 0
    var hearthstoneBuild = RealmProperty<Int?>()
    @objc dynamic var playerCardbackId = -1
    @objc dynamic var opponentCardbackId = -1
    @objc dynamic var friendlyPlayerId = -1
    @objc dynamic var scenarioId = -1
    @objc dynamic var serverInfo: ServerInfo?

    @objc dynamic var season = 0

    @objc private dynamic var _gameType = GameType.gt_unknown.rawValue
    var gameType: GameType {
        get { return GameType(rawValue: _gameType)! }
        set { _gameType = newValue.rawValue }
    }

    var hsDeckId = RealmProperty<Int64?>()
    @objc dynamic var brawlSeasonId = -1
    @objc dynamic var rankedSeasonId = -1
    @objc dynamic var arenaWins = 0
    @objc dynamic var arenaLosses = 0
    @objc dynamic var brawlWins = 0
    @objc dynamic var brawlLosses = 0

    @objc dynamic var __format: String?
    private var _format: Format? {
        get {
            if let __format = __format {
                return Format(rawValue: __format)
            }
            return nil
        }
        set { __format = newValue?.rawValue ?? nil }
    }
    var format: Format? {
        get {
            return gameMode == .ranked || gameMode == .casual ? _format : nil
        }
        set {
            _format = newValue
        }
    }

    @objc dynamic var hsReplayId: String?
    let opponentCards = List<RealmCard>()
    let revealedCards = List<RealmCard>()
    /// The local player's mulligan and draws. Nil for Battlegrounds and Mercenaries
    /// games and for every game recorded before recordVersion 2.
    @objc dynamic var mulligan: MulliganRecord?

    let deck = LinkingObjects(fromType: Deck.self, property: "gameStats")
    let defaultDeckStats = LinkingObjects(fromType: DefaultDeckStats.self, property: "gameStats")

    /// Whether `coin` can be trusted.
    var coinIfKnown: Bool? {
        return coinKnown ? coin : nil
    }

    /// Game length, or nil for rows recorded before start/end time were stored.
    var duration: TimeInterval? {
        guard recordVersion >= 1 else { return nil }
        let value = endTime.timeIntervalSince(startTime)
        return value > 0 ? value : nil
    }

    var rankBefore: RankSnapshot? {
        guard gameMode == .ranked, starLevel > 0 else { return nil }
        return RankSnapshot(leagueId: leagueId, starLevel: starLevel,
                            stars: max(stars, 0), legendRank: max(legendRank, 0))
    }

    var rankAfter: RankSnapshot? {
        guard gameMode == .ranked, starLevelAfter > 0 else { return nil }
        return RankSnapshot(leagueId: leagueId, starLevel: starLevelAfter,
                            stars: max(starsAfter, 0), legendRank: max(legendRankAfter, 0))
    }

    /// An unmanaged copy of every persisted field. Realm cannot move an embedded
    /// object to another parent, so moving a game (e.g. out of a deck being
    /// deleted) means appending a copy and letting the original go with its owner.
    func detachedCopy() -> GameStats {
        let copy = GameStats()
        copy.statId = statId
        copy._playerHero = _playerHero
        copy._opponentHero = _opponentHero
        copy.coin = coin
        copy.coinKnown = coinKnown
        copy._gameMode = _gameMode
        copy._result = _result
        copy.turns = turns
        copy.startTime = startTime
        copy.endTime = endTime
        copy.note = note
        copy.playerName = playerName
        copy.opponentName = opponentName
        copy.wasConceded = wasConceded
        copy.rank = rank
        copy.stars = stars
        copy.legendRank = legendRank
        copy.opponentLegendRank = opponentLegendRank
        copy.opponentRank = opponentRank
        copy.leagueId = leagueId
        copy.starLevel = starLevel
        copy.starMultiplier = starMultiplier
        copy.starLevelAfter = starLevelAfter
        copy.starsAfter = starsAfter
        copy.legendRankAfter = legendRankAfter
        copy.opponentStarLevel = opponentStarLevel
        copy.recordVersion = recordVersion
        copy.hearthstoneBuild.value = hearthstoneBuild.value
        copy.playerCardbackId = playerCardbackId
        copy.opponentCardbackId = opponentCardbackId
        copy.friendlyPlayerId = friendlyPlayerId
        copy.scenarioId = scenarioId
        if let serverInfo = serverInfo {
            let info = ServerInfo()
            info.address = serverInfo.address
            info.auroraPassword = serverInfo.auroraPassword
            info.clientHandle = serverInfo.clientHandle
            info.gameHandle = serverInfo.gameHandle
            info.mission = serverInfo.mission
            info.port = serverInfo.port
            info.resumable = serverInfo.resumable
            info.spectatorMode = serverInfo.spectatorMode
            info.spectatorPassword = serverInfo.spectatorPassword
            info.version = serverInfo.version
            copy.serverInfo = info
        }
        copy.season = season
        copy._gameType = _gameType
        copy.hsDeckId.value = hsDeckId.value
        copy.brawlSeasonId = brawlSeasonId
        copy.rankedSeasonId = rankedSeasonId
        copy.arenaWins = arenaWins
        copy.arenaLosses = arenaLosses
        copy.brawlWins = brawlWins
        copy.brawlLosses = brawlLosses
        copy.__format = __format
        copy.hsReplayId = hsReplayId
        for card in opponentCards {
            copy.opponentCards.append(RealmCard(id: card.id, count: card.count))
        }
        for card in revealedCards {
            copy.revealedCards.append(RealmCard(id: card.id, count: card.count))
        }
        copy.mulligan = mulligan?.detachedCopy()
        return copy
    }
}
