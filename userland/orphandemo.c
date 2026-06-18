// SPDX-License-Identifier: Apache-2.0
// orphandemo.c — QW3 orphan-zombie reaper test fixture.
//
// The parent forks a child and exits IMMEDIATELY without waitpid(), abandoning
// it. The kernel reaps the parent and reparents the still-live child to itself
// (-1); when the child later exits, nobody is waiting on it. The kernel must
// collect the child's zombie slot rather than leak it until reboot.
//
// The child also creates an IPC endpoint and abandons it (never closes the fds),
// exercising the QW3 endpoint owner-reclaim sweep on a dying orphan: its endpoint
// slot must return to the free pool too.
//
// Driven by the in-kernel orphan-reap self-test (runOrphanReapDemo in main.swift),
// which asserts process slots, PMM frames, and endpoint slots return to baseline
// across many rounds.

#include "lib/syscall.h"

int puts_raw(const char *s);

int main(void) {
    int pid = fork();
    if (pid < 0) {
        puts_raw("orphandemo: fork failed\n");
        return 1;
    }
    if (pid == 0) {
        // Child: own an IPC endpoint and abandon it, do a little work so we
        // outlive the parent, then exit as an orphan (parent already reaped,
        // reparented to the kernel). We deliberately never close ep[]: the
        // kernel's per-process teardown + owner sweep must reclaim it.
        int ep[2];
        if (endpoint_create(ep) != 0) {
            puts_raw("orphandemo: endpoint_create failed\n");
            return 1;
        }
        for (volatile int i = 0; i < 200000; i++) { }
        return 7;
    }
    // Parent: abandon the child — return (exit) immediately, no waitpid().
    return 0;
}
