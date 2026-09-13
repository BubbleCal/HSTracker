//
//  RecordStatsTests.swift
//  HSTrackerTests
//

import XCTest
import Foundation
import RealmSwift

@testable import HSTracker

class RecordStatsTests: HSTrackerTests {

    // MARK: - Recording destination

    func testRecordDestinationPersistedDeck() {
        XCTAssertEqual(StatsHelper.recordDestination(mode: .ranked, isBobEncounter: false,
                                                     persistedDeckId: "d1", playerClass: .mage),
                       .deck(id: "d1"))
        // Every mode recorded before keeps being recorded into the deck.
        for mode: GameMode in [.casual, .arena, .brawl, .friendly, .practice, .duels, .none] {
            XCTAssertEqual(StatsHelper.recordDestination(mode: mode, isBobEncounter: false,
                                                         persistedDeckId: "d1", playerClass: .neutral),
                           .deck(id: "d1"), "\(mode)")
        }
    }

    func testRecordDestinationNoDeckUsesClass() {
        XCTAssertEqual(StatsHelper.recordDestination(mode: .casual, isBobEncounter: false,
                                                     persistedDeckId: nil, playerClass: .mage),
                       .defaultDeck(.mage))
        XCTAssertEqual(StatsHelper.recordDestination(mode: .arena, isBobEncounter: false,
                                                     persistedDeckId: nil, playerClass: .demonhunter),
                       .defaultDeck(.demonhunter))
    }

    func testRecordDestinationExcludesBattlegroundsMercenariesSpectator() {
        for mode: GameMode in [.battlegrounds, .mercenaries, .spectator] {
            XCTAssertEqual(StatsHelper.recordDestination(mode: mode, isBobEncounter: false,
                                                         persistedDeckId: "d1", playerClass: .mage),
                           .none, "\(mode)")
            XCTAssertEqual(StatsHelper.recordDestination(mode: mode, isBobEncounter: false,
                                                         persistedDeckId: nil, playerClass: .mage),
                           .none, "\(mode)")
        }
    }

    func testRecordDestinationSkipsBobAndMissingClass() {
        XCTAssertEqual(StatsHelper.recordDestination(mode: .practice, isBobEncounter: true,
                                                     persistedDeckId: "d1", playerClass: .mage),
                       .none)
        for playerClass: CardClass in [.neutral, .invalid, .whizbang, .dream] {
            XCTAssertEqual(StatsHelper.recordDestination(mode: .ranked, isBobEncounter: false,
                                                         persistedDeckId: nil, playerClass: playerClass),
                           .none, "\(playerClass)")
        }
        XCTAssertEqual(StatsHelper.recordDestination(mode: .none, isBobEncounter: false,
                                                     persistedDeckId: nil, playerClass: .mage),
                       .none)
    }

    func testCoinFromFirstPlayerTags() {
        XCTAssertEqual(StatsHelper.coin(playerIsFirst: true, opponentIsFirst: false), false)
        XCTAssertEqual(StatsHelper.coin(playerIsFirst: false, opponentIsFirst: true), true)
        XCTAssertNil(StatsHelper.coin(playerIsFirst: false, opponentIsFirst: false))
        XCTAssertNil(StatsHelper.coin(playerIsFirst: nil, opponentIsFirst: nil))
    }

    func testPostGameRankLooksStale() {
        let before = RankSnapshot(leagueId: 5, starLevel: 30, stars: 1, legendRank: 0)
        let moved = RankSnapshot(leagueId: 5, starLevel: 30, stars: 2, legendRank: 0)
        XCTAssertTrue(StatsHelper.postGameRankLooksStale(result: .win, before: before, after: before))
        XCTAssertTrue(StatsHelper.postGameRankLooksStale(result: .win, before: before, after: nil))
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .win, before: before, after: moved))
        // A loss normally moves the player down too, so an unchanged read is re-checked
        // (the re-read keeps it when the player really sits on a floor).
        XCTAssertTrue(StatsHelper.postGameRankLooksStale(result: .loss, before: before, after: before))
        let dropped = RankSnapshot(leagueId: 5, starLevel: 29, stars: 3, legendRank: 0)
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .loss, before: before, after: dropped))
        // A draw never moves, and an unknown result says nothing.
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .draw, before: before, after: before))
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .unknown, before: before, after: before))
        let legend = RankSnapshot(leagueId: 5, starLevel: 51, stars: 0, legendRank: 1000)
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .win, before: legend, after: legend))
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .win, before: nil, after: nil))
    }

    // MARK: - Season

    func testSeasonForDate() {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        XCTAssertEqual(Database.season(for: date(2014, 4, 10), timeZone: utc), 1)
        XCTAssertEqual(Database.season(for: date(2026, 9, 13), timeZone: utc), (2026 - 2014) * 12 - 3 + 9)
        XCTAssertEqual(Database.season(for: date(2026, 10, 1), timeZone: utc),
                       Database.season(for: date(2026, 9, 30), timeZone: utc) + 1)
        // 30 Sept 20:00 UTC is already 1 October in UTC+8.
        XCTAssertEqual(Database.season(for: date(2026, 9, 30, hour: 20), timeZone: TimeZone(secondsFromGMT: 8 * 3600)!),
                       Database.season(for: date(2026, 10, 1), timeZone: utc))
        XCTAssertEqual(Database.currentSeason, Database.season(for: Date()))
    }

    // MARK: - Data mapping

    private func rankedInternalStats() -> InternalGameStats {
        let stats = InternalGameStats()
        stats.gameMode = .ranked
        stats.format = .standard
        stats.result = .win
        stats.playerHero = .rogue
        stats.opponentHero = .mage
        stats.coin = true
        stats.coinKnown = true
        stats.startTime = Date(timeIntervalSince1970: 1_700_000_000)
        stats.endTime = Date(timeIntervalSince1970: 1_700_000_600)
        stats.note = "x"
        stats.leagueId = 5
        stats.starLevel = 30
        stats.stars = 2
        stats.starMultiplier = 3
        stats.legendRank = 0
        stats.opponentStarLevel = 28
        stats.starLevelAfter = 31
        stats.starsAfter = 0
        stats.legendRankAfter = 0
        return stats
    }

    func testToGameStatsCopiesTimesCoinHeroAndVersion() {
        let internalStats = rankedInternalStats()
        let stats = internalStats.toGameStats()

        XCTAssertEqual(stats.playerHero, .rogue)
        XCTAssertEqual(stats.coinIfKnown, true)
        XCTAssertEqual(stats.startTime, internalStats.startTime)
        XCTAssertEqual(stats.endTime, internalStats.endTime)
        XCTAssertEqual(stats.duration, 600)
        XCTAssertEqual(stats.note, "x")
        XCTAssertEqual(stats.recordVersion, GameStats.currentRecordVersion)
        XCTAssertEqual(stats.recordVersion, 1)
        // InternalGameStats' 0 must not become a real-looking rank.
        XCTAssertEqual(stats.rank, -1)
        XCTAssertEqual(stats.opponentRank, -1)
    }

    func testToGameStatsLeavesUnknownCoinAndRankUnknown() {
        let internalStats = InternalGameStats()
        internalStats.gameMode = .casual
        internalStats.result = .loss
        let stats = internalStats.toGameStats()

        XCTAssertNil(stats.coinIfKnown)
        XCTAssertNil(stats.rankBefore)
        XCTAssertNil(stats.rankAfter)
        XCTAssertEqual(stats.starLevel, -1)
        XCTAssertEqual(stats.starLevelAfter, -1)

        // Ranked, but the post-game medal read failed: before known, after unknown.
        let ranked = rankedInternalStats()
        ranked.starLevelAfter = 0
        ranked.starsAfter = 0
        let rankedStats = ranked.toGameStats()
        XCTAssertNotNil(rankedStats.rankBefore)
        XCTAssertNil(rankedStats.rankAfter)
    }

    func testRankFieldsRoundTrip() throws {
        let realm = try Realm()
        let deck = Deck()
        deck.name = "Rogue"
        deck.playerClass = .rogue
        try realm.write { realm.add(deck) }

        let legendStats = rankedInternalStats()
        legendStats.starLevel = 51
        legendStats.legendRank = 1234
        legendStats.starLevelAfter = 51
        legendStats.legendRankAfter = 1100
        let climbing = rankedInternalStats()

        RealmHelper.addStatistics(to: deck, stats: climbing.toGameStats())
        RealmHelper.addStatistics(to: deck, stats: legendStats.toGameStats())

        let stored = try XCTUnwrap(realm.objects(Deck.self).first?.gameStats)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored[0].rankBefore, RankSnapshot(leagueId: 5, starLevel: 30, stars: 2, legendRank: 0))
        XCTAssertEqual(stored[0].rankAfter, RankSnapshot(leagueId: 5, starLevel: 31, stars: 0, legendRank: 0))
        XCTAssertEqual(stored[0].starMultiplier, 3)
        XCTAssertEqual(stored[0].opponentStarLevel, 28)
        XCTAssertEqual(stored[1].rankBefore?.legendRank, 1234)
        XCTAssertEqual(stored[1].rankBefore?.isLegend, true)
        XCTAssertEqual(stored[1].rankAfter?.legendRank, 1100)

        // A late re-read of the post-game position replaces the "after" side only.
        RealmHelper.updateRankAfter(statId: stored[0].statId,
                                    after: RankSnapshot(leagueId: 5, starLevel: 31, stars: 1, legendRank: 0))
        realm.refresh()
        XCTAssertEqual(stored[0].rankAfter, RankSnapshot(leagueId: 5, starLevel: 31, stars: 1, legendRank: 0))
        XCTAssertEqual(stored[0].rankBefore?.starLevel, 30)
    }

    // MARK: - detachedCopy

    /// Gives every persisted GameStats property a non-default value, found through the
    /// Realm schema so that a property added later is covered without editing this test.
    private func makeFullyPopulatedStat() -> GameStats {
        let stat = GameStats()
        for (index, property) in stat.objectSchema.properties.enumerated() {
            switch property.name {
            case "_playerHero": stat.setValue(CardClass.rogue.rawValue, forKey: property.name)
            case "_opponentHero": stat.setValue(CardClass.mage.rawValue, forKey: property.name)
            case "_gameMode": stat.setValue(GameMode.ranked.rawValue, forKey: property.name)
            case "_result": stat.setValue(GameResult.win.rawValue, forKey: property.name)
            case "_gameType": stat.setValue(GameType.gt_ranked.rawValue, forKey: property.name)
            case "__format": stat.setValue(Format.wild.rawValue, forKey: property.name)
            case "opponentCards":
                stat.opponentCards.append(RealmCard(id: "EX1_001", count: 2))
                stat.opponentCards.append(RealmCard(id: "EX1_002", count: 1))
            case "revealedCards":
                stat.revealedCards.append(RealmCard(id: "EX1_003", count: 1))
            case "serverInfo":
                let info = ServerInfo()
                for (infoIndex, infoProperty) in info.objectSchema.properties.enumerated() {
                    info.setValue(value(for: infoProperty, index: infoIndex), forKey: infoProperty.name)
                }
                stat.serverInfo = info
            default:
                stat.setValue(value(for: property, index: index), forKey: property.name)
            }
        }
        return stat
    }

    private func value(for property: Property, index: Int) -> Any {
        switch property.type {
        case .int: return 1000 + index
        case .bool: return true
        case .string: return "value-\(property.name)"
        case .date: return Date(timeIntervalSince1970: TimeInterval(1_600_000_000 + index))
        case .double: return Double(index) + 0.5
        default:
            XCTFail("Unhandled property type \(property.type) for \(property.name); extend the test")
            return 0
        }
    }

    private func assertSameValues(_ original: GameStats, _ copy: GameStats,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for property in original.objectSchema.properties {
            switch property.name {
            case "opponentCards", "revealedCards":
                let lhs = (original.value(forKey: property.name) as? List<RealmCard>).map { Array($0) } ?? []
                let rhs = (copy.value(forKey: property.name) as? List<RealmCard>).map { Array($0) } ?? []
                XCTAssertEqual(lhs.map { "\($0.id)x\($0.count)" }, rhs.map { "\($0.id)x\($0.count)" },
                               property.name, file: file, line: line)
            case "serverInfo":
                let lhs = try? XCTUnwrap(original.serverInfo)
                let rhs = try? XCTUnwrap(copy.serverInfo)
                XCTAssertNotNil(rhs, file: file, line: line)
                if let lhs = lhs, let rhs = rhs {
                    XCTAssertFalse(lhs === rhs, file: file, line: line)
                    for infoProperty in lhs.objectSchema.properties {
                        XCTAssertEqual(lhs.value(forKey: infoProperty.name) as? NSObject,
                                       rhs.value(forKey: infoProperty.name) as? NSObject,
                                       "serverInfo.\(infoProperty.name)", file: file, line: line)
                    }
                }
            default:
                XCTAssertEqual(original.value(forKey: property.name) as? NSObject,
                               copy.value(forKey: property.name) as? NSObject,
                               property.name, file: file, line: line)
            }
        }
    }

    func testDetachedCopyCopiesEveryPersistedProperty() throws {
        let original = makeFullyPopulatedStat()
        let copy = original.detachedCopy()
        XCTAssertNil(copy.realm)
        assertSameValues(original, copy)

        // The deck-deletion path copies managed objects.
        let realm = try Realm()
        let deck = Deck()
        try realm.write {
            realm.add(deck)
            deck.gameStats.append(makeFullyPopulatedStat())
        }
        let managed = try XCTUnwrap(deck.gameStats.first)
        let managedCopy = managed.detachedCopy()
        XCTAssertNil(managedCopy.realm)
        assertSameValues(managed, managedCopy)
    }

    // MARK: - Persistence

    private func makeStat(_ result: GameResult, mode: GameMode = .ranked, opponentCards: Int = 0) -> GameStats {
        let stat = GameStats()
        stat.statId = generateId()
        stat.result = result
        stat.gameMode = mode
        for index in 0 ..< opponentCards {
            stat.opponentCards.append(RealmCard(id: "CARD_\(index)", count: 1))
        }
        return stat
    }

    private func makeDeck(_ playerClass: CardClass, games: [GameStats], in realm: Realm) throws -> Deck {
        let deck = Deck()
        deck.name = "\(playerClass) deck"
        deck.playerClass = playerClass
        try realm.write {
            realm.add(deck)
            deck.gameStats.append(objectsIn: games)
        }
        return deck
    }

    func testDefaultDeckStatsStoresGamesWithoutDeck() throws {
        let realm = try Realm()
        _ = try makeDeck(.mage, games: [], in: realm)
        let decksBefore = RealmHelper.getDecks()?.count

        RealmHelper.addStatistics(toDefaultDeckFor: .hunter, stats: makeStat(.win))
        RealmHelper.addStatistics(toDefaultDeckFor: .hunter, stats: makeStat(.loss))
        RealmHelper.addStatistics(toDefaultDeckFor: .priest, stats: makeStat(.win))

        let buckets = realm.objects(DefaultDeckStats.self)
        XCTAssertEqual(buckets.count, 2)
        let hunter = try XCTUnwrap(realm.object(ofType: DefaultDeckStats.self, forPrimaryKey: CardClass.hunter.rawValue))
        XCTAssertEqual(hunter.playerClass, .hunter)
        XCTAssertEqual(hunter.gameStats.count, 2)
        XCTAssertEqual(hunter.gameStats.first?.defaultDeckStats.first?.playerClass, .hunter)
        XCTAssertTrue(hunter.gameStats.first?.deck.isEmpty ?? false)
        XCTAssertEqual(RealmHelper.getDefaultDeckStats().count, 2)
        // The buckets never leak into the deck list.
        XCTAssertEqual(RealmHelper.getDecks()?.count, decksBefore)
    }

    func testDeleteDeckKeepsStatsWhenRequested() throws {
        let realm = try Realm()
        let games = [makeStat(.win, opponentCards: 3), makeStat(.loss, opponentCards: 1), makeStat(.draw)]
        let expected = games.map { ($0.statId, $0.result, $0.opponentCards.count) }
        RealmHelper.addStatistics(toDefaultDeckFor: .priest, stats: makeStat(.win))
        let deck = try makeDeck(.priest, games: games, in: realm)

        RealmHelper.delete(deck: deck, keepStats: true)

        XCTAssertEqual(realm.objects(Deck.self).count, 0)
        let bucket = try XCTUnwrap(realm.object(ofType: DefaultDeckStats.self, forPrimaryKey: CardClass.priest.rawValue))
        XCTAssertEqual(bucket.gameStats.count, 4)
        let kept = Array(bucket.gameStats.suffix(3))
        XCTAssertEqual(kept.map { $0.statId }, expected.map { $0.0 })
        XCTAssertEqual(kept.map { $0.result }, expected.map { $0.1 })
        XCTAssertEqual(kept.map { $0.opponentCards.count }, expected.map { $0.2 })
    }

    func testDeleteDeckDropsStatsWhenNotRequested() throws {
        let realm = try Realm()
        let deck = try makeDeck(.warrior, games: [makeStat(.win), makeStat(.loss)], in: realm)

        RealmHelper.delete(deck: deck, keepStats: false)

        XCTAssertEqual(realm.objects(Deck.self).count, 0)
        XCTAssertEqual(realm.objects(DefaultDeckStats.self).flatMap { $0.gameStats }.count, 0)
    }

    func testDeleteGameStatFindsDeckAndNoDeckGames() throws {
        let realm = try Realm()
        let deckGame = makeStat(.win)
        let deckGameId = deckGame.statId
        let deck = try makeDeck(.druid, games: [deckGame, makeStat(.loss)], in: realm)
        let bucketGame = makeStat(.loss)
        let bucketGameId = bucketGame.statId
        RealmHelper.addStatistics(toDefaultDeckFor: .shaman, stats: bucketGame)
        RealmHelper.addStatistics(toDefaultDeckFor: .shaman, stats: makeStat(.win))

        XCTAssertTrue(RealmHelper.deleteGameStat(statId: deckGameId))
        XCTAssertEqual(deck.gameStats.count, 1)
        XCTAssertFalse(deck.gameStats.contains { $0.statId == deckGameId })

        XCTAssertTrue(RealmHelper.deleteGameStat(statId: bucketGameId))
        let bucket = try XCTUnwrap(realm.object(ofType: DefaultDeckStats.self, forPrimaryKey: CardClass.shaman.rawValue))
        XCTAssertEqual(bucket.gameStats.count, 1)

        XCTAssertFalse(RealmHelper.deleteGameStat(statId: "unknown"))
        XCTAssertFalse(RealmHelper.deleteGameStat(statId: deckGameId))
    }

    // MARK: - Tracker matchup line

    private func makeStat(_ result: GameResult, mode: GameMode, against opponent: CardClass) -> GameStats {
        let stat = makeStat(result, mode: mode)
        stat.opponentHero = opponent
        return stat
    }

    func testMatchupTrackerRecordCountsLadderGamesAgainstTheClass() throws {
        let realm = try Realm()
        let deck = try makeDeck(.rogue, games: [
            makeStat(.win, mode: .ranked, against: .mage),
            makeStat(.win, mode: .ranked, against: .mage),
            makeStat(.loss, mode: .casual, against: .mage),
            makeStat(.draw, mode: .ranked, against: .mage),
            makeStat(.unknown, mode: .ranked, against: .mage),
            // Not ladder: the tracker agrees with the Win/Loss Record window.
            makeStat(.win, mode: .arena, against: .mage),
            makeStat(.win, mode: .friendly, against: .mage),
            makeStat(.win, mode: .brawl, against: .mage),
            makeStat(.loss, mode: .practice, against: .mage),
            // Another class.
            makeStat(.loss, mode: .ranked, against: .druid)
        ], in: realm)

        let mage = try XCTUnwrap(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: .mage))
        XCTAssertEqual(mage.wins, 2)
        XCTAssertEqual(mage.losses, 1)
        XCTAssertEqual(mage.draws, 1)
        XCTAssertEqual(mage.total, 4)

        let druid = try XCTUnwrap(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: .druid))
        XCTAssertEqual(druid.wins, 0)
        XCTAssertEqual(druid.losses, 1)

        // A class the deck never met still shows, as 0-0.
        let hunter = try XCTUnwrap(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: .hunter))
        XCTAssertEqual(hunter.total, 0)
    }

    func testMatchupTrackerRecordHiddenWithoutClassOrForArenaDecks() throws {
        let realm = try Realm()
        let deck = try makeDeck(.rogue, games: [makeStat(.win, mode: .ranked, against: .neutral)], in: realm)
        XCTAssertNil(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: nil))
        XCTAssertNil(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: .neutral))
        XCTAssertNil(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: .invalid))

        let arena = try makeDeck(.mage, games: [makeStat(.win, mode: .arena, against: .mage)], in: realm)
        try realm.write {
            arena.isArena = true
        }
        XCTAssertNil(StatsHelper.matchupTrackerRecord(deck: arena, opponentClass: .mage))
    }

    func testMatchupTrackerRecordFollowsNewGames() throws {
        let realm = try Realm()
        let deck = try makeDeck(.warlock, games: [makeStat(.loss, mode: .ranked, against: .priest)], in: realm)
        XCTAssertEqual(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: .priest)?.wins, 0)

        RealmHelper.addStatistics(to: deck, stats: makeStat(.win, mode: .ranked, against: .priest))

        let record = try XCTUnwrap(StatsHelper.matchupTrackerRecord(deck: deck, opponentClass: .priest))
        XCTAssertEqual(record.wins, 1)
        XCTAssertEqual(record.losses, 1)
    }

    func testGameStatsChangedObserversSeeABackgroundWrite() throws {
        let realm = try Realm()
        let deck = try makeDeck(.warlock, games: [], in: realm)
        let deckId = deck.deckId
        // Games are recorded on the log-reader thread. Pin the main thread's Realm so
        // only an explicit refresh moves it, the way it lags until Realm's notifier
        // reaches the run loop.
        realm.autorefresh = false
        defer { realm.autorefresh = true }

        let stat = makeStat(.win, mode: .ranked, against: .priest)
        let written = expectation(description: "recorded off the main thread")
        DispatchQueue.global().async {
            autoreleasepool {
                if let backgroundDeck = try? Realm().object(ofType: Deck.self, forPrimaryKey: deckId) {
                    RealmHelper.addStatistics(to: backgroundDeck, stats: stat)
                }
            }
            written.fulfill()
        }
        wait(for: [written], timeout: 5)
        XCTAssertEqual(deck.gameStats.count, 0, "the main thread's Realm has not caught up yet")

        var seenGames = -1
        let notified = expectation(description: "game_stats_changed")
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name(rawValue: Events.game_stats_changed), object: nil,
            queue: OperationQueue.main) { _ in
            // What the tracker's W-L and VS lines read.
            seenGames = (try? Realm())?.object(ofType: Deck.self, forPrimaryKey: deckId)?.gameStats.count ?? -1
            notified.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        RealmHelper.postGameStatsChanged()
        wait(for: [notified], timeout: 5)
        XCTAssertEqual(seenGames, 1)
    }

    func testMatchupTrackerLabelScore() {
        // The words around the score are localized (the test host runs in the
        // machine's language), so only the score at the end is checked.
        let label = StatsHelper.matchupTrackerLabel(opponentClass: .mage,
                                                    record: StatsDeckRecord(wins: 2, losses: 1, draws: 1, total: 4))
        XCTAssertTrue(label.hasSuffix("2-1 (67%)"), label)
        XCTAssertTrue(label.contains(String.localizedString(CardClass.mage.rawValue, comment: "")), label)

        let empty = StatsHelper.matchupTrackerLabel(opponentClass: .druid, record: StatsDeckRecord())
        XCTAssertTrue(empty.hasSuffix("0-0"), empty)
        XCTAssertFalse(empty.contains("%"), empty)

        let drawsOnly = StatsHelper.matchupTrackerLabel(opponentClass: .druid,
                                                        record: StatsDeckRecord(wins: 0, losses: 0, draws: 2, total: 2))
        XCTAssertTrue(drawsOnly.hasSuffix("0-0"), drawsOnly)
    }

    // MARK: - Migration

    func testMigrationFromSchema8KeepsGames() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecordStatsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hstracker.realm")
        let startTime = Date(timeIntervalSince1970: 1_650_000_000)

        // A realm as HSTracker 3.x left it: schema 8, with the v8 model classes.
        try autoreleasepool {
            let v8Config = Realm.Configuration(fileURL: fileURL, schemaVersion: 8,
                                               objectTypes: [V8Deck.self, V8GameStats.self, V8RealmCard.self,
                                                             V8ServerInfo.self, V8RealmSideboard.self])
            let realm = try Realm(configuration: v8Config)
            try realm.write {
                let deck = V8Deck()
                deck.deckId = "legacy-deck"
                deck.name = "Legacy"
                deck._playerClass = CardClass.paladin.rawValue
                deck.cards.append(V8RealmCard(id: "CS2_092", count: 2))
                for index in 0 ..< 2 {
                    let stat = V8GameStats()
                    stat.statId = "legacy-\(index)"
                    stat._result = GameResult.win.rawValue
                    stat._gameMode = GameMode.ranked.rawValue
                    stat._opponentHero = CardClass.hunter.rawValue
                    stat.__format = Format.standard.rawValue
                    stat.stars = 3
                    stat.legendRank = 0
                    stat.coin = false
                    stat.startTime = startTime
                    stat.endTime = startTime
                    stat.hsReplayId = "replay-\(index)"
                    stat.hsDeckId.value = 42
                    let info = V8ServerInfo()
                    info.address = "127.0.0.1"
                    stat.serverInfo = info
                    stat.opponentCards.append(V8RealmCard(id: "EX1_610", count: 1))
                    deck.gameStats.append(stat)
                }
                realm.add(deck)
            }
        }
        XCTAssertEqual(try schemaVersionAtURL(fileURL), 8)

        let realm = try Realm(configuration: RealmHelper.configuration(fileURL: fileURL))
        XCTAssertEqual(try schemaVersionAtURL(fileURL), RealmHelper.schemaVersion)
        XCTAssertGreaterThanOrEqual(RealmHelper.schemaVersion, 9)

        let deck = try XCTUnwrap(realm.object(ofType: Deck.self, forPrimaryKey: "legacy-deck"))
        XCTAssertEqual(deck.name, "Legacy")
        XCTAssertEqual(deck.playerClass, .paladin)
        XCTAssertEqual(deck.cards.count, 1)
        XCTAssertEqual(deck.gameStats.count, 2)
        let stat = try XCTUnwrap(deck.gameStats.first)
        XCTAssertEqual(stat.statId, "legacy-0")
        XCTAssertEqual(stat.result, .win)
        XCTAssertEqual(stat.gameMode, .ranked)
        XCTAssertEqual(stat.opponentHero, .hunter)
        XCTAssertEqual(stat.format, .standard)
        XCTAssertEqual(stat.stars, 3)
        XCTAssertEqual(stat.startTime, startTime)
        XCTAssertEqual(stat.hsReplayId, "replay-0")
        XCTAssertEqual(stat.hsDeckId.value, 42)
        XCTAssertEqual(stat.serverInfo?.address, "127.0.0.1")
        XCTAssertEqual(stat.opponentCards.first?.id, "EX1_610")

        // Old rows read as unknown rather than as "went first", zero-length or unranked.
        XCTAssertFalse(stat.coinKnown)
        XCTAssertNil(stat.coinIfKnown)
        XCTAssertEqual(stat.recordVersion, 0)
        XCTAssertNil(stat.duration)
        XCTAssertNil(stat.rankBefore)
        XCTAssertNil(stat.rankAfter)
        // Realm fills columns added by a migration with zero, not the Swift default,
        // which is why a rank counts as known only when its star level is above zero.
        XCTAssertEqual(stat.starLevel, 0)
        XCTAssertEqual(stat.starLevelAfter, 0)

        // The new class is usable in the migrated file.
        XCTAssertEqual(realm.objects(DefaultDeckStats.self).count, 0)
        try realm.write {
            let bucket = DefaultDeckStats()
            bucket.playerClassRaw = CardClass.paladin.rawValue
            bucket.gameStats.append(deck.gameStats[1].detachedCopy())
            realm.add(bucket)
        }
        XCTAssertEqual(realm.objects(DefaultDeckStats.self).first?.gameStats.first?.statId, "legacy-1")
    }

    // MARK: - Report

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-09-13 12:00 UTC.
    private static let now = utc.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 12))!

    private static let owners = [
        RecordOwnerInfo(owner: .deck(id: "active"), name: "Active", playerClass: .rogue, isArchived: false),
        RecordOwnerInfo(owner: .deck(id: "archived"), name: "Archived", playerClass: .mage, isArchived: true),
        RecordOwnerInfo(owner: .noDeck(.hunter), name: "No deck", playerClass: .hunter, isArchived: false)
    ]

    private var nextGameOffset: TimeInterval = 0

    /// A game played `hoursAgo` before `now`; later calls default to older games.
    private func game(_ result: GameResult, owner: RecordOwner = .deck(id: "active"), mode: GameMode = .ranked,
                      format: Format? = .standard, opponent: CardClass = .mage, coin: Bool? = nil,
                      turns: Int = 0, hoursAgo: Double? = nil, duration: TimeInterval? = nil,
                      season: Int? = nil, rankedSeasonId: Int = 0,
                      before: RankSnapshot? = nil, after: RankSnapshot? = nil) -> RecordGame {
        nextGameOffset += 60
        let start = RecordStatsTests.now.addingTimeInterval(hoursAgo.map { -$0 * 3600 } ?? -nextGameOffset)
        return RecordGame(statId: UUID().uuidString, owner: owner, playerClass: .rogue, opponentClass: opponent,
                          opponentName: "Opponent", result: result, wasConceded: false, mode: mode, format: format,
                          coin: coin, turns: turns, startTime: start, duration: duration,
                          season: season ?? Database.season(for: start, timeZone: RecordStatsTests.utc.timeZone),
                          rankedSeasonId: rankedSeasonId, rankBefore: before, rankAfter: after)
    }

    private func report(_ games: [RecordGame], filter: RecordFilter = RecordFilter(),
                        gameLimit: Int = 1000) -> RecordReport {
        return StatsHelper.buildRecordReport(data: RecordData(owners: RecordStatsTests.owners, games: games),
                                             filter: filter, now: RecordStatsTests.now,
                                             calendar: RecordStatsTests.utc, gameLimit: gameLimit)
    }

    private func rank(_ starLevel: Int, _ stars: Int, legend: Int = 0) -> RankSnapshot {
        return RankSnapshot(leagueId: 5, starLevel: starLevel, stars: stars, legendRank: legend)
    }

    func testRecordFilterDefaultsToAllLadderGames() {
        let filter = RecordFilter()
        XCTAssertEqual(filter.mode, .all)
        XCTAssertEqual(filter.format, .all)
        XCTAssertEqual(filter.timeFrame, .allTime)
        XCTAssertTrue(filter.includeArchived)
        XCTAssertTrue(filter.includeNoDeck)
        XCTAssertNil(filter.owner)
        XCTAssertEqual(RecordFilter.modes, [.all, .ranked, .casual])
        XCTAssertEqual(RecordFilter.formats, [.all, .standard, .wild, .classic, .twist])
    }

    func testReportIsLadderOnly() {
        var games = [game(.win, mode: .ranked), game(.loss, mode: .casual), game(.win, mode: .casual)]
        for mode: GameMode in [.arena, .brawl, .friendly, .practice, .spectator, .battlegrounds, .duels,
                               .mercenaries, .none, .all] {
            games.append(game(.win, mode: mode))
        }

        let all = report(games)
        XCTAssertEqual(all.overall.record.wins, 2)
        XCTAssertEqual(all.overall.record.losses, 1)
        XCTAssertEqual(all.gameCount, 3)
        XCTAssertTrue(all.games.allSatisfy { $0.mode == .ranked || $0.mode == .casual })

        var filter = RecordFilter()
        filter.mode = .ranked
        XCTAssertEqual(report(games, filter: filter).overall.record.total, 1)
        filter.mode = .casual
        XCTAssertEqual(report(games, filter: filter).overall.record.total, 2)
        // A mode outside the record's list does not open the record up to it.
        filter.mode = .arena
        XCTAssertEqual(report(games, filter: filter).overall.record.total, 0)
    }

    func testReportFormatFilter() {
        let games = [game(.win, format: .standard), game(.win, format: .wild), game(.loss, format: .wild),
                     game(.win, mode: .casual, format: .classic), game(.loss, format: .twist),
                     game(.win, format: nil)]
        var filter = RecordFilter()
        XCTAssertEqual(report(games, filter: filter).overall.record.total, 6)
        filter.format = .wild
        XCTAssertEqual(report(games, filter: filter).overall.record.total, 2)
        filter.format = .classic
        XCTAssertEqual(report(games, filter: filter).overall.record.wins, 1)
        filter.format = .twist
        XCTAssertEqual(report(games, filter: filter).overall.record.losses, 1)
        filter.format = .standard
        XCTAssertEqual(report(games, filter: filter).overall.record.total, 1)
    }

    func testReportTimeFrames() {
        let currentSeason = Database.season(for: RecordStatsTests.now, timeZone: RecordStatsTests.utc.timeZone)
        let games = [game(.win, hoursAgo: 1),          // today
                     game(.win, hoursAgo: 13),         // yesterday
                     game(.win, hoursAgo: 24 * 6),     // this week, this season
                     game(.win, hoursAgo: 24 * 20),    // last season
                     game(.win, hoursAgo: 24 * 60)]    // two seasons ago
        var filter = RecordFilter()
        let expected: [(RecordTimeFrame, Int)] = [(.allTime, 5), (.today, 1), (.last7Days, 3),
                                                  (.last30Days, 4), (.currentSeason, 3), (.lastSeason, 1)]
        for (timeFrame, count) in expected {
            filter.timeFrame = timeFrame
            XCTAssertEqual(report(games, filter: filter).overall.record.total, count, "\(timeFrame)")
        }
        XCTAssertEqual(games[3].season, currentSeason - 1)
    }

    func testReportDeckFilters() {
        let games = [game(.win, owner: .deck(id: "active"), opponent: .mage),
                     game(.loss, owner: .deck(id: "active"), opponent: .priest),
                     game(.win, owner: .deck(id: "archived"), opponent: .mage),
                     game(.loss, owner: .noDeck(.hunter), opponent: .warrior),
                     game(.win, owner: .deck(id: "deleted"), opponent: .mage)]

        let all = report(games)
        XCTAssertEqual(all.overall.record.total, 4, "games of an unknown owner are skipped")
        XCTAssertEqual(Set(all.decks.map { $0.info.owner }),
                       [.deck(id: "active"), .deck(id: "archived"), .noDeck(.hunter)])
        XCTAssertEqual(all.decks.first?.info.owner, .deck(id: "active"), "most games first")
        XCTAssertEqual(all.decks.first?.summary.record.wins, 1)
        XCTAssertEqual(all.decks.first?.summary.record.losses, 1)

        var filter = RecordFilter()
        filter.includeArchived = false
        XCTAssertEqual(report(games, filter: filter).overall.record.total, 3)
        filter.includeNoDeck = false
        let decksOnly = report(games, filter: filter)
        XCTAssertEqual(decksOnly.overall.record.total, 2)
        XCTAssertEqual(decksOnly.decks.map { $0.info.owner }, [.deck(id: "active")])

        filter = RecordFilter()
        filter.owner = .noDeck(.hunter)
        let bucket = report(games, filter: filter)
        XCTAssertEqual(bucket.overall.record.losses, 1)
        XCTAssertEqual(bucket.overall.record.total, 1)
        XCTAssertEqual(bucket.matchups.map { $0.opponentClass }, [.warrior])
        XCTAssertEqual(bucket.games.count, 1)
        // The deck rows still list every deck so the picker can switch back.
        XCTAssertEqual(bucket.decks.count, 3)
    }

    func testReportCountsLegacyGamesWithUnknownTurnOrder() {
        // A row recorded before turn order was stored: coin=false is meaningless.
        let legacy = GameStats()
        legacy.statId = "legacy"
        legacy.gameMode = .ranked
        legacy.result = .win
        legacy.coin = false
        legacy.startTime = RecordStatsTests.now.addingTimeInterval(-7200)
        legacy.endTime = legacy.startTime
        let legacyGame = RecordGame(stat: legacy, owner: .deck(id: "active"), ownerClass: .rogue)
        XCTAssertNil(legacyGame.coin)
        XCTAssertNil(legacyGame.duration)
        XCTAssertEqual(legacyGame.playerClass, .rogue, "neutral playerHero falls back to the deck class")
        XCTAssertNil(legacyGame.rankBefore)

        let recorded = GameStats()
        recorded.statId = "new"
        recorded.gameMode = .ranked
        recorded.result = .loss
        recorded.playerHero = .warlock
        recorded.coin = true
        recorded.coinKnown = true
        recorded.recordVersion = GameStats.currentRecordVersion
        recorded.startTime = RecordStatsTests.now.addingTimeInterval(-3600)
        recorded.endTime = recorded.startTime.addingTimeInterval(420)
        let recordedGame = RecordGame(stat: recorded, owner: .deck(id: "active"), ownerClass: .rogue)
        XCTAssertEqual(recordedGame.coin, true)
        XCTAssertEqual(recordedGame.duration, 420)
        XCTAssertEqual(recordedGame.playerClass, .warlock)

        let games = [recordedGame, legacyGame, game(.win, coin: false, hoursAgo: 3), game(.win, coin: false, hoursAgo: 4)]
        let summary = report(games).overall
        XCTAssertEqual(summary.record.wins, 3)
        XCTAssertEqual(summary.record.losses, 1)
        XCTAssertEqual(summary.goingFirst.wins, 2)
        XCTAssertEqual(summary.goingFirst.total, 2)
        XCTAssertEqual(summary.onCoin.losses, 1)
        XCTAssertEqual(summary.onCoin.total, 1)
        XCTAssertEqual(summary.unknownTurnOrder, 1)
        XCTAssertEqual(summary.averageDuration, 420)

        // Both Realm rows have no opponent class, so only the mage games form a matchup.
        let matchups = report(games).matchups
        XCTAssertEqual(matchups.map { $0.opponentClass }, [.mage])
        XCTAssertEqual(matchups.first?.summary.goingFirst.total, 2)
    }

    func testReportStreakLastTenAndAverages() {
        var games = [game(.win, turns: 8, duration: 300), game(.win, turns: 10, duration: 500),
                     game(.unknown, turns: 30), game(.win), game(.loss), game(.win)]
        var summary = report(games).overall
        XCTAssertEqual(summary.streak, RecordStreak(result: .win, count: 3), "unknown results are skipped")
        XCTAssertEqual(summary.lastTen, [.win, .win, .win, .loss, .win])
        XCTAssertEqual(summary.averageTurns, 9)
        XCTAssertEqual(summary.averageDuration, 400)
        XCTAssertEqual(summary.lastPlayed, games[0].startTime)
        XCTAssertEqual(report(games).gameCount, 6, "unknown results are listed but not counted")
        XCTAssertEqual(summary.record.total, 5)

        nextGameOffset = 0
        games = [game(.loss), game(.loss), game(.draw), game(.loss)]
        summary = report(games).overall
        XCTAssertEqual(summary.streak, RecordStreak(result: .loss, count: 2), "a draw ends the streak")

        nextGameOffset = 0
        games = [game(.draw), game(.win)]
        XCTAssertNil(report(games).overall.streak)

        nextGameOffset = 0
        games = (0 ..< 15).map { game($0 < 12 ? .loss : .win) }
        summary = report(games, gameLimit: 5).overall
        XCTAssertEqual(summary.lastTen, Array(repeating: .loss, count: 10))
        XCTAssertEqual(summary.record.total, 15, "the game limit only caps the list")
        XCTAssertEqual(report(games, gameLimit: 5).games.count, 5)
        XCTAssertEqual(report(games, gameLimit: 5).gameCount, 15)
        XCTAssertEqual(summary.averageTurns, nil)
    }

    func testReportMatchups() {
        let games = [game(.win, opponent: .mage, coin: false), game(.loss, opponent: .mage, coin: true),
                     game(.win, opponent: .mage, coin: true), game(.loss, opponent: .druid),
                     game(.win, opponent: .neutral), game(.unknown, opponent: .paladin)]
        let matchups = report(games).matchups
        XCTAssertEqual(Set(matchups.map { $0.opponentClass }), [.mage, .druid])
        let mage = matchups.first { $0.opponentClass == .mage }
        XCTAssertEqual(mage?.summary.record.wins, 2)
        XCTAssertEqual(mage?.summary.record.losses, 1)
        XCTAssertEqual(mage?.summary.goingFirst.wins, 1)
        XCTAssertEqual(mage?.summary.onCoin.wins, 1)
        XCTAssertEqual(mage?.summary.onCoin.losses, 1)
        XCTAssertEqual(StatsHelper.getDeckWinRate(record: mage!.summary.record), 2.0 / 3.0, accuracy: 0.0001)
    }

    func testRankSnapshotOrdering() {
        XCTAssertEqual(rank(1, 0).ladderStars, 0)
        XCTAssertEqual(rank(45, 3).ladderStars, 135)
        XCTAssertEqual(rank(46, 0).ladderStars, 135)
        XCTAssertEqual(rank(50, 3).ladderStars, 150)
        // A win at Diamond 1 with three stars reaches Legend, one star further.
        XCTAssertEqual(rank(51, 0).ladderStars, 151)
        XCTAssertEqual(rank(51, 0, legend: 500).ladderStars, 151)
        XCTAssertTrue(rank(51, 0).isLegendLevel)
        XCTAssertTrue(rank(31, 1).isHigher(than: rank(30, 3)))
        XCTAssertFalse(rank(30, 3).isHigher(than: rank(30, 3)))
        XCTAssertTrue(rank(51, 0, legend: 100).isHigher(than: rank(51, 0, legend: 500)))
        XCTAssertTrue(rank(51, 0, legend: 500).isHigher(than: rank(51, 0)))
        XCTAssertTrue(rank(51, 0).isHigher(than: rank(50, 3)))
    }

    func testRankProgressionPerSeasonAndFormat() {
        let currentSeason = Database.season(for: RecordStatsTests.now, timeZone: RecordStatsTests.utc.timeZone)
        // Newest first, as the report sorts them.
        let games = [
            // Current season, standard: Diamond 5 ★2 -> climbs to Diamond 4 ★1 -> drops to Diamond 5 ★3.
            game(.loss, hoursAgo: 1, before: rank(46, 1), after: rank(45, 3)),
            game(.win, hoursAgo: 2, before: rank(45, 3), after: rank(46, 1)),
            game(.win, hoursAgo: 3, before: rank(45, 2), after: rank(45, 3)),
            // An unknown post-game read still contributes its pre-game rank.
            game(.win, hoursAgo: 4, before: rank(45, 1), after: nil),
            game(.win, hoursAgo: 5, before: rank(45, 0), after: rank(45, 1)),
            // Legacy ranked game without a rank, and a casual game: not part of it.
            game(.win, hoursAgo: 6),
            game(.win, mode: .casual, hoursAgo: 7, before: rank(10, 0), after: rank(10, 1)),
            // Current season, wild: reaches Legend.
            game(.win, format: .wild, hoursAgo: 8, before: rank(50, 3), after: rank(51, 0, legend: 900)),
            // Last season, standard.
            game(.loss, hoursAgo: 24 * 20, before: rank(51, 0, legend: 300), after: rank(51, 0, legend: 450)),
            game(.win, hoursAgo: 24 * 21, before: rank(51, 0, legend: 800), after: rank(51, 0, legend: 300))
        ]

        let progression = report(games).rankProgression
        XCTAssertEqual(progression.map { $0.season }, [currentSeason, currentSeason, currentSeason - 1])
        XCTAssertEqual(progression.map { $0.format }, [.standard, .wild, .standard])

        let standard = progression[0]
        XCTAssertEqual(standard.games, 5)
        XCTAssertEqual(standard.start, rank(45, 0))
        XCTAssertEqual(standard.current, rank(45, 3))
        XCTAssertEqual(standard.peak, rank(46, 1))
        XCTAssertEqual(standard.netStars, 3)

        let wild = progression[1]
        XCTAssertEqual(wild.start, rank(50, 3))
        XCTAssertEqual(wild.current, rank(51, 0, legend: 900))
        XCTAssertEqual(wild.netStars, 1)

        let lastSeason = progression[2]
        XCTAssertEqual(lastSeason.start, rank(51, 0, legend: 800))
        XCTAssertEqual(lastSeason.current, rank(51, 0, legend: 450))
        XCTAssertEqual(lastSeason.peak, rank(51, 0, legend: 300))
        XCTAssertNil(lastSeason.netStars, "stars do not move inside Legend")

        // Format and time filters scope it; deck filters do not, the rank is the account's.
        var filter = RecordFilter()
        filter.format = .wild
        XCTAssertEqual(report(games, filter: filter).rankProgression.map { $0.format }, [.wild])
        filter = RecordFilter()
        filter.timeFrame = .lastSeason
        XCTAssertEqual(report(games, filter: filter).rankProgression.map { $0.season }, [currentSeason - 1])
        filter = RecordFilter()
        filter.owner = .noDeck(.hunter)
        filter.includeArchived = false
        XCTAssertEqual(report(games, filter: filter).rankProgression.count, 3)
        filter = RecordFilter()
        filter.mode = .casual
        XCTAssertTrue(report(games, filter: filter).rankProgression.isEmpty)
    }

    func testRankProgressionGroupsByRankedSeasonId() {
        let currentSeason = Database.season(for: RecordStatsTests.now, timeZone: RecordStatsTests.utc.timeZone)
        // Ids numbered unlike Database.season, to show only their offset matters.
        let currentId = 500
        let games = [
            game(.win, hoursAgo: 2, rankedSeasonId: currentId, before: rank(5, 0), after: rank(5, 1)),
            game(.win, hoursAgo: 3, rankedSeasonId: currentId, before: rank(4, 3), after: rank(5, 0)),
            // 1 September 02:00 UTC, before the server's rollover: still last season,
            // where the player was climbing Legend.
            game(.win, hoursAgo: 24 * 12 + 10, rankedSeasonId: currentId - 1,
                 before: rank(51, 0, legend: 450), after: rank(51, 0, legend: 200)),
            game(.loss, hoursAgo: 24 * 20, rankedSeasonId: currentId - 1,
                 before: rank(51, 0, legend: 300), after: rank(51, 0, legend: 450)),
            game(.win, hoursAgo: 24 * 21, rankedSeasonId: currentId - 1,
                 before: rank(50, 3), after: rank(51, 0, legend: 300)),
            // An older row without an id keeps its calendar month.
            game(.win, hoursAgo: 24 * 50, before: rank(40, 0), after: rank(40, 1))
        ]
        XCTAssertEqual(games[2].season, currentSeason, "the calendar month is already the new one")

        let progression = report(games).rankProgression
        XCTAssertEqual(progression.map { $0.season }, [currentSeason, currentSeason - 1, currentSeason - 2])
        let current = progression[0]
        XCTAssertEqual(current.games, 2)
        XCTAssertEqual(current.start, rank(4, 3))
        XCTAssertEqual(current.current, rank(5, 1))
        XCTAssertEqual(current.netStars, 1)
        let last = progression[1]
        XCTAssertEqual(last.games, 3)
        XCTAssertEqual(last.start, rank(50, 3))
        XCTAssertEqual(last.current, rank(51, 0, legend: 200))
        XCTAssertEqual(last.peak, rank(51, 0, legend: 200))
        XCTAssertEqual(progression[2].games, 1)
    }

    func testRecordGameSeasonComesFromStartTime() {
        let stat = GameStats()
        stat.gameMode = .ranked
        stat.season = 3 // what a frozen or non-Gregorian season left behind
        stat.startTime = RecordStatsTests.now
        let recordGame = RecordGame(stat: stat, owner: .deck(id: "active"), ownerClass: .rogue)
        XCTAssertEqual(recordGame.season, Database.season(for: RecordStatsTests.now))
    }

    func testLoadRecordDataReadsDecksAndBucketsOffTheMainThread() throws {
        let realm = try Realm()
        let ranked = makeStat(.win)
        ranked.opponentHero = .mage
        let archivedDeck = try makeDeck(.mage, games: [ranked, makeStat(.loss, mode: .arena)], in: realm)
        try realm.write {
            archivedDeck.isActive = false
        }
        RealmHelper.addStatistics(toDefaultDeckFor: .hunter, stats: makeStat(.loss, mode: .casual))
        RealmHelper.addStatistics(toDefaultDeckFor: .hunter, stats: makeStat(.win, mode: .battlegrounds))
        let deckId = archivedDeck.deckId

        let loaded = expectation(description: "report built")
        var data: RecordData?
        DispatchQueue.global(qos: .userInitiated).async {
            data = StatsHelper.loadRecordData()
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 10)

        let result = try XCTUnwrap(data)
        XCTAssertEqual(result.owners.count, 2)
        let deckOwner = try XCTUnwrap(result.owners.first { $0.owner == .deck(id: deckId) })
        XCTAssertTrue(deckOwner.isArchived)
        XCTAssertEqual(deckOwner.playerClass, .mage)
        XCTAssertTrue(result.owners.contains { $0.owner == .noDeck(.hunter) && $0.playerClass == .hunter })
        XCTAssertEqual(result.games.count, 2, "only ladder games are loaded")
        XCTAssertEqual(Set(result.games.map { $0.mode }), [.ranked, .casual])
        XCTAssertEqual(result.games.first { $0.owner == .deck(id: deckId) }?.playerClass, .mage)

        let report = StatsHelper.buildRecordReport(data: result, filter: RecordFilter())
        XCTAssertEqual(report.overall.record.wins, 1)
        XCTAssertEqual(report.overall.record.losses, 1)
    }
}

// MARK: - Schema 8 models

// Frozen copies of the Realm models as they were at schema version 8, mapped onto the
// same table names. Kept out of the default schema so they never clash with the real
// classes; only testMigrationFromSchema8KeepsGames opens a realm with them.

class V8Deck: Object {
    @objc dynamic var deckId: String = ""
    @objc dynamic var name = ""
    @objc dynamic var _playerClass = CardClass.neutral.rawValue
    @objc dynamic var heroId = ""
    @objc dynamic var deckMajorVersion: Int = 1
    @objc dynamic var deckMinorVersion: Int = 0
    @objc dynamic var creationDate = Date()
    @objc dynamic var lastEdited = Date()
    let hearthstatsId = RealmProperty<Int?>()
    let hearthstatsVersionId = RealmProperty<Int?>()
    let hearthStatsArenaId = RealmProperty<Int?>()
    @objc dynamic var isActive = true
    @objc dynamic var isArena = false
    @objc dynamic var isDungeon = false
    @objc dynamic var isDuels = false
    let hsDeckId = RealmProperty<Int64?>()
    let cards = List<V8RealmCard>()
    let gameStats = List<V8GameStats>()
    let sideboards = List<V8RealmSideboard>()

    override static func primaryKey() -> String? { return "deckId" }
    override class func _realmObjectName() -> String? { return "Deck" }
    override class func shouldIncludeInDefaultSchema() -> Bool { return false }
}

class V8GameStats: EmbeddedObject {
    @objc dynamic var statId = ""
    @objc dynamic var _playerHero = CardClass.neutral.rawValue
    @objc dynamic var _opponentHero = CardClass.neutral.rawValue
    @objc dynamic var coin = false
    @objc dynamic var _gameMode = GameMode.none.rawValue
    @objc dynamic var _result = GameResult.unknown.rawValue
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
    let hearthstoneBuild = RealmProperty<Int?>()
    @objc dynamic var playerCardbackId = -1
    @objc dynamic var opponentCardbackId = -1
    @objc dynamic var friendlyPlayerId = -1
    @objc dynamic var scenarioId = -1
    @objc dynamic var serverInfo: V8ServerInfo?
    @objc dynamic var season = 0
    @objc dynamic var _gameType = GameType.gt_unknown.rawValue
    let hsDeckId = RealmProperty<Int64?>()
    @objc dynamic var brawlSeasonId = -1
    @objc dynamic var rankedSeasonId = -1
    @objc dynamic var arenaWins = 0
    @objc dynamic var arenaLosses = 0
    @objc dynamic var brawlWins = 0
    @objc dynamic var brawlLosses = 0
    @objc dynamic var __format: String?
    @objc dynamic var hsReplayId: String?
    let opponentCards = List<V8RealmCard>()
    let revealedCards = List<V8RealmCard>()

    override class func _realmObjectName() -> String? { return "GameStats" }
    override class func shouldIncludeInDefaultSchema() -> Bool { return false }
}

class V8RealmCard: EmbeddedObject {
    @objc dynamic var id = ""
    @objc dynamic var count = 0

    convenience init(id: String, count: Int) {
        self.init()
        self.id = id
        self.count = count
    }

    override class func _realmObjectName() -> String? { return "RealmCard" }
    override class func shouldIncludeInDefaultSchema() -> Bool { return false }
}

class V8ServerInfo: EmbeddedObject {
    @objc dynamic var address = ""
    @objc dynamic var auroraPassword = ""
    @objc dynamic var clientHandle = 0
    @objc dynamic var gameHandle = 0
    @objc dynamic var mission = 0
    @objc dynamic var port = 0
    @objc dynamic var resumable = false
    @objc dynamic var spectatorMode = false
    @objc dynamic var spectatorPassword = ""
    @objc dynamic var version = ""

    override class func _realmObjectName() -> String? { return "ServerInfo" }
    override class func shouldIncludeInDefaultSchema() -> Bool { return false }
}

class V8RealmSideboard: EmbeddedObject {
    @objc dynamic var ownerCardId = ""
    let cards = List<V8RealmCard>()

    override class func _realmObjectName() -> String? { return "RealmSideboard" }
    override class func shouldIncludeInDefaultSchema() -> Bool { return false }
}
