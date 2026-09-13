//
//  ReplayUploadTests.swift
//  HSTracker
//
//  Created by Istvan Fehervari on 09/05/2017.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//
//  NOT BUILT: this file is not in any target's Sources phase, so its tests never run and edits
//  here are not compiled. It no longer compiles against the app: the Wrap library it imports was
//  removed (079fb872) and UploadMetaData.Player renamed `deckId`/`cardBack` to `deck_id`/`cardback`.
//  It needs porting to JSONEncoder and the new names before it can go back into HSTrackerTests.
//

import XCTest
import Wrap

@testable import HSTracker

class ReplayUploadTests: HSTrackerTests {
	
	override func setUp() {
		super.setUp()
	}
	
	override func tearDown() {
		super.tearDown()
	}
	
	func testMetadataWrap() {
		let player = UploadMetaData.Player()
		
//		player.rank = 1
//		player.legendRank = 0
		player.stars = 1
		player.wins = 20
		player.losses = 10
		player.deck = ["one", "two"]
		player.deckId = 12345
		player.cardBack = 3
		
		guard let wrappedPlayer: [String : Any] = try? wrap(player) else {
			XCTFail()
			return
		}
		
//		XCTAssert(wrappedPlayer["rank"] as! Int == player.rank!)
		XCTAssert(wrappedPlayer["cardback"] as! Int == player.cardBack!)
		XCTAssert(wrappedPlayer["deck"] as! [String] == player.deck!)
	}
}

