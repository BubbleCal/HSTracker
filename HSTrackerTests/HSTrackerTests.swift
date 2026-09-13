//
//  HSTrackerTests.swift
//  HSTrackerTests
//
//  Created by Benjamin Michotte on 19/02/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import XCTest
import RealmSwift

@testable import HSTracker

class HSTrackerTests: XCTestCase {

    override func setUp() {
        super.setUp()

        // initialize test realm's database
        Realm.Configuration.defaultConfiguration.inMemoryIdentifier = self.name
        // Every test starts from the settings' defaults, whatever an earlier one changed
        (settingsDefaults as? VolatileUserDefaults)?.removeAll()
    }

    override func tearDown() {
        super.tearDown()
    }

}

/// The unit tests run inside HSTracker.app, on whatever machine they are started on. What a test sees
/// must not depend on that machine's HSTracker settings or on a Hearthstone client running next to it.
class TestHostIsolationTests: HSTrackerTests {

    func testSettingsAreKeptInMemoryAndStartFromTheirDefaults() {
        guard let store = settingsDefaults as? VolatileUserDefaults, store !== UserDefaults.standard else {
            // Checked before writing anything: the store below would be the player's own settings
            return XCTFail("the test host's settings are the player's HSTracker defaults")
        }
        // Defaults, even where the player's own settings turn them on
        XCTAssertFalse(Settings.removeSecretsFromList)
        XCTAssertTrue(Settings.autoGrayoutSecrets)

        let key = "unit_test_probe_\(UUID().uuidString)"
        var probe = UserDefault(key: key, defaultValue: 0)
        probe.wrappedValue = 5
        XCTAssertEqual(probe.wrappedValue, 5)
        XCTAssertEqual(store.integer(forKey: key), 5)
        XCTAssertEqual(store.double(forKey: key), 5)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))

        // Straight into the store: the setting's own setter would notify every Game the tests left
        // behind, whose secret helper refresh needs the CoreManager the test host never creates
        store.set(true, forKey: Settings.remove_secrets_from_list)
        XCTAssertTrue(Settings.removeSecretsFromList)
        store.removeAll()
        XCTAssertFalse(Settings.removeSecretsFromList)
        XCTAssertEqual(probe.wrappedValue, 0)
    }

    func testHearthMirrorIsNeverQueried() {
        // With a Hearthstone client running these would read its memory
        XCTAssertNil(MirrorHelper.getFormat())
        XCTAssertNil(MirrorHelper.getGameType())
        XCTAssertNil(MirrorHelper.getAccountId())
        XCTAssertFalse(MirrorHelper.isInitialized())

        let game = Game(hearthstoneRunState: HearthstoneRunState(isRunning: false, isActive: false))
        XCTAssertEqual(game.currentFormatType, .ft_unknown)
        XCTAssertFalse(game.spectator)
        game.setGameType(.gt_casual, formatType: .ft_standard)
        XCTAssertEqual(game.currentGameType, .gt_casual)
        XCTAssertEqual(game.currentFormatType, .ft_standard)
        XCTAssertEqual(game.currentGameMode, .casual)
    }
}
