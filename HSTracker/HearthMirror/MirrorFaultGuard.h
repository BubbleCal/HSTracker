//
//  MirrorFaultGuard.h
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, and returns the signal it faulted with (SIGSEGV or SIGBUS) instead of letting
/// that fault take the app down, or 0 when it ran to completion.
///
/// Only for calls into HearthMirror. Its C++ core dereferences objects it reads out of
/// Hearthstone's memory without checking them for null, and Hearthstone can hand it one - a game
/// account whose battle tag has not been filled in, say - which is a segmentation fault in
/// HSTracker's own process. The Mono runtime Bob's Buddy runs on turns that into exit(255) with no
/// crash report. HearthMirror takes no locks, so jumping back out of it leaves nothing held; what
/// the abandoned call had allocated is leaked.
///
/// A fault on any other thread, or outside a guarded block, goes to whatever handler was installed
/// before (Mono's, or the default), as if this were not there.
int HSTRunGuardingMemoryFaults(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
