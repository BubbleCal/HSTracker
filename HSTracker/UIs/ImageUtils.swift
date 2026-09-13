/*
 * This file is part of the HSTracker package.
 * (c) Benjamin Michotte <bmichotte@gmail.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 *
 * Created on 16/02/16.
 */

import AppKit
import Foundation
import HearthMirror
import ImageIO

/// The memory cache for decoded card renders.
///
/// Each render is held fully decoded (about 0.4 MB for a 256x388 card) so a hover can draw it
/// straight away, and the trackers read in every card they list ahead of any hover. Kept without a
/// bound, that grew with every opponent deck of a long ladder session. So a render stays for as
/// long as some tracker still lists it, and beyond those only the most recently used
/// `recentLimit` are kept - the cards just hovered in a tooltip, a grid or the Battlegrounds shop.
final class CardArtCache {
    private let lock = UnfairLock()
    private var images = [String: NSImage]()
    private var lastUse = [String: UInt64]()
    private var useCounter: UInt64 = 0
    private var listed = [ObjectIdentifier: Set<String>]()
    let recentLimit: Int

    init(recentLimit: Int) {
        self.recentLimit = recentLimit
    }

    subscript(key: String) -> NSImage? {
        get {
            return lock.around {
                guard let image = images[key] else { return nil }
                touch(key)
                return image
            }
        }
        set {
            lock.around {
                if let newValue {
                    images[key] = newValue
                    touch(key)
                    trim()
                } else {
                    images.removeValue(forKey: key)
                    lastUse.removeValue(forKey: key)
                }
            }
        }
    }

    // Whether a render is held, without counting as a use of it
    func contains(_ key: String) -> Bool {
        return lock.around { images[key] != nil }
    }

    var count: Int {
        return lock.around { images.count }
    }

    /// Replaces the keys `owner` lists. Those renders are kept however many there are; one the
    /// owner stops listing falls back to the recently used ones, and may be evicted from there.
    func setListed(_ keys: Set<String>, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        lock.around {
            // The trackers pass the same list on nearly every refresh
            guard listed[id] != keys else { return }
            if keys.isEmpty {
                listed.removeValue(forKey: id)
            } else {
                listed[id] = keys
            }
            trim()
        }
    }

    func removeAll() {
        lock.around {
            images.removeAll()
            lastUse.removeAll()
        }
    }

    // Called with the lock held
    private func touch(_ key: String) {
        useCounter += 1
        lastUse[key] = useCounter
    }

    // Called with the lock held
    private func trim() {
        var retained = Set<String>()
        for keys in listed.values {
            retained.formUnion(keys)
        }
        let unlisted = images.keys.filter { !retained.contains($0) }
        guard unlisted.count > recentLimit else { return }
        let oldestFirst = unlisted.sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }
        for key in oldestFirst.prefix(unlisted.count - recentLimit) {
            images.removeValue(forKey: key)
            lastUse.removeValue(forKey: key)
        }
    }
}

struct ImageUtils {
    enum ImageType: Int {
        case tile, art, cardArt, cardArtBG, hero
    }
    
    static func tileUrl(cardId: String) -> String {
        return "https://art.hearthstonejson.com/v1/tiles/\(cardId).png"
    }
    
    static func artUrl(cardId: String, lang: String) -> String {
        return "https://art.hearthstonejson.com/v1/render/latest/\(lang)/256x/\(cardId).png"
    }

    static func artUrlBG(cardId: String, lang: String) -> String {
        return "https://art.hearthstonejson.com/v1/bgs/latest/\(lang)/256x/\(cardId).png"
    }

    static func artUrl256(cardId: String) -> String {
        return "https://art.hearthstonejson.com/v1/256x/\(cardId).jpg"
    }

    // Full-body hero portrait, the URL HDT's heroImageDownloader uses.
    static func heroUrl(cardId: String) -> String {
        return "https://art.hearthstonejson.com/v1/heroes/latest/256x/\(cardId).png"
    }

    private static var cache =  SynchronizedDictionary<String, NSImage>()
    private static var cacheArt =  SynchronizedDictionary<String, NSImage>()
    // About 25 MB of renders beyond the ones the trackers list
    private static let cacheCardArt = CardArtCache(recentLimit: 64)
    private static let cacheCardArtBG = CardArtCache(recentLimit: 64)
    private static var cacheHero = SynchronizedDictionary<String, NSImage>()
    
    static func clearCache() {
        cache.removeAll()
        cacheArt.removeAll()
        cacheCardArt.removeAll()
        cacheCardArtBG.removeAll()
        cacheHero.removeAll()
        pendingLock.around {
            failedAt.removeAll()
        }
        
        clearDirectory(path: Paths.cards)
        clearDirectory(path: Paths.cardsBG)
        clearDirectory(path: Paths.arts)
        clearDirectory(path: Paths.tiles)
        clearDirectory(path: Paths.heroes)
    }
    
    static func clearDirectory(path: URL) {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: path,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)
            for fileURL in fileURLs {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            logger.error(error)
        }
    }

    static func cachedTile(cardId: String) -> NSImage? {
        return cache[cardId]
    }
    
    static func tile(for cardId: String,
                     completion: @escaping ((NSImage?) -> Void)) {
        let image = cache[cardId]
        
        if let image = image {
            completion(image)
            return
        }
		
        loadImage(type: .tile, cardId: cardId, completion: completion)
    }
    
    static func art(for cardId: String, completion: @escaping ((NSImage?) -> Void)) {
        let image = cacheArt[cardId]
        
        if let image = image {
            completion(image)
            return
        }
        loadImage(type: .art, cardId: cardId, completion: completion)
    }
    
    static func cardArt(for cardId: String, completion: @escaping ((NSImage?) -> Void)) {
        let image = cacheCardArt[cardId]
        
        if let image = image {
            completion(image)
            return
        }
        loadImage(type: .cardArt, cardId: cardId, completion: completion)
    }
    
    // The render the card hover popup shows, if it is already in memory. The popup puts a hit
    // straight into its image view: cardArt(for:) hands even a hit over in a later main-queue
    // turn once it has been wrapped for thread safety, which drew the window with the previous
    // card's render (or nothing) for a frame.
    static func cachedCardArt(cardId: String) -> NSImage? {
        return cacheCardArt[cardId]
    }

    static func cachedCardArtBG(cardId: String, baconTriple: Bool) -> NSImage? {
        return cacheCardArtBG[cardArtBGKey(cardId: cardId, baconTriple: baconTriple)]
    }

    private static func cardArtBGKey(cardId: String, baconTriple: Bool) -> String {
        return "\(cardId)\(baconTriple ? "_triple" : "")"
    }

    // When a load last came back empty, by type+card: a download error, the art server being
    // unreachable (offline at launch, or just after waking from sleep) or a card with no render.
    // The pre-load leaves such a card alone for a while rather than asking again on every tracker
    // refresh - twice a second during a match - and then tries it again, so a card listed while
    // offline is still ready by the time it is hovered. A hover always retries straight away.
    private static var failedAt = [String: TimeInterval]()
    static let preloadRetryInterval: TimeInterval = 30

    /// Reads the renders of the cards `owner` lists into memory ahead of any hover, from disk or
    /// else from the art server, so the first hover over a row finds its image already decoded.
    /// The renders are kept while they stay listed; pass every card the owner lists each time.
    static func preloadCardArt(cardIds: [String], for owner: AnyObject) {
        cacheCardArt.setListed(Set(cardIds.filter { !$0.isEmpty }), for: owner)
        // The unit tests fill the trackers from a bare Game; they must not download art into the
        // user's own card cache on the way.
        guard !AppDelegate.isRunningUnitTests else { return }
        for cardId in preloadCandidates(cardIds: cardIds, now: ProcessInfo.processInfo.systemUptime) {
            loadImage(type: .cardArt, cardId: cardId, completion: { _ in })
        }
    }

    // The listed cards a pre-load should start a load for: not in memory, not already loading,
    // and not failed within the retry interval
    static func preloadCandidates(cardIds: [String], now: TimeInterval) -> [String] {
        var seen = Set<String>()
        let missing = cardIds.filter { !$0.isEmpty && seen.insert($0).inserted && !cacheCardArt.contains($0) }
        guard !missing.isEmpty else { return [] }
        return pendingLock.around {
            missing.filter { cardId in
                let key = loadKey(type: .cardArt, cardId: cardId)
                guard pending[key] == nil else { return false }
                if let failed = failedAt[key], now - failed < preloadRetryInterval {
                    return false
                }
                return true
            }
        }
    }

    // Internal rather than private so tests can drive the retry interval with their own clock
    static func noteLoadResult(type: ImageType, cardId: String, succeeded: Bool, now: TimeInterval) {
        let key = loadKey(type: type, cardId: cardId)
        pendingLock.around {
            if succeeded {
                failedAt.removeValue(forKey: key)
            } else {
                failedAt[key] = now
            }
        }
    }

    /// The placeholder the hover popups draw while a card's render is still loading
    static func loadingImageName(for type: CardType) -> String {
        switch type {
        case .hero: return "loading_hero"
        case .minion: return "loading_minion"
        case .weapon: return "loading_weapon"
        default: return "loading_spell"
        }
    }

    static func cardArtBG(for cardId: String, baconTriple: Bool, completion: @escaping ((NSImage?) -> Void)) {
        let finalCardId = cardArtBGKey(cardId: cardId, baconTriple: baconTriple)
        let image = cacheCardArtBG[finalCardId]
        
        if let image = image {
            completion(image)
            return
        }
        loadImage(type: .cardArtBG, cardId: finalCardId, completion: completion)
    }

    static func cachedHero(cardId: String) -> NSImage? {
        return cacheHero[cardId]
    }

    static func hero(for cardId: String, completion: @escaping ((NSImage?) -> Void)) {
        if let image = cacheHero[cardId] {
            completion(image)
            return
        }
        loadImage(type: .hero, cardId: cardId, completion: completion)
    }

    static func cachedArt(cardId: String) -> NSImage? {
        let res = cacheArt[cardId]
        
        return res
    }
    
    // Internal rather than private so tests can seed the memory cache without the network
    static func store(_ image: NSImage, type: ImageType, cardId: String) {
        switch type {
        case .tile:
            cache[cardId] = image
        case .art:
            cacheArt[cardId] = image
        case .cardArt:
            cacheCardArt[cardId] = image
        case .cardArtBG:
            cacheCardArtBG[cardId] = image
        case .hero:
            cacheHero[cardId] = image
        }
    }

    private static func localPath(type: ImageType, cardId: String) -> URL {
        switch type {
        case .tile:
            return Paths.tiles.appendingPathComponent("\(cardId).jpg")
        case .art:
            return Paths.arts.appendingPathComponent("\(cardId).jpg")
        case .cardArt:
            return Paths.cards.appendingPathComponent("\(cardId).jpg")
        case .cardArtBG:
            return Paths.cardsBG.appendingPathComponent("\(cardId).jpg")
        case .hero:
            return Paths.heroes.appendingPathComponent("\(cardId).png")
        }
    }

    private static func remoteURL(type: ImageType, cardId: String) -> URL? {
        let url: String
        switch type {
        case .tile:
            url = tileUrl(cardId: cardId)
        case .art:
            url = artUrl256(cardId: cardId)
        case .cardArt:
            url = artUrl(cardId: cardId, lang: Settings.hearthstoneLanguage?.rawValue ?? "enUS")
        case .cardArtBG:
            url = artUrlBG(cardId: cardId, lang: Settings.hearthstoneLanguage?.rawValue ?? "enUS")
        case .hero:
            url = heroUrl(cardId: cardId)
        }
        return URL(string: url)
    }

    // Requests in flight, keyed by type+card, each holding the completions still
    // waiting on it. Hovering a card repeatedly, or a grid that shows the same
    // art in several slots, used to start a separate disk read and a separate
    // download per caller.
    private static let pendingLock = UnfairLock()
    private static var pending = [String: [(NSImage?) -> Void]]()

    // Off the main thread on purpose. Decoding a card render takes long enough
    // to be visible, and this is reached straight out of CardBar.draw() and out
    // of SwiftUI .onAppear - both on the main thread.
    private static let loadQueue = DispatchQueue(label: "net.hearthsim.hstracker.imageload",
                                                 qos: .userInitiated, attributes: .concurrent)

    /// Decodes image data into an NSImage whose pixels are already decompressed.
    ///
    /// NSImage(data:) and NSImage(contentsOf:) only parse the file; the actual decode waits for
    /// the first draw, which for the card renders is the main thread showing the hover popup -
    /// exactly the moment that has to be instant. The size is worked out from the resolution the
    /// file records, the way NSImage(data:) does, so an image does not change size on screen.
    static func decodedImage(data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return NSImage(data: data)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        func dpi(_ key: CFString) -> CGFloat {
            let value = (properties?[key] as? NSNumber)?.doubleValue ?? 72
            return value > 0 ? CGFloat(value) : 72
        }
        let size = NSSize(width: CGFloat(cgImage.width) * 72 / dpi(kCGImagePropertyDPIWidth),
                          height: CGFloat(cgImage.height) * 72 / dpi(kCGImagePropertyDPIHeight))
        return NSImage(cgImage: cgImage, size: size)
    }

    // Only the card renders are decoded up front: they are what the hover popups draw, and the
    // other kinds have callers that crop or otherwise process the image they get.
    private static func makeImage(type: ImageType, data: Data) -> NSImage? {
        switch type {
        case .cardArt, .cardArtBG:
            return decodedImage(data: data)
        case .tile, .art, .hero:
            return NSImage(data: data)
        }
    }

    private static func loadKey(type: ImageType, cardId: String) -> String {
        return "\(type.rawValue):\(cardId)"
    }

    private static func finish(key: String, type: ImageType, cardId: String, image: NSImage?) {
        if let image {
            store(image, type: type, cardId: cardId)
        }
        noteLoadResult(type: type, cardId: cardId, succeeded: image != nil, now: ProcessInfo.processInfo.systemUptime)
        let waiting = pendingLock.around { () -> [(NSImage?) -> Void] in
            let handlers = pending[key] ?? []
            pending.removeValue(forKey: key)
            return handlers
        }
        guard !waiting.isEmpty else { return }
        // Delivered on the main queue: every caller of this is UI code putting
        // the result into a view, and this used to hand it over on whichever
        // queue the download finished on.
        DispatchQueue.main.async {
            for completion in waiting {
                completion(image)
            }
        }
    }

    private static func loadImage(type: ImageType, cardId: String, completion: @escaping ((NSImage?) -> Void)) {
        let key = loadKey(type: type, cardId: cardId)
        let isFirst = pendingLock.around { () -> Bool in
            if pending[key] != nil {
                pending[key]?.append(completion)
                return false
            }
            pending[key] = [completion]
            return true
        }
        guard isFirst else { return }

        let path = localPath(type: type, cardId: cardId)

        loadQueue.async {
            // Check if the image has been downloaded
            if let data = try? Data(contentsOf: path), let image = makeImage(type: type, data: data) {
                finish(key: key, type: type, cardId: cardId, image: image)
                return
            }

            // Download image
            guard let url = remoteURL(type: type, cardId: cardId) else {
                finish(key: key, type: type, cardId: cardId, image: nil)
                return
            }
            logger.verbose("downloading \(type) \(url) to \(path)")

            URLSession.shared.dataTask(with: url) { data, _, error in
                if let error = error {
                    logger.error("download error \(error)")
                    finish(key: key, type: type, cardId: cardId, image: nil)
                } else if let data = data, let image = makeImage(type: type, data: data) {
                    try? data.write(to: path, options: [.atomic])
                    finish(key: key, type: type, cardId: cardId, image: image)
                } else {
                    // A 404 from art.hearthstonejson.com arrives as an HTML body with no
                    // URLSession error - which is what asking for art a card does not have looks
                    // like, e.g. the /bgs variant of a constructed card. Without this branch the
                    // completion is never called at all, silently stranding every caller that has
                    // a fallback to run or a placeholder to show.
                    logger.verbose("no \(type) image at \(url)")
                    finish(key: key, type: type, cardId: cardId, image: nil)
                }
            }.resume()
        }
    }
}
