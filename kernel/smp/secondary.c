// SPDX-License-Identifier: Apache-2.0
// secondary.c - secondary CPU mailbox + stack storage for S1.

#include "../arch/aarch64/io.h"

_Static_assert(sizeof(SMPSecondaryMailbox) == SMP_SECONDARY_MAILBOX_STRIDE,
               "secondary mailbox slots must stay 64 bytes");

// Keep the mailbox table in .data instead of .bss: secondary CPUs may reach the
// park loop before the primary CPU has cleared .bss.
SMPSecondaryMailbox smp_secondary_mailboxes[SMP_SECONDARY_MAILBOX_COUNT] __attribute__((section(".data.smp_mailbox"), used, aligned(SMP_SECONDARY_MAILBOX_STRIDE))) = {0};

uint8_t smp_secondary_stacks[SMP_SECONDARY_MAILBOX_COUNT][SMP_SECONDARY_STACK_SIZE] __attribute__((used, aligned(16))) = {{0}};
