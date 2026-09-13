//
//  HeroPower.swift
//  HSTracker
//
//  Created by Christopher Herrera on 3/16/17.
//  Copyright (c) 2017 Benjamin Michotte. All rights reserved.
//

import Foundation

class HeroPower {
    /// How a hero power's damage reaches the enemy hero, which decides when it can be counted
    enum Kind {
        /// Deals the damage itself
        case direct
        /// Gives the hero Attack this turn (Shapeshift, Demon Claws), so it needs the hero to attack
        case heroAttack
        /// Equips a weapon (Dagger Mastery), so it needs the hero to attack, and gains nothing over a
        /// weapon already equipped
        case weapon
        /// Summons a minion with Charge (Ghoul Charge), so it needs a free board slot
        case chargeMinion
    }

    var _entity: Entity
    var id: String
    var cost: Int
    var name: String?

    var kind: Kind {
        if let englishName = englishName, let kind = HeroPower.byName[englishName]?.kind {
            return kind
        }
        switch id {
        case CardIds.NonCollectible.Druid.Shapeshift, CardIds.NonCollectible.Druid.JusticarTrueheart_DireClaws:
            return .heroAttack
        default:
            return .direct
        }
    }

    var damage: Int {
        if let englishName = englishName, let damage = HeroPower.byName[englishName]?.damage {
            return damage
        }
        return tableDamage ?? 0
    }

    /// Current basic hero powers and their skins have their own ids (HERO_05bp, HERO_08dbp, ...) that
    /// the id table below never learned, so they are matched by English name, which every skin shares.
    /// Powers that don't add damage this turn (armor, healing, cards, totems, 1/1 Recruits without
    /// Charge) count as 0.
    private static let byName: [String: (damage: Int, kind: Kind)] = [
        "Fireblast": (1, .direct),
        "Fireblast Rank 2": (2, .direct),
        "Steady Shot": (2, .direct),
        "Ballista Shot": (3, .direct),
        "Shapeshift": (1, .heroAttack),
        "Dire Shapeshift": (2, .heroAttack),
        "Demon Claws": (1, .heroAttack),
        "Demon's Bite": (2, .heroAttack),
        "Dagger Mastery": (1, .weapon),
        "Poisoned Daggers": (2, .weapon),
        "Ghoul Charge": (1, .chargeMinion),
        "Ghoul Frenzy": (2, .chargeMinion)
    ]

    private var englishName: String? {
        // Cards.by(cardId:) leaves hero powers out
        return Cards.cardsById[id]?.enName
    }

    private var tableDamage: Int? {
        switch id {
        case CardIds.NonCollectible.Druid.Shapeshift,
             CardIds.NonCollectible.Mage.Fireblast,
             CardIds.NonCollectible.Mage.Fireblast_FireblastHeroSkins1,
             CardIds.NonCollectible.Mage.FrostLichJaina_IcyTouch,
             CardIds.NonCollectible.Mage.Fireblast_FireblastHeroSkins2:
            return 1
        case CardIds.NonCollectible.Druid.JusticarTrueheart_DireClaws,
             CardIds.NonCollectible.Priest.Shadowform_MindSpikeToken,
             CardIds.NonCollectible.Hunter.SteadyShot,
             CardIds.NonCollectible.Priest.ShadowreaperAnduin_Voidform,
             CardIds.NonCollectible.Neutral.Eruption,
             CardIds.NonCollectible.Neutral.BoomBotJrTavernBrawl,
             CardIds.NonCollectible.Mage.FireblastRank2HeroSkins1,
             CardIds.NonCollectible.Mage.FireblastRank2HeroSkins2,
             CardIds.NonCollectible.Mage.JusticarTrueheart_FireblastRank2,
             CardIds.NonCollectible.Shaman.ChargedHammer_LightningJoltToken:
            return 2
        case CardIds.NonCollectible.Priest.Shadowform_MindShatterToken,
             CardIds.NonCollectible.Neutral.EruptionHeroic,
             "TB_FW_HeroPower_Boom",
             CardIds.NonCollectible.Neutral.ThrowRocks,
             CardIds.NonCollectible.Warlock.BloodreaverGuldan_SiphonLife,
             CardIds.NonCollectible.Druid.MalfurionthePestilent_PlagueLord,
             CardIds.NonCollectible.Hunter.BallistaShotHeroSkins,
             CardIds.NonCollectible.Hunter.JusticarTrueheart_BallistaShot:
            return 3
        case CardIds.NonCollectible.Neutral.UnbalancingStrike:
            return 4
        case CardIds.NonCollectible.Neutral.MajordomoExecutus_DieInsectHeroPower:
            return 8
        case CardIds.NonCollectible.Neutral.MajordomoExecutus_DieInsects:
            return 16
        default:
            return nil
        }
    }

    init(entity: Entity) {
        self.cost = entity[.cost]
        self.name = entity.name
        self.id = entity.cardId
        self._entity = entity
    }
}
