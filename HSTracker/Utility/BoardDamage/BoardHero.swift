//
//  BoardHero.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/06/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

/// The hero and its weapon. The weapon is never counted on its own: hero ATK already includes it on
/// the current turn, and it is the only Attack that survives to the next turn.
class BoardHero: IBoardEntity {
    let cardId: String
    let weaponCardId: String?
    /// Total health, including armor
    let health: Int

    /// The hero could still swing this turn if it had Attack (used for Shapeshift-style hero powers)
    private(set) var canAttackNow = false
    /// The hero will be able to swing on its next turn if it has Attack then
    private(set) var canAttackNextTurn = false

    private(set) var damageNow = 0
    private(set) var hasInfiniteDamageNow = false
    private(set) var damageNextTurn = 0
    private(set) var hasInfiniteDamageNextTurn = false

    var hasWeapon: Bool { return weaponCardId != nil }

    init(hero: Entity, weapon: Entity?, isCurrent: Bool, isActing: Bool) {
        cardId = hero.cardId
        weaponCardId = weapon?.cardId
        health = hero[.health] + hero[.armor] - hero[.damage]

        let (heroAttack, heroInfinite) = BoardCard.attack(of: hero)
        let heroOwnPerTurn = BoardCard.attacksPerTurn(of: hero)
        let weaponPerTurn = weapon.map { BoardCard.attacksPerTurn(of: $0) } ?? 1
        let heroPerTurn = max(heroOwnPerTurn, weaponPerTurn >= 2 ? 2 : 1)
        let attacksThisTurn = BoardCard.attacksUsed(by: hero)
        let remaining = max(heroPerTurn - attacksThisTurn, 0)
        let cantAttack = BoardCard.cantAttackHeroes(hero)
        // NUM_TURNS_IN_PLAY does not matter for heroes; EXHAUSTED is set after their last attack.
        canAttackNow = isActing && !cantAttack && hero[.frozen] != 1 && hero[.exhausted] != 1 && remaining > 0
        canAttackNextTurn = !cantAttack
            && !BoardCard.isFrozenThroughNextTurn(hero, attacksPerTurn: heroPerTurn, isCurrent: isCurrent)

        if canAttackNow && (heroAttack > 0 || heroInfinite) {
            if heroInfinite {
                hasInfiniteDamageNow = true
            } else if let weapon = weapon {
                // Hero ATK includes the weapon plus any temporary buffs, and swings beyond the weapon's
                // durability lose the weapon's Attack. A windfury weapon copies WINDFURY onto the hero
                // and takes it away again when it breaks, so the hero's own Windfury can't be told
                // apart then and there are no swings after the break. With a plain weapon, the extra
                // swings come from the hero's own Windfury. This reproduces HDT's
                // BoardHero.AttackWithWeapon expectations.
                let durability = max(weapon[.health] - weapon[.damage], 0)
                let weaponAttack = BoardCard.attack(of: weapon).attack
                let withWeapon = min(remaining, durability)
                let withoutWeapon = weaponPerTurn >= 2 ? 0 : remaining - withWeapon
                damageNow = withWeapon * heroAttack + withoutWeapon * max(heroAttack - weaponAttack, 0)
            } else {
                damageNow = remaining * heroAttack
            }
        }

        // Hero ATK drops to 0 when the weapon is sheathed at the end of the controller's turn, and
        // temporary buffs expire then, so next turn only the weapon counts. The weapon's EXHAUSTED only
        // means sheathed.
        if let weapon = weapon, canAttackNextTurn {
            let (weaponAttack, weaponInfinite) = BoardCard.attack(of: weapon)
            let durability = max(weapon[.health] - weapon[.damage], 0)
            var perNextTurn = 1
            if weaponPerTurn >= 2 {
                perNextTurn = weaponPerTurn
            } else if !isCurrent && heroOwnPerTurn >= 2 {
                // On the side not on turn the hero's own Windfury already outlived an end of turn;
                // on the current side it may be a "this turn" effect.
                perNextTurn = heroOwnPerTurn
            }
            let swings = min(perNextTurn, durability)
            if swings > 0 {
                if weaponInfinite {
                    hasInfiniteDamageNextTurn = true
                } else {
                    damageNextTurn = swings * weaponAttack
                }
            }
        }
    }
}
