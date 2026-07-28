// SPDX-License-Identifier: Apache-2.0
// stackovf.c — deliberate user-stack overflow for EL0 fault-backtrace tests.
//
// Forks a child that recurses until SP walks off the mapped stack; the kernel
// terminates the child with SIGSEGV and must log a bounded, collapsed FP-chain
// backtrace. The parent reaps the child, checks the wait status, and prints an
// alive marker so the test proves the kernel stayed up without needing an
// interactive ash session (this checkout's busybox.elf is a known-faulty CI
// binary used to reproduce a separate recursion bug).
//
// Built with -fno-omit-frame-pointer so the AAPCS64 frame chain is present for
// the kernel walker; each call also leaves a non-tail use of a volatile pad so
// -Os cannot collapse the recursion into a loop. Written in C rather than
// Embedded Swift because this tree's USER_SWIFT_FLAGS do not reliably force
// frame-pointer chains under -Osize (no equivalent of -fno-omit-frame-pointer
// for the Swift frontend in this Makefile).

#include "lib/syscall.h"

int puts_raw(const char *s);

// noinline: every call must push its own frame record (no TCO/loop rewrite).
// Function-pointer indirection keeps -Os from seeing a simple self-call that
// it could rewrite, and silences -Winfinite-recursion (the overflow is intentional).
__attribute__((noinline))
static unsigned long recurse(unsigned long depth)
{
    // Volatile pad: forces a real stack frame and prevents dead-store elimination
    // from erasing the stack growth.
    volatile unsigned long pad[16];
    unsigned long i;
    unsigned long (*next)(unsigned long) = recurse;
    for (i = 0; i < 16; i++) {
        pad[i] = depth + i;
    }
    // Non-tail recursive call: the return value is combined with pad after the
    // call, so the compiler cannot rewrite this as a loop even at -Os.
    unsigned long r = next(depth + 1);
    return r + pad[0] + pad[15];
}

static void put_uint(unsigned long v)
{
    char buf[20];
    int n = 0;
    if (v == 0) {
        puts_raw("0");
        return;
    }
    while (v > 0) {
        buf[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (n > 0) {
        char c = buf[--n];
        write(1, &c, 1);
    }
}

int main(int argc, char **argv, char **envp)
{
    int status = 0;
    int pid;
    unsigned long st;

    (void)argc;
    (void)argv;
    (void)envp;

    puts_raw("STACKOVF-START deliberate recursion\n");

    pid = fork();
    if (pid < 0) {
        puts_raw("STACKOVF-FAIL: fork failed\n");
        return 1;
    }
    if (pid == 0) {
        (void)recurse(0);
        // Unreachable on success: the recursive overflow must be killed by SIGSEGV.
        puts_raw("STACKOVF-FAIL: recursion returned\n");
        return 1;
    }

    // waitpid status encoding (kernel/user/process.swift): killed-by-signal ->
    // the bare signal number (< 128); clean exit -> (exitcode << 8).
    if (waitpid(pid, &status, 0) != pid) {
        puts_raw("STACKOVF-FAIL: waitpid failed\n");
        return 1;
    }
    st = (unsigned long)(unsigned int)status;
    if (st == 0 || st >= 128) {
        puts_raw("STACKOVF-FAIL: child not killed by signal, status=");
        put_uint(st);
        puts_raw("\n");
        return 1;
    }
    if (st != 11) {
        puts_raw("STACKOVF-FAIL: expected SIGSEGV (11), got signal=");
        put_uint(st);
        puts_raw("\n");
        return 1;
    }

    puts_raw("STACKOVF-OK child died with SIGSEGV\n");
    puts_raw("STACKOVF-ALIVE parent continued after child fault\n");
    return 0;
}
