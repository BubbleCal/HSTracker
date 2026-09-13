//
//  Secret.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/03/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation
import RealmSwift

enum SecretError: Error {
    case entityIsNotSecret(entity: Entity)
    case entityHasNoClass(entity: Entity)
    case entityHasInvalidClass(entity: Entity)
}

// Why a candidate was ruled out for a secret. Every case describes something the player did or
// saw on the board, never anything about the hidden secret, so it is safe to show.
enum SecretExclusionReason: String, CaseIterable {
    case attackedHero, attackedMinion, minionAttacked, minionPlayed, spellCast, weaponPlayed,
         threeCardsPlayed, cardFromThisTurnPlayed, enemyMinionDied, secondEnemyMinionDied,
         enemyHeroDamaged, enemyHeroNotDamaged, minionDealtThreeDamage, secondCardDrawn,
         heroPowerUsed, turnEndedNoMana, allManaSpent, cardsPlayedInTurn, turnEndedWithMinion,
         opponentTurnStarted, copyRevealed

    var localizationKey: String {
        return "SecretReason_" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    // A deduction from what happened in the game, which Gray out secrets controls. A revealed copy
    // is a game rule, and an exclusion without a reason is a manual one.
    static func isAutomatic(_ reason: SecretExclusionReason?) -> Bool {
        return reason != nil && reason != .copyRevealed
    }
}

struct SecretExclusion {
    // nil for exclusions made through the reason-less HDT-style signatures
    let reason: SecretExclusionReason?
    let turn: Int
}

struct SecretExclusionEvent {
    let secretEntityId: Int
    let cardId: String
    let exclusion: SecretExclusion
    // true when a previous exclusion was taken back
    let included: Bool
}

class Secret {

    private(set) var entity: Entity
    // Order in which the secrets entered play. Entity ids do not give it: deck cards get low ids at
    // game start and created cards high ones.
    let entryOrder: Int

    // The parser thread writes these while the main thread builds the secret list from them.
    private let lock = UnfairLock()
    private var _excluded: [MultiIdCard: Bool] = [:]
    private var _exclusions: [MultiIdCard: SecretExclusion] = [:]

    // Snapshot copies, so callers can iterate while the parser keeps excluding
    var excluded: [MultiIdCard: Bool] {
        return lock.around { _excluded }
    }

    var exclusions: [MultiIdCard: SecretExclusion] {
        return lock.around { _exclusions }
    }

    // Both, taken together, so a candidate excluded or included in between cannot mismatch
    var state: (excluded: [MultiIdCard: Bool], exclusions: [MultiIdCard: SecretExclusion]) {
        return lock.around { (_excluded, _exclusions) }
    }

    init(entity: Entity, entryOrder: Int = 0) throws {
        guard entity.isSecret else { throw SecretError.entityIsNotSecret(entity: entity) }
        guard entity.has(tag: .class) else { throw SecretError.entityHasNoClass(entity: entity) }
        guard let tagClass = TagClass(rawValue: entity[.class]) else {
            throw SecretError.entityHasInvalidClass(entity: entity)
        }
        self.entity = entity
        self.entryOrder = entryOrder
        self._excluded = Secret.getAllSecrets(for: tagClass)
            .reduce([MultiIdCard: Bool]()) { dict, act in
                var ret = dict
                ret[act] = false
                return ret
        }
    }

    // Returns true only when the candidate was possible before, so callers can report each
    // exclusion once. The first reason is kept, unless a revealed copy or a manual exclusion comes
    // after a deduction: those still hold with Gray out secrets off.
    @discardableResult
    func exclude(cardId: MultiIdCard, reason: SecretExclusionReason? = nil, turn: Int = 0) -> Bool {
        // A locked secret cannot trigger, so a condition met meanwhile says nothing about it
        if entity.has(tag: .secret_locked) {
            return false
        }
        return lock.around {
            guard let isExcluded = _excluded[cardId] else { return false }
            if isExcluded {
                if SecretExclusionReason.isAutomatic(_exclusions[cardId]?.reason) && !SecretExclusionReason.isAutomatic(reason) {
                    _exclusions[cardId] = SecretExclusion(reason: reason, turn: turn)
                }
                return false
            }
            _excluded[cardId] = true
            _exclusions[cardId] = SecretExclusion(reason: reason, turn: turn)
            return true
        }
    }

    func isExcluded(cardId: MultiIdCard) -> Bool {
        return lock.around { _excluded[cardId] ?? false }
    }

    func exclusion(for cardId: MultiIdCard) -> SecretExclusion? {
        return lock.around { _exclusions[cardId] }
    }

    // Returns the exclusion that was taken back, if the candidate was excluded.
    @discardableResult
    func include(cardId: MultiIdCard) -> SecretExclusion? {
        return lock.around {
            guard _excluded[cardId] == true else { return nil }
            _excluded[cardId] = false
            return _exclusions.removeValue(forKey: cardId) ?? SecretExclusion(reason: nil, turn: 0)
        }
    }

    private static func getAllSecrets(for heroClass: TagClass) -> [MultiIdCard] {
        switch heroClass {
        case .hunter: return CardIds.Secrets.Hunter.All
        case .mage: return CardIds.Secrets.Mage.All
        case .paladin: return CardIds.Secrets.Paladin.All
        case .rogue: return CardIds.Secrets.Rogue.All
        default: return []
        }
    }
}

extension Secret: Equatable {
    static func == (lhs: Secret, rhs: Secret) -> Bool {
        return lhs.entity.id == rhs.entity.id
    }
}
