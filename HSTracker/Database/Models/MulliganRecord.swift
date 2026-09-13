//
//  MulliganRecord.swift
//  HSTracker
//

import Foundation
import RealmSwift

/// Why a game's mulligan record cannot be trusted. Statistics built from the records
/// should skip every game whose status is not `.complete`.
enum MulliganRecordStatus: String {
    case complete
    /// Hearthstone reconnected to the game (MulliganManager.HandleGameStart with
    /// IsPastBeginPhase()=True), so the log after the reconnect starts from a state
    /// dump and whatever was captured before it may be partial.
    case reconnected
    /// The local player's id was never known, so the captured choices cannot be told
    /// apart from the opponent's.
    case unknownPlayer
    /// No mulligan choice was seen for the local player: HSTracker was started after the
    /// mulligan with the log already truncated, or the choice lines were missing.
    case noMulliganOffer
    /// The game ended before the local player's MULLIGAN_STATE reached DONE, e.g. a
    /// concede while the mulligan was still open.
    case mulliganUnfinished
    /// A card of the opening hand had no card id when the mulligan finished.
    case unknownCards
    /// The hand after the mulligan does not add up: the replacements do not match the
    /// replaced cards, or a card the server reported as kept had left the hand.
    case inconsistent
}

/// The local player's mulligan and draws in one constructed game, kept with its
/// GameStats so that keep rates, opening-hand and drawn win rates can be computed
/// later from the player's own games alone. It holds card ids only - the result,
/// turn order, opponent class, turns, format, game type and class are the parent
/// GameStats' fields and are deliberately not repeated here.
///
/// HDT has no local counterpart; the same tuple is what its GameV2 sends HSReplay as
/// mulligan feedback (offered, kept and final cards in hand).
///
/// When adding a persisted property, also copy it in `detachedCopy()`.
class MulliganRecord: EmbeddedObject {
    /// Bumped whenever the capture starts storing something older records lack, or
    /// changes the meaning of a field.
    /// 1: first version.
    static let currentVersion = 1

    /// Draws past this many are not stored; `drawsTruncated` says so. A deck has at
    /// most 40 cards, and draw win rates only look at the first turns anyway.
    static let drawLimit = 40

    @objc dynamic var version = 0

    @objc private dynamic var _status = MulliganRecordStatus.complete.rawValue
    var status: MulliganRecordStatus {
        get { return MulliganRecordStatus(rawValue: _status) ?? .inconsistent }
        set { _status = newValue.rawValue }
    }

    var isComplete: Bool {
        return status == .complete
    }

    /// Deck.deckId of the saved deck the game was recorded in, empty for games in a
    /// "No deck" bucket. Unlike the owning Deck it survives the game being moved to
    /// that bucket when the deck is deleted.
    @objc dynamic var deckId = ""

    /// The deck as it was played, so a game stays interpretable after the saved deck
    /// is edited. Empty when there was no deck or it could not be serialized, in which
    /// case `deckCards` holds the list instead when one was known.
    @objc dynamic var deckstring = ""
    let deckCards = List<RealmCard>()

    /// The opening hand as offered, in offer order (zone position), without The Coin.
    let offered = List<MulliganOfferedCard>()
    /// Cards drawn from the deck to replace the mulliganed ones, in hand order.
    let replacementCardIds = List<String>()
    /// The hand once the local player's mulligan was done, in zone order, without The
    /// Coin: the kept cards, the replacements and anything else put there meanwhile.
    let finalHandCardIds = List<String>()
    /// Cards of the original deck drawn after the mulligan, in draw order, at most
    /// `drawLimit` of them.
    let draws = List<MulliganDrawnCard>()
    @objc dynamic var drawsTruncated = false

    var keptCardIds: [String] {
        return offered.filter { $0.kept }.map { $0.cardId }
    }

    var mulliganedCardIds: [String] {
        return offered.filter { !$0.kept }.map { $0.cardId }
    }

    /// Opening-hand win rate counts these: every card still in hand after the
    /// mulligan that was kept or came as a replacement (HSReplay's "Mulligan WR").
    var openingHandCardIds: [String] {
        return keptCardIds + Array(replacementCardIds)
    }

    func detachedCopy() -> MulliganRecord {
        let copy = MulliganRecord()
        copy.version = version
        copy._status = _status
        copy.deckId = deckId
        copy.deckstring = deckstring
        for card in deckCards {
            copy.deckCards.append(RealmCard(id: card.id, count: card.count))
        }
        for card in offered {
            copy.offered.append(MulliganOfferedCard(cardId: card.cardId, kept: card.kept, forced: card.forced))
        }
        copy.replacementCardIds.append(objectsIn: replacementCardIds)
        copy.finalHandCardIds.append(objectsIn: finalHandCardIds)
        for draw in draws {
            copy.draws.append(MulliganDrawnCard(cardId: draw.cardId, turn: draw.turn))
        }
        copy.drawsTruncated = drawsTruncated
        return copy
    }
}

class MulliganOfferedCard: EmbeddedObject {
    @objc dynamic var cardId = ""
    /// Still in hand when the mulligan was done. Forced cards are always kept.
    @objc dynamic var kept = false
    /// The player had no say in keeping it: a quest or questline, which the game puts
    /// in the opening hand, a card created there before the mulligan, or any card the
    /// server left in hand without it being among the chosen ones. Keep rates should
    /// leave these out.
    @objc dynamic var forced = false

    convenience init(cardId: String, kept: Bool, forced: Bool) {
        self.init()
        self.cardId = cardId
        self.kept = kept
        self.forced = forced
    }
}

class MulliganDrawnCard: EmbeddedObject {
    @objc dynamic var cardId = ""
    /// The player's turn as the tracker counts it, (TURN + 1) / 2 of the game entity:
    /// 1 is either player's first turn, so "drawn by turn N" is `turn <= N` whether
    /// the player went first or had the coin. 0 for a draw before the first turn.
    @objc dynamic var turn = 0

    convenience init(cardId: String, turn: Int) {
        self.init()
        self.cardId = cardId
        self.turn = turn
    }
}
