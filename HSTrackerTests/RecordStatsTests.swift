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
        // A loss on a floor or a draw legitimately leaves the position unchanged.
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .loss, before: before, after: before))
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .draw, before: before, after: before))
        let legend = RankSnapshot(leagueId: 5, starLevel: 51, stars: 0, legendRank: 1000)
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .win, before: legend, after: legend))
        XCTAssertFalse(StatsHelper.postGameRankLooksStale(result: .win, before: nil, after: nil))
    }

    // MARK: - Season

    func testSeasonForDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        XCTAssertEqual(Database.season(for: date(2014, 4, 10), calendar: calendar), 1)
        XCTAssertEqual(Database.season(for: date(2026, 9, 13), calendar: calendar), (2026 - 2014) * 12 - 3 + 9)
        XCTAssertEqual(Database.season(for: date(2026, 10, 1), calendar: calendar),
                       Database.season(for: date(2026, 9, 30), calendar: calendar) + 1)
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
