//
//  ActionHistoryLineParser.swift
//  HSTracker
//
//  Reads the fields of a Power.log BLOCK_START line for the action history.
//
//  PowerGameStateParser already stores the block type, TriggerKeyword and Target entity id on
//  Block, but the history cannot take the block from there:
//  - BlockStartRegex needs "id=", "cardId=" and "player=" in the line, so blocks started by the
//    game or a player ("Entity=GameEntity", "Entity=Name#1234") do not match it and get a nil
//    type. Those are the DEATHS blocks and the turn-start draws, about half of all blocks.
//  - Block.sourceEntityId is only set for TRIGGER and POWER blocks, and only after the code that
//    runs right after blockStart.
//  Changing either would alter parser branches that trackers and the secret helper rely on, so
//  this parses the line on its own. It anchors each field on the field that follows it, as HDT's
//  BlockStartRegex does, which keeps names with spaces or brackets
//  ("UNKNOWN ENTITY [cardType=INVALID]") intact, and it agrees with Block's fields on the lines
//  both can read (see ActionHistoryLineParserTests).
//

import Foundation

enum ActionHistoryLineParser {
    // HDT: BLOCK_START BlockType=(?<type>(\w+)) Entity=(?<entity>(.*)) EffectCardId=(?<effectCardId>(.*))
    //      EffectIndex=(?<effectIndex>(.*)) Target=(?<target>(.+)) SubOption=(?<subOption>(.+))( TriggerKeyword=(?<triggerKeyword>(.*)))?
    // The entity ends at the first EffectCardId (whose value has no spaces), the target at the last
    // SubOption, and the line has to end after the optional TriggerKeyword.
    private static let blockStartRegex = makeRegex(
        "BLOCK_START BlockType=(\\w+) Entity=(.+?) EffectCardId=\\S* EffectIndex=(-?\\d+) Target=(.+) SubOption=(\\S*)(?:\\s+TriggerKeyword=(\\w+))?\\s*$")
    // The fields after entityName have a fixed shape, so read the id from the end of the entity:
    // the name itself may contain anything.
    private static let entityIdRegex = makeRegex(
        "\\sid=(\\d+)\\s+zone=\\w*\\s+zonePos=-?\\d+\\s+cardId=\\S*\\s+player=\\d+\\]$")
    // Fallback should the client ever reorder or add fields
    private static let looseEntityIdRegex = makeRegex("\\sid=(\\d+)")

    static func parseBlockStart(_ line: String) -> HistoryBlockInfo? {
        guard line.contains("BLOCK_START") else {
            return nil
        }
        let groups = captureGroups(blockStartRegex, in: line)
        guard groups.count == 6, let blockType = groups[0] else {
            return nil
        }
        let entity = groups[1]?.trimmingCharacters(in: .whitespaces) ?? ""
        let sourceKind: HistoryBlockInfo.SourceKind
        let sourceEntityId: Int?
        if let id = entityId(entity) {
            sourceKind = .entity
            sourceEntityId = id
        } else if entity == "GameEntity" {
            sourceKind = .gameEntity
            sourceEntityId = nil
        } else {
            // Players are written by their name (a BattleTag, or the AI's name)
            sourceKind = .player
            sourceEntityId = nil
        }

        let targetEntityId = groups[3].flatMap { entityId($0.trimmingCharacters(in: .whitespaces)) }

        return HistoryBlockInfo(blockType: blockType,
                                sourceKind: sourceKind,
                                sourceEntityId: sourceEntityId,
                                targetEntityId: targetEntityId,
                                triggerKeyword: groups[5],
                                effectIndex: groups[2].flatMap { Int($0) },
                                subOption: groups[4].flatMap { Int($0) })
    }

    /// The id of an entity field: "[entityName=... id=12 ...]" or a bare number. Nil for "0" and
    /// for names, which is how the log writes the GameEntity and players.
    static func entityId(_ field: String) -> Int? {
        if field.hasPrefix("[") {
            var groups = captureGroups(entityIdRegex, in: field)
            if groups.isEmpty {
                groups = captureGroups(looseEntityIdRegex, in: field)
            }
            guard let id = groups.first ?? nil, let value = Int(id), value > 0 else {
                return nil
            }
            return value
        }
        guard let value = Int(field), value > 0 else {
            return nil
        }
        return value
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Illegal regular expression: \(pattern).")
        }
    }

    // Unlike Regex.matches, keeps a nil slot for an optional group that did not take part, so
    // the indexes stay fixed. Ranges are UTF-16 based, as NSRegularExpression works in.
    private static func captureGroups(_ regex: NSRegularExpression, in string: String) -> [String?] {
        let range = NSRange(location: 0, length: string.utf16.count)
        guard let result = regex.firstMatch(in: string, options: [], range: range) else {
            return []
        }
        return (1 ..< result.numberOfRanges).map { index in
            let groupRange = result.range(at: index)
            guard groupRange.location != NSNotFound, let range = Range(groupRange, in: string) else {
                return nil
            }
            return String(string[range])
        }
    }
}
