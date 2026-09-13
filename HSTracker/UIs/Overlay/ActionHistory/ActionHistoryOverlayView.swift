//
//  ActionHistoryOverlayView.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import SwiftUI

// Places the action history panel on the RootOverlay canvas. The placement follows
// BattlegroundsSessionOverlayView: a position stored as percentages of the canvas, dragged only while
// the overlay is unlocked (Settings.windowsLocked), and an interactive region computed from that
// position and the panel's reported size so clicks everywhere else still reach Hearthstone.
//
// It lives in RootOverlayView's fixed-pixel layer rather than the 1080-reference scaled subtree: the
// panel is text meant to stay readable, and a smaller Hearthstone window should leave more of the
// board uncovered rather than shrink the names.
@available(macOS 10.15, *)
struct ActionHistoryOverlayView: View {
    @ObservedObject var viewModel: ActionHistoryViewModel
    // The canvas's real, post-scale size
    let canvasSize: CGSize

    var body: some View {
        // Instantiated unconditionally so the @ObservedObject binding keeps driving it; it renders
        // nothing (and reports no interactive region) while hidden. Before the first turn there is
        // nothing to list, so the mulligan screen stays uncovered.
        ZStack(alignment: .topLeading) {
            Color.clear
            if isVisible {
                panel
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .onPreferenceChange(ActionHistoryPanelSizePreferenceKey.self) { size in
            let newSize = size ?? .zero
            if viewModel.panelSize != newSize {
                viewModel.panelSize = newSize
            }
        }
        .onPreferenceChange(ActionHistoryListHeightPreferenceKey.self) { height in
            if let height, viewModel.listContentHeight != height {
                viewModel.listContentHeight = height
            }
        }
        // The panel takes clicks (folding, dragging) and scroll-wheel events, so the overlay window
        // stops being click-through over it - see InteractiveRegionPreferenceKey. Computed rather
        // than read off a GeometryReader for the same reason BattlegroundsSessionOverlayView gives.
        .preference(key: InteractiveRegionPreferenceKey.self, value: interactiveRegions)
    }

    private var isVisible: Bool {
        return viewModel.isShown && viewModel.hasTurns
    }

    private var interactiveRegions: [CGRect] {
        guard isVisible, viewModel.panelSize.width > 0, viewModel.panelSize.height > 0 else {
            return []
        }
        let origin = viewModel.origin(canvasSize: canvasSize)
        return [CGRect(origin: origin, size: viewModel.panelSize)]
    }

    private var panel: some View {
        let origin = viewModel.origin(canvasSize: canvasSize)
        let placement = viewModel.tooltipPlacement(canvasSize: canvasSize)
        return VStack(alignment: .leading, spacing: 0) {
            titleBar
            if !viewModel.collapsed {
                Color.white.opacity(0.15)
                    .frame(height: 1)
                list(placement: placement)
            }
        }
        .frame(width: ActionHistoryViewModel.panelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ActionHistoryPanelSizePreferenceKey.self, value: proxy.size)
            }
        )
        // Padding rather than .offset: .offset only moves the rendering, and the card names' hover
        // views are matched by their laid-out frames (CardHoverRegistry).
        .padding(.leading, origin.x)
        .padding(.top, origin.y)
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Text(ActionHistoryPresentation.localized("ActionHistory_Title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ActionHistoryStyle.primaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: { viewModel.toggleCollapsed() }, label: {
                // Plain glyphs: SF Symbols need macOS 11
                Text(verbatim: viewModel.collapsed ? "▸" : "▾")
                    .font(.system(size: 13))
                    .foregroundColor(ActionHistoryStyle.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            })
            .buttonStyle(PlainButtonStyle())
            .accessibility(label: Text(ActionHistoryPresentation.localized(viewModel.collapsed ? "ActionHistory_Expand" : "ActionHistory_Collapse")))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .contentShape(Rectangle())
        // Only the title bar drags: the list below has rows to click and a scroller to grab. HDT
        // moves overlay elements only while the overlay is unlocked and saves on mouse up.
        .gesture(dragGesture, including: Settings.windowsLocked ? .none : .all)
    }

    private func list(placement: CardTooltipPlacement) -> some View {
        let maxHeight = viewModel.maxListHeight(canvasSize: canvasSize)
        // A ScrollView takes all the height it is offered, so the viewport is sized to the measured
        // content and capped. Until the first measurement arrives it takes the cap.
        let height = viewModel.listContentHeight > 0 ? min(viewModel.listContentHeight, maxHeight) : maxHeight
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ActionHistoryPresentation.sections(viewModel.turns), id: \.key) { section in
                    turnSection(section, placement: placement)
                }
            }
            .padding(.bottom, 4)
            .frame(width: ActionHistoryViewModel.panelWidth, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ActionHistoryListHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(width: ActionHistoryViewModel.panelWidth, height: height)
    }

    private func turnSection(_ section: ActionHistoryTurnSection, placement: CardTooltipPlacement) -> some View {
        let expanded = viewModel.isTurnExpanded(section)
        let turn = section.turn
        return VStack(alignment: .leading, spacing: 0) {
            // A Button for the same reason as ActionHistoryRowView's
            Button(action: { viewModel.toggleTurn(section) }, label: {
                HStack(spacing: 4) {
                    Text(verbatim: expanded ? "▾" : "▸")
                        .font(ActionHistoryStyle.detailFont)
                        .foregroundColor(ActionHistoryStyle.secondaryText)
                    Text(ActionHistoryPresentation.turnTitle(turn))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ActionHistoryStyle.sideColor(turn.side))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // How many actions a folded turn holds
                    if !expanded && !turn.entries.isEmpty {
                        Text(verbatim: "\(turn.entries.count)")
                            .font(ActionHistoryStyle.detailFont)
                            .foregroundColor(ActionHistoryStyle.secondaryText)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ActionHistoryStyle.sideColor(turn.side).opacity(0.12))
                .contentShape(Rectangle())
            })
            .buttonStyle(PlainButtonStyle())
            if expanded {
                // Turn-start draws and other effects outside any action
                ForEach(ActionHistoryPresentation.lines(turn.header, idPrefix: "header"), id: \.id) { line in
                    ActionHistoryEffectLineView(line: line, placement: placement)
                        .padding(.leading, 12)
                        .padding(.trailing, 6)
                        .padding(.vertical, 1)
                }
                ForEach(turn.entries, id: \.id) { entry in
                    ActionHistoryRowView(viewModel: viewModel, entry: entry, placement: placement)
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard !Settings.windowsLocked else { return }
                viewModel.drag(translation: value.translation, canvasSize: canvasSize)
            }
            .onEnded { _ in
                viewModel.endDrag()
            }
    }
}

// The panel's laid-out size, so the interactive region can be worked out without a reader under the
// padding that places it.
@available(macOS 10.15, *)
private struct ActionHistoryPanelSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize?
    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        if let next = nextValue() {
            value = next
        }
    }
}

// The height of the list's content inside its ScrollView.
@available(macOS 10.15, *)
private struct ActionHistoryListHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = next
        }
    }
}
