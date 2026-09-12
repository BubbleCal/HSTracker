//
//  RecursiveLock.swift
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

import Foundation

/// An `NSRecursiveLock` wrapper with `UnfairLock`'s `around` API.
///
/// Use this instead of `UnfairLock` wherever the guarded section can call back
/// into the same object on the same thread. `os_unfair_lock` deadlocks on
/// re-entry rather than nesting, which for a main-thread lock means the app
/// hangs outright: an `NSTableView` batch update, for instance, asks its data
/// source for the row count and for row views from inside `insertRows`/
/// `removeRows`, so the callbacks land while the caller still holds the lock.
final class RecursiveLock {
    private let lock = NSRecursiveLock()

    /// Executes a closure returning a value while acquiring the lock.
    func around<T>(_ closure: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return closure()
    }

    /// Executes a closure while acquiring the lock.
    func around(_ closure: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        return closure()
    }
}
