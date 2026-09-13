//
//  Block.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 5/12/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

class Block {
    let parent: Block?
    var children: [Block]
    let id: Int
    let type: String?
    let cardId: String?
    let target: String?
    // Entity id from the BLOCK_START Target field; nil for "Target=0"
    let targetEntityId: Int?
    
    let triggerKeyword: String?
    
    var sourceEntityId = 0
    var dredgeCounter = 0
    
    var hasFullEntityHeroPackets = false
    
    var entityDiscardedByArchivist: Entity?
    
    var entitiesCreatedInDeck = [(entity: Entity, ids: Set<Int>)]()
    
    var isTradeableAction = false
    
    var hideShowEntities = false
   
    init(parent: Block?, id: Int, type: String?, cardId: String?, target: String?, targetEntityId: Int? = nil, trigger: String?) {
        self.parent = parent
        self.children = []
        self.id = id
        self.type = type
        self.cardId = cardId
        self.target = target
        self.targetEntityId = targetEntityId
        self.triggerKeyword = trigger
    }

    func createChild(blockId: Int, type: String?, cardId: String?, target: String?, targetEntityId: Int? = nil, trigger: String?) -> Block {
        return Block(parent: self, id: blockId, type: type, cardId: cardId, target: target, targetEntityId: targetEntityId, trigger: trigger)
    }
}
