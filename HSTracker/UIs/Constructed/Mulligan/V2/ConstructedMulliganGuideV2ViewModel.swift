//
//  ConstructedMulliganGuideV2ViewModel.swift
//  HSTracker
//
//  Created by Francisco Moraes on 8/7/26.
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

@available(macOS 10.15, *)
class ConstructedMulliganGuideV2ViewModel: ObservableObject {
    @Published var cardStats: [ConstructedMulliganV2SingleCardViewModel] = []
    @Published var message: String?
    @Published var error: String?
    @Published var statsVisibility = false

    private var liveState: MulliganLiveState?

    var isVisible: Bool {
        error != nil || !cardStats.isEmpty
    }

    // updateMulliganDataAfterMulligan doesn't need isFirst again - each
    // header view model already stashed its own copy at construction time
    // (see ConstructedMulliganV2SingleCardHeaderViewModel.updateCard).
    func setMulliganData(_ data: MulliganV2Data?, isFirst: Bool) {
        guard let data else {
            logger.debug("MulliganGuideV2: setMulliganData without data")
            cardStats = []
            statsVisibility = false
            return
        }

        let deckStatus = data.data.general_info.deck_status
        guard deckStatus == .supported || deckStatus == .partial else {
            logger.info("MulliganGuideV2: deck_status=\(deckStatus), showing not available")
            error = String.localizedString("MulliganGV2_Error_NotAvailable", comment: "")
            cardStats = []
            statsVisibility = false
            return
        }

        var built: [ConstructedMulliganV2SingleCardViewModel] = []
        for (key, cardData) in data.data.cards_by_position {
            guard let position = Int(key) else { continue }
            built.append(ConstructedMulliganV2SingleCardViewModel(position: position, data: cardData, isFirst: isFirst))
        }
        built.sort { $0.position < $1.position }

        error = nil
        cardStats = built
        statsVisibility = true
        logger.debug("MulliganGuideV2: setMulliganData deck_status=\(deckStatus) cards=\(built.count)")
    }

    // Shown over the mulligan cards in place of the stats when a player
    // without Premium has no free trial left. HDT leaves the overlay empty,
    // which is indistinguishable from the tracker not working.
    func showTrialsExhausted(timeRemaining: String?) {
        var text = String.localizedString("MulliganGV2_Error_TrialsExhausted", comment: "")
        if let timeRemaining {
            text += "\n" + String(format: String.localizedString("MulliganGV2_Error_TrialsResetIn", comment: ""), timeRemaining)
        }
        logger.info("MulliganGuideV2: showing trials exhausted (resets in \(timeRemaining ?? "unknown"))")
        cardStats = []
        statsVisibility = false
        error = text
    }

    func updateMulliganDataAfterMulligan(_ data: MulliganV2Data?) {
        guard let data, !cardStats.isEmpty else { return }

        for (key, cardData) in data.data.cards_by_position {
            guard let position = Int(key), let vm = cardStats.first(where: { $0.position == position }) else { continue }
            vm.header.updateCard(cardData)
        }
    }

    // Deferred seam - see the doc comment on MulliganLiveState in
    // ConstructedMulliganV2SingleCardHeaderViewModel.swift. Not called by anything yet.
    func updateLiveMulliganState(_ state: MulliganLiveState?) {
        liveState = state
        for card in cardStats {
            card.header.updateState(state)
        }
    }

    func scopeMessage(opponentClass: CardClass, isFirst: Bool) {
        let localizedCardClass = String.localizedString("\(opponentClass)", comment: "")
        let key = isFirst ? "ConstructedMulliganGuide_Message_VsClass_GoingFirst" : "ConstructedMulliganGuide_Message_VsClass_ExtraCard"
        message = String(format: String.localizedString(key, comment: ""), localizedCardClass)
    }

    func reset() {
        cardStats = []
        statsVisibility = false
        error = nil
        message = nil
        liveState = nil
    }
}
