//
//  Cards.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 24/05/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

final class Cards {
    
    static let classes: [CardClass] = {
        return [.druid, .hunter, .mage, .paladin, .priest,
                .rogue, .shaman, .warlock, .warrior, .demonhunter, .deathknight]
            .sorted { String.localizedString($0.rawValue, comment: "")
                < String.localizedString($1.rawValue, comment: "") }
    }()

    static let classesPlusNeutral: [CardClass] = {
        return [.druid, .hunter, .mage, .paladin, .priest,
                .rogue, .shaman, .warlock, .warrior, .demonhunter, .deathknight, .neutral]
            .sorted { String.localizedString($0.rawValue, comment: "")
                < String.localizedString($1.rawValue, comment: "") }
    }()
    
    static var cards = SynchronizedArray<Card>()
    // map used to quickly find cards by id
    static var cardsById = SynchronizedDictionary<String, Card>()
    // battlegrounds miniona only
    static var battlegroundsMinions = SynchronizedArray<Card>()

    static func hero(byId cardId: String) -> Card? {
        if let card = cardsById[cardId] {
            if card.type == .hero {
                return card.copy()
            }
        }
        return nil
    }

    static func isHero(cardId: String?) -> Bool {
        guard let cardId, !cardId.isBlank else { return false }

        // Was `hero(byId:) != .none`, which deep-copied the whole Card just to
        // throw it away. CardBar.draw() asks this twice per bar per redraw.
        return cardsById[cardId]?.type == .hero
    }
    
    static func isPlayableHero(cardId: String?) -> Bool {
        guard !cardId.isBlank else {
            return false
        }
        
        if let card = cardsById[cardId!] {
            if card.type == .hero && card.set != CardSet.hero_skins {
                return true
            }
        }
        return false
    }

    static func by(cardId: String?) -> Card? {
        guard !cardId.isBlank else { return nil }

        if let card = cardsById[cardId!] {
            if card.type != .hero_power && (card.type != .hero || (card.type == .hero && card.set != CardSet.hero_skins)) {
                return card.copy()
            }
        }
        return nil
    }

    static func by(dbfId: Int?, collectible: Bool = true) -> Card? {
        guard let dbfId = dbfId else { return nil }

        // Indexed rather than scanned: this used to walk the whole database (and,
        // for the collectible variant, rebuild the filtered collectible list first)
        // on every lookup, and it is called from hover and per-minion paths.
        let index = collectible ? collectibleCardsByDbfId() : cardsByDbfId()
        return index[dbfId]?.copy()
    }

    static func any(byId cardId: String) -> Card? {
        guard !cardId.isBlank else { return nil }

        if let card = cardsById[cardId] {
            return card.copy()
        }
        return nil
    }
    
    static func hero(byPlayerClass name: CardClass) -> Card? {
        switch name {
        case .druid: return hero(byId: CardIds.Collectible.Druid.MalfurionStormrage)
        case .hunter: return hero(byId: CardIds.Collectible.Hunter.Rexxar)
        case .mage: return hero(byId: CardIds.Collectible.Mage.JainaProudmoore)
        case .paladin: return hero(byId: CardIds.Collectible.Paladin.UtherLightbringer)
        case .priest: return hero(byId: CardIds.Collectible.Priest.AnduinWrynn)
        case .rogue: return hero(byId: CardIds.Collectible.Rogue.ValeeraSanguinar)
        case .shaman: return hero(byId: CardIds.Collectible.Shaman.Thrall)
        case .warlock: return hero(byId: CardIds.Collectible.Warlock.Guldan)
        case .warrior: return hero(byId: CardIds.Collectible.Warrior.GarroshHellscream)
        default: return nil
        }
    }

    static func by(name: String) -> Card? {
        if let card = collectible().first(where: { $0.name == name }) {
            return card.copy()
        }
        return nil
    }

    static func by(englishName name: String) -> Card? {
        if let card = collectible().first(where: { $0.enName == name || $0.name == name }) {
            return card.copy()
        }
        return nil
    }
    
    static func by(englishNameCaseInsensitive name: String) -> Card? {
        if let card = collectible().first(where: {
            $0.enName.caseInsensitiveCompare(name) == ComparisonResult.orderedSame ||
                $0.name.caseInsensitiveCompare(name) == ComparisonResult.orderedSame
        }) {
            return card.copy()
        }
        return nil
    }

    // MARK: - Derived views of the card database
    //
    // The database is filled once at startup and never mutated afterwards, so
    // the collectible subset and the dbf-id indexes are derived once on first
    // use. `invalidateDerived()` covers the load itself, which appends card by
    // card, and any future reload.

    private static let derivedLock = UnfairLock()
    private static var derivedGeneration = 0
    private static var collectibleCache: [Card]?
    private static var cardsByDbfIdCache: [Int: Card]?
    private static var collectibleByDbfIdCache: [Int: Card]?

    static func invalidateDerived() {
        derivedLock.around {
            derivedGeneration &+= 1
            collectibleCache = nil
            cardsByDbfIdCache = nil
            collectibleByDbfIdCache = nil
        }
    }

    /// Runs `build` outside the lock, then keeps the result only if the database
    /// did not change while it ran. Without the generation check, a lookup that
    /// races the initial load could cache a view of a half-filled database and
    /// then hand it out for the rest of the session.
    private static func derived<T>(_ cached: () -> T?, _ build: () -> T, _ store: @escaping (T) -> Void) -> T {
        if let value = derivedLock.around(cached) {
            return value
        }
        let generation = derivedLock.around { derivedGeneration }
        let built = build()
        derivedLock.around {
            if derivedGeneration == generation {
                store(built)
            }
        }
        return built
    }

    private static func isCollectible(_ card: Card) -> Bool {
        return card.collectible && card.type != .hero_power &&
            (card.type != .hero || (card.type == .hero && card.set != CardSet.expert1 && card.set != CardSet.hero_skins))
            || card.set == CardSet.wild_event
    }

    /// First card per dbf id, in database order - the same card `first(where:)`
    /// used to return.
    private static func index(of list: [Card]) -> [Int: Card] {
        var result = [Int: Card]()
        result.reserveCapacity(list.count)
        for card in list where result[card.dbfId] == nil {
            result[card.dbfId] = card
        }
        return result
    }

    static func collectible() -> [Card] {
        return derived({ collectibleCache },
                       { cards.filter { isCollectible($0) } },
                       { collectibleCache = $0 })
    }

    private static func cardsByDbfId() -> [Int: Card] {
        return derived({ cardsByDbfIdCache },
                       { index(of: cards.array()) },
                       { cardsByDbfIdCache = $0 })
    }

    private static func collectibleCardsByDbfId() -> [Int: Card] {
        return derived({ collectibleByDbfIdCache },
                       { index(of: collectible()) },
                       { collectibleByDbfIdCache = $0 })
    }
    
    static func indexOf(id: String) -> Int {
        var low = 0
        var high = cards.count - 1

        while low <= high {
            let mid = (low + high)/2
            let midVal = cards[mid]

            if midVal.id < id {
                 low = mid + 1
            } else if midVal.id > id {
                 high = mid - 1
            } else {
                 return mid
            }
         }
        
         return -(low + 1)
    }

    static func search(className: CardClass?, sets: [CardSet] = [],
                       term: String = "", cost: Int = -1,
                       rarity: Rarity? = .none, standardOnly: Bool = false,
                       damage: Int = -1, health: Int = -1, type: CardType = .invalid,
                       race: Race?) -> [Card] {
        var cards = collectible()

        if term.isEmpty {
            cards = cards.filter { $0.isClass(cardClass: className ?? .neutral) }
        } else {
            cards = cards.filter { $0.isClass(cardClass: className ?? .neutral) || $0.playerClass == .neutral && $0.multiClassGroup == .invalid }
                .filter {
                    $0.name.lowercased().contains(term.lowercased()) ||
                        $0.enName.lowercased().contains(term.lowercased()) ||
                        $0.text.lowercased().contains(term.lowercased()) ||
                        $0.rarity.rawValue.contains(term.lowercased()) ||
                        $0.type.rawString().lowercased().contains(term.lowercased()) ||
                        $0.race.rawValue.lowercased().contains(term.lowercased())
            }
        }

        if type != .invalid {
            cards = cards.filter { $0.type == type }
        }

        if let race = race {
            cards = cards.filter { $0.race == race }
        }

        if health != -1 {
            cards = cards.filter { $0.health == health }
        }

        if damage != -1 {
            cards = cards.filter { $0.attack == damage }
        }

        if standardOnly {
            cards = cards.filter { $0.isStandard }
        }

        if let rarity = rarity {
            cards = cards.filter { $0.rarity == rarity }
        }

        if !sets.isEmpty {
            cards = cards.filter { $0.set != nil && sets.contains($0.set!) }
        }

        if cost != -1 {
            cards = cards.filter {
                if cost == 7 {
                    return $0.cost >= 7
                }
                return $0.cost == cost
            }
        }

        return cards.sortCardList()
    }
    
    static func getBattlegroundsHeroFromDbfid(dbfId: Int) -> Card? {
        let hero = Cards.by(dbfId: dbfId, collectible: false)
        if let parentSkinDbfid = hero?.battlegroundsSkinParentId, parentSkinDbfid > 0 {
            return Cards.by(dbfId: parentSkinDbfid, collectible: false)
        }
        return hero
    }
    
    static func isValidCardId(_ cardId: String) -> Bool {
        return cardsById.containsKey(cardId)
    }
}
