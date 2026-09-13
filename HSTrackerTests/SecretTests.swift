//
//  SecretTests.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 28/03/17.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//

import XCTest
@testable import HSTracker

class SecretTests: HSTrackerTests {
    private var entityId = 1
    private var game: Game!

    private var gameEntity: Entity!,
    heroPlayer: Entity!,
    heroOpponent: Entity!,
    playerSpell1: Entity!,
    playerSpell2: Entity!,
    playerMinion1: Entity!,
    playerMinion2: Entity!,
    opponentMinion1: Entity!,
    opponentMinion2: Entity!,
    opponentDivineShieldMinion: Entity!,
    secretHunter1: Entity!,
    secretHunter2: Entity!,
    secretMage1: Entity!,
    secretMage2: Entity!,
    secretMage3: Entity!,
    secretPaladin1: Entity!,
    secretPaladin2: Entity!,
    secretRogue1: Entity!,
    secretRogue2: Entity!,
    opponentEntity: Entity!,
    opponentCardInHand1: Entity!,
    playerCardInHand1: Entity!,
    playerCardInHand2: Entity!

    static var database: Database!

    override class func setUp() {
        super.setUp()

        database = Database()
        database.loadDatabase(splashscreen: nil, withLanguages: [.enUS])
    }
    
    override func setUp() {
        super.setUp()

        game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        gameEntity = createNewEntity(cardId: "")
        gameEntity.name = "GameEntity"
        heroPlayer = createNewEntity(cardId: "HERO_01");
        heroPlayer[.cardtype] = CardType.hero.rawValue
        heroPlayer[.controller] = heroPlayer.id
        heroPlayer[.mulligan_state] = Mulligan.done.rawValue
        heroPlayer[.player_id] = heroPlayer.id
        heroOpponent = createNewEntity(cardId: "HERO_02");
        heroOpponent[.cardtype] = CardType.hero.rawValue
        heroOpponent[.controller] = heroOpponent.id
        opponentEntity = createNewEntity(cardId: "")
        opponentEntity[.player_id] = heroOpponent.id
        opponentEntity[.mulligan_state] = Mulligan.done.rawValue

        // Entities live under their own ids, so id lookups (CARD_TARGET, damage dealers) find them
        game.entities[gameEntity.id] = gameEntity
        game.entities[heroPlayer.id] = heroPlayer
        game.player.id = heroPlayer.id
        game.entities[heroOpponent.id] = heroOpponent
        game.opponent.id = heroOpponent.id
        game.entities[opponentEntity.id] = opponentEntity

        playerMinion1 = createNewEntity(cardId: "EX1_010")
        playerMinion1[.cardtype] = CardType.minion.rawValue
        playerMinion1[.controller] = heroPlayer.id
        playerMinion2 = createNewEntity(cardId: "EX1_011")
        playerMinion2[.cardtype] = CardType.minion.rawValue
        playerMinion2[.controller] = heroPlayer.id
        opponentMinion1 = createNewEntity(cardId: "EX1_020")
        opponentMinion1[.cardtype] = CardType.minion.rawValue
        opponentMinion1[.controller] = heroOpponent.id
        opponentMinion2 = createNewEntity(cardId: "EX1_021")
        opponentMinion2[.cardtype] = CardType.minion.rawValue
        opponentMinion2[.controller] = heroOpponent.id
        opponentDivineShieldMinion = createNewEntity(cardId: "EX1_008")
        opponentDivineShieldMinion[.cardtype] = CardType.minion.rawValue
        opponentDivineShieldMinion[.controller] = heroOpponent.id
        opponentDivineShieldMinion[.divine_shield] = 1
        playerSpell1 = createNewEntity(cardId: "CS2_029")
        playerSpell1[.cardtype] = CardType.spell.rawValue
        playerSpell1[.card_target] = opponentMinion1.id
        playerSpell1[.controller] = heroPlayer.id
        playerSpell2 = createNewEntity(cardId: "CS2_025")
        playerSpell2[.cardtype] = CardType.spell.rawValue
        playerSpell2[.controller] = heroPlayer.id

        game.entities[playerMinion1.id] = playerMinion1
        game.entities[playerMinion2.id] = playerMinion2
        game.entities[opponentMinion1.id] = opponentMinion1
        game.entities[opponentMinion2.id] = opponentMinion2
        game.entities[playerSpell1.id] = playerSpell1
        game.entities[playerSpell2.id] = playerSpell2
        
        playerCardInHand1 = createNewEntity(cardId: "")
        playerCardInHand1[.controller] = heroPlayer.id
        playerCardInHand1[.zone] = Zone.hand.rawValue
        game.entities[playerCardInHand1.id] = playerCardInHand1

        playerCardInHand2 = createNewEntity(cardId: "")
        playerCardInHand2[.controller] = heroPlayer.id
        playerCardInHand2[.zone] = Zone.hand.rawValue
        game.entities[playerCardInHand2.id] = playerCardInHand2

        opponentCardInHand1 = createNewEntity(cardId: "")
        opponentCardInHand1[.controller] = heroOpponent.id
        opponentCardInHand1[.zone] = Zone.hand.rawValue
        game.entities[opponentCardInHand1.id] = opponentCardInHand1

        secretHunter1 = createNewEntity(cardId: "")
        secretHunter1[.class] = TagClass.hunter.rawValue
        secretHunter1[.secret] = 1
        secretHunter1[.zone] = Zone.secret.rawValue
        secretHunter2 = createNewEntity(cardId: "")
        secretHunter2[.class] = TagClass.hunter.rawValue
        secretHunter2[.secret] = 1
        secretMage1 = createNewEntity(cardId: "")
        secretMage1[.class] = TagClass.mage.rawValue
        secretMage1[.secret] = 1
        secretMage1[.zone] = Zone.secret.rawValue
        secretMage2 = createNewEntity(cardId: "")
        secretMage2[.class] = TagClass.mage.rawValue
        secretMage2[.secret] = 1
        secretMage3 = createNewEntity(cardId: "")
        secretMage3[.class] = TagClass.mage.rawValue
        secretMage3[.secret] = 1
        secretPaladin1 = createNewEntity(cardId: "")
        secretPaladin1[.class] = TagClass.paladin.rawValue
        secretPaladin1[.secret] = 1
        secretPaladin1[.zone] = Zone.secret.rawValue
        secretPaladin2 = createNewEntity(cardId: "")
        secretPaladin2[.class] = TagClass.paladin.rawValue
        secretPaladin2[.secret] = 1
        secretRogue1 = createNewEntity(cardId: "")
        secretRogue1[.class] = TagClass.rogue.rawValue
        secretRogue1[.secret] = 1
        secretRogue1[.zone] = Zone.secret.rawValue
        secretRogue2 = createNewEntity(cardId: "")
        secretRogue2[.class] = TagClass.rogue.rawValue
        secretRogue2[.secret] = 1

        game.opponentSecretPlayed(entity: secretHunter1, cardId: "",
                                  from: 0, turn: 0,
                                  fromZone: .hand, otherId: secretHunter1.id)
        game.entities[secretHunter1.id] = secretHunter1
        game.opponentSecretPlayed(entity: secretMage1, cardId: "",
                                  from: 0, turn: 0,
                                  fromZone: .hand, otherId: secretMage1.id)
        game.entities[secretMage1.id] = secretMage1
        game.opponentSecretPlayed(entity: secretPaladin1, cardId: "",
                                  from: 0, turn: 0,
                                  fromZone: .hand, otherId: secretPaladin1.id)
        game.entities[secretPaladin1.id] = secretPaladin1
        game.opponentSecretPlayed(entity: secretRogue1, cardId: "",
                                  from: 0, turn: 0,
                                  fromZone: .hand, otherId: secretRogue1.id)
        game.entities[secretRogue1.id] = secretRogue1
    }

    override func tearDown() {
        super.tearDown()
    }

    private func createNewEntity(cardId: String) -> Entity {
        let entity = Entity(id: entityId)
        entityId += 1
        entity.cardId = cardId
        return entity
    }

    private func verifySecrets(secretIndex: Int, allSecrets: [MultiIdCard], triggered: [MultiIdCard] = []) {
        let secrets = game.secretsManager?.secrets[secretIndex]
        XCTAssertNotNil(secrets, "Secrets are nil")
        allSecrets.forEach {
            let card = Cards.any(byId: $0.ids[0])?.name ?? $0.ids[0]
            XCTAssertEqual(secrets?.isExcluded(cardId: $0), triggered.contains($0), "\(card)")
        }
    }

    // What the next root PLAY/ATTACK block or STEP change does in a game
    private func resolve() {
        game.secretsManager?.resolvePendingChecks()
    }

    func testSingleSecret_HeroToHero_PlayerAttack() {
        // without minions on board
        playerMinion1[.zone] = Zone.hand.rawValue
        heroPlayer[.health] = 10
        game.secretsManager?.handleAttack(attacker: heroPlayer, defender: heroOpponent)

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BearTrap,
                                  CardIds.Secrets.Hunter.ExplosiveTrap,
                                  CardIds.Secrets.Hunter.WanderingMonster])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.IceBarrier])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
        
        // with minions on board
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion2[.zone] = Zone.play.rawValue
        game.secretsManager?.handleAttack(attacker: heroPlayer, defender: heroOpponent)
        
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BearTrap,
                                  CardIds.Secrets.Hunter.ExplosiveTrap,
                                  CardIds.Secrets.Hunter.Misdirection,
                                  CardIds.Secrets.Hunter.WanderingMonster])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.IceBarrier])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSingleSecret_MinionToHero_PlayerAttack() {
        // with only one friendly minion on board
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion1[.health] = 1
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: heroOpponent)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BearTrap,
                                  CardIds.Secrets.Hunter.ExplosiveTrap,
                                  CardIds.Secrets.Hunter.FreezingTrap,
                                  CardIds.Secrets.Hunter.WanderingMonster])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.FlameWard,
                                  CardIds.Secrets.Mage.IceBarrier,
                                  CardIds.Secrets.Mage.Vaporize,
                                  CardIds.Secrets.Mage.VengefulVisage,
                                  CardIds.Secrets.Mage.MysticMisdirection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice, CardIds.Secrets.Paladin.JudgementofJustice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.ShadowClone])
        
        // with more than one friendly minions on board
        playerMinion2[.zone] = Zone.play.rawValue
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: heroOpponent)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BearTrap,
                                  CardIds.Secrets.Hunter.ExplosiveTrap,
                                  CardIds.Secrets.Hunter.FreezingTrap,
                                  CardIds.Secrets.Hunter.Misdirection,
                                  CardIds.Secrets.Hunter.WanderingMonster])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.FlameWard,
                                  CardIds.Secrets.Mage.IceBarrier,
                                  CardIds.Secrets.Mage.Vaporize,
                                  CardIds.Secrets.Mage.VengefulVisage,
                                  CardIds.Secrets.Mage.MysticMisdirection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice, CardIds.Secrets.Paladin.JudgementofJustice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All,
                      triggered: [CardIds.Secrets.Rogue.SuddenBetrayal, CardIds.Secrets.Rogue.ShadowClone])
    }

    func testSingleSecret_HeroToMinion_PlayerAttack() {
        game.playerEntity?[.current_player] = 1
        game.secretsManager?.handleAttack(attacker: heroPlayer, defender: opponentMinion1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.SnakeTrap,
                                  CardIds.Secrets.Hunter.VenomstrikeTrap,
                                  CardIds.Secrets.Hunter.PackTactics,
                                  CardIds.Secrets.Hunter.BaitAndSwitch])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.OasisAlly, CardIds.Secrets.Mage.SplittingImage])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice,
                                  CardIds.Secrets.Paladin.AutodefenseMatrix])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Bamboozle])
    }

    func testSingleSecret_MinionToMinion_PlayerAttack() {
        game.playerEntity?[.current_player] = 1
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: opponentMinion1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.FreezingTrap,
                                  CardIds.Secrets.Hunter.SnakeTrap,
                                  CardIds.Secrets.Hunter.VenomstrikeTrap,
                                  CardIds.Secrets.Hunter.PackTactics,
                                  CardIds.Secrets.Hunter.BaitAndSwitch])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.OasisAlly, CardIds.Secrets.Mage.SplittingImage, CardIds.Secrets.Mage.MysticMisdirection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice,
                                  CardIds.Secrets.Paladin.AutodefenseMatrix,
                                  CardIds.Secrets.Paladin.JudgementofJustice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Bamboozle])
    }
    
    func testSingleSecret_HeroToDivineShieldMinion_PlayerAttackTest() {
        game.playerEntity?[.current_player] = 1
        game.secretsManager?.handleAttack(attacker: heroPlayer, defender: opponentDivineShieldMinion)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.SnakeTrap,
                                  CardIds.Secrets.Hunter.VenomstrikeTrap,
                                  CardIds.Secrets.Hunter.PackTactics,
                                  CardIds.Secrets.Hunter.BaitAndSwitch])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.OasisAlly, CardIds.Secrets.Mage.SplittingImage])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Bamboozle])
    }
    
    func testSingleSecret_MinionToDivineShieldMinion_PlayerAttackTest() {
        game.playerEntity?[.current_player] = 1
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: opponentDivineShieldMinion)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.FreezingTrap,
                                  CardIds.Secrets.Hunter.SnakeTrap,
                                  CardIds.Secrets.Hunter.VenomstrikeTrap,
                                  CardIds.Secrets.Hunter.PackTactics,
                                  CardIds.Secrets.Hunter.BaitAndSwitch])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.OasisAlly, CardIds.Secrets.Mage.SplittingImage, CardIds.Secrets.Mage.MysticMisdirection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice,
                                  CardIds.Secrets.Paladin.JudgementofJustice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Bamboozle])
    }

    func testSingleSecret_OnlyMinionDied() {
        opponentMinion2[.zone] = Zone.hand.rawValue
        game.opponentMinionDeath(entity: opponentMinion1, turn: 2)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.EmergencyManeuvers])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.Duplicate, CardIds.Secrets.Mage.Effigy])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.Redemption,
                                  CardIds.Secrets.Paladin.GetawayKodo])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All,
                      triggered: [CardIds.Secrets.Rogue.CheatDeath])
    }

    func testSingleSecret_OnlyMinionDied_MinionWasPlayedTheTurnBefore() {
        opponentMinion1.info.turnPlayed = 1
        gameEntity[.turn] = 2
        game.opponentMinionDeath(entity: opponentMinion1, turn: 2)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.EmergencyManeuvers, CardIds.Secrets.Hunter.UntimelyDeath])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.Duplicate, CardIds.Secrets.Mage.Effigy])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.Redemption,
                                  CardIds.Secrets.Paladin.GetawayKodo])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All,
                      triggered: [CardIds.Secrets.Rogue.CheatDeath])
    }

    func testOpponentMinionDied_CoreSavannahHighmaneFillsBoard_RedemptionNotExcluded() {
        // Five minions stay, so the two Hyenas take the last free slots before Redemption could resummon
        for _ in 0..<5 {
            let minion = createNewEntity(cardId: "EX1_020")
            minion[.cardtype] = CardType.minion.rawValue
            minion[.controller] = heroOpponent.id
            minion[.zone] = Zone.play.rawValue
            game.entities[minion.id] = minion
        }
        let highmane = createNewEntity(cardId: CardIds.Collectible.Hunter.SavannahHighmaneCorePlaceholder)
        highmane[.cardtype] = CardType.minion.rawValue
        highmane[.controller] = heroOpponent.id
        highmane[.deathrattle] = 1
        highmane[.zone] = Zone.graveyard.rawValue
        game.entities[highmane.id] = highmane

        game.opponentMinionDeath(entity: highmane, turn: 2)

        XCTAssertEqual(game.secretsManager?.secrets[2].isExcluded(cardId: CardIds.Secrets.Paladin.Redemption), false)
    }

    func testEveryCollectibleSecretIsInItsClassList() {
        // Placeholder_202204 holds Core prints that cannot appear in games (HearthDb's *CorePlaceholder)
        let lists: [CardClass: [MultiIdCard]] = [
            .hunter: CardIds.Secrets.Hunter.All,
            .mage: CardIds.Secrets.Mage.All,
            .paladin: CardIds.Secrets.Paladin.All,
            .rogue: CardIds.Secrets.Rogue.All
        ]
        let secretCards = Cards.collectible().filter { card in
            card.type == .spell && lists[card.playerClass] != nil && card.set != .placeholder_202204
                && card.enText.replacingOccurrences(of: "[x]", with: "").hasPrefix("<b>Secret:</b>")
        }
        XCTAssertGreaterThan(secretCards.count, 50)
        for card in secretCards {
            let multiIdCard = CardIds.Secrets.getSecretMultiIdCard(card.id)
            XCTAssertNotNil(multiIdCard, "\(card.id) \(card.enName)")
            if let multiIdCard, let list = lists[card.playerClass] {
                XCTAssertTrue(list.contains(multiIdCard), "\(card.id) \(card.enName)")
            }
        }
        XCTAssertTrue(CardIds.Secrets.getSecretMultiIdCard("CORE_CS3_016") == CardIds.Secrets.Paladin.Reckoning)
    }

    private struct NoRemoteSecrets: AvailableSecretsProvider {
        var byType: [String: Set<String>]? { return nil }
        var createdByTypeByCreator: [String: [String: Set<String>]]? { return nil }
    }

    func testFallbackSecretPool_ArenaListsApplyByMode() {
        let manager = SecretsManager(game: game, availableSecrets: NoRemoteSecrets(), relatedCardsManager: game.relatedCardsManager)
        let handOfSalvation = CardIds.Secrets.Paladin.HandOfSalvation.ids[0]
        let snipe = CardIds.Secrets.Hunter.Snipe.ids[0]

        let ranked = manager.getAvailableSecrets(gameMode: .gt_ranked, format: .ft_wild)
        XCTAssertFalse(ranked.contains(handOfSalvation))
        XCTAssertTrue(ranked.contains(snipe))

        let arena = manager.getAvailableSecrets(gameMode: .gt_arena, format: .ft_wild)
        XCTAssertTrue(arena.contains(handOfSalvation))
        XCTAssertFalse(arena.contains(snipe))
    }

    func testNewSecrets_RecordEntryOrder() {
        XCTAssertEqual(game.secretsManager?.secrets.array().map { $0.entryOrder }, [0, 1, 2, 3])
    }

    func testOnExclusionChanged_FiresOncePerTransition() {
        var events = [SecretExclusionEvent]()
        game.secretsManager?.onExclusionChanged = { events.append($0) }
        heroPlayer[.health] = 10

        game.secretsManager?.handleAttack(attacker: heroPlayer, defender: heroOpponent)
        // Bear Trap, Explosive Trap, Wandering Monster, Ice Barrier and Noble Sacrifice
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(events.allSatisfy { !$0.included && $0.exclusion.reason == .attackedHero })
        XCTAssertTrue(events.contains { $0.secretEntityId == secretHunter1.id && $0.cardId == CardIds.Secrets.Hunter.ExplosiveTrap.ids[0] })

        game.secretsManager?.handleAttack(attacker: heroPlayer, defender: heroOpponent)
        XCTAssertEqual(events.count, 5)
    }

    func testExcludedSecret_RecordsReasonAndTurn() {
        gameEntity[.turn] = 9
        playerMinion1[.zone] = Zone.play.rawValue
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: heroOpponent)

        let exclusion = game.secretsManager?.secrets[1].exclusion(for: CardIds.Secrets.Mage.MysticMisdirection)
        XCTAssertEqual(exclusion?.reason, .minionAttacked)
        XCTAssertEqual(exclusion?.turn, game.turnNumber())
        XCTAssertEqual(game.secretsManager?.secrets[1].exclusion(for: CardIds.Secrets.Mage.IceBarrier)?.reason, .attackedHero)
        XCTAssertNil(game.secretsManager?.secrets[1].exclusion(for: CardIds.Secrets.Mage.Counterspell))

        let summary = game.secretsManager?.exclusionSummary(cardId: CardIds.Secrets.Mage.IceBarrier.ids[0])
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("\(game.turnNumber())") ?? false, summary ?? "")
        XCTAssertFalse(summary?.contains("SecretHelper_") ?? true, summary ?? "")
        XCTAssertFalse(summary?.contains("SecretReason_") ?? true, summary ?? "")
        XCTAssertNil(game.secretsManager?.exclusionSummary(cardId: CardIds.Secrets.Mage.Counterspell.ids[0]))
    }

    func testEveryExclusionReasonIsLocalized() {
        for reason in SecretExclusionReason.allCases {
            XCTAssertNotEqual(String.localizedString(reason.localizationKey, comment: ""), reason.localizationKey)
        }
        XCTAssertNotEqual(String.localizedString("SecretReason_BothCopiesPlayed", comment: ""), "SecretReason_BothCopiesPlayed")
        XCTAssertNotEqual(String.localizedString("SecretHelper_RuledOutFormat", comment: ""), "SecretHelper_RuledOutFormat")
    }

    func testIncludedSecret_ReportsTakenBackExclusion() {
        var events = [SecretExclusionEvent]()
        game.secretsManager?.onExclusionChanged = { events.append($0) }
        game.secretsManager?.handleMinionPlayed(entity: playerMinion1)
        let excludedCount = events.count
        XCTAssertGreaterThan(excludedCount, 0)

        // Toggling a card that is excluded somewhere includes it on every secret again
        game.secretsManager?.toggle(cardId: CardIds.Secrets.Mage.MirrorEntity.ids[0])
        XCTAssertEqual(events.count, excludedCount + 1)
        XCTAssertEqual(events.last?.included, true)
        XCTAssertEqual(events.last?.exclusion.reason, .minionPlayed)
        XCTAssertNil(game.secretsManager?.secrets[1].exclusion(for: CardIds.Secrets.Mage.MirrorEntity))
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.MirrorEntity), false)
    }

    // MARK: - Checks resolved at the next action boundary

    private func addOpponentSecret(_ secret: Entity) {
        secret[.zone] = Zone.secret.rawValue
        secret[.controller] = heroOpponent.id
        game.entities[secret.id] = secret
        game.opponentSecretPlayed(entity: secret, cardId: "", from: 0, turn: 0, fromZone: .hand, otherId: secret.id)
    }

    func testSpellCast_ExcludesAfterBoundary_NotBefore() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")

        // Only Counterspell is known right away; everything else waits for the spell to resolve
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Counterspell])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)

        resolve()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.CatTrick, CardIds.Secrets.Hunter.IceTrap])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.Counterspell, CardIds.Secrets.Mage.ManaBind, CardIds.Secrets.Mage.NetherwindPortal])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.OhMyYogg])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All,
                      triggered: [CardIds.Secrets.Rogue.DirtyTricks, CardIds.Secrets.Rogue.StickySituation])
    }

    func testSpellCast_CounterspellTriggered_OnlyCounterspellExcluded() {
        addOpponentSecret(secretMage2)
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")

        // The TRIGGER block arrives after the spell's ZONE change, before the next action
        secretMage2.cardId = CardIds.Secrets.Mage.Counterspell.ids[0]
        game.opponentSecretTrigger(entity: secretMage2, cardId: secretMage2.cardId, turn: 1, otherId: secretMage2.id)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets.count, 4)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Counterspell])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSpellCast_IceTrapTriggered_NothingElseExcluded() {
        addOpponentSecret(secretHunter2)
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")

        secretHunter2.cardId = CardIds.Secrets.Hunter.IceTrap.ids[0]
        game.opponentSecretTrigger(entity: secretHunter2, cardId: secretHunter2.cardId, turn: 1, otherId: secretHunter2.id)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.IceTrap])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Counterspell])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSpellCast_SecretPlayedAfterCast_NotExcludedAtBoundary() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        // A secret that entered play after the cast never saw the spell
        addOpponentSecret(secretRogue2)
        resolve()

        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All,
                      triggered: [CardIds.Secrets.Rogue.DirtyTricks, CardIds.Secrets.Rogue.StickySituation])
        verifySecrets(secretIndex: 4, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSpellCast_DoesNotBlockParserThread() {
        secretHunter1[.controller] = heroOpponent.id
        secretMage1[.controller] = heroOpponent.id
        XCTAssertEqual(game.opponentSecretCount, 2)

        // It used to sleep 750 ms with two opponent secrets plus 200 ms for CARD_TARGET
        let start = Date()
        game.secretsManager?.handleCardPlayed(entity: playerSpell1, parentCardId: "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testOpponentSecretCount_IgnoresSecretsOutsideTheSecretZone() {
        secretHunter1[.controller] = heroOpponent.id
        secretMage2[.controller] = heroOpponent.id
        secretMage2[.zone] = Zone.graveyard.rawValue
        game.entities[secretMage2.id] = secretMage2
        secretPaladin2[.controller] = heroOpponent.id
        secretPaladin2[.zone] = Zone.hand.rawValue
        game.entities[secretPaladin2.id] = secretPaladin2

        XCTAssertEqual(game.opponentSecretCount, 1)
    }

    private func createOpponentMinion(cardId: String, zone: Zone) -> Entity {
        let minion = createNewEntity(cardId: cardId)
        minion[.cardtype] = CardType.minion.rawValue
        minion[.controller] = heroOpponent.id
        minion[.zone] = zone.rawValue
        game.entities[minion.id] = minion
        return minion
    }

    func testTwoDeathrattleMinionsDieTogether_OnlyTokensRemain_AvengeNotExcluded() {
        let golem1 = createOpponentMinion(cardId: CardIds.Collectible.Neutral.HarvestGolem, zone: .graveyard)
        golem1[.deathrattle] = 1
        let golem2 = createOpponentMinion(cardId: CardIds.Collectible.Neutral.HarvestGolem, zone: .graveyard)
        golem2[.deathrattle] = 1
        game.opponentMinionDeath(entity: golem1, turn: 2)
        game.opponentMinionDeath(entity: golem2, turn: 2)
        _ = createOpponentMinion(cardId: "skele21", zone: .play)
        _ = createOpponentMinion(cardId: "skele21", zone: .play)

        resolve()
        XCTAssertEqual(game.secretsManager?.secrets[2].isExcluded(cardId: CardIds.Secrets.Paladin.Avenge), false)
    }

    func testDeathsBlockEnd_UnlistedSummonAfterwards_AvengeNotExcluded() {
        game.opponentMinionDeath(entity: opponentMinion1, turn: 2)
        game.secretsManager?.resolvePendingAvenge()
        // Summoned after the death phase by something DeathrattleSummonCardIds does not know
        _ = createOpponentMinion(cardId: "skele21", zone: .play)

        resolve()
        XCTAssertEqual(game.secretsManager?.secrets[2].isExcluded(cardId: CardIds.Secrets.Paladin.Avenge), false)
    }

    func testReckoning_DealerDiedInTrade_NotExcluded() {
        setPlayerAsCurrentPlayer()
        playerMinion1[.health] = 3
        playerMinion1[.zone] = Zone.play.rawValue
        game.entityDamage(dealer: playerMinion1, entity: opponentMinion1, damage: 3)
        XCTAssertEqual(game.secretsManager?.secrets[2].isExcluded(cardId: CardIds.Secrets.Paladin.Reckoning), false)

        playerMinion1[.zone] = Zone.graveyard.rawValue
        resolve()
        XCTAssertEqual(game.secretsManager?.secrets[2].isExcluded(cardId: CardIds.Secrets.Paladin.Reckoning), false)
    }

    func testReset_DiscardsPendingChecks() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        game.secretsManager?.reset()
        // Same entity id as a secret the pending spell check was taken for
        addOpponentSecret(secretRogue1)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Rogue.All)
    }

    // MARK: - Spells and played cards

    private func fillOpponentBoard(upTo count: Int) -> [Entity] {
        let missing = max(0, count - game.opponentBoardCount)
        return (0..<missing).map { _ in createOpponentMinion(cardId: "EX1_020", zone: .play) }
    }

    private func fillOpponentHand(upTo count: Int) -> [Entity] {
        let missing = max(0, count - game.opponentHandCount)
        return (0..<missing).map { _ in
            let card = createNewEntity(cardId: "")
            card[.controller] = heroOpponent.id
            card[.zone] = Zone.hand.rawValue
            game.entities[card.id] = card
            return card
        }
    }

    func testSpellCast_SpellHasCantPlay_NothingElseExcluded() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        // A Counterspell nobody tracks (e.g. created for the opponent's hero) still marks the spell
        playerSpell2[.cant_play] = 1
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Counterspell])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSpellCast_SpellBackInHand_NothingElseExcluded() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        playerSpell2[.zone] = Zone.hand.rawValue
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSpellCast_OpponentBoardFullAtCastButFreedByResolution_ExcludesNetherwindPortalCatTrickSticky() {
        let board = fillOpponentBoard(upTo: 7)
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        board.forEach { $0[.zone] = Zone.graveyard.rawValue }
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.CatTrick), true)
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.NetherwindPortal), true)
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.StickySituation), true)
        // Never Surrender! reacts when the spell is cast, while the board still held minions
        XCTAssertEqual(game.secretsManager?.secrets[2].isExcluded(cardId: CardIds.Secrets.Paladin.NeverSurrender), true)
    }

    func testSpellCast_OpponentBoardFilledDuringResolution_SummoningSecretsNotExcluded() {
        _ = fillOpponentBoard(upTo: 6)
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        // An older summoning secret or a deathrattle took the last slot
        _ = fillOpponentBoard(upTo: 7)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.CatTrick), false)
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.NetherwindPortal), false)
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.StickySituation), false)
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.ManaBind), true)
    }

    func testSpellCast_OpponentHandFilledDuringResolution_DirtyTricksAndManaBindNotExcluded() {
        _ = fillOpponentHand(upTo: 9)
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        _ = fillOpponentHand(upTo: 10)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.DirtyTricks), false)
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.ManaBind), false)
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.NetherwindPortal), true)
    }

    func testSpellCast_PlayerMinionKilledBySpell_PressurePlateNotExcluded() {
        playerMinion1[.zone] = Zone.play.rawValue
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        playerMinion1[.zone] = Zone.graveyard.rawValue
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.PressurePlate), false)
        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.CatTrick), true)
    }

    func testSpellCast_PlayerMinionLeftToDestroy_PressurePlateExcluded() {
        playerMinion1[.zone] = Zone.play.rawValue
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.PressurePlate), true)
    }

    func testSpellCast_OnlyDormantPlayerMinion_PressurePlateNotExcluded() {
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion1[.dormant] = 1
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.PressurePlate), false)
    }

    func testSpellCast_BlockTargetMinion_ExcludesSpellbenderWithoutCardTargetTag() {
        XCTAssertFalse(playerSpell2.has(tag: .card_target))
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "", targetEntityId: opponentMinion1.id)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.Spellbender), true)
    }

    func testSpellCast_BlockTargetHero_SpellbenderNotExcluded() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "", targetEntityId: heroOpponent.id)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.Spellbender), false)
    }

    func testSpellCast_TargetedMinionWithFullBoard_SpellbenderNotExcluded() {
        _ = fillOpponentBoard(upTo: 7)
        game.secretsManager?.handleCardPlayed(entity: playerSpell1, parentCardId: "")
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.Spellbender), false)
    }

    func testSpellCast_OhMyYoggTriggered_NeverSurrenderNotExcluded() {
        opponentMinion1[.zone] = Zone.play.rawValue
        addOpponentSecret(secretPaladin2)
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")

        secretPaladin2.cardId = CardIds.Secrets.Paladin.OhMyYogg.ids[0]
        game.opponentSecretTrigger(entity: secretPaladin2, cardId: secretPaladin2.cardId, turn: 1, otherId: secretPaladin2.id)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[2].isExcluded(cardId: CardIds.Secrets.Paladin.NeverSurrender), false)
        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.CatTrick), true)
    }

    func testThirdCardIsQuest_ExcludesMotionDeniedRatTrapGallopingHiddenWisdom() {
        setPlayerAsCurrentPlayer()
        heroPlayer[.num_cards_played_this_turn] = 3
        let quest = createNewEntity(cardId: "TLC_817")
        quest[.cardtype] = CardType.spell.rawValue
        quest[.quest] = 1
        quest[.controller] = heroPlayer.id
        quest[.zone] = Zone.secret.rawValue
        game.entities[quest.id] = quest

        game.playerSecretPlayed(entity: quest, cardId: quest.cardId, turn: 1, fromZone: .hand, parentCardId: "")
        // Quests are no casts for the spell reactions
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.Counterspell), false)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.MotionDenied, CardIds.Secrets.Hunter.RatTrap])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.GallopingSavior, CardIds.Secrets.Paladin.HiddenWisdom])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testQuestDrawnThisTurnPlayed_ExcludesAzeriteVein() {
        let quest = createNewEntity(cardId: "TLC_817")
        quest[.cardtype] = CardType.spell.rawValue
        quest[.quest] = 1
        quest[.controller] = heroPlayer.id
        quest[.num_turns_in_hand] = 1
        quest[.zone] = Zone.secret.rawValue
        game.entities[quest.id] = quest

        game.playerSecretPlayed(entity: quest, cardId: quest.cardId, turn: 1, fromZone: .hand, parentCardId: "")

        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.AzeriteVein])
    }

    func testThirdCard_OpponentBoardFilledDuringResolution_RatTrapNotExcluded() {
        setPlayerAsCurrentPlayer()
        heroPlayer[.num_cards_played_this_turn] = 3
        _ = fillOpponentBoard(upTo: 6)
        game.secretsManager?.handleCardPlayed(entity: playerMinion1, parentCardId: "")
        _ = fillOpponentBoard(upTo: 7)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.MotionDenied])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.HiddenWisdom])
    }

    func testThirdCard_Countered_ThreeCardSecretsNotExcluded() {
        setPlayerAsCurrentPlayer()
        heroPlayer[.num_cards_played_this_turn] = 3
        addOpponentSecret(secretMage2)
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")

        secretMage2.cardId = CardIds.Secrets.Mage.Counterspell.ids[0]
        game.opponentSecretTrigger(entity: secretMage2, cardId: secretMage2.cardId, turn: 1, otherId: secretMage2.id)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
    }

    func testThirdCard_NotThePlayersTurn_NothingPending() {
        heroPlayer[.num_cards_played_this_turn] = 3
        game.secretsManager?.handleCardPlayed(entity: playerMinion1, parentCardId: "")
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
    }

    func testSingleSecret_OneMinionDied() {
        opponentMinion2[.zone] = Zone.play.rawValue
        game.opponentMinionDeath(entity: opponentMinion1, turn: 2)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.EmergencyManeuvers])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.Duplicate, CardIds.Secrets.Mage.Effigy])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.Avenge,
                                  CardIds.Secrets.Paladin.Redemption,
                                  CardIds.Secrets.Paladin.GetawayKodo])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All,
                      triggered: [CardIds.Secrets.Rogue.CheatDeath])
    }

    func testSingleSecret_MinionPlayed() {
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        // Ambush and Kidnap wait for the battlecry and the older secrets
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)

        resolve()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.Snipe, CardIds.Secrets.Hunter.Zombeeees])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.ExplosiveRunes,
                                  CardIds.Secrets.Mage.MirrorEntity,
                                  CardIds.Secrets.Mage.PotionOfPolymorph,
                                  CardIds.Secrets.Mage.FrozenClone,
                                  CardIds.Secrets.Mage.Objection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.Repentance])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Ambush, CardIds.Secrets.Rogue.Kidnap])
    }
    
    func testSingleSecret_DormantMinionPlayed() {
        playerMinion1[.dormant] = 1
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        resolve()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.Zombeeees])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.MirrorEntity, CardIds.Secrets.Mage.FrozenClone])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Ambush, CardIds.Secrets.Rogue.Kidnap])
    }

    // MARK: - Minion played

    private func triggerOpponentSecret(_ secret: Entity, as card: MultiIdCard) {
        secret.cardId = card.ids[0]
        game.opponentSecretTrigger(entity: secret, cardId: secret.cardId, turn: 1, otherId: secret.id)
    }

    func testMinionPlayed_ObjectionCounters_MinionToSetaside_RestoresMirrorEntityFrozenCloneExplosiveRunes() {
        addOpponentSecret(secretMage2)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)

        triggerOpponentSecret(secretMage2, as: CardIds.Secrets.Mage.Objection)
        playerMinion1[.zone] = Zone.setaside.rawValue
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Objection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testMinionPlayed_ExplosiveRunesKillsMinion_FrozenCloneRestored() {
        addOpponentSecret(secretMage2)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)

        triggerOpponentSecret(secretMage2, as: CardIds.Secrets.Mage.ExplosiveRunes)
        playerMinion1[.zone] = Zone.graveyard.rawValue
        game.playerMinionDeath(entity: playerMinion1)
        resolve()

        // The revealed Explosive Runes stays ruled out on the other Mage secret
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.ExplosiveRunes, CardIds.Secrets.Mage.Objection])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testMinionPlayed_MortallyWoundedAtNextAction_Restored() {
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion1[.health] = 2
        game.playerMinionPlayed(entity: playerMinion1)
        playerMinion1[.damage] = 2
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.FrozenClone), false)
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Kidnap), false)
    }

    func testMinionPlayed_OpponentBoardFull_KidnapNotExcluded() {
        _ = fillOpponentBoard(upTo: 7)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Kidnap), false)
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Ambush), false)
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.FrozenClone), true)
    }

    func testMinionPlayed_OpponentBoardFilledBeforeNextAction_AmbushAndKidnapNotExcluded() {
        _ = fillOpponentBoard(upTo: 6)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        // A battlecry or an older secret summoned for the opponent
        _ = fillOpponentBoard(upTo: 7)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Ambush), false)
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Kidnap), false)
    }

    func testMinionPlayed_BattlecryFreesOpponentBoard_AmbushAndKidnapExcluded() {
        let board = fillOpponentBoard(upTo: 7)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        board[0][.zone] = Zone.graveyard.rawValue
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Ambush), true)
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Kidnap), true)
    }

    func testMinionPlayed_KidnapSackFillsBoard_AmbushNotExcluded() {
        _ = fillOpponentBoard(upTo: 6)
        addOpponentSecret(secretRogue2)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)

        triggerOpponentSecret(secretRogue2, as: CardIds.Secrets.Rogue.Kidnap)
        playerMinion1[.zone] = Zone.setaside.rawValue
        _ = fillOpponentBoard(upTo: 7)
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets.count, 4)
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Ambush), false)
    }

    func testMinionPlayed_HiddenCacheSavedAndRestoredWhenMinionPlayedSecretTriggered() {
        opponentCardInHand1[.cardtype] = CardType.minion.rawValue
        addOpponentSecret(secretHunter2)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.HiddenCache), true)

        triggerOpponentSecret(secretHunter2, as: CardIds.Secrets.Hunter.Snipe)
        playerMinion1[.zone] = Zone.graveyard.rawValue
        game.playerMinionDeath(entity: playerMinion1)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.Snipe])
    }

    func testMinionPlayed_HandCardRevealedAsMinionBeforeNextAction_HiddenCacheRestoredWithThePlay() {
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.HiddenCache), false)

        opponentCardInHand1[.cardtype] = CardType.minion.rawValue
        game.secretsManager?.onEntityRevealedAsMinion(entity: opponentCardInHand1)
        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.HiddenCache), true)

        playerMinion1[.zone] = Zone.hand.rawValue
        resolve()
        XCTAssertEqual(game.secretsManager?.secrets[0].isExcluded(cardId: CardIds.Secrets.Hunter.HiddenCache), false)
    }

    func testMinionPlayed_MinionPlayedSecretTriggered_MinionDiesLaterInTurn_Restored() {
        addOpponentSecret(secretPaladin2)
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        triggerOpponentSecret(secretPaladin2, as: CardIds.Secrets.Paladin.Repentance)
        resolve()
        XCTAssertEqual(game.secretsManager?.secrets[3].isExcluded(cardId: CardIds.Secrets.Rogue.Kidnap), true)

        // HDT's one-secret-per-event rule takes the play's exclusions back when the minion dies
        playerMinion1[.zone] = Zone.graveyard.rawValue
        game.playerMinionDeath(entity: playerMinion1)

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Objection])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testMinionPlayed_ExclusionsTakenBackOnlyOnTheSecretsThePlayRuledOut() {
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion1[.health] = 1
        // Mirror Entity was already ruled out on the Mage secret before the play
        game.secretsManager?.exclude(cardId: CardIds.Secrets.Mage.MirrorEntity, reason: .minionPlayed)
        game.playerMinionPlayed(entity: playerMinion1)
        addOpponentSecret(secretMage2)
        game.secretsManager?.exclude(cardId: CardIds.Secrets.Mage.FrozenClone, reason: .minionPlayed, secretIds: [secretMage2.id])

        playerMinion1[.zone] = Zone.graveyard.rawValue
        resolve()

        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.MirrorEntity), true)
        XCTAssertEqual(game.secretsManager?.secrets[1].isExcluded(cardId: CardIds.Secrets.Mage.FrozenClone), false)
        XCTAssertEqual(game.secretsManager?.secrets[4].isExcluded(cardId: CardIds.Secrets.Mage.FrozenClone), true)
    }

    func testSingleSecret_OpponentDamage() {
        setPlayerAsCurrentPlayer()
        game.entityDamage(dealer: playerMinion1, entity: heroOpponent, damage: 1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.EyeForAnEye])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All,
                      triggered: [CardIds.Secrets.Rogue.Evasion])
    }

    func testSingleSecret_MinionOpponentDamage_ReckoningNotTriggered() {
        game.entityDamage(dealer: playerMinion1, entity: opponentMinion1, damage: 1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSingleSecret_MinionOpponentDamage_ReckoningTriggered() {
        setPlayerAsCurrentPlayer()
        playerMinion1[.health] = 1
        game.entityDamage(dealer: playerMinion1, entity: opponentMinion1, damage: 3)
        resolve()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.Reckoning])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSingleSecret_MinionTarget_SpellPlayed() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell1, parentCardId: "")
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.CatTrick, CardIds.Secrets.Hunter.IceTrap])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.Counterspell,
                                  CardIds.Secrets.Mage.Spellbender,
                                  CardIds.Secrets.Mage.ManaBind,
                                  CardIds.Secrets.Mage.NetherwindPortal])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.OhMyYogg])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.DirtyTricks, CardIds.Secrets.Rogue.StickySituation])
    }

    func testSingleSecret_NoMinionTarget_SpellPlayed() {
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.CatTrick, CardIds.Secrets.Hunter.IceTrap])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.Counterspell,
                                  CardIds.Secrets.Mage.ManaBind,
                                  CardIds.Secrets.Mage.NetherwindPortal])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.OhMyYogg])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.DirtyTricks, CardIds.Secrets.Rogue.StickySituation])
    }
    
    func testSingleSecret_NoMinionTarget_SpellPlayed_ThirdThisTurn() {
        setPlayerAsCurrentPlayer()
        game.playerEntity?[.num_cards_played_this_turn] = 3
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.CatTrick, CardIds.Secrets.Hunter.IceTrap, CardIds.Secrets.Hunter.MotionDenied, CardIds.Secrets.Hunter.RatTrap])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Counterspell, CardIds.Secrets.Mage.ManaBind, CardIds.Secrets.Mage.NetherwindPortal])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.OhMyYogg, CardIds.Secrets.Paladin.GallopingSavior, CardIds.Secrets.Paladin.HiddenWisdom])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.DirtyTricks, CardIds.Secrets.Rogue.StickySituation])

        game.playerEntity?[.num_cards_drawn_this_turn] = 0
    }
    
    func testSingleSecret_MinionOnBoard_NoMinionTarget_SpellPlayed() {
        opponentMinion1[.zone] = Zone.play.rawValue
        game.secretsManager?.handleCardPlayed(entity: playerSpell2, parentCardId: "")
        resolve()
        
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.CatTrick, CardIds.Secrets.Hunter.IceTrap])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.Counterspell,
                                  CardIds.Secrets.Mage.ManaBind,
                                  CardIds.Secrets.Mage.NetherwindPortal])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NeverSurrender, CardIds.Secrets.Paladin.OhMyYogg])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.DirtyTricks, CardIds.Secrets.Rogue.StickySituation])
    }

    func testSingleSecret_MinionInPlay_OpponentTurnStart() {
        opponentEntity[.current_player] = 1
        game.turnsInPlayChange(entity: opponentMinion1, turn: 1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.RiggedFaireGame])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.CompetitiveSpirit])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Perjury])
    }

    func testSingleSecret_NoMinionInPlay_OpponentTurnStart() {
        game.turnsInPlayChange(entity: heroOpponent, turn: 1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }
    
    func testSingleSecret_OpponentTurnStart() {
        game.opponentEntity?[.current_player] = 1
        game.turnsInPlayChange(entity: opponentMinion1, turn: 1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.RiggedFaireGame])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.CompetitiveSpirit])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Perjury])
    }
    
    func testSingleSecret_Retarget_FriendlyHitsFriendly() {
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: heroPlayer)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
        
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: playerMinion1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }
    
    func testSingleSecret_OpponentAttack_Retarget_OpponentHitsOpponent() {
        game.secretsManager?.handleAttack(attacker: opponentMinion1, defender: heroOpponent)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
        
        game.secretsManager?.handleAttack(attacker: opponentMinion1, defender: opponentMinion2)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }
    
    func testSingleSecret_PlayerTurnStart_OpponentPlayedCards_PlagerizeTriggered() {
        game.player.play(entity: opponentMinion1, turn: 1)
        game.secretsManager?.handleOpponentTurnStart()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Plagiarize])
    }
    
    func testSingleSecret_PlayerTurnStart_OpponentPlayedNoCards_PlagerizeNotTriggered() {
        game.player.play(entity: opponentMinion1, turn: 1)
        game.player.onTurnStart()
        game.secretsManager?.handleOpponentTurnStart()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }
    
    func testSingleSecret_OpponentDrawsTwoCards_ShenanigansTriggered() {
        game.secretsManager?.handleOpponentTurnStart()
        game.player.onTurnStart()
        //Set to 1 because the tag hasn't been incremented by the time the check is being made in normal course
        heroPlayer[GameTag.num_cards_drawn_this_turn] = 1
        game.secretsManager?.handleCardDrawn(entity: playerCardInHand2)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Shenanigans])
    }

    func testSingleSecret_OpponentDrawsOneCard_ShenanigansNotTriggered() {
        game.secretsManager?.handleOpponentTurnStart()
        game.player.onTurnStart()
        heroPlayer[GameTag.num_cards_drawn_this_turn] = 0
        game.secretsManager?    .handleCardDrawn(entity: playerCardInHand1)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }
    
//    func testSingleSecret_OpponentTurnStart_OpponentTookNoDamage_RiggedFaireGameTriggered() {
//        game.opponent.onTurnStart()
//        game.secretsManager?.handleOpponentTurnStart()
//        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
//        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.RiggedFaireGame])
//        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
//        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
//    }


    func testSingleSecret_MinionToHero_PlayerImmune_PlayerAttackTest() {
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion1[.immune] = 1
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: heroOpponent)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [ CardIds.Secrets.Hunter.ExplosiveTrap, CardIds.Secrets.Hunter.WanderingMonster ])
    }

    func testSingleSecret_HeroToHero_MinionImmune_PlayerAttackTest() {
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion1[.immune] = 1
        game.secretsManager?.handleAttack(attacker: heroPlayer, defender: heroOpponent)
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [ CardIds.Secrets.Hunter.ExplosiveTrap, CardIds.Secrets.Hunter.WanderingMonster ])
    }
    
    func testMultipleSecrets_MinionToHero_ExplosiveTrapTriggered_MinionDied_PlayerAttackTest() {
        playerMinion1[.zone] = Zone.play.rawValue
        playerMinion1[.health] = -1
        game.secretsManager?.handleAttack(attacker: playerMinion1, defender: heroOpponent)
        
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.ExplosiveTrap,
                                  CardIds.Secrets.Hunter.WanderingMonster])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.IceBarrier, CardIds.Secrets.Mage.VengefulVisage, CardIds.Secrets.Mage.MysticMisdirection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.NobleSacrifice,
                                  CardIds.Secrets.Paladin.JudgementofJustice])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }
    
    func testMultipleSecrets_MinionPlayed_MinionDiedBeforeNextAction_RestoredExceptObjection() {
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        // Its own battlecry or an untracked effect removed it before the after-play secrets
        playerMinion1[.zone] = Zone.graveyard.rawValue
        game.playerMinionDeath(entity: playerMinion1)
        resolve()

        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Objection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testMultipleSecrets_MinionPlayed_NoSecretTriggered_MinionDiedAfterNextAction() {
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        resolve()
        playerMinion1[.zone] = Zone.graveyard.rawValue
        game.playerMinionDeath(entity: playerMinion1)
        resolve()

        // Nothing triggered on the play, so dying later leaves its exclusions valid
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.Snipe, CardIds.Secrets.Hunter.Zombeeees])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.ExplosiveRunes,
                                  CardIds.Secrets.Mage.FrozenClone,
                                  CardIds.Secrets.Mage.MirrorEntity,
                                  CardIds.Secrets.Mage.PotionOfPolymorph,
                                  CardIds.Secrets.Mage.Objection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.Repentance])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Ambush, CardIds.Secrets.Rogue.Kidnap])
    }
    
//    func testMultipleSecrets_MinionPlayed_SecretTriggered_MinionDied() {
//        game.opponentSecretPlayed(entity: secretMage2, cardId: "", from: 0, turn: 0, fromZone: Zone.hand, otherId: secretMage2.id)
//        secretMage2.cardId = CardIds.Secrets.Mage.ExplosiveRunes
//        game.playerMinionPlayed(entity: playerMinion1)
//        game.opponentSecretTrigger(entity: secretMage2, cardId: "", turn: 2, otherId: secretMage2.id)
//        game.playerMinionDeath(entity: playerMinion1)
//        
//        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
//        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
//                      triggered: [CardIds.Secrets.Mage.ExplosiveRunes,
//                                  CardIds.Secrets.Mage.FrozenClone])
//        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
//        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
//    }
//    
//    func testMultipleSecrets_MinionPlayed_MultipleSecretsTriggered_MinionDied() {
//        game.opponentSecretPlayed(entity: secretMage2, cardId: "", from: 0, turn: 0, fromZone: Zone.hand, otherId: secretMage2.id)
//        game.opponentSecretPlayed(entity: secretMage3, cardId: "", from: 0, turn: 0, fromZone: Zone.hand, otherId: secretMage3.id)
//        secretMage2.cardId = CardIds.Secrets.Mage.PotionOfPolymorph
//        secretMage3.cardId = CardIds.Secrets.Mage.ExplosiveRunes
//        game.playerMinionPlayed(entity: playerMinion1)
//        game.opponentSecretTrigger(entity: secretMage2, cardId: "", turn: 2, otherId: secretMage2.id)
//        game.opponentSecretTrigger(entity: secretMage3, cardId: "", turn: 2, otherId: secretMage3.id)
//        game.playerMinionDeath(entity: playerMinion1)
//        
//        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
//        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
//                      triggered: [CardIds.Secrets.Mage.ExplosiveRunes,
//                                  CardIds.Secrets.Mage.FrozenClone,
//                                  CardIds.Secrets.Mage.PotionOfPolymorph])
//        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
//        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
//    }
//    
//    func testMultipleSecrets_MinionPlayed_MinionDiedNextTurn() {
//        game.playerMinionPlayed(entity: playerMinion1)
//        game.turnStart(player: PlayerType.player, turn: 2)
//        game.playerMinionDeath(entity: playerMinion1)
//        
//        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
//                      triggered: [CardIds.Secrets.Hunter.Snipe])
//        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
//                      triggered: [CardIds.Secrets.Mage.ExplosiveRunes,
//                                  CardIds.Secrets.Mage.FrozenClone,
//                                  CardIds.Secrets.Mage.MirrorEntity,
//                                  CardIds.Secrets.Mage.PotionOfPolymorph])
//        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
//                      triggered: [CardIds.Secrets.Paladin.Repentance])
//        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Ambush])
//    }
    
    func testMultipleSecrets_MinionPlayed_AnotherMinionDied() {
        playerMinion1[.zone] = Zone.play.rawValue
        game.playerMinionPlayed(entity: playerMinion1)
        playerMinion2[.zone] = Zone.graveyard.rawValue
        game.playerMinionDeath(entity: playerMinion2)
        resolve()
        
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All,
                      triggered: [CardIds.Secrets.Hunter.BargainBin, CardIds.Secrets.Hunter.Snipe, CardIds.Secrets.Hunter.Zombeeees])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All,
                      triggered: [CardIds.Secrets.Mage.ExplosiveRunes,
                                  CardIds.Secrets.Mage.FrozenClone,
                                  CardIds.Secrets.Mage.MirrorEntity,
                                  CardIds.Secrets.Mage.PotionOfPolymorph,
                                  CardIds.Secrets.Mage.Objection])
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All,
                      triggered: [CardIds.Secrets.Paladin.Repentance])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Ambush, CardIds.Secrets.Rogue.Kidnap])
    }
 
//    func testMultipleSecrets_MinionToHero_VaporizeTriggered_PlayerAttackTest() {
//        game.opponentSecretPlayed(entity: secretMage2, cardId: "", from: 0, turn: 0, fromZone: .hand, otherId: secretMage2.id)
//        secretMage2.cardId = CardIds.Secrets.Mage.Vaporize
//
//        playerMinion1[.zone] = Zone.play.rawValue
//        playerMinion1[.health] = Cards.by(cardId: playerMinion1.cardId)!.health
//        game.proposedAttacker = playerMinion1.id
//        game.proposedDefender = heroOpponent.id
//        game.opponentSecretTrigger(entity: secretMage2, cardId: "", turn: 2, otherId: secretMage2.id)
//
//        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.ExplosiveTrap, CardIds.Secrets.Hunter.WanderingMonster])
//        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.Vaporize, CardIds.Secrets.Mage.IceBarrier])
//        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.NobleSacrifice])
//        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
//    }
//
//    func testMultipleSecrets_MinionToMinion_FreezingTrapTriggered_PlayerAttackTest() {
//        game.opponentSecretPlayed(entity: secretHunter2, cardId: "", from: 0, turn: 0, fromZone: .hand, otherId: secretHunter2.id)
//        secretHunter2.cardId = CardIds.Secrets.Hunter.FreezingTrap
//
//        playerMinion1[.zone] = Zone.play.rawValue
//        playerMinion1[.health] = Cards.by(cardId: playerMinion1.cardId)!.health
//        opponentMinion1[.zone] = Zone.play.rawValue
//        opponentMinion1[.health] = Cards.by(cardId: opponentMinion1.cardId)!.health
//        game.proposedAttacker = playerMinion1.id
//        game.proposedDefender = opponentMinion1.id
//        game.opponentSecretTrigger(entity: secretHunter2, cardId: "", turn: 2, otherId: secretHunter2.id)
//
//        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.FreezingTrap, CardIds.Secrets.Hunter.PackTactics, CardIds.Secrets.Hunter.SnakeTrap, CardIds.Secrets.Hunter.VenomstrikeTrap])
//        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All, triggered: [CardIds.Secrets.Mage.SplittingImage])
//        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.AutodefenseMatrix, CardIds.Secrets.Paladin.NobleSacrifice])
//        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All, triggered: [CardIds.Secrets.Rogue.Bamboozle])
//    }
    // TODO: Add test for Rat Trap, Hidden Wisdom, Sacred Trial, etc.

    func testSingleSecret_OpponentPlaysTwoCards() {
        setPlayerAsCurrentPlayer()
        heroPlayer[GameTag.num_cards_played_this_turn] = 2
        game.secretsManager?.handleCardPlayed(entity: playerMinion1, parentCardId: "")
        resolve()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }

    func testSingleSecret_OpponentPlaysThreeCards() {
        setPlayerAsCurrentPlayer()
        heroPlayer[GameTag.num_cards_played_this_turn] = 3
        game.secretsManager?.handleCardPlayed(entity: playerMinion1, parentCardId: "")
        // Rat Trap and the others react after the card resolved
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All)

        resolve()
        verifySecrets(secretIndex: 0, allSecrets: CardIds.Secrets.Hunter.All, triggered: [CardIds.Secrets.Hunter.RatTrap, CardIds.Secrets.Hunter.MotionDenied])
        verifySecrets(secretIndex: 1, allSecrets: CardIds.Secrets.Mage.All)
        verifySecrets(secretIndex: 2, allSecrets: CardIds.Secrets.Paladin.All, triggered: [CardIds.Secrets.Paladin.GallopingSavior, CardIds.Secrets.Paladin.HiddenWisdom])
        verifySecrets(secretIndex: 3, allSecrets: CardIds.Secrets.Rogue.All)
    }
    
    func setPlayerAsCurrentPlayer() {
        heroPlayer[.current_player] = 1
    }
}
