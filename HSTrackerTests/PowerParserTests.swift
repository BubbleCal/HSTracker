//
//  PowerParserTests.swift
//  HSTracker
//
//  Created by Istvan Fehervari on 28/03/2017.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//

import XCTest
import Foundation

@testable import HSTracker

class PowerParserTests: HSTrackerTests {
    // BLOCK_START lines as the zhCN client writes them to Power.log. PowerGameStateParser only
    // receives the PowerTaskList lines, where hidden entities are already revealed.
    private static let secretTriggerLine = "D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=压感陷阱 id=96 zone=SECRET zonePos=0 cardId=CORE_ULD_152 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=SECRET"
    private static let deathrattleTriggerLine = "D 14:00:01.9534820 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=预言师 id=62 zone=PLAY zonePos=1 cardId=JAIL_912 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=DEATHRATTLE"
    // PLAY and ATTACK blocks carry no TriggerKeyword and end with a trailing space
    private static let playWithTargetLine = "D 13:59:26.9484680 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=希尔瓦娜斯的胜利 id=10 zone=HAND zonePos=3 cardId=CATA_557 player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=焦油爬行者 id=91 zone=PLAY zonePos=1 cardId=CORE_UNG_928 player=2] SubOption=-1 "
    private static let playWithUnknownTargetLine = "D 15:08:16.5063320 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=61 zone=HAND zonePos=1 cardId= player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=108 zone=HAND zonePos=8 cardId= player=2] SubOption=-1 "
    private static let playWithoutTargetLine = "D 13:58:18.4149580 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=PLAY Entity=[entityName=寻求平衡 id=65 zone=HAND zonePos=1 cardId=TLC_817 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 "
    private static let blockEndLine = "D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_END"
    // Death phases belong to the game entity, which BlockStartRegex does not match
    private static let deathsLine = "D 13:59:29.5357620 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=DEATHS Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 "

    private static var database: Database!

    private var game: Game!
    private var parser: PowerGameStateParser!
    private var entityId = 1

    override class func setUp() {
        super.setUp()

        database = Database()
        database.loadDatabase(splashscreen: nil, withLanguages: [.enUS])
    }

    override func setUp() {
        super.setUp()

        game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        parser = PowerGameStateParser(with: game)

        let gameEntity = createEntity(cardId: "")
        gameEntity.name = "GameEntity"
        let heroPlayer = createEntity(cardId: "HERO_01")
        heroPlayer[.cardtype] = CardType.hero.rawValue
        heroPlayer[.controller] = 1
        heroPlayer[.player_id] = 1
        heroPlayer[.mulligan_state] = Mulligan.done.rawValue
        let heroOpponent = createEntity(cardId: "HERO_02")
        heroOpponent[.cardtype] = CardType.hero.rawValue
        heroOpponent[.controller] = 2
        heroOpponent[.player_id] = 2
        heroOpponent[.mulligan_state] = Mulligan.done.rawValue
        game.player.id = 1
        game.opponent.id = 2
        // Keep the ids used by the log lines free
        entityId = 200
    }

    override func tearDown() {
        parser = nil
        game = nil
        super.tearDown()
    }

    private func createEntity(cardId: String, id: Int? = nil) -> Entity {
        let entity = Entity(id: id ?? entityId)
        if id == nil {
            entityId += 1
        }
        entity.cardId = cardId
        game.entities[entity.id] = entity
        return entity
    }

    private func handle(_ line: String) {
        parser.handle(logLine: LogLine(namespace: .power, line: line))
    }

    func testCreateGameEntity() {
        //let parser = PowerGameStateParser()
    }

    // MARK: - TriggerKeyword

    func testBlockStart_TriggerKeywordSecret() {
        handle(PowerParserTests.secretTriggerLine)

        let block = parser.currentBlock
        XCTAssertEqual(block?.type, "TRIGGER")
        XCTAssertEqual(block?.cardId, "CORE_ULD_152")
        XCTAssertEqual(block?.triggerKeyword, "SECRET")
        XCTAssertNil(block?.targetEntityId)
    }

    func testBlockStart_TriggerKeywordDeathrattle() {
        handle(PowerParserTests.deathrattleTriggerLine)

        XCTAssertEqual(parser.currentBlock?.type, "TRIGGER")
        XCTAssertEqual(parser.currentBlock?.cardId, "JAIL_912")
        XCTAssertEqual(parser.currentBlock?.triggerKeyword, "DEATHRATTLE")
    }

    func testBlockStart_TriggerKeywordOtherValues() {
        handle("D 13:57:30.9310320 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=卡多雷女祭司 id=8 zone=HAND zonePos=3 cardId=EDR_970 player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=4 Target=0 SubOption=-1 TriggerKeyword=1724")
        XCTAssertEqual(parser.currentBlock?.triggerKeyword, "1724")
        handle(PowerParserTests.blockEndLine)

        handle("D 14:22:29.2640010 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=弑君者 id=51 zone=PLAY zonePos=0 cardId=TIME_875t1 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=1 Target=0 SubOption=-1 TriggerKeyword=TRIGGER_VISUAL")
        XCTAssertEqual(parser.currentBlock?.triggerKeyword, "TRIGGER_VISUAL")
        handle(PowerParserTests.blockEndLine)

        handle("D 14:09:45.2681070 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=26 zone=DECK zonePos=0 cardId= player=1] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=START_OF_GAME_KEYWORD")
        XCTAssertEqual(parser.currentBlock?.triggerKeyword, "START_OF_GAME_KEYWORD")
        XCTAssertEqual(parser.currentBlock?.cardId, "")
    }

    func testBlockStart_NoTriggerKeyword() {
        handle(PowerParserTests.playWithoutTargetLine)

        XCTAssertEqual(parser.currentBlock?.type, "PLAY")
        XCTAssertEqual(parser.currentBlock?.cardId, "TLC_817")
        XCTAssertNil(parser.currentBlock?.triggerKeyword)
    }

    func testBlockStart_TriggerKeywordAfterCombiningScriptEntityName() {
        // Thai names hold more UTF-16 code units than characters; the regex range must cover them
        handle("D 14:02:21.6735360 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=[entityName=กับดักแรงกดดั้น id=96 zone=SECRET zonePos=0 cardId=CORE_ULD_152 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=0 SubOption=-1 TriggerKeyword=SECRET")

        XCTAssertEqual(parser.currentBlock?.cardId, "CORE_ULD_152")
        XCTAssertEqual(parser.currentBlock?.triggerKeyword, "SECRET")
    }

    func testBlockStart_ChildBlockKeepsItsOwnTriggerKeyword() {
        handle(PowerParserTests.secretTriggerLine)
        handle("D 14:02:21.6735360 PowerTaskList.DebugPrintPower() -     BLOCK_START BlockType=POWER Entity=[entityName=压感陷阱 id=96 zone=SECRET zonePos=0 cardId=CORE_ULD_152 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=焦油爬行者 id=91 zone=PLAY zonePos=1 cardId=CORE_UNG_928 player=1] SubOption=-1 ")

        XCTAssertEqual(parser.currentBlock?.type, "POWER")
        XCTAssertNil(parser.currentBlock?.triggerKeyword)
        XCTAssertEqual(parser.currentBlock?.targetEntityId, 91)
        XCTAssertEqual(parser.currentBlock?.parent?.triggerKeyword, "SECRET")

        handle(PowerParserTests.blockEndLine)
        XCTAssertEqual(parser.currentBlock?.triggerKeyword, "SECRET")
        XCTAssertNil(parser.currentBlock?.targetEntityId)
    }

    // MARK: - Target

    func testBlockStart_TargetEntity() {
        handle(PowerParserTests.playWithTargetLine)

        XCTAssertEqual(parser.currentBlock?.target, "CORE_UNG_928")
        XCTAssertEqual(parser.currentBlock?.targetEntityId, 91)
        XCTAssertNil(parser.currentBlock?.triggerKeyword)
    }

    func testBlockStart_TargetUnknownEntity() {
        handle(PowerParserTests.playWithUnknownTargetLine)

        XCTAssertNil(parser.currentBlock?.target)
        XCTAssertEqual(parser.currentBlock?.targetEntityId, 108)
    }

    func testBlockStart_TargetZero() {
        handle(PowerParserTests.playWithoutTargetLine)

        XCTAssertNil(parser.currentBlock?.target)
        XCTAssertNil(parser.currentBlock?.targetEntityId)
    }

    func testBlockStart_AttackTarget() {
        handle("D 13:59:09.1156510 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=ATTACK Entity=[entityName=焦油爬行者 id=91 zone=PLAY zonePos=1 cardId=CORE_UNG_928 player=2] EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=0 Target=[entityName=火山暴龙克鲁什 id=71 zone=PLAY zonePos=0 cardId=HERO_05bo player=1] SubOption=-1 ")

        XCTAssertEqual(parser.currentBlock?.type, "ATTACK")
        XCTAssertEqual(parser.currentBlock?.cardId, "CORE_UNG_928")
        XCTAssertEqual(parser.currentBlock?.target, "HERO_05bo")
        XCTAssertEqual(parser.currentBlock?.targetEntityId, 71)
    }

    // MARK: - Secret triggers

    private func createOpponentSecret(id: Int, cardClass: TagClass) -> Entity {
        let secret = createEntity(cardId: "", id: id)
        secret[.class] = cardClass.rawValue
        secret[.secret] = 1
        secret[.controller] = game.opponent.id
        secret[.zone] = Zone.secret.rawValue
        game.opponentSecretPlayed(entity: secret, cardId: "", from: 0, turn: 1, fromZone: .hand, otherId: secret.id)
        return secret
    }

    func testOpponentSecretTriggerBlock_ReachesSecretsManager() {
        let secret = createOpponentSecret(id: 96, cardClass: .hunter)
        XCTAssertEqual(game.secretsManager?.secrets.count, 1)
        // SHOW_ENTITY reveals the secret before its TRIGGER block
        secret.cardId = CardIds.Collectible.Hunter.PressurePlateCore

        handle(PowerParserTests.secretTriggerLine)

        XCTAssertEqual(game.secretsManager?.secrets.count, 0)
        XCTAssertEqual(game.opponent.secretsTriggeredCards.map { $0.id }, [96])
        XCTAssertTrue(game.player.secretsTriggeredCards.isEmpty)
        XCTAssertEqual(secret.info.turn, game.turnNumber())
    }

    func testPlayerSecretTriggerBlock_RecordsTriggeredSecret() {
        let secret = createEntity(cardId: CardIds.Collectible.Hunter.PressurePlateCore, id: 96)
        secret[.class] = TagClass.hunter.rawValue
        secret[.secret] = 1
        secret[.controller] = game.player.id
        secret[.zone] = Zone.secret.rawValue

        handle(PowerParserTests.secretTriggerLine.replacingOccurrences(of: "player=2]", with: "player=1]"))

        XCTAssertEqual(game.player.secretsTriggeredCards.map { $0.id }, [96])
        XCTAssertTrue(game.opponent.secretsTriggeredCards.isEmpty)
    }

    func testNonSecretTriggerBlock_DoesNotTriggerSecret() {
        let secret = createOpponentSecret(id: 96, cardClass: .hunter)
        secret.cardId = CardIds.Collectible.Hunter.PressurePlateCore

        handle(PowerParserTests.secretTriggerLine.replacingOccurrences(of: "TriggerKeyword=SECRET", with: "TriggerKeyword=TAG_NOT_SET"))

        XCTAssertEqual(game.secretsManager?.secrets.count, 1)
        XCTAssertTrue(game.opponent.secretsTriggeredCards.isEmpty)
    }

    func testSnipeTriggerBlock_RestoresMinionPlayedExclusionsWhenTheMinionDies() {
        let snipe = createOpponentSecret(id: 96, cardClass: .hunter)
        let otherSecret = createOpponentSecret(id: 97, cardClass: .hunter)
        let minion = createEntity(cardId: "EX1_010")
        minion[.cardtype] = CardType.minion.rawValue
        minion[.controller] = game.player.id
        minion[.zone] = Zone.play.rawValue

        game.playerMinionPlayed(entity: minion)
        XCTAssertEqual(game.secretsManager?.secrets.first(where: { $0.entity.id == otherSecret.id })?.isExcluded(cardId: CardIds.Secrets.Hunter.BargainBin), true)

        snipe.cardId = CardIds.Collectible.Hunter.Snipe
        handle(PowerParserTests.secretTriggerLine.replacingOccurrences(of: "cardId=CORE_ULD_152", with: "cardId=EX1_609"))
        handle(PowerParserTests.blockEndLine)
        game.playerMinionDeath(entity: minion)

        // Snipe killed the minion, so the secrets that were excluded for the minion being played never
        // got their chance and are possible again. Snipe itself is known to be gone.
        let remaining = game.secretsManager?.secrets.first(where: { $0.entity.id == otherSecret.id })
        XCTAssertEqual(game.secretsManager?.secrets.count, 1)
        XCTAssertEqual(remaining?.isExcluded(cardId: CardIds.Secrets.Hunter.BargainBin), false)
        XCTAssertEqual(remaining?.isExcluded(cardId: CardIds.Secrets.Hunter.Snipe), true)
    }

    // MARK: - Secret checks resolved at action boundaries

    private func createPlayerSpell() -> Entity {
        let spell = createEntity(cardId: "CS2_025")
        spell[.cardtype] = CardType.spell.rawValue
        spell[.controller] = game.player.id
        return spell
    }

    func testRootPlayBlock_ResolvesPendingSecretChecks() {
        let secret = createOpponentSecret(id: 96, cardClass: .mage)
        game.secretsManager?.handleCardPlayed(entity: createPlayerSpell(), parentCardId: "")
        let tracked = game.secretsManager?.secrets.first { $0.entity.id == secret.id }
        XCTAssertEqual(tracked?.isExcluded(cardId: CardIds.Secrets.Mage.Counterspell), true)
        XCTAssertEqual(tracked?.isExcluded(cardId: CardIds.Secrets.Mage.ManaBind), false)

        handle(PowerParserTests.playWithoutTargetLine)

        XCTAssertEqual(tracked?.isExcluded(cardId: CardIds.Secrets.Mage.ManaBind), true)
    }

    func testNestedPlayBlock_LeavesPendingSecretChecks() {
        let secret = createOpponentSecret(id: 96, cardClass: .mage)
        handle(PowerParserTests.deathrattleTriggerLine)
        game.secretsManager?.handleCardPlayed(entity: createPlayerSpell(), parentCardId: "")
        let tracked = game.secretsManager?.secrets.first { $0.entity.id == secret.id }

        handle(PowerParserTests.playWithTargetLine)
        XCTAssertEqual(tracked?.isExcluded(cardId: CardIds.Secrets.Mage.ManaBind), false)

        handle(PowerParserTests.blockEndLine)
        handle(PowerParserTests.blockEndLine)
        handle(PowerParserTests.playWithoutTargetLine)
        XCTAssertEqual(tracked?.isExcluded(cardId: CardIds.Secrets.Mage.ManaBind), true)
    }

    func testDeathsBlockEnd_ResolvesAvengeBeforeDeathrattleSummons() {
        let secret = createOpponentSecret(id: 96, cardClass: .paladin)
        let dying = createEntity(cardId: "EX1_020")
        dying[.cardtype] = CardType.minion.rawValue
        dying[.controller] = game.opponent.id
        dying[.zone] = Zone.graveyard.rawValue

        handle(PowerParserTests.deathsLine)
        XCTAssertEqual(parser.currentBlock?.type, "DEATHS")
        game.secretsManager?.handleOpponentMinionDeath(entity: dying)
        handle(PowerParserTests.blockEndLine)

        // A later block summons a minion the deathrattle table does not know about
        let summoned = createEntity(cardId: "skele21")
        summoned[.cardtype] = CardType.minion.rawValue
        summoned[.controller] = game.opponent.id
        summoned[.zone] = Zone.play.rawValue
        handle(PowerParserTests.playWithoutTargetLine)

        let tracked = game.secretsManager?.secrets.first { $0.entity.id == secret.id }
        XCTAssertEqual(tracked?.isExcluded(cardId: CardIds.Secrets.Paladin.Avenge), false)
        XCTAssertEqual(tracked?.isExcluded(cardId: CardIds.Secrets.Paladin.Redemption), true)
    }
}
