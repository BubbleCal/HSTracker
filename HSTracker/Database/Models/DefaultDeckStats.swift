//
//  DefaultDeckStats.swift
//  HSTracker
//

import Foundation
import RealmSwift

/// The "No deck – <class>" bucket for games played without a saved deck: no deck
/// selected, deck detection failing, a loaner or template deck, Whizbang, Book of
/// Heroes, or the games of a deleted deck. Mirrors HDT's Stats/DefaultDeckStats.cs,
/// where GameEventHandler files such games under the player's class instead of
/// dropping them.
///
/// It is a separate class rather than a hidden Deck so it can never show up in the
/// deck list, the Decks menu or deck auto-detection.
class DefaultDeckStats: Object {
    @objc dynamic var playerClassRaw = CardClass.neutral.rawValue
    let gameStats = List<GameStats>()

    var playerClass: CardClass {
        return CardClass(rawValue: playerClassRaw) ?? .neutral
    }

    override static func primaryKey() -> String? {
        return "playerClassRaw"
    }
}
