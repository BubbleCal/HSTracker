//
//  HSReplayPreferences.swift
//  HSTracker
//
//  Created by Benjamin Michotte on 13/08/16.
//  Copyright © 2016 Benjamin Michotte. All rights reserved.
//

import Foundation

class HSReplayPreferences: PreferencePaneController, PreferencePane {
    var preferencePaneIdentifier = PreferencePaneIdentifier.hsreplay
    
    var preferencePaneTitle = "HSReplay"
    
    var preferencePaneIcon = NSImage(named: "settings-hsreplay")!
    
    @IBOutlet var oAuthAccount: NSButton!
    @IBOutlet var myAccountMessage: NSTextField!
    
    @objc dynamic var statusIcon = ""
    @objc dynamic var statusColor = NSColor.red

    override func viewWillAppear() {
        super.viewWillAppear()

        updateStatus()
    }

    @IBAction func oauthAccount(_ sender: AnyObject) {
        if Settings.hsReplayOAuthRefreshToken != nil {
            Settings.hsReplayOAuthRefreshToken = nil
            Settings.hsReplayOAuthToken = nil
            Settings.hsReplayUploadToken = nil
            Settings.hsReplayUsername = nil
            MixpanelEvents.resetAccount()

            updateStatus()
        } else {
            HSReplayAPI.oAuthAuthorize {
                _ = HSReplayAPI.getAccount().done { result in
                    switch result {
                    case .failed:
                        logger.error("Failed to retrieve account data")
                    case .success(account: let data):
                        Settings.hsReplayUsername = data.username
                        logger.info("Successfully retrieved account data: Username: \(data.username), battletag: \(data.battletag)")
                    }

                    self.updateStatus()
                }
            }
        }
    }

    private func updateStatus() {
        if Settings.hsReplayOAuthRefreshToken != nil {
            oAuthAccount.title = String.localizedString("Logout", comment: "")
            var message = String.localizedString("Logged in to HSReplay.net.", comment: "")

            if let username = Settings.hsReplayUsername {
                message = String(format: String.localizedString("Logged in to HSReplay.net as %@.", comment: ""), username)
            }
            myAccountMessage.stringValue = message
        } else {
            oAuthAccount.title = String.localizedString("Login to HSReplay.net", comment: "")
            myAccountMessage.stringValue = String.localizedString("Login to enable all HSReplay.net features.", comment: "")
        }
        
        statusIcon = hasSubscription ? "✔" : "✖"
        statusColor = hasSubscription ? NSColor.green : NSColor.red
    }
    
    @objc dynamic var hasSubscription: Bool {
        return subscriptions != SubscriptionStatus.none
    }
    
    @objc dynamic var subscriptionStatusText: String {
        return switch subscriptions {
        case .premium:
            String.localizedString("Options_HSReplay_Account_Subscription_Premium", comment: "")
        case .tier7:
            String.localizedString("Options_HSReplay_Account_Subscription_Tier7", comment: "")
        case .bundle:
            String.localizedString("Options_HSReplay_Account_Subscription_Bundle", comment: "")
        default:
            String.localizedString("Options_HSReplay_Account_Subscription_Generic", comment: "")
        }
    }
    
    var subscriptions: SubscriptionStatus {
        let isPremium = HSReplayAPI.accountData?.is_premium ?? false
        let isTier7 = HSReplayAPI.accountData?.is_tier7 ?? false
            
        if isPremium && isTier7 {
            return .bundle
        }
        if isPremium {
            return .premium
        }
        if isTier7 {
            return .tier7
        }
        return .none
    }
}

enum SubscriptionStatus {
    case none, premium, tier7, bundle
}

// MARK: - Preferences
extension PreferencePaneIdentifier {
    static let hsreplay = Self("hsreplay")
}
