//
//  Mode.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 27/02/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

enum Mode: String, CaseIterable {
    case invalid,
    startup,
    login,
    hub,
    gameplay,
    collectionmanager,
    packopening,
    tournament,
    friendly,
    fatal_error,
    draft,
    credits,
    reset,
    adventure,
    tavern_brawl,
    bacon,
    game_mode,
    pvp_dungeon_run,
    bacon_collection,
    lettuce_village,
    lettuce_bounty_board,
    lettuce_map,
    lettuce_play,
    lettuce_collection,
    lettuce_coop,
    lettuce_friendly,
    lettuce_bounty_team_select,
    lettuce_pack_opening,
    lucky_draw,
    black_market
}

extension Mode {
    /// The scene the game reports through SceneMgr, as seen by HearthMirror.
    ///
    /// The ids are this enum's own order, which mirrors HDT's Mode. Hearthstone adds
    /// scenes when it patches, and reads taken while it is still starting up are not
    /// necessarily a scene at all, so anything this build has no case for is reported as
    /// `.invalid` - the scene HSTracker already shows nothing for - rather than trapping
    /// on the watcher's queue. Each unknown id is logged once, so a new scene can be
    /// added here from a user's log.
    static func from(sceneMode index: Int) -> Mode {
        if let mode = Mode.allCases[safeIndex: index] {
            return mode
        }
        unknownSceneModesLock.around {
            if loggedUnknownSceneModes.insert(index).inserted {
                logger.warning("Hearthstone reported scene mode \(index), which this build has no Mode for; treating it as invalid")
            }
        }
        return .invalid
    }

    private static let unknownSceneModesLock = UnfairLock()
    private static var loggedUnknownSceneModes = Set<Int>()
}
