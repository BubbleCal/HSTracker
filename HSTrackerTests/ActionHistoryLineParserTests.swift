//
//  ActionHistoryLineParserTests.swift
//  HSTrackerTests
//

import XCTest
import Foundation

@testable import HSTracker

class ActionHistoryLineParserTests: HSTrackerTests {
    // PowerTaskList BLOCK_START lines from a zhCN client, BattleTags replaced
    private static let attackLine = "D 13:59:09.1156510 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=ATTACK Entity=[entityName=焦油爬行者 id=91 zone=PLAY zonePos=1 cardId=CORE_UNG_928 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=火山暴龙克鲁什 id=71 zone=PLAY zonePos=0 cardId=HERO_05bo player=1] SubOption=-1 "
    private static let heroPowerLine = "D 14:05:22.8153910 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=稳固射击 id=72 zone=PLAY zonePos=0 cardId=HERO_05dbp player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 "
    private static let targetedHeroPowerLine = "D 14:04:58.3265190 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=次级治疗术 id=74 zone=PLAY zonePos=0 cardId=HERO_09dbp player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=神使安度因 id=73 zone=PLAY zonePos=0 cardId=HERO_09am_Anduin_hnv player=2] SubOption=-1 "
    private static let secretTriggerLine = "D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=压感陷阱 id=96 zone=SECRET zonePos=0 cardId=CORE_ULD_152 player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=SECRET"
    private static let deathrattleLine = "D 14:00:05.1719970 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=预言师 id=62 zone=GRAVEYARD zonePos=0 cardId=JAIL_912 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=DEATHRATTLE"
    private static let playerTriggerLine = "D 13:58:10.3018100 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET"
    private static let gameEntityTriggerLine = "D 13:57:33.1109040 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=6 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET"
    private static let deathsLine = "D 13:59:29.5357620 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=DEATHS Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 "
    private static let gameResetLine = "D 15:27:43.9601440 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=GAME_RESET Entity=[entityName=抹除存在 id=26 zone=GRAVEYARD zonePos=0 cardId=TIME_433 player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 "
    private static let unknownSourceAndTargetLine = "D 15:08:16.5063320 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=61 zone=HAND zonePos=1 cardId= player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=108 zone=HAND zonePos=8 cardId= player=2] SubOption=-1 "
    private static let chooseOneLine = "D 14:02:18.7741970 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=暮光侵扰 id=56 zone=HAND zonePos=2 cardId=EDR_463 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=永恒雏龙 id=21 zone=PLAY zonePos=2 cardId=TIME_045 player=1] SubOption=0 "
    private static let nestedPowerLine = "D 14:02:18.7931810 PowerTaskList.DebugPrintPower() -     BLOCK_START BlockType=POWER Entity=[entityName=暮光侵扰 id=56 zone=PLAY zonePos=0 cardId=EDR_463 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=永恒雏龙 id=21 zone=PLAY zonePos=2 cardId=TIME_045 player=1] SubOption=0 "
    private static let deckActionLine = "D 13:59:07.6450020 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=DECK_ACTION Entity=[entityName=预言师 id=62 zone=HAND zonePos=2 cardId=JAIL_912 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 "
    private static let startOfGameLine = "D 14:09:45.2681070 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=26 zone=DECK zonePos=0 cardId= player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=START_OF_GAME_KEYWORD"

    private func parse(_ line: String, file: StaticString = #filePath, lineNumber: UInt = #line) -> HistoryBlockInfo? {
        let info = ActionHistoryLineParser.parseBlockStart(line)
        XCTAssertNotNil(info, "not parsed: \(line)", file: file, line: lineNumber)
        return info
    }

    func testAttack() {
        let info = parse(ActionHistoryLineParserTests.attackLine)
        XCTAssertEqual(info, HistoryBlockInfo(blockType: "ATTACK", sourceKind: .entity, sourceEntityId: 91, targetEntityId: 71,
                                              triggerKeyword: nil, effectIndex: 0, subOption: -1))
    }

    func testHeroPowerWithoutTarget() {
        let info = parse(ActionHistoryLineParserTests.heroPowerLine)
        XCTAssertEqual(info?.blockType, "PLAY")
        XCTAssertEqual(info?.sourceKind, .entity)
        XCTAssertEqual(info?.sourceEntityId, 72)
        XCTAssertNil(info?.targetEntityId)
        XCTAssertNil(info?.triggerKeyword)
        XCTAssertEqual(info?.isBareEntity, false)
    }

    func testHeroPowerOnOwnHero() {
        let info = parse(ActionHistoryLineParserTests.targetedHeroPowerLine)
        XCTAssertEqual(info?.sourceEntityId, 74)
        XCTAssertEqual(info?.targetEntityId, 73)
    }

    func testSecretTrigger() {
        let info = parse(ActionHistoryLineParserTests.secretTriggerLine)
        XCTAssertEqual(info?.blockType, "TRIGGER")
        XCTAssertEqual(info?.sourceEntityId, 96)
        XCTAssertEqual(info?.triggerKeyword, "SECRET")
        XCTAssertNil(info?.targetEntityId)
    }

    func testDeathrattleTriggerFromGraveyard() {
        let info = parse(ActionHistoryLineParserTests.deathrattleLine)
        XCTAssertEqual(info?.sourceEntityId, 62)
        XCTAssertEqual(info?.triggerKeyword, "DEATHRATTLE")
    }

    func testTriggerOnPlayerName() {
        let info = parse(ActionHistoryLineParserTests.playerTriggerLine)
        XCTAssertEqual(info, HistoryBlockInfo(blockType: "TRIGGER", sourceKind: .player, sourceEntityId: nil, targetEntityId: nil,
                                              triggerKeyword: "TAG_NOT_SET", effectIndex: -1, subOption: -1))
        XCTAssertEqual(info?.isBareEntity, true)
    }

    func testTriggerOnPlayerNameWithChineseBattleTag() {
        let line = ActionHistoryLineParserTests.playerTriggerLine.replacingOccurrences(of: "Player#1234", with: "炉石玩家丶#9999")
        let info = parse(line)
        XCTAssertEqual(info?.sourceKind, .player)
        XCTAssertNil(info?.sourceEntityId)
        XCTAssertEqual(info?.triggerKeyword, "TAG_NOT_SET")
    }

    func testTriggerOnGameEntity() {
        let info = parse(ActionHistoryLineParserTests.gameEntityTriggerLine)
        XCTAssertEqual(info?.sourceKind, .gameEntity)
        XCTAssertNil(info?.sourceEntityId)
        XCTAssertEqual(info?.effectIndex, 6)
        XCTAssertEqual(info?.triggerKeyword, "TAG_NOT_SET")
    }

    func testDeathsOnGameEntity() {
        let info = parse(ActionHistoryLineParserTests.deathsLine)
        XCTAssertEqual(info, HistoryBlockInfo(blockType: "DEATHS", sourceKind: .gameEntity, sourceEntityId: nil, targetEntityId: nil,
                                              triggerKeyword: nil, effectIndex: 0, subOption: -1))
        XCTAssertEqual(info?.isBareEntity, true)
    }

    func testGameReset() {
        let info = parse(ActionHistoryLineParserTests.gameResetLine)
        XCTAssertEqual(info?.blockType, "GAME_RESET")
        XCTAssertEqual(info?.sourceEntityId, 26)
        XCTAssertEqual(info?.effectIndex, -1)
    }

    func testDeckAction() {
        let info = parse(ActionHistoryLineParserTests.deckActionLine)
        XCTAssertEqual(info?.blockType, "DECK_ACTION")
        XCTAssertEqual(info?.sourceEntityId, 62)
    }

    func testHiddenEntitiesStillYieldTheirIds() {
        let info = parse(ActionHistoryLineParserTests.unknownSourceAndTargetLine)
        XCTAssertEqual(info?.sourceKind, .entity)
        XCTAssertEqual(info?.sourceEntityId, 61)
        XCTAssertEqual(info?.targetEntityId, 108)

        let startOfGame = parse(ActionHistoryLineParserTests.startOfGameLine)
        XCTAssertEqual(startOfGame?.sourceEntityId, 26)
        XCTAssertEqual(startOfGame?.triggerKeyword, "START_OF_GAME_KEYWORD")
    }

    func testChooseOneSubOptionAndNestedBlock() {
        let play = parse(ActionHistoryLineParserTests.chooseOneLine)
        XCTAssertEqual(play?.subOption, 0)
        XCTAssertEqual(play?.targetEntityId, 21)

        let power = parse(ActionHistoryLineParserTests.nestedPowerLine)
        XCTAssertEqual(power?.blockType, "POWER")
        XCTAssertEqual(power?.sourceEntityId, 56)
        XCTAssertEqual(power?.targetEntityId, 21)
        XCTAssertEqual(power?.subOption, 0)
    }

    func testEntityNameThatLooksLikeFields() {
        // The id is read from the fixed fields at the end of the entity, so a name cannot shadow it
        let line = ActionHistoryLineParserTests.attackLine
            .replacingOccurrences(of: "entityName=焦油爬行者", with: "entityName=Odd id=5 zone=HAND [x] Target=0")
            .replacingOccurrences(of: "entityName=火山暴龙克鲁什", with: "entityName=Also id=6 SubOption=3")
        let info = parse(line)
        XCTAssertEqual(info?.sourceEntityId, 91)
        XCTAssertEqual(info?.targetEntityId, 71)
        XCTAssertEqual(info?.subOption, -1)
    }

    func testCombiningScriptNameKeepsTriggerKeyword() {
        let line = ActionHistoryLineParserTests.secretTriggerLine.replacingOccurrences(of: "压感陷阱", with: "กับดักแรงกดดั้น")
        let info = parse(line)
        XCTAssertEqual(info?.sourceEntityId, 96)
        XCTAssertEqual(info?.triggerKeyword, "SECRET")
    }

    func testOtherLinesAreNotBlockStarts() {
        XCTAssertNil(ActionHistoryLineParser.parseBlockStart("D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_END"))
        XCTAssertNil(ActionHistoryLineParser.parseBlockStart("D 13:59:09.1156510 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=焦油爬行者 id=91 zone=PLAY zonePos=1 cardId=CORE_UNG_928 player=2] tag=ATTACKING value=1 "))
        XCTAssertNil(ActionHistoryLineParser.parseBlockStart("D 13:41:40.4709320 PowerTaskList.DebugDump() - Block Start=(null)"))
    }

    func testEntityIdField() {
        XCTAssertNil(ActionHistoryLineParser.entityId("0"))
        XCTAssertNil(ActionHistoryLineParser.entityId("GameEntity"))
        XCTAssertNil(ActionHistoryLineParser.entityId("Player#1234"))
        XCTAssertEqual(ActionHistoryLineParser.entityId("12"), 12)
        XCTAssertEqual(ActionHistoryLineParser.entityId("[entityName=UNKNOWN ENTITY [cardType=INVALID] id=108 zone=HAND zonePos=8 cardId= player=2]"), 108)
        // Loose fallback for a changed field layout
        XCTAssertEqual(ActionHistoryLineParser.entityId("[entityName=Foo id=7 zone=PLAY]"), 7)
    }

    // The parser's own Block reads type, TriggerKeyword and the Target id from the same lines;
    // on every line it can read, both must agree.
    func testAgreesWithPowerGameStateParserBlocks() {
        let game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        game.player.id = 1
        game.opponent.id = 2
        let parser = PowerGameStateParser(with: game)
        let lines = [
            ActionHistoryLineParserTests.attackLine,
            ActionHistoryLineParserTests.heroPowerLine,
            ActionHistoryLineParserTests.targetedHeroPowerLine,
            ActionHistoryLineParserTests.secretTriggerLine,
            ActionHistoryLineParserTests.deathrattleLine,
            ActionHistoryLineParserTests.gameResetLine,
            ActionHistoryLineParserTests.unknownSourceAndTargetLine,
            ActionHistoryLineParserTests.chooseOneLine,
            ActionHistoryLineParserTests.nestedPowerLine,
            ActionHistoryLineParserTests.deckActionLine,
            ActionHistoryLineParserTests.startOfGameLine
        ]
        for line in lines {
            parser.handle(logLine: LogLine(namespace: .power, line: line))
            let block = parser.currentBlock
            let info = ActionHistoryLineParser.parseBlockStart(line)
            XCTAssertEqual(block?.type, info?.blockType, line)
            XCTAssertEqual(block?.triggerKeyword, info?.triggerKeyword, line)
            XCTAssertEqual(block?.targetEntityId, info?.targetEntityId, line)
            parser.handle(logLine: LogLine(namespace: .power, line: "D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_END"))
        }
    }

    func testBlockInfoRoundTripsThroughJSON() throws {
        let info = try XCTUnwrap(ActionHistoryLineParser.parseBlockStart(ActionHistoryLineParserTests.playerTriggerLine))
        let decoded = try JSONDecoder().decode(HistoryBlockInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded, info)
    }
}
