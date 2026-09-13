//
//  ActionHistoryReplayTests.swift
//  HSTrackerTests
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import XCTest
import Foundation

@testable import HSTracker

// Feeds PowerTaskList lines from a zhCN ranked game through PowerGameStateParser into a Game, to
// check the parser and TagChangeHandler hooks reach Game.actionHistory with what the recorder needs.
//
// The lines are copied from Power.log with the BattleTags replaced. Tags the history does not read
// were left out, and so were lines that reach AppDelegate.instance().coreManager, which is nil in
// the test host: the local player's RESOURCES_USED (TagChangeActions.onResourcesUsedChange) and the
// local player's own turn-start draw, whose SHOW_ENTITY body queues more of those actions.
// Game.reset and Game.handleEndGame are not called here for the same reason (OpponentDeadForTracker
// and the end-of-game statistics reach CoreManager on the main queue); the recorder's own lifecycle
// is covered by ActionHistoryRecorderTests.
class ActionHistoryReplayTests: HSTrackerTests {
    private static let localName = "Player#1234"
    private static let opponentName = "Opponent#5678"

    // Turn 8 starts for the opponent, who draws a card
    private static let opponentTurnStart = """
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=CURRENT_PLAYER value=0
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Opponent#5678 tag=CURRENT_PLAYER value=1
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=TURN value=8
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=STEP value=MAIN_READY
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Opponent#5678 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=7 zone=DECK zonePos=0 cardId= player=1] tag=ZONE value=HAND
        D 13:59:52.5135460 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 13:59:54.0480770 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=STEP value=MAIN_ACTION
        """

    // The opponent plays a Secret from hand. The client only shows an unknown card.
    private static let opponentPlaysSecret = """
        D 14:00:08.5281050 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=96 zone=HAND zonePos=4 cardId= player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1
        D 14:00:08.5281050 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=96 zone=HAND zonePos=4 cardId= player=1] tag=SECRET value=1
        D 14:00:08.5281050 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=96 zone=HAND zonePos=4 cardId= player=1] tag=ZONE value=SECRET
        D 14:00:10.0870090 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Opponent#5678 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 14:00:10.0870090 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 14:00:10.0870090 PowerTaskList.DebugPrintPower() - BLOCK_END
        """

    // Turn 13 starts for the local player (their own draw is left out)
    private static let localTurnStart = """
        D 14:01:48.8256030 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 14:01:48.8256030 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Opponent#5678 tag=CURRENT_PLAYER value=0
        D 14:01:48.8256030 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=CURRENT_PLAYER value=1
        D 14:01:48.8256030 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=TURN value=13
        D 14:01:48.8256030 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 14:01:48.8256030 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=STEP value=MAIN_READY
        D 14:01:49.3626190 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=STEP value=MAIN_ACTION
        """

    // 暮光侵扰 (EDR_463) destroys 永恒雏龙 (TIME_045), which is reborn. The opponent's Secret
    // 压感陷阱 (CORE_ULD_152) is shown, triggers and destroys 暮光时空撕裂者 (END_010).
    private static let localPlaysSpell = """
        D 14:02:18.7741970 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=暮光侵扰 id=56 zone=HAND zonePos=2 cardId=EDR_463 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=永恒雏龙 id=21 zone=PLAY zonePos=2 cardId=TIME_045 player=1] SubOption=0
        D 14:02:18.7741970 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=暮光侵扰 id=56 zone=HAND zonePos=2 cardId=EDR_463 player=2] tag=CARD_TARGET value=21
        D 14:02:18.7741970 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=暮光侵扰 id=56 zone=HAND zonePos=2 cardId=EDR_463 player=2] tag=ZONE value=PLAY
        D 14:02:18.7741970 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=操纵荆棘 id=57 zone=SETASIDE zonePos=0 cardId=EDR_463a player=2] tag=CARD_TARGET value=21
        D 14:02:18.7931810 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=POWER Entity=[entityName=暮光侵扰 id=56 zone=PLAY zonePos=0 cardId=EDR_463 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=永恒雏龙 id=21 zone=PLAY zonePos=2 cardId=TIME_045 player=1] SubOption=0
        D 14:02:18.7931810 PowerTaskList.DebugPrintPower() -         TAG_CHANGE Entity=[entityName=永恒雏龙 id=21 zone=PLAY zonePos=2 cardId=TIME_045 player=1] tag=TO_BE_DESTROYED value=1
        D 14:02:20.6044450 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 14:02:20.6044450 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=暮光侵扰 id=56 zone=PLAY zonePos=0 cardId=EDR_463 player=2] tag=ZONE value=GRAVEYARD
        D 14:02:20.6169440 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=DEATHS Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1
        D 14:02:20.6169440 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=永恒雏龙 id=21 zone=PLAY zonePos=2 cardId=TIME_045 player=1] tag=TO_BE_DESTROYED value=0
        D 14:02:20.6169440 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=永恒雏龙 id=21 zone=PLAY zonePos=2 cardId=TIME_045 player=1] tag=ZONE value=GRAVEYARD
        D 14:02:20.6169440 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -     FULL_ENTITY - Updating [entityName=永恒雏龙 id=140 zone=PLAY zonePos=2 cardId=TIME_045 player=1] CardID=TIME_045
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=1
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=MINION
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=COST value=3
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=ATK value=1
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=HEALTH value=4
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=EXHAUSTED value=1
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=ZONE value=PLAY
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=140
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=CLASS value=NEUTRAL
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=RARITY value=COMMON
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=CREATOR value=21
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -         tag=REBORN value=1
        D 14:02:20.6622000 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=永恒雏龙 id=140 zone=PLAY zonePos=2 cardId=TIME_045 player=1] tag=DAMAGE value=3
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=污染光明 id=86 zone=SECRET zonePos=0 cardId=TLC_817t2 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=污染光明 id=86 zone=SECRET zonePos=0 cardId=TLC_817t2 player=2] tag=QUEST_PROGRESS value=1
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=96 zone=SECRET zonePos=0 cardId= player=1] CardID=CORE_ULD_152
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=1
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=COST value=2
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=EXHAUSTED value=0
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=96
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=CLASS value=HUNTER
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=RARITY value=COMMON
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=SECRET value=1
        D 14:02:21.6545270 PowerTaskList.DebugPrintPower() -         tag=CREATOR value=5
        D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=压感陷阱 id=96 zone=SECRET zonePos=0 cardId=CORE_ULD_152 player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=SECRET
        D 14:02:21.6735360 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=暮光时空撕裂者 id=108 zone=PLAY zonePos=1 cardId=END_010 player=2] tag=TO_BE_DESTROYED value=1
        D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 14:02:26.6867400 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=压感陷阱 id=96 zone=SECRET zonePos=0 cardId=CORE_ULD_152 player=1] tag=ZONE value=GRAVEYARD
        D 14:02:27.7114330 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=DEATHS Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1
        D 14:02:27.7114330 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=暮光时空撕裂者 id=108 zone=PLAY zonePos=1 cardId=END_010 player=2] tag=TO_BE_DESTROYED value=0
        D 14:02:27.7114330 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=暮光时空撕裂者 id=108 zone=PLAY zonePos=1 cardId=END_010 player=2] tag=ZONE value=GRAVEYARD
        D 14:02:27.7114330 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 14:02:27.7436030 PowerTaskList.DebugPrintPower() - BLOCK_END
        """

    // 预言师 (JAIL_912) attacks the opponent's hero (HERO_05bo) for 4
    private static let localAttacks = """
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=ATTACK Entity=[entityName=预言师 id=38 zone=PLAY zonePos=1 cardId=JAIL_912 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=火山暴龙克鲁什 id=71 zone=PLAY zonePos=0 cardId=HERO_05bo player=1] SubOption=-1
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=PROPOSED_ATTACKER value=38
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=PROPOSED_DEFENDER value=71
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=预言师 id=38 zone=PLAY zonePos=1 cardId=JAIL_912 player=2] tag=ATTACKING value=1
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=火山暴龙克鲁什 id=71 zone=PLAY zonePos=0 cardId=HERO_05bo player=1] tag=DEFENDING value=1
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=火山暴龙克鲁什 id=71 zone=PLAY zonePos=0 cardId=HERO_05bo player=1] tag=DAMAGE value=11
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=PROPOSED_ATTACKER value=0
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=PROPOSED_DEFENDER value=0
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=预言师 id=38 zone=PLAY zonePos=1 cardId=JAIL_912 player=2] tag=ATTACKING value=0
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=火山暴龙克鲁什 id=71 zone=PLAY zonePos=0 cardId=HERO_05bo player=1] tag=DEFENDING value=0
        D 14:02:34.0947090 PowerTaskList.DebugPrintPower() - BLOCK_END
        """

    private static var database: Database!

    private var game: Game!
    private var parser: PowerGameStateParser!

    override class func setUp() {
        super.setUp()

        database = Database()
        database.loadDatabase(splashscreen: nil, withLanguages: [.enUS])
    }

    override func setUp() {
        super.setUp()

        game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        parser = PowerGameStateParser(with: game)

        // The board as it was before the excerpt: turn 7 was the local player's (PlayerID 2)
        let gameEntity = entity(1)
        gameEntity.name = "GameEntity"
        gameEntity[.cardtype] = CardType.game.rawValue
        gameEntity[.turn] = 7
        gameEntity[.step] = Step.main_next.rawValue

        let opponentPlayer = entity(2, controller: 1, type: .player)
        opponentPlayer.name = ActionHistoryReplayTests.opponentName
        opponentPlayer[.player_id] = 1
        opponentPlayer[.mulligan_state] = Mulligan.done.rawValue
        let localPlayer = entity(3, controller: 2, type: .player)
        localPlayer.name = ActionHistoryReplayTests.localName
        localPlayer[.player_id] = 2
        localPlayer[.mulligan_state] = Mulligan.done.rawValue
        localPlayer[.current_player] = 1

        game.player.id = 2
        game.player.name = ActionHistoryReplayTests.localName
        game.opponent.id = 1
        game.opponent.name = ActionHistoryReplayTests.opponentName

        let opponentHero = entity(71, cardId: "HERO_05bo", controller: 1, zone: .play, type: .hero)
        opponentHero[.health] = 30
        opponentHero[.damage] = 7
        opponentPlayer[.hero_entity] = opponentHero.id
        let localHero = entity(73, cardId: "HERO_09am_Anduin_hnv", controller: 2, zone: .play, type: .hero)
        localHero[.health] = 30
        localPlayer[.hero_entity] = localHero.id

        // The opponent's hand and deck are unknown
        entity(7, controller: 1, zone: .deck, type: .invalid)
        entity(96, controller: 1, zone: .hand, type: .invalid)
        entity(21, cardId: "TIME_045", controller: 1, zone: .play, type: .minion)[.health] = 4

        entity(56, cardId: "EDR_463", controller: 2, zone: .hand, type: .spell)
        entity(57, cardId: "EDR_463a", controller: 2, zone: .setaside, type: .spell)
        entity(38, cardId: "JAIL_912", controller: 2, zone: .play, type: .minion)[.health] = 4
        entity(108, cardId: "END_010", controller: 2, zone: .play, type: .minion)[.health] = 5
        entity(86, cardId: "TLC_817t2", controller: 2, zone: .secret, type: .spell)
    }

    override func tearDown() {
        parser = nil
        game = nil
        super.tearDown()
    }

    @discardableResult
    private func entity(_ id: Int, cardId: String = "", controller: Int = 0, zone: Zone? = nil, type: CardType? = nil) -> Entity {
        let entity = Entity(id: id)
        entity.cardId = cardId
        if controller > 0 {
            entity[.controller] = controller
        }
        if let zone {
            entity[.zone] = zone.rawValue
        }
        if let type {
            entity[.cardtype] = type.rawValue
        }
        game.entities[id] = entity
        return entity
    }

    private func feed(_ lines: String) {
        for line in lines.split(separator: "\n") where !line.isEmpty {
            parser.handle(logLine: LogLine(namespace: .power, line: String(line)))
        }
    }

    private var turns: [HistoryTurn] {
        return game.actionHistory.snapshot().turns
    }

    private func effect(_ entry: HistoryEntry?, _ kind: HistoryEffectKind) -> HistoryEffect? {
        return entry?.effects.first { $0.kind == kind }
    }

    private func json(_ turns: [HistoryTurn]) -> String {
        guard let data = try? JSONEncoder().encode(turns) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Tests

    func testOpponentTurnKeepsTheDrawAndTheSecretAnonymous() {
        feed(ActionHistoryReplayTests.opponentTurnStart)
        feed(ActionHistoryReplayTests.opponentPlaysSecret)

        let turns = self.turns
        XCTAssertEqual(turns.count, 1)
        guard let turn = turns.first else {
            return
        }
        XCTAssertEqual(turn.rawTurn, 8)
        XCTAssertEqual(turn.turn, 4)
        XCTAssertEqual(turn.side, .opponent)

        XCTAssertEqual(turn.header.count, 1)
        XCTAssertEqual(turn.header.first?.kind, .drewUnknown)
        XCTAssertEqual(turn.header.first?.amount, 1)
        XCTAssertEqual(turn.header.first?.targets.map { $0.cardId }, [nil])

        XCTAssertEqual(turn.entries.count, 1)
        let play = turn.entries.first
        XCTAssertEqual(play?.type, .play)
        XCTAssertEqual(play?.activeSide, .opponent)
        XCTAssertEqual(play?.source?.entityId, 96)
        XCTAssertEqual(play?.source?.side, .opponent)
        XCTAssertNil(play?.source?.cardId)
        XCTAssertNil(play?.revealedLater)
        XCTAssertFalse(json(turns).contains("CORE_ULD_152"))
    }

    func testReplayRecordsPlaySecretTriggerDeathsAndAttack() {
        feed(ActionHistoryReplayTests.opponentTurnStart)
        feed(ActionHistoryReplayTests.opponentPlaysSecret)
        feed(ActionHistoryReplayTests.localTurnStart)
        feed(ActionHistoryReplayTests.localPlaysSpell)
        feed(ActionHistoryReplayTests.localAttacks)

        let turns = self.turns
        XCTAssertEqual(turns.map { $0.rawTurn }, [8, 13])
        XCTAssertEqual(turns.map { $0.side }, [.opponent, .player])
        guard turns.count == 2 else {
            return
        }

        // The Secret was named once the client showed it
        let secretPlay = turns[0].entries.first
        XCTAssertNil(secretPlay?.source?.cardId)
        XCTAssertEqual(secretPlay?.revealedLater?.entityId, 96)
        XCTAssertEqual(secretPlay?.revealedLater?.cardId, "CORE_ULD_152")

        let entries = turns[1].entries
        XCTAssertEqual(entries.map { $0.type }, [.play, .attack])
        guard entries.count == 2 else {
            return
        }

        let play = entries[0]
        XCTAssertEqual(play.activeSide, .player)
        XCTAssertEqual(play.source?.cardId, "EDR_463")
        XCTAssertEqual(play.source?.side, .player)
        XCTAssertEqual(play.target?.entityId, 21)
        XCTAssertEqual(play.target?.cardId, "TIME_045")
        // The nested POWER of the spell merges into the play, and the empty quest trigger is dropped
        XCTAssertEqual(play.children.map { $0.type }, [.secret])
        let secret = play.children.first
        XCTAssertEqual(secret?.source?.entityId, 96)
        XCTAssertEqual(secret?.source?.cardId, "CORE_ULD_152")
        XCTAssertEqual(secret?.source?.side, .opponent)
        XCTAssertEqual(secret?.triggerKeyword, "SECRET")

        let deaths = play.effects.filter { $0.kind == .died || $0.kind == .destroyed }.flatMap { $0.targets }
        XCTAssertEqual(Set(deaths.map { $0.entityId }), [21, 108])
        XCTAssertEqual(Set(deaths.compactMap { $0.cardId }), ["TIME_045", "END_010"])
        XCTAssertEqual(effect(play, .summoned)?.targets.map { $0.entityId }, [140])
        XCTAssertEqual(effect(play, .summoned)?.targets.map { $0.cardId }, ["TIME_045"])

        let attack = entries[1]
        XCTAssertEqual(attack.source?.cardId, "JAIL_912")
        XCTAssertEqual(attack.target?.entityId, 71)
        XCTAssertEqual(attack.target?.cardId, "HERO_05bo")
        XCTAssertEqual(effect(attack, .damage)?.amount, 4)
        XCTAssertEqual(effect(attack, .damage)?.targets.map { $0.entityId }, [71])
    }

    func testCreateGameKeepsTheTurnsRecordedSoFar() {
        feed(ActionHistoryReplayTests.opponentTurnStart)
        feed(ActionHistoryReplayTests.opponentPlaysSecret)
        let before = turns
        XCTAssertEqual(before.first?.entries.count, 1)

        feed("D 13:57:30.9310320 PowerTaskList.DebugPrintPower() -     CREATE_GAME")

        XCTAssertEqual(turns, before)
    }
}
