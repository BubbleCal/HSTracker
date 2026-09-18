//
//  EnumTests.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 5/05/17.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//

import XCTest
@testable import HSTracker

class EnumTests: HSTrackerTests {

    override func setUp() {
        super.setUp()
    }
    
    override func tearDown() {
        super.tearDown()
    }

    func testLanguages() {
        let locales: [Language.Hearthstone] = [.deDE, .enUS, .esES, .esMX,
                                               .frFR, .itIT, .koKR, .plPL,
                                               .ptBR, .ruRU, .zhCN, .zhTW,
                                               .jaJP, .thTH].sorted(by: {
            $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue) == ComparisonResult.orderedAscending
        })

        let languages: [Language.Hearthstone] = Array(Language.Hearthstone.allCases).sorted(by: {
            $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue) == ComparisonResult.orderedAscending
        })
        XCTAssertEqual(languages.count, 14, "There are 14 locales")
        XCTAssertEqual(languages, locales, "Sorting locale is not the same")
    }

    func testKnownSceneModes() {
        XCTAssertEqual(Mode.from(sceneMode: 0), .invalid)
        XCTAssertEqual(Mode.from(sceneMode: 3), .hub)
        XCTAssertEqual(Mode.from(sceneMode: 4), .gameplay)
        XCTAssertEqual(Mode.from(sceneMode: 7), .tournament)
        XCTAssertEqual(Mode.from(sceneMode: Mode.allCases.count - 1), .lucky_draw)
    }

    /// A scene id Hearthstone knows and this build does not used to trap in
    /// `Mode.allCases[args.mode]` on the SceneWatcher queue and take the app down.
    func testSceneModesThisBuildHasNoCaseForAreInvalid() {
        XCTAssertEqual(Mode.from(sceneMode: Mode.allCases.count), .invalid)
        XCTAssertEqual(Mode.from(sceneMode: Mode.allCases.count + 7), .invalid)
        XCTAssertEqual(Mode.from(sceneMode: -1), .invalid)
        XCTAssertEqual(Mode.from(sceneMode: Int.max), .invalid)
        XCTAssertEqual(Mode.from(sceneMode: Int.min), .invalid)
    }

    func testCaseAtStaysInsideTheEnum() {
        XCTAssertEqual(CardClass.at(0), .invalid)
        XCTAssertEqual(CardClass.at(CardClass.allCases.count - 1), CardClass.allCases.last)
        XCTAssertNil(CardClass.at(CardClass.allCases.count))
        XCTAssertNil(CardClass.at(-1))
        XCTAssertNil(Race.at(Race.allCases.count))
        XCTAssertNil(Rarity.at(Rarity.allCases.count))
        XCTAssertNil(Mode.at(Int.max))
    }

    func testCardIgnoresClassValuesThisBuildHasNoCaseFor() {
        let card = Card()
        card.playerClass = .mage
        card.tourist = CardClass.allCases.count
        XCTAssertNil(card.getTouristClass(), "an unknown tourist class is no class, not a crash")

        card.tourist = 0
        // The bit for a class this build has no case for, next to druid's.
        card.multipleClasses = (1 << (CardClass.allCases.count - 1)) | (1 << 1)
        XCTAssertEqual(card.getClasses(), [CardClass.allCases[2]])
    }
}
