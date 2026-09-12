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

    fileprivate func internalSet(cards: [Card]) {
        lock.around {
            var newCards = [Card]()
            cards.forEach({ (card: Card) in
                let existing = animatedCards.first { bar in
                    guard let barCard = bar.card else { return false }
                    return areEqualForList(barCard, card)
                }
                if existing == nil {
                    newCards.append(card)
                }
            })

            var toRemove: [Int] = []
            animatedCards.forEach({ (c: CardBar) in
                // A bar with no card is stale by definition, so it goes too -
                // this used to force-unwrap and take the app down with it.
                let stillListed = c.card.map { barCard in cards.any({ areEqualForList($0, barCard) }) } ?? false
                if !stillListed {
                    if let index = animatedCards.firstIndex(of: c), index < table?.numberOfRows ?? 0 {
                        toRemove.append(index)
                    }
                }
            })

            table?.beginUpdates()
            var indexSet = IndexSet(toRemove)
            table?.removeRows(at: indexSet, withAnimation: [.effectFade, .slideRight])
            for index in indexSet.reversed() {
                animatedCards.remove(at: index)
            }
            indexSet.removeAll()
            newCards.forEach({
                guard let index = cards.firstIndex(of: $0) else { return }
                let newCard = CardBar.factory()
                newCard.setDelegate(self)
                newCard.card = $0
                newCard.playerType = .secrets
                animatedCards.insert(newCard, at: min(index, animatedCards.count))
                indexSet.insert(index)
            })
            table?.insertRows(at: indexSet, withAnimation: .slideLeft)
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
        NotificationCenter.default
            .post(name: Notification.Name(rawValue: Events.show_floating_card),
                                  object: nil,
                                  userInfo: [
                                    "card": card,
                                    "frame": frame,
                                    "useFrame": true
                ])
    }

    func out(card: Card) {
        NotificationCenter.default
            .post(name: Notification.Name(rawValue: Events.hide_floating_card), object: nil, userInfo: [
                "card": card ])
    }
}
