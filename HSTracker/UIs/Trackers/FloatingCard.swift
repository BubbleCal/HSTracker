//
//  FloatingCard.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 7/04/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation
import TextAttributes

enum FloatingCardStyle: String {
    case text
    case image
}

class FloatingCard: OverWindowController {

    @IBOutlet var imageView: NSImageView!

    var card: Card?
    var isBattlegrounds = false
    // A short note under the image, such as why the secret helper ruled a secret out
    private(set) var subtitle: String?
    // false shows the subtitle alone, for players who turned card previews off
    private(set) var showsImage = true

    private static let subtitlePadding: CGFloat = 6
    private var subtitleBox: NSView?
    private var subtitleLabel: NSTextField?
    private var subtitleHeightConstraint: NSLayoutConstraint?
    // The xib pins the image to the bottom of the window; with a subtitle it ends at the box instead
    private var imageBottomToWindow: NSLayoutConstraint?
    private var imageBottomToSubtitle: NSLayoutConstraint?

    func set(card: Card, subtitle: String? = nil, showsImage: Bool = true) {
        self.card = card
        self.subtitle = subtitle?.isEmpty == false ? subtitle : nil
        self.showsImage = showsImage || self.subtitle == nil
        reload()
    }

    // How much taller the window has to be, at this width, to fit the subtitle under the image
    func subtitleHeight(width: CGFloat) -> CGFloat {
        guard let subtitle, let label = makeSubtitleViews()?.label else { return 0 }
        let padding = FloatingCard.subtitlePadding
        label.stringValue = subtitle
        let bounds = NSRect(x: 0, y: 0, width: max(width - 2 * padding, 1), height: .greatestFiniteMagnitude)
        let textHeight = label.cell?.cellSize(forBounds: bounds).height ?? 0
        return ceil(textHeight) + 2 * padding
    }

    // Shows or hides the subtitle for the window's current size
    func updateSubtitleLayout() {
        guard let window, let views = makeSubtitleViews() else { return }
        let height = subtitleHeight(width: window.frame.width)
        let show = height > 0
        views.label.stringValue = subtitle ?? ""
        views.box.isHidden = !show
        subtitleHeightConstraint?.constant = height
        // Deactivate before activating so the two bottom constraints never conflict
        if show {
            imageBottomToWindow?.isActive = false
            imageBottomToSubtitle?.isActive = true
        } else {
            imageBottomToSubtitle?.isActive = false
            imageBottomToWindow?.isActive = true
        }
    }

    private func makeSubtitleViews() -> (box: NSView, label: NSTextField)? {
        if let subtitleBox, let subtitleLabel {
            return (subtitleBox, subtitleLabel)
        }
        guard let contentView = window?.contentView, let imageView else { return nil }

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        box.layer?.cornerRadius = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        box.isHidden = true

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.white
        label.alignment = .center
        // Unlimited, so the measured height is the drawn one; the text is at most a few short lines
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        contentView.addSubview(box)

        let padding = FloatingCard.subtitlePadding
        let height = box.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            height,
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        subtitleHeightConstraint = height
        imageBottomToWindow = contentView.constraints.first { c in
            c.firstAttribute == .bottom && c.secondAttribute == .bottom
                && ((c.firstItem === contentView && c.secondItem === imageView) || (c.firstItem === imageView && c.secondItem === contentView))
        }
        imageBottomToSubtitle = imageView.bottomAnchor.constraint(equalTo: box.topAnchor)
        subtitleBox = box
        subtitleLabel = label
        return (box, label)
    }

    private func reload() {
        if showsImage, let cardId = self.card?.id, let baconTriple = card?.baconTriple {
            if isBattlegrounds {
                ImageUtils.cardArtBG(for: cardId, baconTriple: baconTriple, completion: { image in
                    DispatchQueue.main.async {
                        self.imageView.image = image
                    }
                })
            } else {
                ImageUtils.cardArt(for: cardId, completion: { image in
                    DispatchQueue.main.async {
                        self.imageView.image = image
                    }
                })
            }
        }

        window?.backgroundColor = NSColor.clear
        imageView.isHidden = !showsImage

        // "pack frame"
        if let window = self.window {
            let width = window.frame.size.width
            let totalHeight = (showsImage ? width * 250/180 : 0) + subtitleHeight(width: width)
            self.window?.setContentSize(NSSize(width: width,
                    height: totalHeight))
        }
        updateSubtitleLayout()
    }
}
