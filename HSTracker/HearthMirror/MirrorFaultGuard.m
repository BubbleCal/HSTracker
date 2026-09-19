//
//  MirrorFaultGuard.m
//  HSTracker
//
//  Copyright © 2026 Benjamin Michotte. All rights reserved.
//

#import "MirrorFaultGuard.h"

#include <pthread.h>
#include <setjmp.h>
#include <signal.h>

// The jump buffer of the guarded block running on this thread, if any. A pthread key rather than
// a _Thread_local: reading it from the signal handler must not allocate, and pthread_getspecific
// is a plain TSD read.
static pthread_key_t hst_jump_key;
static pthread_once_t hst_key_once = PTHREAD_ONCE_INIT;

// The handlers this one replaced, to hand every fault that is not ours to
static struct sigaction hst_previous_segv;
static struct sigaction hst_previous_bus;
static pthread_mutex_t hst_install_lock = PTHREAD_MUTEX_INITIALIZER;

static void hst_make_key(void) {
    pthread_key_create(&hst_jump_key, NULL);
}

static void hst_forward(int sig, siginfo_t *info, void *context) {
    struct sigaction *previous = sig == SIGBUS ? &hst_previous_bus : &hst_previous_segv;
    if (previous->sa_flags & SA_SIGINFO) {
        if (previous->sa_sigaction != NULL) {
            previous->sa_sigaction(sig, info, context);
            return;
        }
    } else if (previous->sa_handler == SIG_IGN) {
        return;
    } else if (previous->sa_handler != SIG_DFL && previous->sa_handler != NULL) {
        previous->sa_handler(sig);
        return;
    }
    // Nothing installed before: fault the default way, with a crash report
    signal(sig, SIG_DFL);
    raise(sig);
}

static void hst_fault_handler(int sig, siginfo_t *info, void *context) {
    sigjmp_buf *jump = pthread_getspecific(hst_jump_key);
    if (jump != NULL) {
        pthread_setspecific(hst_jump_key, NULL);
        siglongjmp(*jump, sig);
    }
    hst_forward(sig, info, context);
}

// Installs the handler, or reinstalls it over one set up since: the Mono runtime installs its own
// crash handlers when it starts, and whichever handler went in last is the one that runs.
static void hst_install_handlers(void) {
    pthread_mutex_lock(&hst_install_lock);
    int signals[] = { SIGSEGV, SIGBUS };
    for (int i = 0; i < 2; i++) {
        int sig = signals[i];
        struct sigaction current;
        if (sigaction(sig, NULL, &current) != 0) {
            continue;
        }
        if ((current.sa_flags & SA_SIGINFO) && current.sa_sigaction == hst_fault_handler) {
            continue;
        }
        struct sigaction mine;
        memset(&mine, 0, sizeof(mine));
        mine.sa_sigaction = hst_fault_handler;
        mine.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&mine.sa_mask);
        struct sigaction *previous = sig == SIGBUS ? &hst_previous_bus : &hst_previous_segv;
        sigaction(sig, &mine, previous);
    }
    pthread_mutex_unlock(&hst_install_lock);
}

int HSTRunGuardingMemoryFaults(void (NS_NOESCAPE ^block)(void)) {
    pthread_once(&hst_key_once, hst_make_key);
    hst_install_handlers();

    sigjmp_buf jump;
    // Nested guards on one thread: the inner one's fault stays with the inner one
    void *outer = pthread_getspecific(hst_jump_key);
    int sig = sigsetjmp(jump, 1);
    if (sig == 0) {
        pthread_setspecific(hst_jump_key, &jump);
        block();
    }
    pthread_setspecific(hst_jump_key, outer);
    return sig;
}
