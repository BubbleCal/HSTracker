//
//  AnimatedCardList.swift
//  HSTracker
//
//  Created by Francisco Moraes on 4/15/22.
//  Copyright © 2022 Benjamin Michotte. All rights reserved.
//

import Foundation

class AnimatedCardList: NSView {
    fileprivate var animatedCards: [CardBar] = []
    
    var playerType: PlayerType = .player
    
    var delegate: CardCellHover?
    
    // Recursive: the guarded sections add and remove CardBar subviews and assign
    // their cards, and AppKit answers both by calling back into the bar - which
    // routes hover changes through the tracker and back into this list's own
    // shouldHighlightCard. A non-recursive lock turns any of those paths into a
    // main-thread deadlock.
    let lock = RecursiveLock()
    
    var isBattlegrounds = false
    
    var count: Int {
        lock.around {
            return animatedCards.count
        }
    }
    var cardCount = 0
    
    var cardHeight: CGFloat?
    
    private var _shouldHighlightCard: ((Card, [Card]) -> HighlightColor)?
    
    var shouldHighlightCard: ((Card, [Card]) -> HighlightColor)? {
        get {
            return _shouldHighlightCard
        }
        set {
            _shouldHighlightCard = newValue
            lock.around {
                let cards = animatedCards.filter { ac in ac.card?.count ?? 0 > 0 }.compactMap({ ac in ac.card })
                for animatedCard in animatedCards {
                    guard let card = animatedCard.card else {
                        continue
                    }
                    let color: HighlightColor = card.count <= 0 || card.jousted
                        ? .none
                        : (newValue?(card, cards) ?? .none)
                    // Only repaint a bar whose highlight actually moved. This
                    // used to mark every bar dirty on every pass - twice a
                    // second for a whole deck list - and a CardBar redraw is
                    // not cheap: it re-measures the card name to fit and
                    // recomposes all of its theme layers.
                    guard card.highlightColor != color else {
                        continue
                    }
                    card.highlightColor = color
                    DispatchQueue.main.async {
                        animatedCard.needsDisplay = true
                    }
                }
            }
        }
    }
    
    private func internalIntrinsicContentSize(_ count: Int) -> NSSize {
        let height = switch Settings.cardSize {
        case .tiny:
            CGFloat(kTinyRowHeight)
        case .small:
            CGFloat(kSmallRowHeight)
        case .medium:
            CGFloat(kMediumRowHeight)
        case .huge:
            CGFloat(kHighRowFrameWidth)
        case .big:
            CGFloat(kRowHeight)
        }
        let barHeight = cardHeight ?? height
        let cnt = CGFloat(count)
        return CGSize(width: SizeHelper.trackerWidth, height: barHeight * cnt)
    }
    
    override var intrinsicContentSize: NSSize {
        return internalIntrinsicContentSize(count)
    }

    @discardableResult func update(cards: [Card], reset: Bool) -> Bool {
        assertMainThread()
        return lock.around {
            if reset {
                animatedCards.removeAll()
            }
            cardCount = cards.count

            var newCards = [Card]()
            for card in cards {
                if let existing = animatedCards.first(where: {
                    if let c0 = $0.card {
                        return self.areEqualForList(c0, card)
                    }
                    return false
                }) {
                    if existing.card?.count != card.count || existing.card?.highlightInHand != card.highlightInHand {
                        let highlight = existing.card?.count != card.count
                        existing.card?.count = card.count
                        existing.card?.highlightInHand = card.highlightInHand
                        existing.update(highlight: highlight)
                    } else if existing.card?.isCreated != card.isCreated {
                        existing.update(highlight: false)
                    } else if existing.card?.extraInfo?.cardNameSuffix != card.extraInfo?.cardNameSuffix {
                        existing.card?.extraInfo = card.extraInfo?.copy() as? (any ICardExtraInfo)
                        existing.update(highlight: true)
                    }
                } else {
                    newCards.append(card)
                }
            }

            var toUpdate = [CardBar]()
            for c in animatedCards {
                if let card = c.card, !cards.any({ self.areEqualForList($0, card) }) {
                    toUpdate.append(c)
                }
            }
            var toRemove: [CardBar: Bool] = [:]
            for card in toUpdate {
                let newCard = newCards.first { $0.id == card.card?.id }
                toRemove[card] = newCard == nil
                if let newCard = newCard {
                    let newAnimated = CardBar.factory()
                    newCard.highlightColor = shouldHighlightCard?(newCard, animatedCards.filter({ ac in ac.card?.count ?? 0 > 0 }).compactMap({ ac in ac.card })) ?? .none
                    newAnimated.playerType = self.playerType
                    newAnimated.isBattlegrounds = isBattlegrounds
                    if let delegate = delegate {
                        newAnimated.setDelegate(delegate)
                    }
                    newAnimated.card = newCard

                    if let index = animatedCards.firstIndex(of: card) {
                        animatedCards.insert(newAnimated, at: index)
                        newAnimated.update(highlight: true)
                        newCards.remove(newCard)
                    }
                }
            }
            for (cardCellView, fadeOut) in toRemove {
                remove(card: cardCellView, fadeOut: fadeOut)
            }
            
            for card in newCards {
                let newCard = CardBar.factory()
                newCard.playerType = self.playerType
                if let delegate = delegate {
                    newCard.setDelegate(delegate)
                }
                newCard.card = card
                newCard.isBattlegrounds = isBattlegrounds
                newCard.card?.highlightColor = shouldHighlightCard?(card, animatedCards.filter({ ac in ac.card?.count ?? 0 > 0 }).compactMap({ ac in ac.card })) ?? .none
                if let index = cards.firstIndex(of: card), index <= animatedCards.count {
                    animatedCards.insert(newCard, at: index)
                } else {
                    animatedCards.append(newCard)
                }
                newCard.fadeIn(highlight: !reset)
            }

            return toRemove.count > 0
        }
    }
    
    private func remove(card: CardBar, fadeOut: Bool) {
        if fadeOut {
            card.fadeOut(highlight: (card.card?.count ?? 0) > 0)
            let when = DispatchTime.now()
                + Double(Int64(600 * Double(NSEC_PER_MSEC))) / Double(NSEC_PER_SEC)
            let queue = DispatchQueue.main
            queue.asyncAfter(deadline: when) {
                self.lock.around {
                    self.animatedCards.remove(card)
                }
            }
        } else {
            animatedCards.remove(card)
        }
    }

    fileprivate func areEqualForList(_ c1: Card, _ c2: Card) -> Bool {
        let ei = (c1.extraInfo as? IncindiusCounter) == (c2.extraInfo as? IncindiusCounter)
        return c1.id == c2.id && c1.jousted == c2.jousted && c1.isCreated == c2.isCreated
        && (!Settings.highlightDiscarded || c1.wasDiscarded == c2.wasDiscarded) && c1.deckListIndex == c2.deckListIndex && ei
    }
    
    func updateFrames() {
        assertMainThread()
        lock.around {
            let ics = internalIntrinsicContentSize(cardCount)
            var y = ics.height
            let rowHeight = cardHeight ?? (animatedCards.isEmpty ? 0 : ics.height / CGFloat(animatedCards.count))
            let width = frame.width

            // Only the bars that have actually left the list are detached. This
            // used to tear the whole hierarchy down and rebuild it on every
            // refresh - twice a second during a match - which besides the
            // churn also broke hover: a CardBar pulled out from under the
            // cursor never gets its mouseExited, and the bar that replaces it
            // gets no mouseEntered until the mouse moves again, so the card
            // tooltip kept showing whatever had been hovered before.
            for view in subviews where !animatedCards.contains(where: { $0 === view }) {
                view.removeFromSuperview()
            }

            for cell in animatedCards {
                y -= rowHeight
                let cellFrame = NSRect(x: 0, y: y, width: width, height: rowHeight)
                if cell.frame != cellFrame {
                    cell.frame = cellFrame
                }
                if cell.superview !== self {
                    addSubview(cell)
                }
            }
        }
    }
}
