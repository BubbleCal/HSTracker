//
//  ActionHistoryRecorderTests.swift
//  HSTrackerTests
//
//  Drives ActionHistoryRecorder the way PowerGameStateParser and TagChangeHandler do: blocks start
//  and end, and every tag change is stored on the entity before the recorder hears about it. The
//  entities are built in code, so no Game or card database is needed.
//

import XCTest
import Foundation

@testable import HSTracker

class ActionHistoryRecorderTests: HSTrackerTests {
    private static let localPlayerId = 1
    private static let opponentId = 2

    private var entities: SynchronizedDictionary<Int, Entity>!
    private var recorder: ActionHistoryRecorder!
    private var gameEntity: Entity!
    private var localPlayer: Entity!
    private var opponent: Entity!
    private var nextEntityId = 4
    private var nextBlockId = 1
    private var hideShowEntities = false
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        entities = SynchronizedDictionary<Int, Entity>()
        recorder = ActionHistoryRecorder()
        nextEntityId = 4
        nextBlockId = 1
        hideShowEntities = false

        gameEntity = Entity(id: 1)
        gameEntity.name = "GameEntity"
        gameEntity[.cardtype] = CardType.game.rawValue
        entities[1] = gameEntity
        localPlayer = playerEntity(id: 2, playerId: ActionHistoryRecorderTests.localPlayerId)
        opponent = playerEntity(id: 3, playerId: ActionHistoryRecorderTests.opponentId)
    }

    override func tearDown() {
        recorder = nil
        entities = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func playerEntity(id: Int, playerId: Int) -> Entity {
        let entity = Entity(id: id)
        entity[.cardtype] = CardType.player.rawValue
        entity[.player_id] = playerId
        entity[.controller] = playerId
        entities[id] = entity
        return entity
    }

    /// An entity that already exists, with its tags set without telling the recorder.
    private func card(_ cardId: String, controller: Int, zone: Zone, type: CardType = .minion) -> Entity {
        let entity = Entity(id: nextEntityId)
        nextEntityId += 1
        entity.cardId = cardId
        entity[.controller] = controller
        entity[.zone] = zone.rawValue
        entity[.cardtype] = type.rawValue
        entity[.health] = 5
        entities[entity.id] = entity
        return entity
    }

    /// A FULL_ENTITY body: ZONE comes first, CARDTYPE and CONTROLLER after it, as in Power.log.
    @discardableResult
    private func fullEntity(_ cardId: String, controller: Int, zone: Zone, type: CardType = .minion,
                            extraTags: [(GameTag, Int)] = []) -> Entity {
        let entity = Entity(id: nextEntityId)
        nextEntityId += 1
        entity.cardId = cardId
        entities[entity.id] = entity
        tag(entity, .zone, zone.rawValue, creation: true)
        tag(entity, .controller, controller, creation: true)
        tag(entity, .cardtype, type.rawValue, creation: true)
        for (gameTag, value) in extraTags {
            tag(entity, gameTag, value, creation: true)
        }
        return entity
    }

    /// TagChangeHandler.tagChange: store the value, then tap.
    private func tag(_ entity: Entity, _ gameTag: GameTag, _ value: Int, creation: Bool = false) {
        let prevValue = entity[gameTag]
        guard prevValue != value else {
            return
        }
        entity[gameTag] = value
        recorder.tagChanged(entity: entity, tag: gameTag, prevValue: prevValue, value: value, isCreationTag: creation,
                            hideShowEntities: hideShowEntities, localPlayerId: ActionHistoryRecorderTests.localPlayerId,
                            entities: entities)
    }

    private func zone(_ entity: Entity, _ zone: Zone, creation: Bool = false) {
        tag(entity, .zone, zone.rawValue, creation: creation)
    }

    private func block(_ type: String, _ source: Entity?, target: Entity? = nil, keyword: String? = nil,
                       sourceKind: HistoryBlockInfo.SourceKind? = nil, _ body: () -> Void = {}) {
        let blockId = nextBlockId
        nextBlockId += 1
        let info = HistoryBlockInfo(blockType: type, sourceKind: sourceKind ?? (source == nil ? .gameEntity : .entity),
                                    sourceEntityId: source?.id, targetEntityId: target?.id, triggerKeyword: keyword)
        recorder.blockStarted(blockId: blockId, info: info, localPlayerId: ActionHistoryRecorderTests.localPlayerId,
                              entities: entities, time: time)
        body()
        recorder.blockEnded(blockId: blockId, localPlayerId: ActionHistoryRecorderTests.localPlayerId, entities: entities)
    }

    /// A step or draw block started by a player, logged by name.
    private func playerBlock(_ body: () -> Void) {
        block("TRIGGER", nil, keyword: "TAG_NOT_SET", sourceKind: .player, body)
    }

    /// Game.reset replaces the entities; the tests reuse them, so clear what a new game sets again.
    private func clearGameTags() {
        gameEntity[.turn] = 0
        gameEntity[.step] = 0
        for player in [localPlayer!, opponent!] {
            player[.mulligan_state] = 0
            player[.current_player] = 0
        }
    }

    private func finishMulligan() {
        tag(localPlayer, .mulligan_state, Mulligan.done.rawValue)
        tag(opponent, .mulligan_state, Mulligan.done.rawValue)
    }

    private func startTurn(_ rawTurn: Int, localTurn: Bool) {
        block("TRIGGER", nil, keyword: "TAG_NOT_SET") {
            tag(localTurn ? opponent : localPlayer, .current_player, 0)
            tag(localTurn ? localPlayer : opponent, .current_player, 1)
            tag(gameEntity, .turn, rawTurn)
        }
    }

    private func startGame(rawTurn: Int = 3, localTurn: Bool = true) {
        finishMulligan()
        startTurn(rawTurn, localTurn: localTurn)
    }

    private var turns: [HistoryTurn] {
        return recorder.snapshot().turns
    }

    private var entries: [HistoryEntry] {
        return turns.last?.entries ?? []
    }

    private func effects(_ entry: HistoryEntry?, _ kind: HistoryEffectKind) -> [HistoryEffect] {
        return entry?.effects.filter { $0.kind == kind } ?? []
    }

    // MARK: - Actions and effects

    func testPlayMergesItsBattlecryIntoOneEntry() {
        startGame()
        let minion = card("CORE_EX1_066", controller: 1, zone: .hand)
        let enemy = card("CORE_CS2_120", controller: 2, zone: .play)

        block("PLAY", minion, target: enemy) {
            zone(minion, .play)
            tag(minion, .card_target, enemy.id)
            block("POWER", minion, target: enemy) {
                tag(enemy, .damage, 3)
            }
        }

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.turn, 2)
        XCTAssertEqual(turns.first?.side, .player)
        XCTAssertEqual(entries.count, 1)
        let entry = entries.first
        XCTAssertEqual(entry?.type, .play)
        XCTAssertEqual(entry?.activeSide, .player)
        XCTAssertEqual(entry?.source?.cardId, "CORE_EX1_066")
        XCTAssertEqual(entry?.target?.cardId, "CORE_CS2_120")
        XCTAssertEqual(entry?.children, [])
        XCTAssertEqual(entry?.effects.count, 1)
        XCTAssertEqual(entry?.effects.first?.kind, .damage)
        XCTAssertEqual(entry?.effects.first?.amount, 3)
        XCTAssertEqual(entry?.effects.first?.targets.map { $0.cardId }, ["CORE_CS2_120"])
        XCTAssertEqual(entry?.effects.first?.targets.first?.side, .opponent)
    }

    func testAttackFollowsRedirectAndKeepsNestedDeaths() {
        startGame()
        let attacker = card("CORE_CS2_182", controller: 1, zone: .play)
        let defender = card("CORE_CS2_120", controller: 2, zone: .play)
        let redirected = card("CORE_EX1_130a", controller: 2, zone: .play)

        block("ATTACK", attacker, target: defender) {
            tag(gameEntity, .proposed_defender, defender.id)
            tag(gameEntity, .proposed_defender, redirected.id)
            tag(redirected, .damage, 4)
            tag(attacker, .damage, 1)
            tag(gameEntity, .proposed_defender, 0)
            block("DEATHS", nil) {
                zone(redirected, .graveyard)
                tag(redirected, .damage, 0)
            }
        }

        XCTAssertEqual(entries.count, 1)
        let attack = entries.first
        XCTAssertEqual(attack?.type, .attack)
        XCTAssertEqual(attack?.source?.cardId, "CORE_CS2_182")
        XCTAssertEqual(attack?.target?.entityId, redirected.id)
        XCTAssertEqual(attack?.target?.cardId, "CORE_EX1_130a")
        XCTAssertEqual(effects(attack, .damage).map { $0.amount }, [4, 1])
        XCTAssertEqual(effects(attack, .died).first?.targets.map { $0.entityId }, [redirected.id])
        XCTAssertTrue(effects(attack, .heal).isEmpty)
    }

    func testHeroAttackNamesItsWeapon() {
        startGame()
        let hero = card("HERO_03", controller: 1, zone: .play, type: .hero)
        hero[.health] = 30
        let enemy = card("CORE_CS2_120", controller: 2, zone: .play)
        block("PLAY", card("CS2_083b", controller: 1, zone: .play, type: .hero_power)) {
            fullEntity("CS2_082", controller: 1, zone: .play, type: .weapon)
        }
        XCTAssertEqual(entries.last?.type, .heroPower)
        XCTAssertEqual(effects(entries.last, .equipped).first?.targets.first?.cardId, "CS2_082")

        block("ATTACK", hero, target: enemy) {
            tag(enemy, .damage, 1)
        }
        XCTAssertEqual(entries.last?.type, .attack)
        XCTAssertEqual(entries.last?.weapon?.cardId, "CS2_082")
    }

    func testTopLevelDeathsAndDeathrattlesJoinThePreviousActionUntilTheStepChanges() {
        startGame()
        let attacker = card("CORE_CS2_182", controller: 1, zone: .play)
        let defender = card("CORE_FP1_007", controller: 2, zone: .play)

        block("ATTACK", attacker, target: defender) {
            tag(defender, .damage, 5)
        }
        block("DEATHS", nil) {
            zone(defender, .graveyard)
        }
        block("TRIGGER", defender, keyword: "DEATHRATTLE") {
            fullEntity("FP1_007t", controller: 2, zone: .play)
        }

        XCTAssertEqual(entries.count, 1)
        let attack = entries.first
        XCTAssertEqual(effects(attack, .died).first?.targets.map { $0.entityId }, [defender.id])
        XCTAssertEqual(attack?.children.count, 1)
        XCTAssertEqual(attack?.children.first?.type, .deathrattle)
        XCTAssertEqual(attack?.children.first?.triggerKeyword, "DEATHRATTLE")
        XCTAssertEqual(attack?.children.first?.source?.cardId, "CORE_FP1_007")
        XCTAssertEqual(effects(attack?.children.first, .summoned).first?.targets.map { $0.cardId }, ["FP1_007t"])

        // Once the game moves on, deaths are their own row
        tag(gameEntity, .step, Step.main_action.rawValue)
        let other = card("CORE_CS2_120", controller: 2, zone: .play)
        block("DEATHS", nil) {
            zone(other, .graveyard)
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.type, .deaths)
        XCTAssertEqual(effects(entries.last, .died).first?.targets.map { $0.entityId }, [other.id])

        // A new action starts a new window: its deaths attach to it, not to the attack
        let spell = card("CORE_CS2_029", controller: 1, zone: .hand, type: .spell)
        let victim = card("CORE_CS2_172", controller: 2, zone: .play)
        block("PLAY", spell) {
            zone(spell, .play)
            block("POWER", spell) {
                tag(victim, .damage, 6)
            }
            zone(spell, .graveyard)
        }
        block("DEATHS", nil) {
            zone(victim, .graveyard)
        }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.last?.type, .play)
        XCTAssertEqual(effects(entries.last, .died).first?.targets.map { $0.entityId }, [victim.id])
    }

    func testEmptyTriggersAreDroppedAndDeathrattleSummonsAreKept() {
        startGame()
        let adventurer = card("EX1_044", controller: 2, zone: .play)
        let spell = card("CORE_CS2_029", controller: 1, zone: .hand, type: .spell)
        let target = card("CORE_FP1_007", controller: 2, zone: .play)

        block("PLAY", spell, target: target) {
            zone(spell, .play)
            block("TRIGGER", adventurer, keyword: "TRIGGER_VISUAL")
            block("POWER", spell, target: target) {
                tag(target, .damage, 6)
            }
            zone(spell, .graveyard)
            block("DEATHS", nil) {
                zone(target, .graveyard)
            }
            block("TRIGGER", target, keyword: "DEATHRATTLE") {
                fullEntity("FP1_007t", controller: 2, zone: .play)
            }
        }

        let play = entries.first
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(play?.children.map { $0.type }, [.deathrattle])
        XCTAssertEqual(effects(play?.children.first, .summoned).first?.targets.first?.cardId, "FP1_007t")
        XCTAssertEqual(effects(play, .died).first?.targets.first?.entityId, target.id)
        // The spell itself going to the graveyard is not a death
        XCTAssertFalse(play?.effects.contains { effect in effect.targets.contains { $0.entityId == spell.id } } ?? true)
    }

    func testHealingAndPostDeathResets() {
        startGame()
        let wounded = card("CORE_CS2_120", controller: 1, zone: .play)
        wounded[.damage] = 5
        let spell = card("CORE_CS2_236", controller: 1, zone: .hand, type: .spell)

        block("PLAY", spell) {
            zone(spell, .play)
            tag(wounded, .damage, 2)
        }
        XCTAssertEqual(effects(entries.last, .heal).first?.amount, 3)
        XCTAssertTrue(effects(entries.last, .damage).isEmpty)

        let dying = card("CORE_CS2_172", controller: 2, zone: .play)
        dying[.damage] = 5
        let killer = card("CORE_CS2_029", controller: 1, zone: .hand, type: .spell)
        block("PLAY", killer) {
            zone(killer, .play)
            zone(dying, .graveyard)
            tag(dying, .damage, 0)
        }
        XCTAssertTrue(effects(entries.last, .heal).isEmpty)
        XCTAssertEqual(effects(entries.last, .died).count, 1)
    }

    func testArmorFoldsIntoTheDamageTotal() {
        startGame()
        let hero = card("HERO_01", controller: 2, zone: .play, type: .hero)
        hero[.health] = 30
        hero[.armor] = 4
        let fireball = card("CORE_CS2_029", controller: 1, zone: .hand, type: .spell)

        block("PLAY", fireball, target: hero) {
            zone(fireball, .play)
            block("POWER", fireball, target: hero) {
                tag(hero, .armor, 0)
                tag(hero, .damage, 2)
            }
        }
        let entry = entries.last
        XCTAssertEqual(effects(entry, .damage).first?.amount, 6)
        XCTAssertEqual(effects(entry, .damage).first?.targets.first?.entityId, hero.id)
        XCTAssertEqual(effects(entry, .armorLost).first?.amount, 4)
        XCTAssertEqual(entry?.target?.cardId, "HERO_01")
    }

    func testAreaDamageWithEqualAmountsIsOneEffect() {
        startGame()
        let consecration = card("CORE_CS2_093", controller: 1, zone: .hand, type: .spell)
        let minions = (0..<3).map { _ in card("CORE_CS2_120", controller: 2, zone: .play) }
        let hero = card("HERO_08", controller: 2, zone: .play, type: .hero)
        hero[.health] = 30
        let tough = card("CORE_CS2_187", controller: 2, zone: .play)

        block("PLAY", consecration) {
            zone(consecration, .play)
            block("POWER", consecration) {
                for minion in minions {
                    tag(minion, .damage, 2)
                }
                tag(hero, .damage, 2)
                tag(tough, .damage, 1)
                tag(tough, .damage, 2)
            }
        }
        let damage = effects(entries.last, .damage)
        XCTAssertEqual(damage.count, 1)
        XCTAssertEqual(damage.first?.amount, 2)
        XCTAssertEqual(damage.first?.targets.map { $0.entityId }, minions.map { $0.id } + [hero.id, tough.id])
    }

    func testDestroyedWeaponIsNotADeath() {
        startGame(rawTurn: 4, localTurn: false)
        let weapon = card("CS2_082", controller: 1, zone: .play, type: .weapon)
        let harrison = card("CORE_EX1_558", controller: 2, zone: .hand)
        block("PLAY", harrison) {
            zone(harrison, .play)
            block("POWER", harrison) {
                zone(weapon, .graveyard)
            }
        }
        XCTAssertEqual(turns.last?.side, .opponent)
        XCTAssertEqual(entries.last?.source?.cardId, "CORE_EX1_558")
        XCTAssertEqual(effects(entries.last, .destroyed).first?.targets.first?.cardId, "CS2_082")
        XCTAssertTrue(effects(entries.last, .died).isEmpty)
    }

    func testTransformNamesTheBeforeAndAfterCards() {
        startGame()
        let hex = card("CORE_EX1_246", controller: 1, zone: .hand, type: .spell)
        let minion = card("CORE_CS2_120", controller: 2, zone: .play)
        block("PLAY", hex, target: minion) {
            zone(hex, .play)
            block("POWER", hex, target: minion) {
                minion.info.latestCardId = "hexfrog"
                recorder.entityChanged(entity: minion, fromCardId: "CORE_CS2_120", toCardId: "hexfrog", hideShowEntities: false,
                                       localPlayerId: ActionHistoryRecorderTests.localPlayerId, entities: entities)
            }
        }
        let transformed = effects(entries.last, .transformed).first
        XCTAssertEqual(transformed?.targets.first?.cardId, "CORE_CS2_120")
        XCTAssertEqual(transformed?.detailCardId, "hexfrog")
    }

    func testBattlecryBuffIsRecordedAndAurasAreNot() {
        startGame()
        let target = card("CORE_CS2_120", controller: 1, zone: .play)
        let buffer = card("CORE_EX1_019", controller: 1, zone: .hand)
        block("PLAY", buffer, target: target) {
            zone(buffer, .play)
            // An aura applied straight in the PLAY block
            fullEntity("CS2_222o", controller: 1, zone: .play, type: .enchantment,
                       extraTags: [(.attached, target.id), (.creator, buffer.id)])
            block("POWER", buffer, target: target) {
                fullEntity("EX1_019e", controller: 1, zone: .play, type: .enchantment,
                           extraTags: [(.attached, target.id), (.creator, buffer.id)])
            }
        }
        let enchanted = effects(entries.last, .enchanted)
        XCTAssertEqual(enchanted.count, 1)
        XCTAssertEqual(enchanted.first?.detailCardId, "EX1_019e")
        XCTAssertEqual(enchanted.first?.targets.map { $0.entityId }, [target.id])
        XCTAssertTrue(effects(entries.last, .summoned).isEmpty)
    }

    func testFreezeSilenceAndDivineShield() {
        startGame()
        let spell = card("CORE_CS2_026", controller: 1, zone: .hand, type: .spell)
        let shielded = card("CORE_EX1_008", controller: 2, zone: .play)
        shielded[.divine_shield] = 1
        let other = card("CORE_CS2_120", controller: 2, zone: .play)
        block("PLAY", spell) {
            zone(spell, .play)
            tag(shielded, .divine_shield, 0)
            tag(other, .frozen, 1)
            tag(other, .silenced, 1)
        }
        XCTAssertEqual(effects(entries.last, .divineShieldLost).first?.targets.first?.entityId, shielded.id)
        XCTAssertEqual(effects(entries.last, .frozen).first?.targets.first?.entityId, other.id)
        XCTAssertEqual(effects(entries.last, .silenced).first?.targets.first?.entityId, other.id)
    }

    // MARK: - Hidden information

    func testOpponentPredictedDrawIsOnlyCounted() {
        startGame(rawTurn: 4, localTurn: false)
        let predicted = card("CORE_EX1_610", controller: 2, zone: .deck, type: .spell)
        predicted.info.guessedCardState = .guessed
        let plain = Entity(id: nextEntityId)
        nextEntityId += 1
        plain[.controller] = 2
        plain[.zone] = Zone.deck.rawValue
        entities[plain.id] = plain

        playerBlock {
            zone(predicted, .hand)
            zone(plain, .hand)
        }
        let header = turns.last?.header ?? []
        XCTAssertEqual(header.count, 1)
        XCTAssertEqual(header.first?.kind, .drewUnknown)
        XCTAssertEqual(header.first?.amount, 2)
        XCTAssertEqual(header.first?.targets.compactMap { $0.cardId }, [])
    }

    func testLocalDrawIsNamedInTheTurnHeader() {
        startGame()
        let drawn = Entity(id: nextEntityId)
        nextEntityId += 1
        drawn[.controller] = 1
        drawn[.zone] = Zone.deck.rawValue
        entities[drawn.id] = drawn
        playerBlock {
            // SHOW_ENTITY: the card, then its body
            drawn.cardId = "CORE_CS2_029"
            tag(drawn, .zone, Zone.hand.rawValue, creation: true)
            tag(drawn, .cardtype, CardType.spell.rawValue, creation: true)
        }
        let header = turns.last?.header ?? []
        XCTAssertEqual(header.first?.kind, .drew)
        XCTAssertEqual(header.first?.targets.first?.cardId, "CORE_CS2_029")
        XCTAssertEqual(header.first?.targets.first?.cardType, CardType.spell.rawValue)
    }

    func testOpponentGeneratedCardIsAnonymousAndLocalIsNamed() {
        startGame(rawTurn: 4, localTurn: false)
        let spell = card("CORE_UNG_856", controller: 2, zone: .hand, type: .spell)
        block("PLAY", spell) {
            zone(spell, .play)
            block("POWER", spell) {
                let offered = fullEntity("KAR_076", controller: 2, zone: .setaside, type: .spell)
                zone(offered, .hand)
            }
            zone(spell, .graveyard)
        }
        let generated = effects(entries.last, .generated)
        XCTAssertEqual(generated.count, 1)
        XCTAssertNil(generated.first?.targets.first?.cardId)
        XCTAssertEqual(generated.first?.amount, 1)
        XCTAssertEqual(entries.last?.source?.cardId, "CORE_UNG_856")

        startTurn(5, localTurn: true)
        let local = card("CORE_UNG_856", controller: 1, zone: .hand, type: .spell)
        block("PLAY", local) {
            zone(local, .play)
            block("POWER", local) {
                fullEntity("CS2_022", controller: 1, zone: .hand, type: .spell)
            }
        }
        XCTAssertEqual(effects(entries.last, .generated).first?.targets.first?.cardId, "CS2_022")
        XCTAssertNil(effects(entries.last, .generated).first?.amount)
    }

    func testOpponentSecretIsAnnotatedOnceRevealed() {
        startGame(rawTurn: 4, localTurn: false)
        let secret = Entity(id: nextEntityId)
        nextEntityId += 1
        secret[.controller] = 2
        secret[.zone] = Zone.hand.rawValue
        secret[.cardtype] = CardType.spell.rawValue
        secret[.secret] = 1
        secret.info.hidden = true
        entities[secret.id] = secret

        block("PLAY", secret) {
            zone(secret, .secret)
        }
        let played = entries.last
        XCTAssertEqual(played?.type, .play)
        XCTAssertNil(played?.source?.cardId)
        XCTAssertEqual(played?.source?.isSecret, true)
        XCTAssertNil(played?.revealedLater)

        startTurn(5, localTurn: true)
        let attacker = card("CORE_CS2_182", controller: 1, zone: .play)
        let defender = card("HERO_08", controller: 2, zone: .play, type: .hero)
        defender[.health] = 30
        block("ATTACK", attacker, target: defender) {
            // SHOW_ENTITY of the Secret, then its trigger
            secret.cardId = "CORE_EX1_130"
            secret.info.hidden = false
            recorder.entityShown(entity: secret, localPlayerId: ActionHistoryRecorderTests.localPlayerId, entities: entities)
            block("TRIGGER", secret, keyword: "SECRET") {
                let token = fullEntity("EX1_130a", controller: 2, zone: .play)
                tag(gameEntity, .proposed_defender, token.id)
            }
            zone(secret, .graveyard)
        }

        XCTAssertEqual(turns.first?.entries.first?.revealedLater?.cardId, "CORE_EX1_130")
        let attack = entries.last
        XCTAssertEqual(attack?.children.first?.type, .secret)
        XCTAssertEqual(attack?.children.first?.source?.cardId, "CORE_EX1_130")
        XCTAssertEqual(effects(attack?.children.first, .summoned).first?.targets.first?.cardId, "EX1_130a")
        XCTAssertEqual(attack?.target?.cardId, "EX1_130a")
    }

    func testSecretPutIntoPlayByAnotherCardIsAnonymousUntilRevealed() {
        startGame(rawTurn: 4, localTurn: false)
        let scientist = card("FP1_004", controller: 2, zone: .graveyard)
        block("TRIGGER", scientist, keyword: "DEATHRATTLE") {
            let secret = card("", controller: 2, zone: .deck, type: .spell)
            secret[.secret] = 1
            zone(secret, .secret)
        }
        let entry = entries.last
        XCTAssertEqual(entry?.type, .deathrattle)
        let secretPlayed = effects(entry, .secretPlayed).first
        XCTAssertNil(secretPlayed?.targets.first?.cardId)
        XCTAssertEqual(secretPlayed?.targets.first?.isSecret, true)

        let secret = entities[secretPlayed?.targets.first?.entityId ?? 0]!
        secret.cardId = "CORE_EX1_610"
        block("TRIGGER", secret, keyword: "SECRET")
        XCTAssertEqual(turns.first?.entries.first?.revealedLater?.cardId, "CORE_EX1_610")
    }

    func testTrackerHiddenAndOverrideHistoryCardsAreAnonymousForTheLocalPlayer() {
        startGame()
        let tracking = card("CORE_DS1_184", controller: 1, zone: .hand, type: .spell)
        let hiddenCard = card("CORE_CS2_029", controller: 1, zone: .deck, type: .spell)
        hiddenCard.info.hidden = true
        let shownCard = card("CORE_CS2_024", controller: 1, zone: .deck, type: .spell)
        block("PLAY", tracking) {
            zone(tracking, .play)
            zone(hiddenCard, .graveyard)
            hideShowEntities = true
            zone(shownCard, .graveyard)
            hideShowEntities = false
        }
        let burned = effects(entries.last, .burned)
        XCTAssertEqual(burned.first?.targets.count, 2)
        XCTAssertEqual(burned.first?.targets.compactMap { $0.cardId }, [])
        XCTAssertEqual(entries.last?.source?.cardId, "CORE_DS1_184")
    }

    func testShuffleIntoLocalDeckIsNamedOnlyFromLocalSources() {
        startGame(rawTurn: 4, localTurn: false)
        let plagueSpell = card("TTN_450", controller: 2, zone: .hand, type: .spell)
        block("PLAY", plagueSpell) {
            zone(plagueSpell, .play)
            fullEntity("TTN_450t", controller: 1, zone: .deck, type: .spell)
        }
        XCTAssertNil(effects(entries.last, .shuffledIntoDeck).first?.targets.first?.cardId)

        startTurn(5, localTurn: true)
        let local = card("CORE_ICC_091", controller: 1, zone: .hand, type: .spell)
        block("PLAY", local) {
            zone(local, .play)
            fullEntity("CORE_ICC_091t", controller: 1, zone: .deck, type: .spell)
        }
        XCTAssertEqual(effects(entries.last, .shuffledIntoDeck).first?.targets.first?.cardId, "CORE_ICC_091t")
    }

    func testOpponentPlayIsNamedWhenItsBlockEnds() {
        startGame(rawTurn: 4, localTurn: false)
        let played = Entity(id: nextEntityId)
        nextEntityId += 1
        played[.controller] = 2
        played[.zone] = Zone.hand.rawValue
        played.info.hidden = true
        entities[played.id] = played

        block("PLAY", played) {
            // SHOW_ENTITY inside the PLAY block
            played.cardId = "CORE_CS2_120"
            played.info.hidden = false
            tag(played, .zone, Zone.play.rawValue, creation: true)
            tag(played, .cardtype, CardType.minion.rawValue, creation: true)
        }
        XCTAssertEqual(entries.last?.source?.cardId, "CORE_CS2_120")
        XCTAssertEqual(entries.last?.source?.side, .opponent)
        XCTAssertEqual(entries.last?.activeSide, .opponent)
        XCTAssertEqual(entries.last?.effects, [])
    }

    func testDontShowInHistoryCardsAreOmitted() {
        startGame()
        let summoner = card("CORE_CS2_222", controller: 1, zone: .hand)
        block("PLAY", summoner) {
            zone(summoner, .play)
            block("POWER", summoner) {
                fullEntity("HIDDEN_TOKEN", controller: 1, zone: .play, extraTags: [(.dont_show_in_history, 1)])
                fullEntity("CS2_101t", controller: 1, zone: .play)
            }
        }
        XCTAssertEqual(effects(entries.last, .summoned).first?.targets.map { $0.cardId }, ["CS2_101t"])
    }

    // MARK: - Turns, lifecycle and gating

    func testTurnSidesAndTheMulliganGate() {
        tag(gameEntity, .turn, 1)
        let coin = card("GAME_005", controller: 1, zone: .hand, type: .spell)
        playerBlock {
            zone(card("CORE_CS2_029", controller: 1, zone: .deck, type: .spell), .hand)
            zone(coin, .deck)
        }
        block("PLAY", coin) {
            zone(coin, .play)
        }
        XCTAssertEqual(turns, [])

        // Start of game effects happen before the mulligan is over
        let starter = card("TIME_875t", controller: 2, zone: .deck)
        block("TRIGGER", starter, keyword: "START_OF_GAME_KEYWORD") {
            fullEntity("CORE_CS2_120", controller: 2, zone: .play)
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.type, .trigger)
        XCTAssertEqual(entries.first?.triggerKeyword, "START_OF_GAME_KEYWORD")

        finishMulligan()
        startTurn(3, localTurn: true)
        XCTAssertEqual(turns.last?.rawTurn, 3)
        XCTAssertEqual(turns.last?.turn, 2)
        XCTAssertEqual(turns.last?.side, .player)
        startTurn(4, localTurn: false)
        XCTAssertEqual(turns.last?.turn, 2)
        XCTAssertEqual(turns.last?.side, .opponent)
        XCTAssertEqual(turns.map { $0.rawTurn }, [1, 3, 4])
    }

    func testParserResetKeepsTurnsAndIgnoresTheCreateGameDump() {
        startGame()
        let minion = card("CORE_CS2_120", controller: 1, zone: .hand)
        block("PLAY", minion) {
            zone(minion, .play)
        }
        XCTAssertEqual(entries.count, 1)

        recorder.parserReset()
        // CREATE_GAME re-dump: creation tags outside any block
        clearGameTags()
        tag(gameEntity, .turn, 3, creation: true)
        tag(localPlayer, .mulligan_state, Mulligan.done.rawValue, creation: true)
        tag(opponent, .mulligan_state, Mulligan.done.rawValue, creation: true)
        tag(localPlayer, .current_player, 1, creation: true)
        fullEntity("CORE_CS2_120", controller: 1, zone: .play)
        fullEntity("CORE_CS2_029", controller: 1, zone: .hand, type: .spell)
        let enemy = fullEntity("CORE_CS2_172", controller: 2, zone: .play)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(turns.last?.header, [])

        let spell = card("CORE_CS2_029", controller: 1, zone: .hand, type: .spell)
        block("PLAY", spell, target: enemy) {
            zone(spell, .play)
            tag(enemy, .damage, 6)
        }
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map { $0.id }).count, 2)
    }

    func testReconnectRestoresTheInterruptedGame() {
        startGame()
        let minion = card("CORE_CS2_120", controller: 1, zone: .hand)
        block("PLAY", minion) {
            zone(minion, .play)
        }
        let before = entries

        recorder.reset(opponentName: "Opponent#1234", now: time)
        XCTAssertEqual(turns, [])
        // The same turn goes on after the reconnect
        clearGameTags()
        startGame()
        let second = card("CORE_CS2_172", controller: 1, zone: .hand)
        block("PLAY", second) {
            zone(second, .play)
        }
        XCTAssertEqual(entries.count, 1)

        XCTAssertTrue(recorder.restoreInterruptedIfReconnect(opponentName: "Opponent#1234", now: time.addingTimeInterval(60)))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(entries.map { $0.type }, [.play, .reconnected, .play])
        XCTAssertEqual(entries.first, before.first)
        XCTAssertEqual(Set(entries.map { $0.id }).count, 3)
        // Restoring is one-shot
        XCTAssertFalse(recorder.restoreInterruptedIfReconnect(opponentName: "Opponent#1234", now: time.addingTimeInterval(60)))

        // A later turn after the reconnect keeps both turns apart
        startTurn(4, localTurn: false)
        XCTAssertEqual(turns.map { $0.rawTurn }, [3, 4])
    }

    func testReconnectRestoresOnlyTheSameRecentUnfinishedGame() {
        func playOneCard() {
            clearGameTags()
            startGame()
            let minion = card("CORE_CS2_120", controller: 1, zone: .hand)
            block("PLAY", minion) {
                zone(minion, .play)
            }
        }

        playOneCard()
        recorder.reset(opponentName: "Opponent#1234", now: time)
        XCTAssertFalse(recorder.restoreInterruptedIfReconnect(opponentName: "Someone#5678", now: time))
        XCTAssertEqual(turns, [])

        playOneCard()
        recorder.reset(opponentName: "Opponent#1234", now: time)
        XCTAssertFalse(recorder.restoreInterruptedIfReconnect(opponentName: "Opponent#1234",
                                                              now: time.addingTimeInterval(ActionHistoryRecorder.reconnectWindow + 1)))

        playOneCard()
        recorder.gameEnded()
        XCTAssertEqual(entries.count, 1, "the history stays on the end screen")
        recorder.reset(opponentName: "Opponent#1234", now: time)
        XCTAssertFalse(recorder.restoreInterruptedIfReconnect(opponentName: "Opponent#1234", now: time))
        XCTAssertEqual(turns, [])

        // A second reset with nothing recorded yet keeps the interrupted game
        playOneCard()
        recorder.reset(opponentName: "Opponent#1234", now: time)
        recorder.reset(opponentName: nil, now: time)
        XCTAssertTrue(recorder.restoreInterruptedIfReconnect(opponentName: "Opponent#1234", now: time))
    }

    func testGameResetMarksTheRewindWithoutRecordingTheRebuiltBoard() {
        startGame()
        let rewinder = card("TIME_000", controller: 1, zone: .hand, type: .spell)
        block("PLAY", rewinder) {
            zone(rewinder, .play)
            block("GAME_RESET", rewinder) {
                fullEntity("CORE_CS2_120", controller: 2, zone: .play)
                block("TRIGGER", card("CORE_CS2_172", controller: 2, zone: .play), keyword: "TAG_NOT_SET") {
                    fullEntity("CORE_CS2_029", controller: 1, zone: .hand, type: .spell)
                }
            }
        }
        let play = entries.last
        XCTAssertEqual(play?.children.map { $0.type }, [.gameReset])
        XCTAssertEqual(play?.children.first?.effects, [])
        XCTAssertEqual(play?.children.first?.children, [])
    }

    func testPublishingIsCoalesced() {
        var calls = 0
        let published = expectation(description: "onChanged")
        published.assertForOverFulfill = false
        recorder.onChanged = {
            XCTAssertTrue(Thread.isMainThread)
            calls += 1
            published.fulfill()
        }
        startGame()
        for _ in 0..<100 {
            let minion = card("CORE_CS2_120", controller: 1, zone: .hand)
            block("PLAY", minion) {
                zone(minion, .play)
            }
        }
        wait(for: [published], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(ActionHistoryRecorder.publishDelay * 2))
        XCTAssertGreaterThanOrEqual(calls, 1)
        XCTAssertLessThanOrEqual(calls, 3)
        XCTAssertEqual(entries.count, 100)
    }

    func testBattlegroundsAndMercenariesAreNotRecorded() {
        for gameType in [GameType.gt_battlegrounds, .gt_battlegrounds_duo, .gt_mercenaries_pvp] {
            recorder = ActionHistoryRecorder()
            recorder.gameTypeProvider = { gameType }
            clearGameTags()
            startGame()
            let minion = card("BG_CS2_120", controller: 1, zone: .hand)
            block("PLAY", minion) {
                zone(minion, .play)
                fullEntity("BG_TOKEN", controller: 1, zone: .play)
            }
            XCTAssertEqual(turns, [], "\(gameType)")
        }

        recorder = ActionHistoryRecorder()
        recorder.gameTypeProvider = { .gt_ranked }
        clearGameTags()
        startGame()
        let minion = card("CORE_CS2_120", controller: 1, zone: .hand)
        block("PLAY", minion) {
            zone(minion, .play)
        }
        XCTAssertEqual(entries.count, 1)
    }

    func testTurnsRecordedBeforeABattlegroundsGameTypeIsKnownAreDropped() {
        var gameType = GameType.gt_unknown
        recorder.gameTypeProvider = { gameType }
        startGame()
        let minion = card("BG_CS2_120", controller: 1, zone: .hand)
        block("PLAY", minion) {
            zone(minion, .play)
        }
        XCTAssertEqual(entries.count, 1)

        gameType = .gt_battlegrounds
        let other = card("BG_CS2_120", controller: 1, zone: .hand)
        block("PLAY", other) {
            zone(other, .play)
        }
        XCTAssertEqual(turns, [])
    }

    func testSnapshotsCanBeTakenWhileTheLogQueueRecords() {
        startGame()
        let cards = (0..<200).map { _ in card("CORE_CS2_120", controller: 1, zone: .hand) }
        let enemy = card("CORE_CS2_172", controller: 2, zone: .play)
        enemy[.health] = 1000
        let done = expectation(description: "recorded")
        DispatchQueue.global(qos: .userInitiated).async {
            for minion in cards {
                self.block("PLAY", minion, target: enemy) {
                    self.zone(minion, .play)
                    self.tag(enemy, .damage, enemy[.damage] + 1)
                }
            }
            done.fulfill()
        }
        var lastCount = 0
        for _ in 0..<200 {
            let count = recorder.snapshot().turns.last?.entries.count ?? 0
            XCTAssertGreaterThanOrEqual(count, lastCount)
            lastCount = count
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(entries.count, 200)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        startGame()
        let minion = card("CORE_CS2_120", controller: 1, zone: .hand)
        let enemy = card("CORE_CS2_172", controller: 2, zone: .play)
        block("PLAY", minion, target: enemy) {
            zone(minion, .play)
            tag(enemy, .damage, 2)
        }
        let snapshot = recorder.snapshot()
        let decoded = try JSONDecoder().decode(ActionHistorySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }
}
