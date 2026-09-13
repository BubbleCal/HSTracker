/*
 * This file is part of the HSTracker package.
 * (c) Benjamin Michotte <bmichotte@gmail.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 *
 * Created on 13/02/16.
 */

import Foundation

class TagChangeHandler {

    let ParseEntityIDRegex = Regex("id=(\\d+)")
    let ParseEntityZonePosRegex = Regex("zonePos=(\\d+)")
    let ParseEntityPlayerRegex = Regex("player=(\\d+)")
    let ParseEntityNameRegex = Regex("name=(\\w+)")
    let ParseEntityZoneRegex = Regex("zone=(\\w+)")
    let ParseEntityCardIDRegex = Regex("cardId=(\\w+)")
    let ParseEntityTypeRegex = Regex("type=(\\w+)")

    private var creationTagActionQueue: [(id: Int, action: (() -> Void))] = []
    private var tagChangeAction = TagChangeActions()
    // The parser owns this handler; the action history reads its current block's OVERRIDE_HISTORY flag
    private weak var powerGameStateParser: PowerGameStateParser?
    
    func setPowerGameStateParser(parser: PowerGameStateParser) {
        powerGameStateParser = parser
        tagChangeAction.setPowerGameStateParser(parser: parser)
    }

    func tagChange(eventHandler: PowerEventHandler, rawTag: String, id: Int,
                   rawValue: String, isCreationTag: Bool = false) {
        if let tag = GameTag(rawString: rawTag) {
            let value = self.parseTag(tag: tag, rawValue: rawValue)
            tagChange(eventHandler: eventHandler, tag: tag, id: id, value: value,
                      isCreationTag: isCreationTag)
        } else {
            //logger.warning("Can't parse \(rawTag) -> \(rawValue)")
        }
    }

    func tagChange(eventHandler: PowerEventHandler, tag: GameTag, id: Int,
                   value: Int, isCreationTag: Bool = false) {
        if eventHandler.entities[id] == .none {
            eventHandler.entities[id] = Entity(id: id)
        }
        
        eventHandler.lastId = id

        if let entity = eventHandler.entities[id] {
            let prevValue = entity[tag]
            if prevValue == value {
                return
            }
            entity[tag] = value

            // The action history reads the raw value as it is set. Queued creation-tag actions run
            // only after the block moved on, too late to tell which block caused the change.
            if let game = eventHandler as? Game {
                game.actionHistory.tagChanged(entity: entity, tag: tag, prevValue: prevValue, value: value,
                                              isCreationTag: isCreationTag,
                                              hideShowEntities: powerGameStateParser?.currentBlock?.hideShowEntities ?? false,
                                              localPlayerId: eventHandler.player?.id ?? 0, entities: eventHandler.entities)
                // Attacks, freezes and Attack changes don't refresh the trackers on their own, and the
                // board damage counters must follow them as they happen
                if BoardState.affectsBoardDamage(entity: entity, tag: tag, prevValue: prevValue, value: value) {
                    game.updateBoardDamage()
                }
                // A draw is read here for the same reason, and for either controller: a SHOW_ENTITY's
                // queued ZONE action waits until both player ids are known, which on a Power.log backlog
                // replayed before HearthMirror answered is turns later, or never for a game already over
                if tag == .zone && prevValue == Zone.deck.rawValue && value == Zone.hand.rawValue && id > 3 {
                    game.mulliganRecorder.cardDrawn(playerId: entity[.controller], entityId: id, cardId: entity.info.latestCardId,
                                                    gameTurn: eventHandler.gameEntity?[.turn] ?? 0)
                }
            }

            if isCreationTag {
                if let action = tagChangeAction.findAction(eventHandler: eventHandler,
                                                        tag: tag,
                                                        id: id,
                                                        value: value,
                                                        prevValue: prevValue) {
                    entity.info.hasOutstandingTagChanges = true
                    creationTagActionQueue.append((id: id, action: action))
                }
            } else {
                tagChangeAction.findAction(eventHandler: eventHandler, tag: tag,
                                           id: id, value: value,
                                           prevValue: prevValue)?()
            }
        }
    }

    func invokeQueuedActions(eventHandler: PowerEventHandler) {
        while creationTagActionQueue.count > 0 {
            let action = creationTagActionQueue.removeFirst()
            action.action()

            if creationTagActionQueue.all({ $0.id != action.id }), let entity = eventHandler.entities[action.id] {
                entity.info.hasOutstandingTagChanges = false
                // Player.board leaves out entities with outstanding tag changes, so a minion created in
                // play joins the board damage only now, whenever the refresh its ZONE tag asked for ran
                if entity.isInPlay {
                    (eventHandler as? Game)?.updateBoardDamage()
                }
            }
        }
    }

    func clearQueuedActions() {
        if creationTagActionQueue.count > 0 {
            logger.warning("Clearing tagActionQueue with \(creationTagActionQueue.count)"
                + " elements in it")
        }
        creationTagActionQueue.removeAll()
    }

    struct LogEntity {
        var id: Int?
        var zonePos: Int?
        var player: Int?
        var name: String?
        var zone: String?
        var cardId: String?
        var type: String?

        func isValid() -> Bool {
            let a: [Any?] = [id, zonePos, player, name, zone, cardId, type]
            return a.any { $0 != nil }
        }
    }

    // parse an entity
    func parseEntity(entity: String) -> LogEntity {
        var id: Int?, zonePos: Int?, player: Int?
        var name: String?, zone: String?, cardId: String?, type: String?

        if ParseEntityIDRegex.match(entity) {
            if let match = ParseEntityIDRegex.matches(entity).first {
                id = Int(match.value)
            }
        }
        if ParseEntityZonePosRegex.match(entity) {
            if let match = ParseEntityZonePosRegex.matches(entity).first {
                zonePos = Int(match.value)
            }
        }
        if ParseEntityPlayerRegex.match(entity) {
            if let match = ParseEntityPlayerRegex.matches(entity).first {
                player = Int(match.value)
            }
        }
        if ParseEntityNameRegex.match(entity) {
            if let match = ParseEntityNameRegex.matches(entity).first {
                name = match.value
            }
        }
        if ParseEntityZoneRegex.match(entity) {
            if let match = ParseEntityZoneRegex.matches(entity).first {
                zone = match.value
            }
        }
        if ParseEntityCardIDRegex.match(entity) {
            if let match = ParseEntityCardIDRegex.matches(entity).first {
                cardId = match.value
            }
        }
        if ParseEntityTypeRegex.match(entity) {
            if let match = ParseEntityTypeRegex.matches(entity).first {
                type = match.value
            }
        }

        return LogEntity(id: id, zonePos: zonePos, player: player,
                         name: name, zone: zone, cardId: cardId, type: type)
    }

    // check if the entity is a raw entity
    func isEntity(rawEntity: String) -> Bool {
        return parseEntity(entity: rawEntity).isValid()
    }

    func parseTag(tag: GameTag, rawValue: String) -> Int {
        switch tag {
        case .zone:
            return Zone(rawString: rawValue)!.rawValue

        case .mulligan_state:
            return Mulligan(rawString: rawValue)!.rawValue

        case .playstate:
            return PlayState(rawString: rawValue)!.rawValue

        case .cardtype:
            return CardType(rawString: rawValue)!.rawValue

        case .class:
            return TagClass(rawString: rawValue)!.rawValue

        case .state:
            return State(rawString: rawValue)!.rawValue
            
        case .step:
            return Step(rawString: rawValue)!.rawValue

        default:
            if let value = Int(rawValue) {
                return value
            }
            return 0
        }
    }
}
