//
//  CaseIterable.swift
//  HSTracker
//
//  Created by Francisco Moraes on 9/16/26.
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

extension CaseIterable where AllCases.Index == Int {
    /// The case at `index`, or nil when the game names a value this build does not.
    ///
    /// Hearthstone hands these enums over as plain integers - through HearthMirror, the
    /// power log and CardDefs - and every patch is free to append new ones. Subscripting
    /// `allCases` with such a value traps, which is how a scene id the SceneMgr knew and
    /// `Mode` did not took the whole app down from the SceneWatcher queue. HDT casts the
    /// integer instead, so an unknown value there is merely a nameless enum case that
    /// matches nothing; `at(_:)` is the same idea, with the unknown case spelled nil.
    static func at(_ index: Int) -> Self? {
        let all = allCases
        guard index >= 0, index < all.count else {
            return nil
        }
        return all[index]
    }
}
