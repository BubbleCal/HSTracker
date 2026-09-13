//
//  BoardCard.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/06/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

/// A minion in play. Mirrors HDT's BoardCard, split into what it can still do this turn and what it
/// could do on its controller's next turn.
class BoardCard: IBoardEntity {
    /// ATK value the game uses for "infinite" Attack
    static let infiniteAttack = 2147483647

    let cardId: String
    /// ATK, 0 under HIDE_STATS or when infinite
    let attack: Int
    let hasInfiniteAttack: Bool
    let attacksPerTurn: Int
    /// Attacks this turn that used up the minion's own attacks, leaving out forced ones
    let attacksThisTurn: Int
    let exhausted: Bool
    let frozen: Bool
    let charge: Bool
    let rush: Bool
    let turnsInPlay: Int
    /// Excluded from both numbers whatever the turn: can't attack (heroes), dormant, a titan with
    /// abilities left, or no Attack
    let neverAttacksFace: Bool

    private(set) var damageNow = 0
    private(set) var hasInfiniteDamageNow = false
    private(set) var damageNextTurn = 0
    private(set) var hasInfiniteDamageNextTurn = false

    /// - Parameters:
    ///   - isCurrent: the controller has CURRENT_PLAYER
    ///   - isActing: the controller is current and in a step where attacks can happen
    init(entity: Entity, isCurrent: Bool, isActing: Bool) {
        cardId = entity.cardId
        (attack, hasInfiniteAttack) = BoardCard.attack(of: entity)
        attacksPerTurn = BoardCard.attacksPerTurn(of: entity)
        attacksThisTurn = BoardCard.attacksUsed(by: entity)
        exhausted = entity[.exhausted] == 1
        frozen = entity[.frozen] == 1
        charge = entity[.charge] == 1
        rush = entity[.rush] == 1
        turnsInPlay = entity[.num_turns_in_play]
        neverAttacksFace = BoardCard.cantAttackHeroes(entity)
            || entity[.dormant] == 1
            || BoardCard.isLockedTitan(entity)
            || (attack <= 0 && !hasInfiniteAttack)

        if neverAttacksFace {
            return
        }

        let remaining = max(attacksPerTurn - attacksThisTurn, 0)
        // A Rush minion that arrived this turn comes in with EXHAUSTED=0 but can't hit heroes, so its
        // turns in play are what leave it out. That check is for Rush only: a minion transformed on its
        // controller's turn also restarts at NUM_TURNS_IN_PLAY=0, yet keeps the old minion's
        // EXHAUSTED=0 and can still attack. Real summoning sickness is EXHAUSTED=1 on arrival, which
        // Charge given later (without attacking) lifts; EXHAUSTED=1 is also set after the last attack.
        // HDT's Exhausted rule treats every NUM_TURNS_IN_PLAY=0 minion as summoning sick.
        let rushArrival = turnsInPlay == 0 && rush && !charge
        let outOfAttacks = exhausted && !(charge && attacksThisTurn == 0)
        if isActing && !frozen && remaining > 0 && !rushArrival && !outOfAttacks {
            if hasInfiniteAttack {
                hasInfiniteDamageNow = true
            } else {
                damageNow = remaining * attack
            }
        }

        // By the controller's next MAIN_READY every minion is unexhausted with its attacks reset, so
        // the turn tags don't matter, except for predicting whether a frozen one thaws first.
        if !BoardCard.isFrozenThroughNextTurn(entity, attacksPerTurn: attacksPerTurn, isCurrent: isCurrent) {
            if hasInfiniteAttack {
                hasInfiniteDamageNextTurn = true
            } else {
                damageNextTurn = attacksPerTurn * attack
            }
        }
    }

    /// ATK and whether it is infinite. HIDE_STATS hides a real value behind 0.
    static func attack(of entity: Entity) -> (attack: Int, infinite: Bool) {
        let atk = entity.has(tag: .hide_stats) ? 0 : entity[.atk]
        if atk == infiniteAttack {
            return (0, true)
        }
        return (atk, false)
    }

    /// NUM_ATTACKS_THIS_TURN less the attacks an effect forced, which the game counts in both
    /// NUM_ATTACKS_THIS_TURN and EXTRA_ATTACKS_THIS_TURN and which leave the minion's own attacks
    /// available (HDT ignores EXTRA_ATTACKS_THIS_TURN).
    static func attacksUsed(by entity: Entity) -> Int {
        return max(entity[.num_attacks_this_turn] - entity[.extra_attacks_this_turn], 0)
    }

    /// Mega-Windfury is 4 attacks unless silenced, which leaves the plain WINDFURY behind.
    static func attacksPerTurn(of entity: Entity) -> Int {
        if (entity[.mega_windfury] == 1 || entity[.windfury] == 3) && entity[.silenced] != 1 {
            return 4
        }
        return entity[.windfury] >= 1 ? 2 : 1
    }

    static func cantAttackHeroes(_ entity: Entity) -> Bool {
        return entity[.cant_attack] == 1 || entity[.cannot_attack_heroes] == 1
    }

    /// A titan can't attack until its three abilities are used
    static func isLockedTitan(_ entity: Entity) -> Bool {
        if entity[.titan] != 1 {
            return false
        }
        let used = [GameTag.titan_ability_used_1, .titan_ability_used_2, .titan_ability_used_3]
            .filter { entity[$0] == 1 }.count
        return used < 3
    }

    /// Whether a frozen character is still frozen on its controller's next own turn. FROZEN is cleared
    /// at MAIN_CLEANUP of the controller's turn, but only for a character that still had an attack
    /// left then. So on the side not on turn the thaw has already passed; on the current side it
    /// thaws tonight only if it is not exhausted and has attacks left.
    static func isFrozenThroughNextTurn(_ entity: Entity, attacksPerTurn: Int, isCurrent: Bool) -> Bool {
        if entity[.frozen] != 1 {
            return false
        }
        if !isCurrent {
            return true
        }
        let canStillAttack = entity[.exhausted] == 0 && attacksUsed(by: entity) < attacksPerTurn
        return !canStillAttack
    }
}
