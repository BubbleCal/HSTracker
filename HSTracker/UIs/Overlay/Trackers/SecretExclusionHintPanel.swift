//
//  SecretExclusionHintPanel.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import AppKit

/// Why the secret helper ruled a dimmed secret out - "Turn 5: You attacked the enemy hero" - in a
/// small box under the card render its row raises. HDT's secret helper has no such hint; this is
/// the fork's.
///
/// A panel of its own rather than part of CardTooltipPanel, whose one caption line is laid over
/// the top of the card and shrunk to its width, while a reason can take up to four lines. With card
/// previews off it shows alone, beside the row, so the reason is still there to read.
@available(macOS 10.15, *)
final class SecretExclusionHintPanel: NSPanel {
    static let shared = SecretExclusionHintPanel()

    private static let padding: CGFloat = 6
    private let box = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // Level with CardTooltipPanel, which it hangs under
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        ignoresMouseEvents = true
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        box.layer?.cornerRadius = 6
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        box.addSubview(label)
        contentView = box
    }

    /// Shows the reason `card` was ruled out, when it is a secret the helper dimmed, and hides the
    /// box otherwise. `rowFrame` is the hovered row in screen coordinates.
    func show(for card: Card, rowFrame: NSRect) {
        let summary = card.count <= 0
            ? AppDelegate.instance().coreManager?.game.secretsManager?.exclusionSummary(cardId: card.id)
            : nil
        guard summary?.isEmpty == false else {
            hide()
            return
        }
        show(summary: summary, renderFrame: TrackerRowCardPreview.frame(card: card, rowFrame: rowFrame), rowFrame: rowFrame)
    }

    /// Shows `summary` under `render`, where the row's card render lands, or hides the box when
    /// there is none.
    func show(summary: String?, renderFrame render: NSRect, rowFrame: NSRect) {
        guard let summary, !summary.isEmpty else {
            hide()
            return
        }
        let width = render.width > 0 ? render.width : 220
        label.stringValue = summary
        let padding = Self.padding
        let textBounds = NSRect(x: 0, y: 0, width: max(width - 2 * padding, 1), height: .greatestFiniteMagnitude)
        let textHeight = ceil(label.cell?.cellSize(forBounds: textBounds).height ?? 0)
        let height = textHeight + 2 * padding

        // Under the render, or - with card previews off - level with the row where the render
        // would have been
        let origin = Settings.showFloatingCard
            ? NSPoint(x: render.minX, y: render.minY - height)
            : NSPoint(x: render.minX, y: rowFrame.midY - height / 2)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        box.frame = NSRect(x: 0, y: 0, width: width, height: height)
        label.frame = NSRect(x: padding, y: padding, width: width - 2 * padding, height: textHeight)
        orderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}
