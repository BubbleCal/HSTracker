//
//  CardList.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 10/03/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation
import AppKit

class CardList: OverWindowController {

    @IBOutlet var table: NSTableView?

    fileprivate var animatedCards: [CardBar] = []
    // Recursive on purpose: internalSet() holds this across NSTableView's
    // insertRows/removeRows, and the table answers those by calling back into
    // numberOfRows(in:) and tableView(_:viewFor:row:) on the same thread - both
    // of which take the lock again. With a non-recursive lock that is a
    // main-thread deadlock, i.e. a frozen app.
    let lock = RecursiveLock()
    var isSecretPanel = false

    var observer: NSObjectProtocol?

    override func windowDidLoad() {
        super.windowDidLoad()
        if #available(macOS 11.0, *) {
            table?.style = .fullWidth
        }
        table?.intercellSpacing = NSSize(width: 0, height: 0)

        table?.backgroundColor = NSColor.clear
        table?.autoresizingMask = [NSView.AutoresizingMask.width,
                                       NSView.AutoresizingMask.height]

        self.observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: Settings.card_size), object: nil, queue: OperationQueue.main) { _ in
            self.cardSizeChange()
        }
    }
    
    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func cardSizeChange() {
        setWindowSizes()
    }
    
    func cardCount() -> Int {
        return lock.around {
            return animatedCards.count
        }
    }

    // Brings the rows in line with `cards`, keeping the bars that stay listed: remove, update in
    // place, reorder, insert. The secret helper keeps impossible candidates as count 0 rows and
    // moves them below the possible ones, so a row can change its count and its position without
    // leaving the list (the in-place half of AnimatedCardList.update).
    fileprivate func internalSet(cards: [Card]) {
        lock.around {
            var toRemove = IndexSet()
            for (index, bar) in animatedCards.enumerated() {
                // A bar with no card is stale by definition, so it goes too -
                // this used to force-unwrap and take the app down with it.
                let stillListed = bar.card.map { barCard in cards.any({ areEqualForList($0, barCard) }) } ?? false
                if !stillListed {
                    toRemove.insert(index)
                }
            }

            // NSTableView applies each call of the batch to the result of the previous one, so
            // every index below is relative to the rows as they are at that point.
            table?.beginUpdates()
            table?.removeRows(at: toRemove, withAnimation: [.effectFade, .slideRight])
            for index in toRemove.reversed() {
                animatedCards.remove(at: index)
            }

            for bar in animatedCards {
                guard let barCard = bar.card, let newCard = cards.first(where: { areEqualForList($0, barCard) }) else { continue }
                guard barCard.count != newCard.count || barCard.isCreated != newCard.isCreated
                        || barCard.jousted != newCard.jousted else { continue }
                // A fresh Card, not a mutation of the old one: CardBar.draw() skips the redraw
                // while the card equals the one it replaced, and that comparison needs both.
                bar.card = newCard
                bar.needsDisplay = true
                if bar.isHovered {
                    // Deferred for the same reason CardBar defers its own re-hover: the handler
                    // must not run inside this lock and table update. A row that just became
                    // impossible gets its reason under the popup without the cursor moving.
                    DispatchQueue.main.async { [weak self, weak bar] in
                        guard let self, let bar, bar.isHovered, let current = bar.card else { return }
                        self.hover(cell: bar, card: current)
                    }
                }
            }

            let listed = cards.compactMap { card in
                animatedCards.first { bar in bar.card.map { areEqualForList($0, card) } ?? false }
            }
            for (target, bar) in listed.enumerated() {
                guard let from = animatedCards.firstIndex(of: bar), from != target else { continue }
                table?.moveRow(at: from, to: target)
                animatedCards.remove(at: from)
                animatedCards.insert(bar, at: target)
            }

            for (index, card) in cards.enumerated() {
                guard !animatedCards.contains(where: { bar in bar.card.map { areEqualForList($0, card) } ?? false }) else { continue }
                let newCard = CardBar.factory()
                newCard.setDelegate(self)
                newCard.card = card
                newCard.playerType = .secrets
                // Clamped for both: telling the table about a row the array
                // does not have leaves NSTableView's own count disagreeing with
                // the data source, which it answers with an exception at
                // endUpdates().
                let insertAt = min(index, animatedCards.count)
                animatedCards.insert(newCard, at: insertAt)
                table?.insertRows(at: IndexSet(integer: insertAt), withAnimation: .slideLeft)
            }
        }
        // Deliberately outside the critical section: endUpdates() is where the
        // table actually applies the batch and asks back for its rows.
        table?.endUpdates()
    }
    
    func set(cards: [Card]) {
        if Thread.isMainThread {
            internalSet(cards: cards)
        } else {
            DispatchQueue.main.async { [self] in
                self.internalSet(cards: cards)
            }
        }
    }
    
    fileprivate func areEqualForList(_ c1: Card, _ c2: Card) -> Bool {
        return c1.id == c2.id
    }
    
    var frameHeight: CGFloat {
        var rowHeight: CGFloat = 0
        switch Settings.cardSize {
        case .tiny: rowHeight = CGFloat(kTinyRowHeight)
        case .small: rowHeight = CGFloat(kSmallRowHeight)
        case .medium: rowHeight = CGFloat(kMediumRowHeight)
        case .huge: rowHeight = CGFloat(kHighRowHeight)
        case .big: rowHeight = CGFloat(kRowHeight)
        }
        return lock.around {
            return rowHeight * CGFloat(self.animatedCards.count)
        }
    }
}

// MARK: - NSTableViewDataSource
extension CardList: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return cardCount()
    }
}

// MARK: - NSTableViewDelegate
extension CardList: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        return lock.around {
            return row >= 0 && row < animatedCards.count ? animatedCards[row] : nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch Settings.cardSize {
        case .tiny: return CGFloat(kTinyRowHeight)
        case .small: return CGFloat(kSmallRowHeight)
        case .medium: return CGFloat(kMediumRowHeight)
        case .huge: return CGFloat(kHighRowHeight)
        case .big: return CGFloat(kRowHeight)
        }
    }

    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        return false
    }
}

// MARK: - CardCellHover
extension CardList: CardCellHover {
    func hover(cell: CardBar, card: Card) {
        // Every one of these used to be force-unwrapped. A hover can outlive the
        // window being torn down (the tracker hides while the cursor is over a
        // row), and a bar that has just been removed from the table answers
        // row(for:) with -1, so this ran a real risk of crashing on a mouse move.
        guard let table, let window = self.window else { return }
        let row = table.row(for: cell)
        guard row >= 0 else { return }
        let rect = table.frameOfCell(atColumn: 0, row: row)

        let visibleOrigin = table.enclosingScrollView?.documentVisibleRect.origin.y ?? 0
        let offset = rect.origin.y - visibleOrigin
        let windowRect = window.frame

        let hoverFrame = NSRect(x: 0, y: 0, width: 256, height: 388)

        var x: CGFloat
        if windowRect.origin.x < hoverFrame.size.width || isSecretPanel {
            x = windowRect.origin.x + windowRect.size.width
        } else {
            x = windowRect.origin.x - hoverFrame.size.width
        }

        var y = windowRect.origin.y + windowRect.height - offset - 30
        if y < hoverFrame.height {
            y = hoverFrame.height
        }
        if let screen = self.window?.screen {
            if y + hoverFrame.height > screen.frame.height {
                y = screen.frame.height - hoverFrame.height
            }
        }

        let frame = [x, y - hoverFrame.height / 2.0, hoverFrame.width, hoverFrame.height]
        var userInfo: [String: Any] = [
            "card": card,
            "frame": frame,
            "useFrame": true
        ]
        // A dimmed secret row says why it was ruled out, under the card image. Overlay panels are
        // click-through or non-key, so an NSView tooltip would never show.
        if isSecretPanel && card.count <= 0,
           let summary = AppDelegate.instance().coreManager?.game.secretsManager?.exclusionSummary(cardId: card.id) {
            userInfo["subtitle"] = summary
        }
        NotificationCenter.default
            .post(name: Notification.Name(rawValue: Events.show_floating_card),
                                  object: nil,
                                  userInfo: userInfo)
    }

    func out(card: Card) {
        NotificationCenter.default
            .post(name: Notification.Name(rawValue: Events.hide_floating_card), object: nil, userInfo: [
                "card": card ])
    }
}
