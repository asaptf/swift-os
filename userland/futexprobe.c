// SPDX-License-Identifier: Apache-2.0
// futexprobe.c — aggressive direct-futex boundary probe (TH8).
//
// pthread already exercises futex on the happy path. This drives the raw
// SYS_FUTEX syscall against its boundaries, which nothing else tests:
//   1. FUTEX_WAIT with *uaddr != val returns 0 immediately (no block) — the
//      compare-and-block fast path.
//   2. FUTEX_WAKE with no waiters returns 0 (woke nobody), never faults.
//   3. Several threads FUTEX_WAIT on one word; setting it and FUTEX_WAKE wakes
//      EVERY waiter — no lost wakeup across CPUs. The table-full EAGAIN branch is
//      intentionally not a normal target: the futex waiter table grows with the
//      process-slot table, and at most one waiter can exist per process slot.
// Built to run at -smp 4 so the wait/wake handoff crosses CPUs.

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

#define SYS_FUTEX     49
#define SYS_NANOSLEEP 57
#define FUTEX_WAIT     0
#define FUTEX_WAKE     1
#define ERR_AGAIN     11   // EAGAIN, returned negated by the kernel

#define NWAIT 3            // real waiters for the wait/wake roundtrip

static long sys3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}

static long futex(volatile unsigned int *u, int op, unsigned int val) {
    return sys3(SYS_FUTEX, (long)u, op, (long)val);
}

static void msleep(long ms) {
    sys3(SYS_NANOSLEEP, ms / 1000, (ms % 1000) * 1000000L, 0);
}

static volatile unsigned int park_word = 0;   // parkers block while this is 0

// Block on park_word until it is set. Because the loop re-reads park_word, a
// parker that has NOT yet entered FUTEX_WAIT when main sets the word still exits
// (the compare-and-block fast path returns 0 on the mismatch) — so the join can
// only hang if a genuinely-parked waiter's wakeup is LOST, which is the bug we
// are testing for.
static void *parker(void *arg) {
    (void)arg;
    while (__atomic_load_n(&park_word, __ATOMIC_SEQ_CST) == 0) {
        futex(&park_word, FUTEX_WAIT, 0);
    }
    return 0;
}

int main(void) {
    // 1. Compare-and-block fast path: a mismatched value never blocks.
    volatile unsigned int w = 5;
    long r = futex(&w, FUTEX_WAIT, 6);   // *w (5) != 6 -> return 0 at once
    if (r != 0) { printf("futexprobe: FAIL val-mismatch returned %ld\n", r); return 1; }
    printf("FUTEXPROBE-VALMISMATCH-OK\n");

    // 2. Waking an address with no waiters wakes nobody and is harmless.
    volatile unsigned int e = 0;
    long woke = futex(&e, FUTEX_WAKE, 1);
    if (woke != 0) { printf("futexprobe: FAIL wake-empty woke %ld\n", woke); return 1; }
    printf("FUTEXPROBE-WAKEEMPTY-OK\n");

    // 3. Wait/wake roundtrip across CPUs: NWAIT threads block on park_word, then
    //    one FUTEX_WAKE must release every one of them (no lost wakeup). The join
    //    below can only hang if a parked waiter's wakeup was lost.
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0 ||
        pthread_attr_setstacksize(&attr, 32768) != 0 ||
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE) != 0) {
        printf("futexprobe: FAIL attr setup\n"); return 1;
    }
    pthread_t th[NWAIT];
    for (int i = 0; i < NWAIT; i++) {
        if (pthread_create(&th[i], &attr, parker, 0) != 0) {
            printf("futexprobe: FAIL create %d\n", i); return 1;
        }
    }
    msleep(200);   // let the waiters reach FUTEX_WAIT (then test the real wakeup)

    // Set the word FIRST (so any not-yet-parked waiter exits via the fast path),
    // then wake the genuinely-parked ones.
    __atomic_store_n(&park_word, 1, __ATOMIC_SEQ_CST);
    woke = futex(&park_word, FUTEX_WAKE, NWAIT);
    if (woke < 0) { printf("futexprobe: FAIL wake returned %ld\n", woke); return 1; }
    for (int i = 0; i < NWAIT; i++) {
        if (pthread_join(th[i], 0) != 0) { printf("futexprobe: FAIL join %d\n", i); return 1; }
    }
    pthread_attr_destroy(&attr);
    printf("FUTEXPROBE-WAKEALL-OK\n");

    printf("FUTEXPROBE-OK\n");
    return 0;
}
