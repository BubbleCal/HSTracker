//
//  PlayerBoard.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/06/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

/// One side's board damage: what it can still deal to the enemy hero this turn (damageNow) and what
/// its board could deal on its next own turn if nothing changes (damageNextTurn).
class PlayerBoard {
    /// Minions, then the hero
    private(set) var cards: [IBoardEntity] = []
    private(set) var hero: BoardHero?
    private(set) var heroPower: HeroPower?
    let isCurrent: Bool
    let isActing: Bool

    private(set) var heroPowerDamageNow = 0
    private(set) var heroPowerDamageNextTurn = 0

    var damageNow: Int {
        return cards.map { $0.damageNow }.reduce(heroPowerDamageNow, +)
    }

    var damageNextTurn: Int {
        return cards.map { $0.damageNextTurn }.reduce(heroPowerDamageNextTurn, +)
    }

    var hasInfiniteDamageNow: Bool {
        return cards.any { $0.hasInfiniteDamageNow }
    }

    var hasInfiniteDamageNextTurn: Bool {
        return cards.any { $0.hasInfiniteDamageNextTurn }
    }

    /// - Parameters:
    ///   - list: the side's entities in play
    ///   - isCurrent: the side has CURRENT_PLAYER
    ///   - isActing: the side is current and in a step where it can still attack
    ///   - playerEntity: the side's player entity, for the mana the hero power needs this turn
    init(list: [Entity], isCurrent: Bool, isActing: Bool, playerEntity: Entity? = nil) {
        self.isCurrent = isCurrent
        self.isActing = isActing

        let inPlay = list.filter { $0.isInPlay }
        let weapon = getWeapon(list: inPlay)

        for minion in inPlay where minion.isMinion {
            cards.append(BoardCard(entity: minion, isCurrent: isCurrent, isActing: isActing))
        }
        if let heroEntity = inPlay.filter({ $0.isHero }).min(by: { $0.id < $1.id }) {
            let hero = BoardHero(hero: heroEntity, weapon: weapon, isCurrent: isCurrent, isActing: isActing)
            self.hero = hero
            cards.append(hero)
        }
        if let heroPowerEntity = inPlay.filter({ $0.isHeroPower }).last {
            let heroPower = HeroPower(entity: heroPowerEntity)
            self.heroPower = heroPower
            computeHeroPowerDamage(heroPower: heroPower, playerEntity: playerEntity)
        }
    }

    func getWeapon(list: [Entity]) -> Entity? {
        let weapons = list.filter { $0.isWeapon }
        if weapons.count <= 1 {
            return weapons.first
        }
        // Two weapons in play for a moment while one replaces the other: the new one is JUST_PLAYED.
        // HDT gives up when none is; the newest id is the likelier survivor.
        return weapons.first { $0[.just_played] == 1 } ?? weapons.max { $0.id < $1.id }
    }

    /// The hero power's damage keeps what HSTracker always added on top of the board (HDT counts
    /// none), now gated by whether it can still be used this turn.
    private func computeHeroPowerDamage(heroPower: HeroPower, playerEntity: Entity?) {
        let entity = heroPower._entity
        let damage = heroPower.damage
        if damage <= 0 || entity[.hero_power_disabled] == 1 {
            return
        }
        // Garrison Commander allows a second use each turn
        let usesPerTurn = cards.any { $0.cardId == CardIds.Collectible.Neutral.GarrisonCommander } ? 2 : 1

        if isActing && (!heroPower.isHeroAttack || hero?.canAttackNow == true) {
            // The game sets EXHAUSTED once no activation is left this turn
            var uses = entity[.exhausted] == 1 ? 0
                : max(usesPerTurn - entity[.heropower_activations_this_turn], 0)
            if heroPower.cost > 0 {
                let mana = playerEntity.map {
                    $0[.resources] + $0[.temp_resources] - $0[.resources_used]
                } ?? 0
                uses = min(uses, max(mana, 0) / heroPower.cost)
            }
            heroPowerDamageNow = uses * damage
        }

        // Next turn's mana is assumed to be enough
        if !heroPower.isHeroAttack || hero?.canAttackNextTurn == true {
            heroPowerDamageNextTurn = usesPerTurn * damage
        }
    }
}
