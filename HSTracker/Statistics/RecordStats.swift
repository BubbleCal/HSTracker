//
//  RecordStats.swift
//  HSTracker
//

import Foundation

/// Where a finished game is stored.
enum RecordDestination: Equatable {
    /// The saved deck with this deckId.
    case deck(id: String)
    /// The class's "No deck" bucket (DefaultDeckStats).
    case defaultDeck(CardClass)
    /// Not recorded.
    case none
}

extension StatsHelper {
    /// Modes that never go into the win/loss record: Battlegrounds and Mercenaries
    /// have no win/loss against a class, and a spectated game is not the user's.
    /// Before this guard a Battlegrounds game played with deck detection off landed
    /// in whatever constructed deck was still selected.
    static let recordExcludedModes: Set<GameMode> = [.battlegrounds, .mercenaries, .spectator]

    /// Decides where a finished game is recorded. Mirrors HDT GameEventHandler's
    /// HandleGameEnd: the selected deck when there is one, otherwise the
    /// DefaultDeckStats bucket of the player's class.
    ///
    /// - Parameters:
    ///   - persistedDeckId: deckId of the current deck when it is saved in Realm;
    ///     nil for no deck and for unsaved ones (loaner/template decks, Whizbang,
    ///     Book of Heroes).
    ///   - playerClass: the class the game was played as.
    static func recordDestination(mode: GameMode, isBobEncounter: Bool,
                                  persistedDeckId: String?, playerClass: CardClass) -> RecordDestination {
        if isBobEncounter || recordExcludedModes.contains(mode) {
            return .none
        }
        if let deckId = persistedDeckId {
            return .deck(id: deckId)
        }
        if mode != .none && mode != .all && Cards.classes.contains(playerClass) {
            return .defaultDeck(playerClass)
        }
        return .none
    }

    /// Turn order from the FIRST_PLAYER tag of both player entities: false when the
    /// player went first, true when they had the coin, nil when neither entity says.
    static func coin(playerIsFirst: Bool?, opponentIsFirst: Bool?) -> Bool? {
        if playerIsFirst == true {
            return false
        }
        if opponentIsFirst == true {
            return true
        }
        return nil
    }

    /// Whether a post-game medal read probably still shows the pre-game position, so
    /// it is worth reading again a bit later. Only a win below Legend is certain to
    /// move the player (a loss can stay put on a floor, a draw never moves), so that
    /// is the only case detected besides a failed read.
    static func postGameRankLooksStale(result: GameResult, before: RankSnapshot?,
                                       after: RankSnapshot?) -> Bool {
        guard let before = before else {
            return false
        }
        guard let after = after else {
            return true
        }
        return result == .win && !before.isLegend
            && after.starLevel == before.starLevel && after.stars == before.stars
    }
}
