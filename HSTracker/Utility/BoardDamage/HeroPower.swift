//
//  HeroPower.swift
//  HSTracker
//
//  Created by Christopher Herrera on 3/16/17.
//  Copyright (c) 2017 Benjamin Michotte. All rights reserved.
//

import Foundation

class HeroPower {
    var _entity: Entity
    var id: String
    var cost: Int
    var name: String?

    /// Hero powers that give the hero Attack for the turn instead of dealing damage directly, so they
    /// only add damage while the hero can still attack.
    var isHeroAttack: Bool {
        return id == CardIds.NonCollectible.Druid.Shapeshift || HeroPower.heroAttackNames.contains(englishName ?? "")
    }

    var damage: Int {
        if let damage = tableDamage {
            return damage
        }
        if let englishName = englishName, let damage = HeroPower.damageByName[englishName] {
            return damage
        }
        return 0
    }

    /// Current basic hero powers and their skins have their own ids (HERO_05bp, HERO_08dbp, ...) that
    /// the id table below never learned, so the plain ones are matched by English name as well.
    private static let damageByName: [String: Int] = [
        "Fireblast": 1,
        "Shapeshift": 1,
        "Steady Shot": 2,
        "Fireblast Rank 2": 2,
        "Dire Shapeshift": 2,
        "Ballista Shot": 3
    ]
    private static let heroAttackNames: Set<String> = ["Shapeshift", "Dire Shapeshift"]

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
