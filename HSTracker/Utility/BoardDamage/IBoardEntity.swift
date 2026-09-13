//
//  IBoardEntity.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/06/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

/// A character on the board with the face damage it contributes to the board damage counters.
/// The turn state is resolved when it is built, since a BoardState is a snapshot of one refresh.
protocol IBoardEntity {
    var cardId: String { get }
    /// Damage to the enemy hero this character can still deal during the current turn
    var damageNow: Int { get }
    var hasInfiniteDamageNow: Bool { get }
    /// Damage to the enemy hero this character could deal on its controller's next own turn,
    /// if nothing changes before then
    var damageNextTurn: Int { get }
    var hasInfiniteDamageNextTurn: Bool { get }
}
