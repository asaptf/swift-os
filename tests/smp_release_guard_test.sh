#!/usr/bin/env bash
# smp_release_guard_test.sh - S0i guard: secondaries must stay parked pre-S1.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
BOOT_OBJ="$ROOT/build/boot.o"
BOOT_SRC="$ROOT/kernel/arch/aarch64/boot.S"
OBJDUMP="${LLVM_OBJDUMP:-/opt/homebrew/opt/llvm/bin/llvm-objdump}"

[[ -x "$OBJDUMP" ]] || { echo "FAIL: llvm-objdump not found at $OBJDUMP" >&2; exit 2; }
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL not found - run 'make build' first." >&2; exit 2; }
[[ -f "$BOOT_OBJ" ]] || { echo "FAIL: $BOOT_OBJ not found - run 'make build' first." >&2; exit 2; }
[[ -f "$BOOT_SRC" ]] || { echo "FAIL: $BOOT_SRC missing." >&2; exit 2; }

if "$OBJDUMP" -d "$KERNEL" |
   grep -E '^[[:space:]]*[0-9a-f]+:.*[[:space:]](hvc|smc)([[:space:]]|$)' >/dev/null; then
  echo "FAIL: S0 kernel contains hvc/smc instructions; PSCI CPU_ON must wait for S1 review." >&2
  exit 1
fi

boot_disasm="$("$OBJDUMP" -d "$BOOT_OBJ")"

if ! grep -E '^[[:space:]]*[0-9a-f]+:.*[[:space:]]ldar[[:space:]]+x3, \[x1\]' <<<"$boot_disasm" >/dev/null; then
  echo "FAIL: secondary park path no longer acquire-loads the mailbox release flag." >&2
  exit 1
fi

wfe_count="$(grep -Ec '^[[:space:]]*[0-9a-f]+:.*[[:space:]]wfe([[:space:]]|$)' <<<"$boot_disasm")"
if (( wfe_count < 3 )); then
  echo "FAIL: secondary park path should retain WFE parking loops; found only $wfe_count WFE instructions." >&2
  exit 1
fi

if grep -E '^[[:space:]]*[0-9a-f]+:.*[[:space:]](br|blr)[[:space:]]+x[0-9]+' <<<"$boot_disasm" >/dev/null; then
  echo "FAIL: boot object contains an indirect branch; S0 must not jump to a secondary entry." >&2
  exit 1
fi

if ! awk '
  $1 == ".Lsecondary_release_disabled:" { seen = 1; next }
  seen && $1 == "b" && $2 == ".Lsecondary_release_disabled" { found = 1 }
  END { exit found ? 0 : 1 }
' "$BOOT_SRC"; then
  echo "FAIL: boot.S no longer keeps the secondary release-disabled loop explicit." >&2
  exit 1
fi

if rg -n '(__atomic_store_n\(&smp_secondary_mailboxes|smp_secondary_release_.*store|smp_secondary_mailboxes\[.*\]\.(release_flag|entry|stack_top|argument)[[:space:]]*=)' \
      "$ROOT/kernel/arch/aarch64/io.h" "$ROOT/kernel/smp" >/dev/null; then
  echo "FAIL: S0 code writes secondary release mailbox fields; S1 must add release writes deliberately." >&2
  exit 1
fi

echo "PASS: S0 secondary release guard holds (no PSCI calls, no secondary entry branch, mailbox remains read-only)"
