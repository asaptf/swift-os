#!/usr/bin/env bash
# smp_mailbox_layout_test.sh - verify S0e mailbox placement before SMP boot.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
OBJDUMP="${LLVM_OBJDUMP:-/opt/homebrew/opt/llvm/bin/llvm-objdump}"

if [[ ! -f "$KERNEL" ]]; then
  echo "FAIL: $KERNEL not found - run 'make build' first." >&2
  exit 2
fi

line="$("$OBJDUMP" -t "$KERNEL" | awk '$6 == "smp_secondary_mailboxes" { print $1, $4, $5 }')"
if [[ -z "$line" ]]; then
  echo "FAIL: smp_secondary_mailboxes symbol not found in kernel image." >&2
  exit 1
fi

read -r addr section size <<<"$line"
if [[ "$section" != ".data" ]]; then
  echo "FAIL: smp_secondary_mailboxes is in $section, expected .data." >&2
  exit 1
fi
if [[ "$size" != "0000000000000200" ]]; then
  echo "FAIL: smp_secondary_mailboxes size is $size, expected 0000000000000200." >&2
  exit 1
fi
if (( (16#$addr & 63) != 0 )); then
  echo "FAIL: smp_secondary_mailboxes address 0x$addr is not 64-byte aligned." >&2
  exit 1
fi

echo "PASS: SMP secondary mailbox table is in .data, 512 bytes, 64-byte aligned"
