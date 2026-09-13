//
//  MulliganRecorderTests.swift
//  HSTrackerTests
//

import XCTest
import Foundation
import RealmSwift

@testable import HSTracker

// Feeds the mulligan of zhCN ranked games through ChoicesHandler (the GameState choice lines) and
// PowerGameStateParser (the PowerTaskList lines) the way LogReaderManager.processLine routes them,
// then checks the MulliganRecord built from what Game.mulliganRecorder collected.
//
// The lines are copied from Power.log with the BattleTags replaced, and with tags nothing here
// reads left out. Each game's hand is set up as it was right before the excerpt: the opening hand
// revealed in PowerTaskList, the deck still unknown.
class MulliganRecorderTests: HSTrackerTests {
    private static let localName = "Player#1234"
    private static let opponentName = "Opponent#5678"

    // MARK: - Game 1: on the coin as PlayerID 1, the quest and one card kept, two replaced

    private static let coinGameChoices = """
        D 22:13:22.8946590 GameState.DebugPrintEntityChoices() - id=1 Player=Player#1234 TaskList=5 ChoiceType=MULLIGAN CountMin=0 CountMax=5
        D 22:13:22.8946590 GameState.DebugPrintEntityChoices() -   Source=GameEntity
        D 22:13:22.8946590 GameState.DebugPrintEntityChoices() -   Entities[0]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=31 zone=DECK zonePos=0 cardId= player=1]
        D 22:13:22.8946590 GameState.DebugPrintEntityChoices() -   Entities[1]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=18 zone=DECK zonePos=0 cardId= player=1]
        D 22:13:22.8946590 GameState.DebugPrintEntityChoices() -   Entities[2]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=35 zone=DECK zonePos=0 cardId= player=1]
        D 22:13:22.8946590 GameState.DebugPrintEntityChoices() -   Entities[3]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=5 zone=DECK zonePos=0 cardId= player=1]
        D 22:13:22.8946590 GameState.DebugPrintEntityChoices() -   Entities[4]=[entityName=幸运币 id=72 zone=HAND zonePos=5 cardId=GDB_COIN1 player=1]
        D 22:13:22.9012710 GameState.DebugPrintPowerList() - Count=1
        D 22:13:22.9082760 GameState.DebugPrintEntityChoices() - id=2 Player=Opponent#5678 TaskList=6 ChoiceType=MULLIGAN CountMin=0 CountMax=3
        D 22:13:22.9082760 GameState.DebugPrintEntityChoices() -   Source=GameEntity
        D 22:13:22.9082760 GameState.DebugPrintEntityChoices() -   Entities[0]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=66 zone=DECK zonePos=0 cardId= player=2]
        D 22:13:22.9082760 GameState.DebugPrintEntityChoices() -   Entities[1]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=50 zone=DECK zonePos=0 cardId= player=2]
        D 22:13:22.9082760 GameState.DebugPrintEntityChoices() -   Entities[2]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=56 zone=DECK zonePos=0 cardId= player=2]
        D 22:13:24.7210210 PowerProcessor.EndCurrentTaskList() - m_currentTaskList=1
        """

    private static let coinGameChosen = """
        D 22:13:52.2252960 GameState.SendChoices() - id=1 ChoiceType=MULLIGAN
        D 22:13:52.2252960 GameState.SendChoices() -   m_chosenEntities[0]=[entityName=寻求平衡 id=31 zone=HAND zonePos=1 cardId=TLC_817 player=1]
        D 22:13:52.2252960 GameState.SendChoices() -   m_chosenEntities[1]=[entityName=生命仪式 id=35 zone=HAND zonePos=3 cardId=DINO_426 player=1]
        D 22:13:52.3938330 GameState.DebugPrintEntitiesChosen() - id=1 Player=Player#1234 EntitiesCount=2
        D 22:13:52.3938330 GameState.DebugPrintEntitiesChosen() -   Entities[0]=[entityName=寻求平衡 id=31 zone=HAND zonePos=1 cardId=TLC_817 player=1]
        D 22:13:52.3938330 GameState.DebugPrintEntitiesChosen() -   Entities[1]=[entityName=生命仪式 id=35 zone=HAND zonePos=3 cardId=DINO_426 player=1]
        D 22:13:52.4054060 GameState.DebugPrintPowerList() - Count=56
        """

    // The opponent finishes first; then CATA_308 and CAP_804 are replaced by TLC_816 and EDR_463,
    // whose Choose One options are revealed in SETASIDE on the way.
    private static let coinGameDealing = """
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Opponent#5678 tag=MULLIGAN_STATE value=DONE
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=DEALING
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=15 zone=DECK zonePos=0 cardId= player=1] CardID=TLC_816
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=1
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=COST value=4
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ZONE value=HAND
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=15
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CLASS value=PRIEST
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=RARITY value=COMMON
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=SPELL_SCHOOL value=5
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=15 zone=DECK zonePos=0 cardId= player=1] tag=NUM_TURNS_IN_HAND value=1
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=15 zone=DECK zonePos=0 cardId= player=1] tag=ZONE_POSITION value=2
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=麦迪文的胜利 id=18 zone=HAND zonePos=2 cardId=CATA_308 player=1] tag=ZONE_POSITION value=0
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     HIDE_ENTITY - Entity=[entityName=麦迪文的胜利 id=18 zone=HAND zonePos=2 cardId=CATA_308 player=1] tag=ZONE value=DECK
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=麦迪文的胜利 id=18 zone=HAND zonePos=2 cardId=CATA_308 player=1] tag=ZONE value=DECK
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=32 zone=DECK zonePos=0 cardId= player=1] CardID=EDR_463
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=1
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=COST value=2
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ZONE value=HAND
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=32
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CLASS value=PRIEST
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=RARITY value=RARE
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CHOOSE_ONE value=1
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=SPELL_SCHOOL value=6
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=33 zone=SETASIDE zonePos=0 cardId= player=1] CardID=EDR_463a
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=1
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=COST value=2
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ZONE value=SETASIDE
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=33
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CLASS value=PRIEST
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CREATOR value=32
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=SPELL_SCHOOL value=6
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=34 zone=SETASIDE zonePos=0 cardId= player=1] CardID=EDR_463b
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=1
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=COST value=2
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ZONE value=SETASIDE
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=34
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CLASS value=PRIEST
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=CREATOR value=32
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -         tag=SPELL_SCHOOL value=6
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=32 zone=DECK zonePos=0 cardId= player=1] tag=NUM_TURNS_IN_HAND value=1
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=32 zone=DECK zonePos=0 cardId= player=1] tag=ZONE_POSITION value=4
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=捉鬼专家 id=5 zone=HAND zonePos=4 cardId=CAP_804 player=1] tag=ZONE_POSITION value=0
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     HIDE_ENTITY - Entity=[entityName=捉鬼专家 id=5 zone=HAND zonePos=4 cardId=CAP_804 player=1] tag=ZONE value=DECK
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=捉鬼专家 id=5 zone=HAND zonePos=4 cardId=CAP_804 player=1] tag=ZONE value=DECK
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=WAITING
        D 22:13:52.4054060 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 22:13:52.5061740 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:13:52.5061740 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=DONE
        D 22:13:52.5061740 PowerTaskList.DebugPrintPower() -     SHUFFLE_DECK PlayerID=1
        D 22:13:52.5061740 PowerTaskList.DebugPrintPower() -     SHUFFLE_DECK PlayerID=2
        D 22:13:52.5061740 PowerTaskList.DebugPrintPower() - BLOCK_END
        """

    // Turn 2, the local player's first: CAP_805 is drawn
    private static let coinGameFirstDraw = """
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=GameEntity EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Opponent#5678 tag=CURRENT_PLAYER value=0
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=CURRENT_PLAYER value=1
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=TURN value=2
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=TURN value=1
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=NEXT_STEP value=MAIN_READY
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=10 zone=DECK zonePos=0 cardId= player=1] CardID=CAP_805
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=1
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=TAG_LAST_KNOWN_COST_IN_HAND value=4
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=COST value=4
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=ZONE value=HAND
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=10
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=CLASS value=PRIEST
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=RARITY value=EPIC
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=SPELL_SCHOOL value=6
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=10 zone=DECK zonePos=0 cardId= player=1] tag=NUM_TURNS_IN_HAND value=1
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=10 zone=DECK zonePos=0 cardId= player=1] tag=ZONE_POSITION value=6
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=10 zone=DECK zonePos=0 cardId= player=1] tag=ZONE_POSITION value=0
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=10 zone=DECK zonePos=0 cardId= player=1] tag=ZONE_POSITION value=6
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=NUM_CARDS_DRAWN_THIS_TURN value=1
        D 22:14:04.3327860 PowerTaskList.DebugPrintPower() - BLOCK_END
        """

    // Once both mulligans are done, as in HearthSim's kotlin-hslog power.log: the first turn starts
    private static let firstTurnStart = """
        D 22:13:54.8100220 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=NEXT_STEP value=MAIN_READY
        D 22:13:54.8100220 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=GameEntity tag=STEP value=MAIN_READY
        """

    // MARK: - Game 2: going first as PlayerID 2, the quest kept and both other cards replaced

    // The opponent's choice is logged under a name that is not known yet
    private static let firstGameChoices = """
        D 22:21:05.8972910 GameState.DebugPrintEntityChoices() - id=1 Player=UNKNOWN HUMAN PLAYER TaskList=5 ChoiceType=MULLIGAN CountMin=0 CountMax=5
        D 22:21:05.8972910 GameState.DebugPrintEntityChoices() -   Source=GameEntity
        D 22:21:05.8972910 GameState.DebugPrintEntityChoices() -   Entities[0]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=7 zone=DECK zonePos=0 cardId= player=1]
        D 22:21:05.9107000 GameState.DebugPrintEntityChoices() - id=2 Player=Player#1234 TaskList=6 ChoiceType=MULLIGAN CountMin=0 CountMax=3
        D 22:21:05.9107000 GameState.DebugPrintEntityChoices() -   Source=GameEntity
        D 22:21:05.9107000 GameState.DebugPrintEntityChoices() -   Entities[0]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=63 zone=DECK zonePos=0 cardId= player=2]
        D 22:21:05.9107000 GameState.DebugPrintEntityChoices() -   Entities[1]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=44 zone=DECK zonePos=0 cardId= player=2]
        D 22:21:05.9107000 GameState.DebugPrintEntityChoices() -   Entities[2]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=61 zone=DECK zonePos=0 cardId= player=2]
        D 22:21:07.9296350 PowerProcessor.EndCurrentTaskList() - m_currentTaskList=1
        """

    private static let firstGameChosen = """
        D 22:21:28.6189610 GameState.DebugPrintEntitiesChosen() - id=2 Player=Player#1234 EntitiesCount=1
        D 22:21:28.6189610 GameState.DebugPrintEntitiesChosen() -   Entities[0]=[entityName=寻求平衡 id=63 zone=HAND zonePos=1 cardId=TLC_817 player=2]
        D 22:21:28.6313930 GameState.DebugPrintPowerList() - Count=28
        """

    private static let firstGameDealing = """
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=DEALING
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=43 zone=DECK zonePos=0 cardId= player=2] CardID=JAIL_940
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=2
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=COST value=1
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=ZONE value=HAND
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=43
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=CLASS value=PRIEST
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=RARITY value=RARE
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=SPELL_SCHOOL value=6
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=43 zone=DECK zonePos=0 cardId= player=2] tag=NUM_TURNS_IN_HAND value=1
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=43 zone=DECK zonePos=0 cardId= player=2] tag=ZONE_POSITION value=2
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=幽魂不散 id=44 zone=HAND zonePos=2 cardId=CAP_801 player=2] tag=ZONE_POSITION value=0
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     HIDE_ENTITY - Entity=[entityName=幽魂不散 id=44 zone=HAND zonePos=2 cardId=CAP_801 player=2] tag=ZONE value=DECK
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=幽魂不散 id=44 zone=HAND zonePos=2 cardId=CAP_801 player=2] tag=ZONE value=DECK
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=67 zone=DECK zonePos=0 cardId= player=2] CardID=CORE_CS2_004
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=CONTROLLER value=2
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=CARDTYPE value=SPELL
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=COST value=1
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=ZONE value=HAND
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=ENTITY_ID value=67
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=CLASS value=PRIEST
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=RARITY value=COMMON
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -         tag=SPELL_SCHOOL value=5
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=67 zone=DECK zonePos=0 cardId= player=2] tag=NUM_TURNS_IN_HAND value=1
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=67 zone=DECK zonePos=0 cardId= player=2] tag=ZONE_POSITION value=3
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=雷斯·范盖斯特 id=61 zone=HAND zonePos=3 cardId=CAP_806 player=2] tag=ZONE_POSITION value=0
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     HIDE_ENTITY - Entity=[entityName=雷斯·范盖斯特 id=61 zone=HAND zonePos=3 cardId=CAP_806 player=2] tag=ZONE value=DECK
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=[entityName=雷斯·范盖斯特 id=61 zone=HAND zonePos=3 cardId=CAP_806 player=2] tag=ZONE value=DECK
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=WAITING
        D 22:21:28.6313930 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 22:21:28.7197120 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:21:28.7197120 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=DONE
        D 22:21:28.7197120 PowerTaskList.DebugPrintPower() - BLOCK_END
        """

    // MARK: - Game 3: on the coin as PlayerID 2, every card kept

    // EntitiesChosen lists the kept cards in a different order than they were offered
    private static let keepAllChoices = """
        D 22:06:11.9752810 GameState.DebugPrintEntityChoices() - id=2 Player=Player#1234 TaskList=6 ChoiceType=MULLIGAN CountMin=0 CountMax=5
        D 22:06:11.9752810 GameState.DebugPrintEntityChoices() -   Source=GameEntity
        D 22:06:11.9752810 GameState.DebugPrintEntityChoices() -   Entities[0]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=60 zone=DECK zonePos=0 cardId= player=2]
        D 22:06:11.9752810 GameState.DebugPrintEntityChoices() -   Entities[1]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=65 zone=DECK zonePos=0 cardId= player=2]
        D 22:06:11.9752810 GameState.DebugPrintEntityChoices() -   Entities[2]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=51 zone=DECK zonePos=0 cardId= player=2]
        D 22:06:11.9752810 GameState.DebugPrintEntityChoices() -   Entities[3]=[entityName=UNKNOWN ENTITY [cardType=INVALID] id=66 zone=DECK zonePos=0 cardId= player=2]
        D 22:06:11.9752810 GameState.DebugPrintEntityChoices() -   Entities[4]=[entityName=幸运币 id=76 zone=HAND zonePos=5 cardId=GDB_COIN1 player=2]
        D 22:06:14.1248080 PowerProcessor.EndCurrentTaskList() - m_currentTaskList=1
        D 22:06:41.9302690 GameState.DebugPrintEntitiesChosen() - id=2 Player=Player#1234 EntitiesCount=4
        D 22:06:41.9302690 GameState.DebugPrintEntitiesChosen() -   Entities[0]=[entityName=寻求平衡 id=60 zone=HAND zonePos=1 cardId=TLC_817 player=2]
        D 22:06:41.9302690 GameState.DebugPrintEntitiesChosen() -   Entities[1]=[entityName=真言术：盾 id=51 zone=HAND zonePos=3 cardId=CORE_CS2_004 player=2]
        D 22:06:41.9302690 GameState.DebugPrintEntitiesChosen() -   Entities[2]=[entityName=捉鬼专家 id=66 zone=HAND zonePos=4 cardId=CAP_804 player=2]
        D 22:06:41.9302690 GameState.DebugPrintEntitiesChosen() -   Entities[3]=[entityName=预言师 id=65 zone=HAND zonePos=2 cardId=JAIL_912 player=2]
        D 22:06:41.9364720 GameState.DebugPrintPowerList() - Count=29
        """

    private static let keepAllDealing = """
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Opponent#5678 tag=MULLIGAN_STATE value=DONE
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=DEALING
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=WAITING
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() - BLOCK_END
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() - BLOCK_START BlockType=TRIGGER Entity=Player#1234 EffectCardId=System.Collections.Generic.List`1[System.String] EffectIndex=-1 Target=0 SubOption=-1 TriggerKeyword=TAG_NOT_SET
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() -     TAG_CHANGE Entity=Player#1234 tag=MULLIGAN_STATE value=DONE
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() -     SHUFFLE_DECK PlayerID=1
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() -     SHUFFLE_DECK PlayerID=2
        D 22:06:43.4929520 PowerTaskList.DebugPrintPower() - BLOCK_END
        """

    private static var database: Database!

    private var game: Game!
    private var parser: PowerGameStateParser!
    private var choices: ChoicesHandler!

    override class func setUp() {
        super.setUp()

        database = Database()
        database.loadDatabase(splashscreen: nil, withLanguages: [.enUS])
    }

    override func setUp() {
        super.setUp()

        game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        parser = PowerGameStateParser(with: game)
        choices = ChoicesHandler(with: game)
    }

    override func tearDown() {
        choices = nil
        parser = nil
        game = nil
        super.tearDown()
    }

    // MARK: - Setup

    private struct HandCard {
        let id: Int
        let cardId: String
        var quest = false
    }

    /// The board right after the opening hand was revealed: STEP is BEGIN_MULLIGAN and both
    /// players are choosing. Entity 2 is PlayerID 1 and entity 3 PlayerID 2, as in every game.
    private func setUpMulligan(localPlayerId: Int, hand: [HandCard], coinId: Int?, deck: [Int], setAside: [Int] = []) {
        let opponentPlayerId = localPlayerId == 1 ? 2 : 1
        // Game.gameStart clears it; the parser leaves queued creation-tag actions alone in the menu
        game.isInMenu = false

        let gameEntity = entity(1)
        gameEntity.name = "GameEntity"
        gameEntity[.cardtype] = CardType.game.rawValue
        gameEntity[.turn] = 1
        gameEntity[.step] = Step.begin_mulligan.rawValue

        for playerId in [1, 2] {
            let player = entity(playerId + 1, controller: playerId, type: .player)
            player.name = playerId == localPlayerId ? MulliganRecorderTests.localName : MulliganRecorderTests.opponentName
            player[.player_id] = playerId
            player[.mulligan_state] = Mulligan.input.rawValue
        }
        game.player.id = localPlayerId
        game.player.name = MulliganRecorderTests.localName
        game.opponent.id = opponentPlayerId
        game.opponent.name = MulliganRecorderTests.opponentName
        // GameInfoHandler's DebugPrintGame PlayerID/PlayerName lines, which ChoicesHandler needs
        game.playerIdsByPlayerName[MulliganRecorderTests.localName] = localPlayerId
        game.playerIdsByPlayerName[MulliganRecorderTests.opponentName] = opponentPlayerId

        for (index, card) in hand.enumerated() {
            let handCard = entity(card.id, cardId: card.cardId, controller: localPlayerId, zone: .hand, type: .spell)
            handCard[.zone_position] = index + 1
            if card.quest {
                handCard[.quest] = 1
            }
        }
        if let coinId {
            let coin = entity(coinId, cardId: "GDB_COIN1", controller: localPlayerId, zone: .hand, type: .spell)
            coin[.zone_position] = hand.count + 1
            coin[.coin_card] = 1
            coin[.creator] = 1
        }
        for id in deck {
            entity(id, controller: localPlayerId, zone: .deck, type: .invalid)
        }
        for id in setAside {
            entity(id, controller: localPlayerId, zone: .setaside, type: .invalid)
        }
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

    /// Routes each line like LogReaderManager.processLine does.
    private func feed(_ lines: String) {
        for line in lines.split(separator: "\n") where !line.isEmpty {
            let logLine = LogLine(namespace: .power, line: String(line))
            if logLine.content.hasPrefix("GameState.") {
                if logLine.content.hasPrefix("GameState.DebugPrintEntityChoices") ||
                    logLine.content.hasPrefix("GameState.DebugPrintEntitiesChosen") {
                    choices.handle(logLine: logLine)
                } else {
                    choices.flush()
                }
            } else if logLine.content.hasPrefix("PowerProcessor.EndCurrentTaskList") {
                choices.handle(logLine: logLine)
            } else {
                parser.handle(logLine: logLine)
                choices.flush()
            }
        }
    }

    private func buildRecord() -> MulliganRecord {
        return game.mulliganRecorder.buildRecord(localPlayerId: game.player.id) { [game] id in game?.entities[id] }
    }

    private func offered(_ record: MulliganRecord) -> [String] {
        return record.offered.map { card in
            card.cardId + (card.forced ? " forced" : "") + (card.kept ? "" : " replaced")
        }
    }

    private func setUpCoinGame() {
        setUpMulligan(localPlayerId: 1,
                      hand: [HandCard(id: 31, cardId: "TLC_817", quest: true), HandCard(id: 18, cardId: "CATA_308"),
                             HandCard(id: 35, cardId: "DINO_426"), HandCard(id: 5, cardId: "CAP_804")],
                      coinId: 72, deck: [15, 32, 10, 24, 36], setAside: [33, 34])
        let opponentHand = [66, 50, 56]
        for id in opponentHand {
            entity(id, controller: 2, zone: .hand, type: .invalid)
        }
    }

    private func setUpFirstGame() {
        setUpMulligan(localPlayerId: 2,
                      hand: [HandCard(id: 63, cardId: "TLC_817", quest: true), HandCard(id: 44, cardId: "CAP_801"),
                             HandCard(id: 61, cardId: "CAP_806")],
                      coinId: nil, deck: [43, 67, 50])
    }

    // MARK: - Captured from the log

    func testCoinPartialMulliganWithQuestAndLaterDraw() {
        setUpCoinGame()
        feed(MulliganRecorderTests.coinGameChoices)
        feed(MulliganRecorderTests.coinGameChosen)
        feed(MulliganRecorderTests.coinGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)
        feed(MulliganRecorderTests.coinGameFirstDraw)

        XCTAssertEqual(game.entities[10]?.cardId, "CAP_805")
        let record = buildRecord()
        XCTAssertEqual(record.version, MulliganRecord.currentVersion)
        XCTAssertEqual(record.status, .complete)
        // The Coin, offered fifth, is left out
        XCTAssertEqual(offered(record), ["TLC_817 forced", "CATA_308 replaced", "DINO_426", "CAP_804 replaced"])
        XCTAssertEqual(record.keptCardIds, ["TLC_817", "DINO_426"])
        XCTAssertEqual(record.mulliganedCardIds, ["CATA_308", "CAP_804"])
        XCTAssertEqual(Array(record.replacementCardIds), ["TLC_816", "EDR_463"])
        XCTAssertEqual(Array(record.finalHandCardIds), ["TLC_817", "TLC_816", "DINO_426", "EDR_463"])
        XCTAssertEqual(record.openingHandCardIds, ["TLC_817", "DINO_426", "TLC_816", "EDR_463"])
        // Game turn 2 is the coin player's first turn
        XCTAssertEqual(record.draws.map { "\($0.cardId)@\($0.gameTurn)" }, ["CAP_805@2"])
        XCTAssertEqual(record.draws.first?.transformed, false)
        XCTAssertEqual(record.drawnCardIds(byOwnTurn: 1, goingFirst: false), ["CAP_805"])
        XCTAssertFalse(record.drawsTruncated)
    }

    func testGoingFirstQuestKeptAndEveryOtherCardReplaced() {
        setUpFirstGame()
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameChosen)
        feed(MulliganRecorderTests.firstGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)

        let record = buildRecord()
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["TLC_817 forced", "CAP_801 replaced", "CAP_806 replaced"])
        XCTAssertEqual(Array(record.replacementCardIds), ["JAIL_940", "CORE_CS2_004"])
        XCTAssertEqual(Array(record.finalHandCardIds), ["TLC_817", "JAIL_940", "CORE_CS2_004"])
        // The replacements were dealt from the deck during the mulligan, not drawn later
        XCTAssertEqual(record.draws.count, 0)
    }

    func testCoinEveryCardKeptInOfferOrder() {
        setUpMulligan(localPlayerId: 2,
                      hand: [HandCard(id: 60, cardId: "TLC_817", quest: true), HandCard(id: 65, cardId: "JAIL_912"),
                             HandCard(id: 51, cardId: "CORE_CS2_004"), HandCard(id: 66, cardId: "CAP_804")],
                      coinId: 76, deck: [10, 11])
        feed(MulliganRecorderTests.keepAllChoices)
        feed(MulliganRecorderTests.keepAllDealing)
        feed(MulliganRecorderTests.firstTurnStart)

        let record = buildRecord()
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["TLC_817 forced", "JAIL_912", "CORE_CS2_004", "CAP_804"])
        XCTAssertEqual(record.mulliganedCardIds, [])
        XCTAssertEqual(Array(record.replacementCardIds), [])
        XCTAssertEqual(Array(record.finalHandCardIds), ["TLC_817", "JAIL_912", "CORE_CS2_004", "CAP_804"])
    }

    func testChoicesSeenBeforeThePlayerIdIsKnown() {
        setUpFirstGame()
        // HearthMirror has not answered yet when the GameState choice lines are read
        game.player.id = -1
        game.opponent.id = -1
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameChosen)
        game.player.id = 2
        game.opponent.id = 1
        feed(MulliganRecorderTests.firstGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)

        let record = buildRecord()
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["TLC_817 forced", "CAP_801 replaced", "CAP_806 replaced"])
    }

    func testConcedeDuringTheMulliganIsUnfinished() {
        setUpFirstGame()
        feed(MulliganRecorderTests.firstGameChoices)

        let record = buildRecord()
        XCTAssertEqual(record.status, .mulliganUnfinished)
        XCTAssertFalse(record.isComplete)
        // What was offered is still there, but nothing counts as kept
        XCTAssertEqual(offered(record), ["TLC_817 forced replaced", "CAP_801 replaced", "CAP_806 replaced"])
        XCTAssertEqual(Array(record.finalHandCardIds), [])
    }

    func testReconnectIsIncomplete() {
        setUpFirstGame()
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameChosen)
        feed(MulliganRecorderTests.firstGameDealing)
        game.mulliganRecorder.gameReconnected()

        let record = buildRecord()
        XCTAssertEqual(record.status, .reconnected)
        // Kept for reference, but statistics skip it
        XCTAssertEqual(record.offered.count, 3)
    }

    func testJoinedAfterTheMulliganHasNoOffer() {
        setUpFirstGame()
        // HSTracker started after the mulligan, with the choice lines no longer in the log
        feed(MulliganRecorderTests.firstGameDealing)

        let record = buildRecord()
        XCTAssertEqual(record.status, .noMulliganOffer)
        XCTAssertEqual(record.offered.count, 0)
    }

    func testBuildingStartsTheNextGameClean() {
        setUpFirstGame()
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameChosen)
        feed(MulliganRecorderTests.firstGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)
        XCTAssertEqual(buildRecord().status, .complete)

        let next = buildRecord()
        XCTAssertEqual(next.status, .noMulliganOffer)
        XCTAssertEqual(next.offered.count, 0)
    }

    func testUnknownLocalPlayer() {
        setUpFirstGame()
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameDealing)
        XCTAssertEqual(game.mulliganRecorder.buildRecord(localPlayerId: 0) { _ in nil }.status, .unknownPlayer)
    }

    func testMissingChoiceEchoIsNotComplete() {
        setUpFirstGame()
        // The offer and the dealt hand, but no DebugPrintEntitiesChosen for the local player
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)

        let record = buildRecord()
        XCTAssertEqual(record.status, .mulliganChoiceMissing)
        XCTAssertFalse(record.isComplete)
        // The hand itself is still known
        XCTAssertEqual(offered(record), ["TLC_817 forced", "CAP_801 replaced", "CAP_806 replaced"])
        XCTAssertEqual(Array(record.replacementCardIds), ["JAIL_940", "CORE_CS2_004"])
    }

    func testGameEndingBeforeTheFirstTurnIsNotComplete() {
        setUpFirstGame()
        // The local mulligan is done, then the game ends while the opponent is still choosing
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameChosen)
        feed(MulliganRecorderTests.firstGameDealing)

        let record = buildRecord()
        XCTAssertEqual(record.status, .endedBeforeFirstTurn)
        XCTAssertEqual(offered(record), ["TLC_817 forced", "CAP_801 replaced", "CAP_806 replaced"])
    }

    func testDrawsReplayedBeforeThePlayerIdIsKnown() {
        setUpCoinGame()
        // A Power.log backlog replayed in full before HearthMirror answered
        game.player.id = -1
        game.opponent.id = -1
        feed(MulliganRecorderTests.coinGameChoices)
        feed(MulliganRecorderTests.coinGameChosen)
        feed(MulliganRecorderTests.coinGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)
        feed(MulliganRecorderTests.coinGameFirstDraw)
        game.player.id = 1
        game.opponent.id = 2

        let record = buildRecord()
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["TLC_817 forced", "CATA_308 replaced", "DINO_426", "CAP_804 replaced"])
        XCTAssertEqual(record.draws.map { "\($0.cardId)@\($0.gameTurn)" }, ["CAP_805@2"])
    }

    func testDrawOfACardTransformedInTheDeckKeepsTheDeckCard() throws {
        setUpCoinGame()
        feed(MulliganRecorderTests.coinGameChoices)
        feed(MulliganRecorderTests.coinGameChosen)
        feed(MulliganRecorderTests.coinGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)
        // As if Lady Prestor had turned the deck's Wisp into CAP_805 while it was in the deck
        let wispDbfId = try XCTUnwrap(Cards.any(byId: "CS2_231")?.dbfId)
        feed(MulliganRecorderTests.coinGameFirstDraw.replacingOccurrences(
            of: "        tag=ENTITY_ID value=10\n",
            with: "        tag=ENTITY_ID value=10\n"
                + "D 22:14:04.3327860 PowerTaskList.DebugPrintPower() -         tag=TRANSFORMED_FROM_CARD value=\(wispDbfId)\n"))

        XCTAssertEqual(game.entities[10]?[.transformed_from_card], wispDbfId)
        let record = buildRecord()
        XCTAssertEqual(record.draws.map { "\($0.cardId)@\($0.gameTurn):\($0.transformed)" }, ["CS2_231@2:true"])
    }

    // MARK: - Recorder rules

    func testQuestsAreForcedByTheirCardDataWithoutTheTag() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4, 5])
        // Hearthstone lists the quest among the chosen cards, as in every quest game in the log
        recorder.mulliganChosen(playerId: 1, entityIds: [4, 5])
        recorder.mulliganDone(playerId: 1, entities: [handEntity(4, "TLC_817", position: 1), handEntity(5, "CS2_231", position: 2)])
        recorder.turnStarted()

        let record = recorder.buildRecord(localPlayerId: 1) { _ in nil }
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["TLC_817 forced", "CS2_231"])
    }

    func testTransformedDrawsStoreTheCardFromTheDeck() throws {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4])
        recorder.mulliganDone(playerId: 1, entities: [handEntity(4, "CS2_231", position: 1), handEntity(20, "", position: 0, zone: .deck),
                                                      handEntity(21, "", position: 0, zone: .deck)])
        // 20 was an Elven Archer turned into a Chillwind Yeti in the deck; 21 was drawn as a Wisp and
        // transformed in hand afterwards, so its tag names the Wisp
        let inDeck = handEntity(20, "CS2_182", position: 5)
        inDeck[.transformed_from_card] = try XCTUnwrap(Cards.any(byId: "CS2_189")?.dbfId)
        let inHand = handEntity(21, "CS2_120", position: 6)
        inHand[.transformed_from_card] = try XCTUnwrap(Cards.any(byId: "CS2_231")?.dbfId)
        recorder.cardDrawn(playerId: 1, entityId: 20, cardId: "CS2_182", gameTurn: 5)
        recorder.cardDrawn(playerId: 1, entityId: 21, cardId: "CS2_231", gameTurn: 7)

        let record = recorder.buildRecord(localPlayerId: 1) { id in [20: inDeck, 21: inHand][id] }
        XCTAssertEqual(record.draws.map { "\($0.cardId)@\($0.gameTurn):\($0.transformed)" }, ["CS2_189@5:true", "CS2_231@7:false"])
    }

    func testDrawnByOwnTurnFollowsTheTurnOrder() {
        // Game TURN 6 is the second player's third turn
        let duringOpponentsThirdTurn = MulliganDrawnCard(cardId: "CS2_231", gameTurn: 6)
        XCTAssertFalse(duringOpponentsThirdTurn.isDrawn(byOwnTurn: 3, goingFirst: true))
        XCTAssertTrue(duringOpponentsThirdTurn.isDrawn(byOwnTurn: 4, goingFirst: true))
        XCTAssertTrue(duringOpponentsThirdTurn.isDrawn(byOwnTurn: 3, goingFirst: false))
        let onOwnThirdTurn = MulliganDrawnCard(cardId: "CS2_231", gameTurn: 5)
        XCTAssertTrue(onOwnThirdTurn.isDrawn(byOwnTurn: 3, goingFirst: true))
        XCTAssertFalse(MulliganDrawnCard(cardId: "CS2_231", gameTurn: 7).isDrawn(byOwnTurn: 3, goingFirst: false))
    }

    private func handEntity(_ id: Int, _ cardId: String, position: Int, controller: Int = 1, zone: Zone = .hand) -> Entity {
        let entity = Entity(id: id)
        entity.cardId = cardId
        entity[.controller] = controller
        entity[.zone] = zone.rawValue
        entity[.zone_position] = position
        entity[.cardtype] = CardType.minion.rawValue
        return entity
    }

    func testFullMulliganWithoutForcedCards() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4, 5, 6])
        recorder.mulliganChosen(playerId: 1, entityIds: [])
        recorder.mulliganDone(playerId: 1, entities: [
            handEntity(4, "CS2_231", position: 0, zone: .deck), handEntity(5, "CS2_189", position: 0, zone: .deck),
            handEntity(6, "CS2_120", position: 0, zone: .deck),
            handEntity(7, "EX1_011", position: 1), handEntity(8, "CS2_172", position: 2), handEntity(9, "CS2_168", position: 3),
            handEntity(10, "", position: 0, zone: .deck)
        ])
        recorder.turnStarted()

        let record = recorder.buildRecord(localPlayerId: 1) { _ in nil }
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["CS2_231 replaced", "CS2_189 replaced", "CS2_120 replaced"])
        XCTAssertEqual(Array(record.replacementCardIds), ["EX1_011", "CS2_172", "CS2_168"])
    }

    func testCardsLeftInHandWithoutBeingChosenOrCreatedAreForced() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4, 5, 6])
        // 6 was never chosen, but the server left it in hand
        recorder.mulliganChosen(playerId: 1, entityIds: [4])
        let created = handEntity(6, "TOY_330t5", position: 3)
        created.info.created = true
        let extra = handEntity(8, "EX1_169", position: 4)
        extra.info.created = true
        recorder.mulliganDone(playerId: 1, entities: [
            handEntity(4, "CS2_231", position: 1), handEntity(5, "CS2_189", position: 0, zone: .deck),
            handEntity(7, "EX1_011", position: 2), created, extra
        ])
        recorder.turnStarted()

        let record = recorder.buildRecord(localPlayerId: 1) { _ in nil }
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["CS2_231", "CS2_189 replaced", "TOY_330t5 forced"])
        // A card created into the hand during the mulligan did not replace anything
        XCTAssertEqual(Array(record.replacementCardIds), ["EX1_011"])
        XCTAssertEqual(Array(record.finalHandCardIds), ["CS2_231", "EX1_011", "TOY_330t5", "EX1_169"])
    }

    func testReplacementsThatDoNotAddUpAreInconsistent() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4, 5])
        recorder.mulliganChosen(playerId: 1, entityIds: [4, 5])
        // 5 was chosen, yet it is back in the deck with nothing dealt for it
        recorder.mulliganDone(playerId: 1, entities: [
            handEntity(4, "CS2_231", position: 1), handEntity(5, "CS2_189", position: 0, zone: .deck)
        ])
        recorder.turnStarted()
        XCTAssertEqual(recorder.buildRecord(localPlayerId: 1) { _ in nil }.status, .inconsistent)
    }

    func testCardIdsUnknownAtTheEndAreFlagged() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4, 5])
        recorder.mulliganChosen(playerId: 1, entityIds: [4, 5])
        recorder.mulliganDone(playerId: 1, entities: [handEntity(4, "CS2_231", position: 1), handEntity(5, "", position: 2)])
        recorder.turnStarted()
        let record = recorder.buildRecord(localPlayerId: 1) { _ in nil }
        XCTAssertEqual(record.status, .unknownCards)
        XCTAssertEqual(offered(record), ["CS2_231", ""])
    }

    func testCardIdsRevealedAfterTheMulliganAreLookedUpAtTheEnd() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4, 5])
        recorder.mulliganChosen(playerId: 1, entityIds: [4, 5])
        let late = handEntity(5, "", position: 2)
        recorder.mulliganDone(playerId: 1, entities: [handEntity(4, "CS2_231", position: 1), late])
        recorder.turnStarted()
        late.cardId = "CS2_189"
        let record = recorder.buildRecord(localPlayerId: 1) { id in id == 5 ? late : nil }
        XCTAssertEqual(record.status, .complete)
        XCTAssertEqual(offered(record), ["CS2_231", "CS2_189"])
    }

    func testDrawsCountOriginalDeckCardsOnceUpToTheLimit() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4])
        var deck = [Entity]()
        for id in 100 ..< 100 + MulliganRecord.drawLimit + 5 {
            deck.append(handEntity(id, "", position: 0, zone: .deck))
        }
        recorder.mulliganDone(playerId: 1, entities: [handEntity(4, "CS2_231", position: 1)] + deck)

        // Before the snapshot of another player, and cards that were not in the deck then
        recorder.cardDrawn(playerId: 2, entityId: 100, cardId: "EX1_001", gameTurn: 1)
        recorder.cardDrawn(playerId: 1, entityId: 500, cardId: "EX1_002", gameTurn: 1)
        recorder.cardDrawn(playerId: 1, entityId: 4, cardId: "CS2_231", gameTurn: 1)
        recorder.cardDrawn(playerId: 1, entityId: 100, cardId: "EX1_003", gameTurn: 1)
        // The same entity again, e.g. traded back and redrawn
        recorder.cardDrawn(playerId: 1, entityId: 100, cardId: "EX1_003", gameTurn: 3)
        for id in 101 ..< 100 + MulliganRecord.drawLimit + 5 {
            recorder.cardDrawn(playerId: 1, entityId: id, cardId: "CS2_\(id)", gameTurn: id - 99)
        }

        let record = recorder.buildRecord(localPlayerId: 1) { _ in nil }
        XCTAssertEqual(record.draws.count, MulliganRecord.drawLimit)
        XCTAssertEqual(record.draws.first?.cardId, "EX1_003")
        XCTAssertEqual(record.draws.first?.gameTurn, 1)
        XCTAssertEqual(record.draws[1].gameTurn, 2)
        XCTAssertTrue(record.drawsTruncated)
    }

    func testASecondOfferStartsOverButKeepsTheReconnect() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4, 5])
        recorder.mulliganChosen(playerId: 1, entityIds: [5])
        recorder.gameReconnected()
        recorder.mulliganOffered(playerId: 1, entityIds: [4])
        recorder.mulliganDone(playerId: 1, entities: [handEntity(4, "CS2_231", position: 1)])

        let record = recorder.buildRecord(localPlayerId: 1) { _ in nil }
        XCTAssertEqual(record.status, .reconnected)
        XCTAssertEqual(offered(record), ["CS2_231"])
    }

    func testDrawsBeforeTheMulliganIsDoneAreNotRecorded() {
        let recorder = MulliganRecorder()
        recorder.mulliganOffered(playerId: 1, entityIds: [4])
        recorder.cardDrawn(playerId: 1, entityId: 4, cardId: "CS2_231", gameTurn: 0)
        recorder.mulliganDone(playerId: 1, entities: [handEntity(4, "CS2_231", position: 1)])
        XCTAssertEqual(recorder.buildRecord(localPlayerId: 1) { _ in nil }.draws.count, 0)
    }

    // MARK: - Game end

    func testOnlyConstructedGamesKeepTheRecord() {
        setUpFirstGame()
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameChosen)
        feed(MulliganRecorderTests.firstGameDealing)
        game.setGameType(.gt_battlegrounds, formatType: .ft_wild)
        XCTAssertNil(game.buildMulliganRecord())
        // Consumed all the same
        game.setGameType(.gt_ranked, formatType: .ft_standard)
        XCTAssertEqual(game.buildMulliganRecord()?.status, .noMulliganOffer)

        game.setGameType(.gt_mercenaries_pvp, formatType: .ft_wild)
        XCTAssertNil(game.buildMulliganRecord())
    }

    func testNoDeckKeepsTheCardsSeenFromTheDeck() {
        setUpFirstGame()
        game.setGameType(.gt_ranked, formatType: .ft_standard)
        feed(MulliganRecorderTests.firstGameChoices)
        feed(MulliganRecorderTests.firstGameChosen)
        feed(MulliganRecorderTests.firstGameDealing)
        feed(MulliganRecorderTests.firstTurnStart)
        XCTAssertNil(game.currentDeck)

        let record = game.buildMulliganRecord()
        XCTAssertEqual(record?.status, .complete)
        XCTAssertEqual(record?.deckSource, .seenCards)
        XCTAssertEqual(record?.deckstring, "")
        // The hand, the replacements and the mulliganed cards back in the deck; The Coin and unknown cards are not
        XCTAssertEqual(record?.deckCards.map { "\($0.id)x\($0.count)" },
                       ["CAP_801x1", "CAP_806x1", "CORE_CS2_004x1", "JAIL_940x1", "TLC_817x1"])
    }

    func testNoDeckAndNothingSeenIsUnknown() {
        game.setGameType(.gt_ranked, formatType: .ft_standard)
        let record = game.buildMulliganRecord()
        XCTAssertEqual(record?.deckSource, .unknown)
        XCTAssertEqual(record?.deckCards.count, 0)
    }

    func testGameResetDropsTheCapture() {
        setUpFirstGame()
        feed(MulliganRecorderTests.firstGameChoices)
        game.mulliganRecorder.reset()
        XCTAssertEqual(buildRecord().status, .noMulliganOffer)
    }

    // MARK: - Persistence

    static func makeRecord() -> MulliganRecord {
        let record = MulliganRecord()
        record.version = MulliganRecord.currentVersion
        record.status = .complete
        record.deckId = "deck-1"
        record.deckSource = .seenCards
        record.deckstring = "AAECAa0GBsX7BQ=="
        record.deckCards.append(RealmCard(id: "CS2_004", count: 2))
        record.offered.append(MulliganOfferedCard(cardId: "TLC_817", kept: true, forced: true))
        record.offered.append(MulliganOfferedCard(cardId: "CAP_801", kept: false, forced: false))
        record.replacementCardIds.append("JAIL_940")
        record.finalHandCardIds.append(objectsIn: ["TLC_817", "JAIL_940"])
        record.draws.append(MulliganDrawnCard(cardId: "CAP_805", gameTurn: 2, transformed: true))
        record.drawsTruncated = true
        return record
    }

    static func summary(_ record: MulliganRecord?) -> String {
        guard let record else {
            return "nil"
        }
        let deckCards: [String] = record.deckCards.map { "\($0.id)x\($0.count)" }
        let offered: [String] = record.offered.map { "\($0.cardId):\($0.kept):\($0.forced)" }
        let draws: [String] = record.draws.map { "\($0.cardId)@\($0.gameTurn):\($0.transformed)" }
        return "v\(record.version) \(record.status) \(record.deckId) \(record.deckSource) \(record.deckstring) deck=\(deckCards) "
            + "offered=\(offered) replacements=\(Array(record.replacementCardIds)) "
            + "final=\(Array(record.finalHandCardIds)) draws=\(draws) truncated=\(record.drawsTruncated)"
    }

    func testSummaryAndDetachedCopyCoverEveryRecordProperty() {
        // A property added to MulliganRecord has to be copied in detachedCopy and compared in summary
        XCTAssertEqual(MulliganRecord().objectSchema.properties.map { $0.name }.sorted(),
                       ["_deckSource", "_status", "deckCards", "deckId", "deckstring", "draws", "drawsTruncated", "finalHandCardIds",
                        "offered", "replacementCardIds", "version"])
        XCTAssertEqual(MulliganOfferedCard().objectSchema.properties.map { $0.name }.sorted(), ["cardId", "forced", "kept"])
        XCTAssertEqual(MulliganDrawnCard().objectSchema.properties.map { $0.name }.sorted(), ["cardId", "gameTurn", "transformed"])

        let original = MulliganRecorderTests.makeRecord()
        let copy = original.detachedCopy()
        XCTAssertFalse(original === copy)
        XCTAssertEqual(MulliganRecorderTests.summary(copy), MulliganRecorderTests.summary(original))
    }

    func testToGameStatsCarriesTheRecord() throws {
        let internalStats = InternalGameStats()
        internalStats.mulligan = MulliganRecorderTests.makeRecord()
        let stats = internalStats.toGameStats()
        XCTAssertEqual(stats.recordVersion, GameStats.currentRecordVersion)
        XCTAssertGreaterThanOrEqual(GameStats.currentRecordVersion, 2)

        let realm = try Realm()
        try realm.write {
            let bucket = DefaultDeckStats()
            bucket.playerClassRaw = CardClass.priest.rawValue
            bucket.gameStats.append(stats)
            realm.add(bucket)
        }
        let stored = try XCTUnwrap(realm.objects(DefaultDeckStats.self).first?.gameStats.first)
        XCTAssertEqual(MulliganRecorderTests.summary(stored.mulligan),
                       MulliganRecorderTests.summary(MulliganRecorderTests.makeRecord()))
    }

    func testDeletingADeckKeepsItsGamesRecords() throws {
        let realm = try Realm()
        let deck = Deck()
        deck.playerClass = .priest
        let stat = GameStats()
        stat.statId = "with-record"
        stat.mulligan = MulliganRecorderTests.makeRecord()
        try realm.write {
            realm.add(deck)
            deck.gameStats.append(stat)
        }

        RealmHelper.delete(deck: deck, keepStats: true)

        let bucket = try XCTUnwrap(realm.object(ofType: DefaultDeckStats.self, forPrimaryKey: CardClass.priest.rawValue))
        let kept = try XCTUnwrap(bucket.gameStats.first)
        XCTAssertEqual(kept.statId, "with-record")
        XCTAssertEqual(MulliganRecorderTests.summary(kept.mulligan),
                       MulliganRecorderTests.summary(MulliganRecorderTests.makeRecord()))
    }
}
