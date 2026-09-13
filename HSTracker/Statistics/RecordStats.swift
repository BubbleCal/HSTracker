//
//  RecordStats.swift
//  HSTracker
//

import Foundation
import RealmSwift

/// Where a finished game is stored.
enum RecordDestination: Equatable {
    /// The saved deck with this deckId.
    case deck(id: String)
    /// The class's "No deck" bucket (DefaultDeckStats).
    case defaultDeck(CardClass)
    /// Not recorded.
    case none
}

extension StatsHelper {
    /// Modes that never go into the win/loss record: Battlegrounds and Mercenaries
    /// have no win/loss against a class, and a spectated game is not the user's.
    /// Before this guard a Battlegrounds game played with deck detection off landed
    /// in whatever constructed deck was still selected.
    static let recordExcludedModes: Set<GameMode> = [.battlegrounds, .mercenaries, .spectator]

    /// Decides where a finished game is recorded. Mirrors HDT GameEventHandler's
    /// HandleGameEnd: the selected deck when there is one, otherwise the
    /// DefaultDeckStats bucket of the player's class.
    ///
    /// - Parameters:
    ///   - persistedDeckId: deckId of the current deck when it is saved in Realm;
    ///     nil for no deck and for unsaved ones (loaner/template decks, Whizbang,
    ///     Book of Heroes).
    ///   - playerClass: the class the game was played as.
    static func recordDestination(mode: GameMode, isBobEncounter: Bool,
                                  persistedDeckId: String?, playerClass: CardClass) -> RecordDestination {
        if isBobEncounter || recordExcludedModes.contains(mode) {
            return .none
        }
        if let deckId = persistedDeckId {
            return .deck(id: deckId)
        }
        if mode != .none && mode != .all && Cards.classes.contains(playerClass) {
            return .defaultDeck(playerClass)
        }
        return .none
    }

    /// Turn order from the FIRST_PLAYER tag of both player entities: false when the
    /// player went first, true when they had the coin, nil when neither entity says.
    static func coin(playerIsFirst: Bool?, opponentIsFirst: Bool?) -> Bool? {
        if playerIsFirst == true {
            return false
        }
        if opponentIsFirst == true {
            return true
        }
        return nil
    }

    /// Whether a post-game medal read probably still shows the pre-game position, so
    /// it is worth reading again a bit later. Only a win below Legend is certain to
    /// move the player (a loss can stay put on a floor, a draw never moves), so that
    /// is the only case detected besides a failed read.
    static func postGameRankLooksStale(result: GameResult, before: RankSnapshot?,
                                       after: RankSnapshot?) -> Bool {
        guard let before = before else {
            return false
        }
        guard let after = after else {
            return true
        }
        return result == .win && !before.isLegend
            && after.starLevel == before.starLevel && after.stars == before.stars
    }
}

// MARK: - Win/Loss Record report

/// Time frames of the Win/Loss Record window, a subset of HDT's Enums/TimeFrame.cs.
enum RecordTimeFrame: Int, CaseIterable {
    case allTime, today, last7Days, last30Days, currentSeason, lastSeason

    var userFacingName: String {
        switch self {
        case .allTime: return String.localizedString("Record_Time_AllTime", comment: "")
        case .today: return String.localizedString("Record_Time_Today", comment: "")
        case .last7Days: return String.localizedString("Record_Time_Week", comment: "")
        case .last30Days: return String.localizedString("Record_Time_Month", comment: "")
        case .currentSeason: return String.localizedString("Record_Time_CurrentSeason", comment: "")
        case .lastSeason: return String.localizedString("Record_Time_LastSeason", comment: "")
        }
    }
}

/// A deck or a "No deck" bucket that games are recorded into.
enum RecordOwner: Hashable {
    case deck(id: String)
    case noDeck(CardClass)
}

struct RecordOwnerInfo {
    let owner: RecordOwner
    let name: String
    let playerClass: CardClass
    let isArchived: Bool
}

/// Filters of the Win/Loss Record window. The record covers the ladder only, so the
/// mode is Ranked and Casual together (`.all`), Ranked or Casual.
struct RecordFilter: Equatable {
    static let modes: [GameMode] = [.all, .ranked, .casual]
    static let formats: [Format] = [.all, .standard, .wild, .classic, .twist]

    var mode: GameMode = .all
    var format: Format = .all
    var timeFrame: RecordTimeFrame = .allTime
    var includeArchived = true
    var includeNoDeck = true
    /// One deck or bucket only. Not persisted: the deck may be gone next time.
    var owner: RecordOwner?

    static func fromSettings() -> RecordFilter {
        var filter = RecordFilter()
        if let mode = GameMode(rawValue: Settings.recordFilterMode), modes.contains(mode) {
            filter.mode = mode
        }
        if let format = Format(rawValue: Settings.recordFilterFormat), formats.contains(format) {
            filter.format = format
        }
        filter.timeFrame = RecordTimeFrame(rawValue: Settings.recordFilterTimeFrame) ?? .allTime
        filter.includeArchived = Settings.recordIncludeArchived
        filter.includeNoDeck = Settings.recordIncludeNoDeck
        return filter
    }

    func saveToSettings() {
        if Settings.recordFilterMode != mode.rawValue {
            Settings.recordFilterMode = mode.rawValue
        }
        if Settings.recordFilterFormat != format.rawValue {
            Settings.recordFilterFormat = format.rawValue
        }
        if Settings.recordFilterTimeFrame != timeFrame.rawValue {
            Settings.recordFilterTimeFrame = timeFrame.rawValue
        }
        if Settings.recordIncludeArchived != includeArchived {
            Settings.recordIncludeArchived = includeArchived
        }
        if Settings.recordIncludeNoDeck != includeNoDeck {
            Settings.recordIncludeNoDeck = includeNoDeck
        }
    }
}

/// A value copy of one recorded game, safe to pass between queues.
struct RecordGame {
    let statId: String
    let owner: RecordOwner
    let playerClass: CardClass
    let opponentClass: CardClass
    let opponentName: String
    let result: GameResult
    let wasConceded: Bool
    let mode: GameMode
    let format: Format?
    /// False when the player went first, true on the coin, nil when unknown.
    let coin: Bool?
    let turns: Int
    let startTime: Date
    let duration: TimeInterval?
    let season: Int
    let rankBefore: RankSnapshot?
    let rankAfter: RankSnapshot?
}

extension RecordGame {
    init(stat: GameStats, owner: RecordOwner, ownerClass: CardClass) {
        // Rows recorded before playerHero was copied read neutral.
        let hero = stat.playerHero
        self.init(statId: stat.statId,
                  owner: owner,
                  playerClass: hero == .neutral || hero == .invalid ? ownerClass : hero,
                  opponentClass: stat.opponentHero,
                  opponentName: stat.opponentName,
                  result: stat.result,
                  wasConceded: stat.wasConceded,
                  mode: stat.gameMode,
                  format: stat.format,
                  coin: stat.coinIfKnown,
                  turns: stat.turns,
                  startTime: stat.startTime,
                  duration: stat.duration,
                  season: stat.season,
                  rankBefore: stat.rankBefore,
                  rankAfter: stat.rankAfter)
    }
}

struct RecordStreak: Equatable {
    let result: GameResult
    let count: Int
}

/// Counts of a set of games. Follows getDeckRecord: wins, losses and draws count,
/// games with an unknown result do not, and the win rate is W / (W + L).
struct RecordSummary {
    private(set) var record = StatsDeckRecord()
    private(set) var goingFirst = StatsDeckRecord()
    private(set) var onCoin = StatsDeckRecord()
    /// Counted games whose turn order is unknown (everything recorded before it was
    /// stored). They are left out of both splits rather than guessed.
    private(set) var unknownTurnOrder = 0
    private(set) var turnsTotal = 0
    private(set) var turnsCount = 0
    private(set) var durationTotal: TimeInterval = 0
    private(set) var durationCount = 0
    private(set) var streak: RecordStreak?
    /// Newest first.
    private(set) var lastTen: [GameResult] = []
    private(set) var lastPlayed: Date?
    private var streakClosed = false

    /// Games must be added newest first: the streak and the last ten depend on it.
    mutating func add(_ game: RecordGame) {
        guard game.result != .unknown else {
            return
        }
        if lastPlayed == nil {
            lastPlayed = game.startTime
        }
        RecordSummary.count(game.result, into: &record)
        switch game.coin {
        case .some(false): RecordSummary.count(game.result, into: &goingFirst)
        case .some(true): RecordSummary.count(game.result, into: &onCoin)
        case .none: unknownTurnOrder += 1
        }
        if game.turns > 0 {
            turnsTotal += game.turns
            turnsCount += 1
        }
        if let duration = game.duration {
            durationTotal += duration
            durationCount += 1
        }
        if lastTen.count < 10 {
            lastTen.append(game.result)
        }
        if !streakClosed {
            if game.result == .draw {
                streakClosed = true
            } else if let current = streak {
                if current.result == game.result {
                    streak = RecordStreak(result: current.result, count: current.count + 1)
                } else {
                    streakClosed = true
                }
            } else {
                streak = RecordStreak(result: game.result, count: 1)
            }
        }
    }

    var averageTurns: Double? {
        return turnsCount > 0 ? Double(turnsTotal) / Double(turnsCount) : nil
    }

    var averageDuration: TimeInterval? {
        return durationCount > 0 ? durationTotal / Double(durationCount) : nil
    }

    private static func count(_ result: GameResult, into record: inout StatsDeckRecord) {
        switch result {
        case .win: record.wins += 1
        case .loss: record.losses += 1
        case .draw: record.draws += 1
        case .unknown: return
        }
        record.total += 1
    }
}

struct RecordDeckRow {
    let info: RecordOwnerInfo
    let summary: RecordSummary
}

struct RecordMatchupRow {
    let opponentClass: CardClass
    let summary: RecordSummary
}

/// Ladder movement in one season and format, from the rank stored before and after
/// each ranked game.
struct RecordRankProgression {
    let season: Int
    let format: Format
    /// Ranked games with a known rank.
    let games: Int
    let start: RankSnapshot
    let current: RankSnapshot
    let peak: RankSnapshot
    /// Stars gained (negative when lost) from start to current; nil when both are
    /// Legend, where stars no longer move.
    let netStars: Int?
}

struct RecordReport {
    let filter: RecordFilter
    let owners: [RecordOwner: RecordOwnerInfo]
    let overall: RecordSummary
    /// One row per deck or bucket with games. Ignores `filter.owner` so the deck
    /// picker keeps listing every deck.
    let decks: [RecordDeckRow]
    let matchups: [RecordMatchupRow]
    /// Newest first, at most `gameLimit` rows.
    let games: [RecordGame]
    /// Games matching the filter, including the ones beyond `gameLimit`.
    let gameCount: Int
    let rankProgression: [RecordRankProgression]
}

struct RecordData {
    let owners: [RecordOwnerInfo]
    let games: [RecordGame]
}

extension RankSnapshot {
    /// Every star level of the Bronze-to-Diamond ladder holds three stars. A win with
    /// all three moves to the next level with one star, so level L with 3 stars and
    /// level L+1 with 0 stars count the same.
    static let starsPerLevel = 3
    static let legendStarLevel = 51

    var isLegendLevel: Bool {
        return isLegend || starLevel >= RankSnapshot.legendStarLevel
    }

    /// Stars from the bottom of Bronze 10. Legend is one star above Diamond 1 with
    /// three stars; the Legend position itself is not measured in stars.
    var ladderStars: Int {
        if isLegendLevel {
            return (RankSnapshot.legendStarLevel - 1) * RankSnapshot.starsPerLevel + 1
        }
        return (starLevel - 1) * RankSnapshot.starsPerLevel + stars
    }

    func isHigher(than other: RankSnapshot) -> Bool {
        if isLegendLevel && other.isLegendLevel {
            if legendRank > 0 && other.legendRank > 0 {
                return legendRank < other.legendRank
            }
            return legendRank > 0 && other.legendRank <= 0
        }
        if isLegendLevel != other.isLegendLevel {
            return isLegendLevel
        }
        return ladderStars > other.ladderStars
    }
}

extension StatsHelper {
    /// The Win/Loss Record covers ladder games only.
    static let recordModes: Set<GameMode> = [.ranked, .casual]

    /// Reads every ladder game from Realm into value types. Opens its own Realm so
    /// it can run off the main thread; nothing Realm-backed leaves this function.
    static func loadRecordData() -> RecordData {
        return autoreleasepool {
            guard let realm = try? Realm() else {
                logger.error("Error accessing Realm database")
                return RecordData(owners: [], games: [])
            }
            // A background thread may hold a cached Realm from an earlier read.
            realm.refresh()

            var owners = [RecordOwnerInfo]()
            var games = [RecordGame]()
            for deck in realm.objects(Deck.self) {
                let owner = RecordOwner.deck(id: deck.deckId)
                owners.append(RecordOwnerInfo(owner: owner, name: deck.name,
                                              playerClass: deck.playerClass, isArchived: !deck.isActive))
                for stat in deck.gameStats where recordModes.contains(stat.gameMode) {
                    games.append(RecordGame(stat: stat, owner: owner, ownerClass: deck.playerClass))
                }
            }
            for bucket in realm.objects(DefaultDeckStats.self) {
                let owner = RecordOwner.noDeck(bucket.playerClass)
                owners.append(RecordOwnerInfo(owner: owner, name: noDeckName(bucket.playerClass),
                                              playerClass: bucket.playerClass, isArchived: false))
                for stat in bucket.gameStats where recordModes.contains(stat.gameMode) {
                    games.append(RecordGame(stat: stat, owner: owner, ownerClass: bucket.playerClass))
                }
            }
            return RecordData(owners: owners, games: games)
        }
    }

    static func noDeckName(_ playerClass: CardClass) -> String {
        return String(format: String.localizedString("Record_NoDeck_Class", comment: ""),
                      String.localizedString(playerClass.rawValue, comment: ""))
    }

    static func getRecordReport(filter: RecordFilter) -> RecordReport {
        return buildRecordReport(data: loadRecordData(), filter: filter)
    }

    /// Aggregates the record. Pure: no Realm, no Settings, so it runs on any queue.
    /// Mirrors the parts of HDT's ConstructedStats.GetFilteredGames this window has.
    static func buildRecordReport(data: RecordData, filter: RecordFilter, now: Date = Date(),
                                  calendar: Calendar = .current, gameLimit: Int = 1000) -> RecordReport {
        var owners = [RecordOwner: RecordOwnerInfo]()
        for info in data.owners {
            owners[info.owner] = info
        }

        let currentSeason = Database.season(for: now, calendar: calendar)
        let startOfToday = calendar.startOfDay(for: now)
        func inTimeFrame(_ game: RecordGame) -> Bool {
            switch filter.timeFrame {
            case .allTime: return true
            case .today: return game.startTime >= startOfToday
            case .last7Days: return game.startTime >= now.addingTimeInterval(-7 * 86400)
            case .last30Days: return game.startTime >= now.addingTimeInterval(-30 * 86400)
            case .currentSeason: return game.season == currentSeason
            case .lastSeason: return game.season == currentSeason - 1
            }
        }

        // Mode, format and time describe the games themselves, so they also scope the
        // rank progression. Deck filters do not: the rank belongs to the account.
        let ladderGames = data.games
            .filter { game in
                guard recordModes.contains(game.mode) else { return false }
                if filter.mode != .all && game.mode != filter.mode { return false }
                if filter.format != .all && game.format != filter.format { return false }
                return inTimeFrame(game)
            }
            .sorted { $0.startTime > $1.startTime }

        let deckGames = ladderGames.filter { game in
            guard let info = owners[game.owner] else { return false }
            if !filter.includeArchived && info.isArchived { return false }
            if case .noDeck = game.owner, !filter.includeNoDeck { return false }
            return true
        }

        var deckSummaries = [RecordOwner: RecordSummary]()
        for game in deckGames {
            deckSummaries[game.owner, default: RecordSummary()].add(game)
        }
        let decks = deckSummaries.compactMap { owner, summary -> RecordDeckRow? in
            guard let info = owners[owner] else { return nil }
            return RecordDeckRow(info: info, summary: summary)
        }.sorted { lhs, rhs in
            if lhs.summary.record.total != rhs.summary.record.total {
                return lhs.summary.record.total > rhs.summary.record.total
            }
            return (lhs.summary.lastPlayed ?? .distantPast) > (rhs.summary.lastPlayed ?? .distantPast)
        }

        let games: [RecordGame]
        if let selected = filter.owner {
            games = deckGames.filter { $0.owner == selected }
        } else {
            games = deckGames
        }

        var overall = RecordSummary()
        var matchupSummaries = [CardClass: RecordSummary]()
        for game in games {
            overall.add(game)
            matchupSummaries[game.opponentClass, default: RecordSummary()].add(game)
        }
        let matchups = Cards.classes.compactMap { opponentClass -> RecordMatchupRow? in
            guard let summary = matchupSummaries[opponentClass], summary.record.total > 0 else {
                return nil
            }
            return RecordMatchupRow(opponentClass: opponentClass, summary: summary)
        }

        return RecordReport(filter: filter,
                            owners: owners,
                            overall: overall,
                            decks: decks,
                            matchups: matchups,
                            games: Array(games.prefix(gameLimit)),
                            gameCount: games.count,
                            rankProgression: rankProgression(newestFirst: ladderGames))
    }

    /// Start, current and peak rank per season and format, newest season first.
    static func rankProgression(newestFirst games: [RecordGame]) -> [RecordRankProgression] {
        struct Key: Hashable {
            let season: Int
            let format: Format
        }
        var groups = [Key: [RecordGame]]()
        for game in games.reversed() where game.mode == .ranked
            && (game.rankBefore != nil || game.rankAfter != nil) {
            groups[Key(season: game.season, format: game.format ?? .unknown), default: []].append(game)
        }

        let formatOrder = RecordFilter.formats + [.unknown]
        return groups.compactMap { key, oldestFirst -> RecordRankProgression? in
            guard let first = oldestFirst.first, let last = oldestFirst.last,
                  let start = first.rankBefore ?? first.rankAfter,
                  let current = last.rankAfter ?? last.rankBefore else {
                return nil
            }
            var peak = start
            for game in oldestFirst {
                for rank in [game.rankBefore, game.rankAfter].compactMap({ $0 }) where rank.isHigher(than: peak) {
                    peak = rank
                }
            }
            let netStars: Int? = start.isLegendLevel && current.isLegendLevel
                ? nil : current.ladderStars - start.ladderStars
            return RecordRankProgression(season: key.season, format: key.format, games: oldestFirst.count,
                                         start: start, current: current, peak: peak, netStars: netStars)
        }.sorted { lhs, rhs in
            if lhs.season != rhs.season {
                return lhs.season > rhs.season
            }
            return (formatOrder.firstIndex(of: lhs.format) ?? 0) < (formatOrder.firstIndex(of: rhs.format) ?? 0)
        }
    }
}

// MARK: - Tracker matchup line

extension StatsHelper {
    /// The deck's ladder record against one class, for the player tracker's
    /// "VS <class>" line (HDT's LblWinRateAgainst in OverlayWindow.Update.cs).
    ///
    /// Only Ranked and Casual games count, the same scope as the Win/Loss Record
    /// window, so the tracker and the window's matchup table agree. Returns nil when
    /// the line should stay hidden: the opponent's class is not known yet (or is not
    /// a real class, like an adventure boss), or the deck is an Arena deck, which by
    /// definition never has ladder games and would always read 0-0.
    static func matchupTrackerRecord(deck: Deck, opponentClass: CardClass?) -> StatsDeckRecord? {
        guard let opponentClass = opponentClass, Cards.classes.contains(opponentClass), !deck.isArena else {
            return nil
        }
        var wins = 0
        var losses = 0
        var draws = 0
        for stat in deck.gameStats where stat.opponentHero == opponentClass && recordModes.contains(stat.gameMode) {
            switch stat.result {
            case .win: wins += 1
            case .loss: losses += 1
            case .draw: draws += 1
            case .unknown: break
            }
        }
        return StatsDeckRecord(wins: wins, losses: losses, draws: draws, total: wins + losses + draws)
    }

    /// "VS <class>: W-L (x%)". The percentage is left out until a game was won or
    /// lost, where HDT prints "-%".
    static func matchupTrackerLabel(opponentClass: CardClass, record: StatsDeckRecord) -> String {
        var score = "\(record.wins)-\(record.losses)"
        let winRate = getDeckWinRate(record: record)
        if winRate >= 0 {
            score += " (\(Int((winRate * 100).rounded()))%)"
        }
        return String(format: String.localizedString("Tracker_MatchupWinRate", comment: ""),
                      String.localizedString(opponentClass.rawValue, comment: ""), score)
    }
}
