//
//  BoardDamage.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 9/06/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import AppKit

class BoardDamage: OverWindowController {
    
    @IBOutlet var damage: NSTextField!
    var player: PlayerType?
    
    var hasValidFrame = false

    /// Room for the text inside the badge's 54pt borderless text field: the cell and the line fragment
    /// padding take 2pt on each side, and wider text is clipped
    static let maxTextWidth: CGFloat = 46
    static let fontName = "Belwe Bd BT"
    static let nowFontSize: CGFloat = 18
    static let nextTurnFontSize: CGFloat = 12
    static let minNowFontSize: CGFloat = 12

    private var lastValues: (now: Int, nextTurn: Int)?
    
    override func windowDidLoad() {
        super.windowDidLoad()

        // "n(m)" is shrunk to fit instead, and must never turn into an ellipsis
        damage.lineBreakMode = .byClipping
        damage.cell?.lineBreakMode = .byClipping
        if let lastValues = lastValues {
            update(now: lastValues.now, nextTurn: lastValues.nextTurn)
        }
    }

    /// Shows "n(m)": the damage that side can still deal this turn, then what its board could deal on
    /// its next turn. Int.max stands for infinite.
    func update(now: Int, nextTurn: Int) {
        lastValues = (now, nextTurn)
        if let damage = self.damage {
            damage.attributedStringValue = BoardDamage.attributedText(now: now, nextTurn: nextTurn)
        }
    }

    static func text(for value: Int) -> String {
        return value == Int.max ? "\u{221e}" : "\(value)"
    }

    /// n in the large font and "(m)" in a smaller one, scaled down together in 1pt steps until it fits
    static func attributedText(now: Int, nextTurn: Int) -> NSAttributedString {
        var nowSize = nowFontSize
        var result = attributedText(now: now, nextTurn: nextTurn, nowFontSize: nowSize)
        while result.size().width > maxTextWidth && nowSize > minNowFontSize {
            nowSize -= 1
            result = attributedText(now: now, nextTurn: nextTurn, nowFontSize: nowSize)
        }
        return result
    }

    private static func attributedText(now: Int, nextTurn: Int, nowFontSize size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // An attributed string's paragraph style wins over the field's line break mode, and the default
        // word wrapping would push the tail onto a second line outside the field
        paragraph.lineBreakMode = .byClipping
        func attributes(_ fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
            return [
                .font: NSFont(name: fontName, size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: NSColor.white,
                .strokeWidth: -1.5,
                .strokeColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
        }
        let result = NSMutableAttributedString(string: text(for: now), attributes: attributes(size))
        let nextTurnSize = size * nextTurnFontSize / nowFontSize
        result.append(NSAttributedString(string: "(\(text(for: nextTurn)))", attributes: attributes(nextTurnSize)))
        return result
    }
}

extension BoardDamage: NSWindowDelegate {
    
    func windowDidMove(_ notification: Notification) {
        onWindowMove()
    }
    
    private func onWindowMove() {
        if !self.isWindowLoaded || !self.hasValidFrame {return}
        if player == .player {
            Settings.playerBoardDamageFrame = self.window?.frame
        } else {
            Settings.opponentBoardDamageFrame = self.window?.frame
        }
    }
}
