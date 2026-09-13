//
//  ActionHistoryPresentation.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

// Turns the recorder's snapshot into what the action history panel prints: turn titles, verbs, card
// names, effect lines and the per-row summary. Kept apart from the SwiftUI views and free of the
// macOS 10.15 gate so the wording and the grouping rules can be unit tested without rendering.
//
// Names come only from what the snapshot carries. A ref without a cardId was not public when it was
// recorded (see ActionHistoryVisibility), so it is printed as "a card" / "a Secret" and never looked
// up by entity id, which would reveal what HSTracker merely predicted.

/// A turn as the panel lists it, newest first.
struct ActionHistoryTurnSection: Equatable {
    // Stays the same across snapshots, so a turn the player folded stays folded. A GAME_RESET rewind
    // can record the same raw turn twice, hence the occurrence count.
    let key: String
    let turn: HistoryTurn
    // Position among the turns, oldest first
    let index: Int
}

/// One line under an expanded entry or a turn title, such as "3 damage  Ragnaros".
struct ActionHistoryEffectLine: Equatable {
    enum Tone: Equatable {
        case damage
        case heal
        case death
        case neutral
    }

    let id: String
    let label: String
    let tone: Tone
    // Printed after the label. Two cards are a transform: the card before and the card it became.
    let cards: [HistoryCardRef]
}

/// The totals shown at the end of a collapsed row, taken over the entry and its sub-actions.
struct ActionHistorySummary: Equatable {
    var damage = 0
    var heal = 0
    var deaths = 0

    var isEmpty: Bool {
        return damage == 0 && heal == 0 && deaths == 0
    }
}

enum ActionHistoryPresentation {
    // MARK: - Turns

    static func sections(_ turns: [HistoryTurn]) -> [ActionHistoryTurnSection] {
        var occurrences: [Int: Int] = [:]
        var sections: [ActionHistoryTurnSection] = []
        sections.reserveCapacity(turns.count)
        for (index, turn) in turns.enumerated() {
            let occurrence = occurrences[turn.rawTurn, default: 0]
            occurrences[turn.rawTurn] = occurrence + 1
            sections.append(ActionHistoryTurnSection(key: "\(turn.rawTurn).\(occurrence)", turn: turn, index: index))
        }
        // The panel cannot scroll to the bottom on macOS 10.15 (no ScrollViewReader), so the turn
        // being played goes first
        return sections.reversed()
    }

    static func turnTitle(_ turn: HistoryTurn) -> String {
        guard turn.turn > 0 else {
            return localized("ActionHistory_StartOfGame")
        }
        switch turn.side {
        case .player:
            return String(format: localized("ActionHistory_TurnPlayer"), turn.turn)
        case .opponent:
            return String(format: localized("ActionHistory_TurnOpponent"), turn.turn)
        case .neutral:
            return localized("ActionHistory_StartOfGame")
        }
    }

    // MARK: - Entries

    static func verb(_ type: HistoryActionType) -> String {
        switch type {
        case .play: return localized("ActionHistory_Play")
        case .heroPower: return localized("ActionHistory_HeroPower")
        case .useLocation: return localized("ActionHistory_UseLocation")
        case .attack: return localized("ActionHistory_Attack")
        case .trade: return localized("ActionHistory_Trade")
        case .deckAction: return localized("ActionHistory_DeckAction")
        case .power: return localized("ActionHistory_Power")
        case .trigger: return localized("ActionHistory_Trigger")
        case .secret: return localized("ActionHistory_Secret")
        case .deathrattle: return localized("ActionHistory_Deathrattle")
        case .fatigue: return localized("ActionHistory_Fatigue")
        case .reveal: return localized("ActionHistory_Reveal")
        case .turnStart: return localized("ActionHistory_TurnStart")
        case .deaths: return localized("ActionHistory_Deaths")
        case .gameReset: return localized("ActionHistory_GameReset")
        case .reconnected: return localized("ActionHistory_Reconnected")
        }
    }

    /// Whether clicking the row has anything to unfold.
    static func hasDetails(_ entry: HistoryEntry) -> Bool {
        return !entry.effects.isEmpty || !entry.children.isEmpty || entry.weapon != nil
    }

    /// Sub-actions in the order they resolved. The panel indents one level only, so a trigger inside
    /// a trigger is listed right after its parent instead of further in.
    static func flattenedChildren(_ entry: HistoryEntry) -> [HistoryEntry] {
        var result: [HistoryEntry] = []
        func visit(_ children: [HistoryEntry]) {
            for child in children {
                var flat = child
                flat.children = []
                result.append(flat)
                visit(child.children)
            }
        }
        visit(entry.children)
        return result
    }

    static func summary(_ entry: HistoryEntry) -> ActionHistorySummary {
        var summary = ActionHistorySummary()
        func add(_ entry: HistoryEntry) {
            for effect in entry.effects {
                switch effect.kind {
                case .damage:
                    summary.damage += (effect.amount ?? 0) * effect.targets.count
                case .heal:
                    summary.heal += (effect.amount ?? 0) * effect.targets.count
                case .died, .destroyed:
                    summary.deaths += effect.targets.count
                default:
                    break
                }
            }
            entry.children.forEach(add)
        }
        add(entry)
        return summary
    }

    static func deathsText(_ count: Int) -> String {
        return String(format: localized("ActionHistory_SummaryDeaths"), count)
    }

    // MARK: - Cards

    static func name(_ ref: HistoryCardRef) -> String {
        guard let cardId = ref.cardId else {
            return localized(ref.isSecret ? "ActionHistory_UnknownSecret" : "ActionHistory_UnknownCard")
        }
        return cardName(cardId)
    }

    // Read straight from the index: Cards.by(cardId:) skips hero powers and hero skins, which are
    // exactly the sources and targets of hero power rows and hero attacks, and copies the card.
    static func cardName(_ cardId: String) -> String {
        if let name = Cards.cardsById[cardId]?.name, !name.isBlank {
            return name
        }
        return cardId
    }

    // MARK: - Effects

    static func lines(_ effects: [HistoryEffect], idPrefix: String) -> [ActionHistoryEffectLine] {
        var lines: [ActionHistoryEffectLine] = []
        for (effectIndex, effect) in effects.enumerated() {
            let prefix = "\(idPrefix)/\(effectIndex)"
            switch effect.kind {
            case .drewUnknown:
                // The client shows only that cards were drawn
                lines.append(ActionHistoryEffectLine(id: prefix, label: String(format: localized("ActionHistory_EffectDrewCount"), effect.amount ?? effect.targets.count),
                                                     tone: .neutral, cards: []))
                continue
            case .generated where effect.targets.first?.isHidden == true:
                lines.append(ActionHistoryEffectLine(id: prefix, label: String(format: localized("ActionHistory_EffectGeneratedCount"), effect.amount ?? effect.targets.count),
                                                     tone: .neutral, cards: []))
                continue
            default:
                break
            }
            for (targetIndex, target) in effect.targets.enumerated() {
                var cards = [target]
                if effect.kind == .transformed, let newCardId = effect.detailCardId {
                    cards.append(HistoryCardRef(entityId: target.entityId, cardId: newCardId, side: target.side, cardType: target.cardType))
                }
                lines.append(ActionHistoryEffectLine(id: "\(prefix)/\(targetIndex)", label: label(effect, target: target), tone: tone(effect.kind), cards: cards))
            }
        }
        return lines
    }

    /// - Parameter target: the card the line is about, when the wording depends on what kind of card it is.
    static func label(_ effect: HistoryEffect, target: HistoryCardRef? = nil) -> String {
        let amount = effect.amount ?? 0
        switch effect.kind {
        case .damage: return String(format: localized("ActionHistory_EffectDamage"), amount)
        case .heal: return String(format: localized("ActionHistory_EffectHeal"), amount)
        case .armorGained: return String(format: localized("ActionHistory_EffectArmorGained"), amount)
        case .armorLost: return String(format: localized("ActionHistory_EffectArmorLost"), amount)
        case .died: return localized("ActionHistory_EffectDied")
        case .destroyed:
            // The Chinese clients destroy (消灭) minions but break (摧毁) weapons and locations
            if let cardType = target?.cardType, cardType == CardType.weapon.rawValue || cardType == CardType.location.rawValue {
                return localized("ActionHistory_EffectDestroyedObject")
            }
            return localized("ActionHistory_EffectDestroyed")
        case .summoned: return localized("ActionHistory_EffectSummoned")
        case .equipped: return localized("ActionHistory_EffectEquipped")
        case .drew: return localized("ActionHistory_EffectDrew")
        case .drewUnknown: return String(format: localized("ActionHistory_EffectDrewCount"), effect.amount ?? effect.targets.count)
        case .generated: return localized("ActionHistory_EffectGenerated")
        case .discarded: return localized("ActionHistory_EffectDiscarded")
        case .burned: return localized("ActionHistory_EffectBurned")
        case .shuffledIntoDeck: return localized("ActionHistory_EffectShuffled")
        case .returnedToHand: return localized("ActionHistory_EffectReturned")
        case .transformed: return localized("ActionHistory_EffectTransformed")
        case .stolen: return localized("ActionHistory_EffectStolen")
        case .enchanted:
            // The enchantment's own name ("Blessing of Kings") says more than a generic label
            if let enchantmentId = effect.detailCardId, Cards.cardsById[enchantmentId] != nil {
                return cardName(enchantmentId)
            }
            return localized("ActionHistory_EffectEnchanted")
        case .frozen: return localized("ActionHistory_EffectFrozen")
        case .silenced: return localized("ActionHistory_EffectSilenced")
        case .divineShieldLost: return localized("ActionHistory_EffectDivineShieldLost")
        case .secretPlayed: return localized("ActionHistory_EffectSecretPlayed")
        }
    }

    static func tone(_ kind: HistoryEffectKind) -> ActionHistoryEffectLine.Tone {
        switch kind {
        case .damage, .armorLost: return .damage
        case .heal, .armorGained: return .heal
        case .died, .destroyed, .burned, .discarded: return .death
        default: return .neutral
        }
    }

    // MARK: - Strings

    /// Every key the panel uses, so a test can check they all exist in Localizable.xcstrings.
    static let localizationKeys = [
        "ActionHistory_Title", "ActionHistory_Collapse", "ActionHistory_Expand",
        "ActionHistory_TurnPlayer", "ActionHistory_TurnOpponent", "ActionHistory_StartOfGame",
        "ActionHistory_Play", "ActionHistory_HeroPower", "ActionHistory_UseLocation", "ActionHistory_Attack",
        "ActionHistory_Trade", "ActionHistory_DeckAction",
        "ActionHistory_Power", "ActionHistory_Trigger", "ActionHistory_Secret", "ActionHistory_Deathrattle",
        "ActionHistory_Fatigue", "ActionHistory_Reveal", "ActionHistory_TurnStart", "ActionHistory_Deaths",
        "ActionHistory_GameReset", "ActionHistory_Reconnected",
        "ActionHistory_UnknownCard", "ActionHistory_UnknownSecret", "ActionHistory_RevealedLater",
        "ActionHistory_Weapon", "ActionHistory_SummaryDeaths",
        "ActionHistory_EffectDamage", "ActionHistory_EffectHeal", "ActionHistory_EffectArmorGained",
        "ActionHistory_EffectArmorLost", "ActionHistory_EffectDied", "ActionHistory_EffectDestroyed",
        "ActionHistory_EffectDestroyedObject",
        "ActionHistory_EffectSummoned", "ActionHistory_EffectEquipped", "ActionHistory_EffectDrew",
        "ActionHistory_EffectDrewCount", "ActionHistory_EffectGenerated", "ActionHistory_EffectGeneratedCount",
        "ActionHistory_EffectDiscarded", "ActionHistory_EffectBurned", "ActionHistory_EffectShuffled",
        "ActionHistory_EffectReturned", "ActionHistory_EffectTransformed", "ActionHistory_EffectStolen",
        "ActionHistory_EffectEnchanted", "ActionHistory_EffectFrozen", "ActionHistory_EffectSilenced",
        "ActionHistory_EffectDivineShieldLost", "ActionHistory_EffectSecretPlayed"
    ]

    static func localized(_ key: String) -> String {
        return String.localizedString(key, comment: "")
    }
}
