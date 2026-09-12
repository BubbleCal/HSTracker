//
//  DelayedTooltip.swift
//  HSTracker
//
//  Created by Francisco Moraes on 11/10/24.
//  Copyright © 2024 Benjamin Michotte. All rights reserved.
//

import Foundation

/// Fires `handler` once, on the main thread, after `delay` - unless `cancel()`
/// gets there first.
///
/// The timer is explicitly scheduled on the main run loop rather than on
/// whatever run loop the caller happens to be on. `Timer.scheduledTimer` uses
/// the *current* thread's run loop, so constructing one of these from a watcher
/// queue either never fired at all (a plain `DispatchQueue` thread has no run
/// loop running) or fired off the main thread straight into the `fatalError`
/// this class used to raise there.
class DelayedTooltip: NSObject {
    let handler: ((Any?) -> Void)
    private var timer: Timer?

    init(handler: @escaping (Any?) -> Void, _ delay: TimeInterval = 0.500, _ userInfo: Any?) {
        self.handler = handler
        super.init()
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(self.onTimer),
                          userInfo: userInfo, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func onTimer(_ timer: Timer) {
        self.timer = nil
        handler(timer.userInfo)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
