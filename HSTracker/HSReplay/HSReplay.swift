//
//  HSReplay.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 12/08/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

struct HSReplay {
    static let baseUrl = "https://hsreplay.net"
    private static let baseOAuth = "/oauth2"
    private static let baseApi = "/api/v1"
    private static let authorizeApi = "/authorize/"
    private static let tokenApi = "/token/"
    private static let accountApi = "/account/"
    
    static let baseApiUrl = "\(baseUrl)\(baseApi)"
    static let baseOAuthUrl = "\(baseUrl)\(baseOAuth)"
    static let oAuthAuthorizeUrl = "\(baseOAuthUrl)\(authorizeApi)"
    static let oAuthTokenUrl = "\(baseOAuthUrl)\(tokenApi)"
    static let accountUrl = "\(baseApiUrl)\(accountApi)"

    static let tier7HeroPickStatsUrl = "\(baseApiUrl)/battlegrounds/hero_pick/"
    static let tier7DuosHeroPickStatsUrl = "\(baseApiUrl)/battlegrounds/duos/hero_pick/"
    static let tier7QuestStatsUrl = "\(baseApiUrl)/battlegrounds/quest_pick/"
    static let tier7AllTimeMMR = "\(baseApiUrl)/battlegrounds/alltime/"
    static let tier7CompStatsUrl = "\(baseApiUrl)/battlegrounds/first_place_comps/"
    static let battlegroundsInspirationUrl = "\(baseApiUrl)/battlegrounds/inspiration/"
    static let playerTrial = "\(baseApiUrl)/playertrials/"
    static let tier7TrinketPickStats = "\(baseApiUrl)/battlegrounds/trinket_pick/"
    // Outfinder keyword -> card-id map behind the related-cards summary chips and the pool
    // browser's keyword filter. Path taken from HSReplay-API-Client's
    // OAuthClient.DataQueries.DiscoverPoolKeywordsUrl.
    static let discoverPoolKeywordsUrl = "\(baseApiUrl)/live/discover_pool_keywords/"

    static let compGuidesUrl = "\(baseUrl)\(baseApi)/battlegrounds/comp_guides/"
    static let tier7CompGuidesUrl = "\(baseUrl)\(baseApi)/battlegrounds/comp_guides/tier7/"
    static let heroGuidesUrl = "\(baseUrl)\(baseApi)/battlegrounds/hero_guides/"
    static let trinketGuidesUrl = "\(baseUrl)\(baseApi)/battlegrounds/trinket_guides/"
    static let anomalyGuidesUrl = "\(baseUrl)\(baseApi)/battlegrounds/anomaly_guides/"
    static let questGuidesUrl = "\(baseUrl)\(baseApi)/battlegrounds/quest_guides/"

    // Arenasmith. Paths from HSReplay-API-Client's HsReplayClient.cs /
    // OAuth/OAuthClient.DataQueries.cs.
    static let arenaHeroPickUrl = "\(baseApiUrl)/arena/hero_pick/"
    static let arenaCardPickUrl = "\(baseApiUrl)/arena/card_pick/"
    static let arenaScoreDeckUrl = "\(baseApiUrl)/arena/score_deck/"
    static let arenaTrialsUrl = "\(baseApiUrl)/arena/trials/"
    static let arenasmithStatusUrl = "\(baseApiUrl)/arena/arenasmith_status/"
    static let arenaCardPackagesUrl = "\(baseApiUrl)/arena/card_packages_by_unique_card/"
    static let arenaCardPackagesFreeUrl = "\(baseApiUrl)/arena/card_packages_by_unique_card/free/"
}
