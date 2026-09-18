//
//  Events.swift
//  HSTracker+
//
//  Created by Fehervari, Istvan on 1/4/18.
//  Copyright © 2018 Benjamin Michotte. All rights reserved.
//

import Foundation

class Events {
    
    static let reload_decks = "reload_decks"

    // A game was recorded, deleted or moved (e.g. into a No-deck bucket). Separate
    // from reload_decks so a game end does not rebuild the Decks menu or refresh
    // every tracker.
    static let game_stats_changed = "game_stats_changed"
    
    static let space_changed = "space_changed"
    
    static let hearthstone_closed = "hearthstone_closed"
    static let hearthstone_running = "hearthstone_running"
    static let hearthstone_active = "hearthstone_active"
    static let hearthstone_deactived = "hearthstone_deactived"
    
    // Fired by Tier7Trial once a trial token has been obtained, mirroring HDT's
    // Tier7Trial.OnTrialActivated event. Lets the Battlegrounds Minions tab turn
    // its inspiration indicators on the moment a trial starts rather than at the
    // next match.
    static let tier7_trial_activated = "tier7_trial_activated"
}
