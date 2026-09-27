//
//  PlayerBoard.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/06/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

/// One side's board damage: what it can still deal to the enemy hero this turn (damageNow) and what
/// its board could deal on its next own turn if nothing changes (damageNextTurn). Like HDT, only the
/// Attack of the minions and the hero (with its weapon) counts, never the hero power.
class PlayerBoard {
    /// Minions, then the hero
    let cards: [IBoardEntity]
    let hero: BoardHero?
    let isCurrent: Bool
    let isActing: Bool

    let damageNow: Int
    let damageNextTurn: Int
    let hasInfiniteDamageNow: Bool
    let hasInfiniteDamageNextTurn: Bool

    /// - Parameters:
    ///   - list: the side's entities in play
    ///   - isCurrent: the side has CURRENT_PLAYER
    ///   - isActing: the side is current and in a step where it can still attack
    init(list: [Entity], isCurrent: Bool, isActing: Bool) {
        self.isCurrent = isCurrent
        self.isActing = isActing

        let inPlay = list.filter { $0.isInPlay }
        var cards: [IBoardEntity] = inPlay.filter { $0.isMinion }.map {
            BoardCard(entity: $0, isCurrent: isCurrent, isActing: isActing)
        }
        var hero: BoardHero?
        if let heroEntity = inPlay.filter({ $0.isHero }).min(by: { $0.id < $1.id }) {
            let boardHero = BoardHero(hero: heroEntity, weapon: PlayerBoard.getWeapon(list: inPlay),
                                      isCurrent: isCurrent, isActing: isActing)
            hero = boardHero
            cards.append(boardHero)
        }
        self.cards = cards
        self.hero = hero
        damageNow = cards.reduce(0) { $0 + $1.damageNow }
        damageNextTurn = cards.reduce(0) { $0 + $1.damageNextTurn }
        hasInfiniteDamageNow = cards.contains { $0.hasInfiniteDamageNow }
        hasInfiniteDamageNextTurn = cards.contains { $0.hasInfiniteDamageNextTurn }
    }

    static func getWeapon(list: [Entity]) -> Entity? {
        let weapons = list.filter { $0.isWeapon }
        if weapons.count <= 1 {
            return weapons.first
        }
        // Two weapons in play for a moment while one replaces the other: the new one is JUST_PLAYED.
        // HDT gives up when none is; the newest id is the likelier survivor.
        return weapons.first { $0[.just_played] == 1 } ?? weapons.max { $0.id < $1.id }
    }
}
