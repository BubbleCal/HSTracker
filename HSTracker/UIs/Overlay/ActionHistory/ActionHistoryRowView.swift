//
//  ActionHistoryRowView.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import SwiftUI

// The colours and fonts every part of the action history panel shares.
@available(macOS 10.15, *)
enum ActionHistoryStyle {
    static let playerColor = Color(red: 0.36, green: 0.78, blue: 0.40)
    static let opponentColor = Color(red: 0.90, green: 0.36, blue: 0.33)
    static let neutralColor = Color(white: 0.6)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.68)
    static let hiddenText = Color(white: 0.55)
    static let damageText = Color(red: 1.0, green: 0.45, blue: 0.40)
    static let healText = Color(red: 0.45, green: 0.85, blue: 0.45)
    static let chipBackground = Color.white.opacity(0.14)

    static let nameFont = Font.system(size: 12)
    static let detailFont = Font.system(size: 11)
    static let chipFont = Font.system(size: 10, weight: .semibold)

    static func sideColor(_ side: HistorySide) -> Color {
        switch side {
        case .player: return playerColor
        case .opponent: return opponentColor
        case .neutral: return neutralColor
        }
    }

    static func toneColor(_ tone: ActionHistoryEffectLine.Tone) -> Color {
        switch tone {
        case .damage: return damageText
        case .heal: return healText
        case .death, .neutral: return secondaryText
        }
    }
}

// A card name. Public cards open their image on hover through the canvas's CardHoverRegistry, which
// RootOverlayWindow polls whether or not the overlay is click-through at that pixel. Hidden cards
// print "a card" / "a Secret" in grey and have nothing to hover.
@available(macOS 10.15, *)
struct ActionHistoryCardName: View {
    let ref: HistoryCardRef
    let placement: CardTooltipPlacement
    var font: Font = ActionHistoryStyle.nameFont

    var body: some View {
        let text = Text(ActionHistoryPresentation.name(ref)).font(font)
        return (ref.isHidden ? text.italic().foregroundColor(ActionHistoryStyle.hiddenText) : text.foregroundColor(ActionHistoryStyle.primaryText))
            .lineLimit(1)
            .truncationMode(.tail)
            // Constructed cards: skip the Battlegrounds art request the tooltip would otherwise try first
            .cardImageTooltip(cardId: ref.cardId, showTriple: false, baconCard: false, placement: placement)
    }
}

// "3 damage  Ragnaros", "Transformed  Ragnaros → Sheep", or "Drew 2 cards".
@available(macOS 10.15, *)
struct ActionHistoryEffectLineView: View {
    let line: ActionHistoryEffectLine
    let placement: CardTooltipPlacement

    var body: some View {
        HStack(spacing: 4) {
            Text(line.label)
                .font(ActionHistoryStyle.detailFont)
                .foregroundColor(ActionHistoryStyle.toneColor(line.tone))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let first = line.cards.first {
                ActionHistoryCardName(ref: first, placement: placement, font: ActionHistoryStyle.detailFont)
            }
            if line.cards.count > 1 {
                Text(verbatim: "→")
                    .font(ActionHistoryStyle.detailFont)
                    .foregroundColor(ActionHistoryStyle.secondaryText)
                ActionHistoryCardName(ref: line.cards[1], placement: placement, font: ActionHistoryStyle.detailFont)
            }
            Spacer(minLength: 0)
        }
    }
}

// One top-level action: the side stripe, the verb, "source → target" and the damage and death totals.
// Clicking it unfolds what the action did and the actions it set off (a Secret, a Deathrattle).
@available(macOS 10.15, *)
struct ActionHistoryRowView: View {
    @ObservedObject var viewModel: ActionHistoryViewModel
    let entry: HistoryEntry
    let placement: CardTooltipPlacement

    var body: some View {
        if entry.type == .reconnected {
            Text(ActionHistoryPresentation.verb(.reconnected))
                .font(ActionHistoryStyle.detailFont)
                .italic()
                .foregroundColor(ActionHistoryStyle.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        } else {
            row
        }
    }

    private var row: some View {
        let expanded = viewModel.isEntryExpanded(entry)
        let hasDetails = ActionHistoryPresentation.hasDetails(entry)
        return VStack(alignment: .leading, spacing: 2) {
            // A Button rather than .onTapGesture, which does not reliably fire inside a ScrollView on
            // macOS (see BattlegroundsCardsGroupView's group header)
            Button(action: {
                if hasDetails {
                    viewModel.toggleEntry(entry)
                }
            }, label: {
                HStack(spacing: 4) {
                    ActionHistoryActionTitle(entry: entry, placement: placement)
                    Spacer(minLength: 4)
                    summary
                    if hasDetails {
                        Text(verbatim: expanded ? "▾" : "▸")
                            .font(ActionHistoryStyle.detailFont)
                            .foregroundColor(ActionHistoryStyle.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(PlainButtonStyle())
            if expanded {
                ActionHistoryDetailsView(entry: entry, placement: placement)
                    .padding(.leading, 8)
                ForEach(ActionHistoryPresentation.flattenedChildren(entry), id: \.id) { child in
                    VStack(alignment: .leading, spacing: 2) {
                        ActionHistoryActionTitle(entry: child, placement: placement)
                        ActionHistoryDetailsView(entry: child, placement: placement)
                            .padding(.leading, 8)
                    }
                    .padding(.leading, 10)
                    .overlay(ActionHistoryStyle.sideColor(sourceSide(child))
                                .opacity(0.6)
                                .frame(width: 2),
                             alignment: .leading)
                }
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        // Whose action it was. An overlay rather than an HStack sibling, so the stripe takes the
        // row's height instead of proposing one.
        .overlay(ActionHistoryStyle.sideColor(entry.type == .secret ? sourceSide(entry) : entry.activeSide).frame(width: 3),
                 alignment: .leading)
    }

    // A Secret or Deathrattle belongs to the card's owner, not to whoever's turn it is
    private func sourceSide(_ child: HistoryEntry) -> HistorySide {
        return child.source?.side ?? child.activeSide
    }

    private var summary: some View {
        let totals = ActionHistoryPresentation.summary(entry)
        return HStack(spacing: 4) {
            if totals.damage > 0 {
                Text(verbatim: "-\(totals.damage)")
                    .foregroundColor(ActionHistoryStyle.damageText)
            }
            if totals.heal > 0 {
                Text(verbatim: "+\(totals.heal)")
                    .foregroundColor(ActionHistoryStyle.healText)
            }
            if totals.deaths > 0 {
                Text(ActionHistoryPresentation.deathsText(totals.deaths))
                    .foregroundColor(ActionHistoryStyle.secondaryText)
            }
        }
        .font(ActionHistoryStyle.detailFont)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// "[Played] Fireball → Ragnaros", with "Revealed: Explosive Trap" under an opponent's Secret that
// the game has since shown.
@available(macOS 10.15, *)
struct ActionHistoryActionTitle: View {
    let entry: HistoryEntry
    let placement: CardTooltipPlacement

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(ActionHistoryPresentation.verb(entry.type))
                    .font(ActionHistoryStyle.chipFont)
                    .foregroundColor(ActionHistoryStyle.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(ActionHistoryStyle.chipBackground))
                    .fixedSize(horizontal: true, vertical: false)
                if let source = entry.source {
                    ActionHistoryCardName(ref: source, placement: placement)
                        .layoutPriority(1)
                }
                if let target = entry.target {
                    Text(verbatim: "→")
                        .font(ActionHistoryStyle.detailFont)
                        .foregroundColor(ActionHistoryStyle.secondaryText)
                    ActionHistoryCardName(ref: target, placement: placement)
                }
            }
            // One line per Secret the action put into play and the game has since shown
            ForEach(entry.revealedLater, id: \.entityId) { revealed in
                HStack(spacing: 3) {
                    Text(ActionHistoryPresentation.localized("ActionHistory_RevealedLater"))
                        .font(ActionHistoryStyle.detailFont)
                        .foregroundColor(ActionHistoryStyle.secondaryText)
                        .fixedSize(horizontal: true, vertical: false)
                    ActionHistoryCardName(ref: revealed, placement: placement, font: ActionHistoryStyle.detailFont)
                }
            }
        }
    }
}

// The weapon an attack was made with, then one line per card an effect touched.
@available(macOS 10.15, *)
struct ActionHistoryDetailsView: View {
    let entry: HistoryEntry
    let placement: CardTooltipPlacement

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let weapon = entry.weapon {
                ActionHistoryEffectLineView(line: ActionHistoryEffectLine(id: "weapon", label: ActionHistoryPresentation.localized("ActionHistory_Weapon"),
                                                                          tone: .neutral, cards: [weapon]),
                                            placement: placement)
            }
            ForEach(ActionHistoryPresentation.lines(entry.effects, idPrefix: "\(entry.id)"), id: \.id) { line in
                ActionHistoryEffectLineView(line: line, placement: placement)
            }
        }
    }
}
