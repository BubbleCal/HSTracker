//
//  TimethiefRafaam.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

/// Timethief Rafaam wins the game once the nine other Rafaams it puts in the deck have all been
/// played, so hovering it lights up the ones still in the deck - the ones left to play. HDT has no
/// highlight for it; Tiny Rafaam and Explorer Rafaam, which draw and discover Rafaams, do.
class TimethiefRafaam: ICardWithHighlight {
    func getCardId() -> String {
        CardIds.Collectible.Warlock.TimethiefRafaam
    }

    func shouldHighlight(card: Card, deck: [Card]) -> HighlightColor {
        HighlightColorHelper.getHighlightColor(TimethiefRafaam.otherRafaams.contains(card.id))
    }

    static let otherRafaams: [String] = [
        CardIds.NonCollectible.Warlock.TimethiefRafaam_TinyRafaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_GreenRafaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_MurlocRafaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_ExplorerRafaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_WarchiefRafaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_CalamitousRafaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_MindflayerRfaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_GiantRafaamToken,
        CardIds.NonCollectible.Warlock.TimethiefRafaam_ArchmageRafaamToken
    ]

    required init() {}
}
