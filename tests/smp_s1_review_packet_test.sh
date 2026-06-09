#!/usr/bin/env bash
# smp_s1_review_packet_test.sh - S0k guard for the reviewed S1 handoff.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/S1_REVIEW_PACKET.md"
AUDIT="$ROOT/docs/SMP_STATE_AUDIT.md"
MAKEFILE="$ROOT/Makefile"
RELEASE_GUARD="$ROOT/tests/smp_release_guard_test.sh"

[[ -f "$DOC" ]] || { echo "FAIL: docs/S1_REVIEW_PACKET.md missing" >&2; exit 1; }
[[ -f "$AUDIT" ]] || { echo "FAIL: docs/SMP_STATE_AUDIT.md missing" >&2; exit 1; }
[[ -f "$MAKEFILE" ]] || { echo "FAIL: Makefile missing" >&2; exit 1; }
[[ -f "$RELEASE_GUARD" ]] || { echo "FAIL: tests/smp_release_guard_test.sh missing" >&2; exit 1; }

require() {
  local needle="$1"
  if ! grep -qF "$needle" "$DOC"; then
    echo "FAIL: S1 review packet missing: $needle" >&2
    exit 1
  fi
}

require_in() {
  local file="$1" needle="$2"
  if ! grep -qF "$needle" "$file"; then
    echo "FAIL: $(basename "$file") missing: $needle" >&2
    exit 1
  fi
}

require "S0 is intentionally a parked-SMP foundation"
require "Pending review"
require "D1 - Uniprocessor Fast Path"
require "D2 - Secondary Release Mechanism"
require "D3 - First SMP Support Limit"
require "D4 - Secondary Stack Source"
require "D5 - Timer And Online Marker Contract"
require "D6 - Shared-State Admission Control"

require "docs/RISK_REMEDIATION_ROADMAP.md"
require "docs/SMP_STATE_AUDIT.md"
require "tests/smp_release_guard_test.sh"
require "tests/smp_s1_preflight_test.sh"
require "tests/smp_boot_test.sh"
require "tests/smp_headroom_test.sh"
require "tests/uefi_boot_test.sh"

require "make s0-test"
require "make smp-release-guard"
require "make smp-s1-preflight"
require "make smp-s1-review-packet"
require "make smp-uefi-test"

for blocker in \
  'kernel/user/process.swift:currentProc' \
  'kernel/user/process.swift:rrCursor' \
  'kernel/sched/scheduler.swift:currentThread' \
  'kernel/timer/generic_timer.swift:systemTicks' \
  'kernel/mm/pmm.swift:pmm' \
  'kernel/runtime/heap.c:heap_cursor' \
  'kernel/vfs/vfs.swift:handles' \
  'kernel/vfs/vfs.swift:openDescriptions' \
  'kernel/vfs/vfs.swift:pipes' \
  'kernel/vfs/vfs.swift:endpoints' \
  'kernel/smp/secondary.c:smp_secondary_mailboxes'
do
  require_in "$AUDIT" "\`$blocker\`"
done

s0_line="$(grep -E '^s0-test:' "$MAKEFILE" || true)"
for target in \
  smp-state-audit \
  smp-mailbox-layout \
  smp-release-guard \
  smp-s1-preflight \
  smp-s1-review-packet \
  smp-test \
  smp-headroom-test \
  smp-uefi-test
do
  if [[ "$s0_line" != *"$target"* ]]; then
    echo "FAIL: s0-test does not include $target" >&2
    echo "$s0_line" >&2
    exit 1
  fi
done

require_in "$RELEASE_GUARD" "PSCI CPU_ON must wait for S1 review"
require_in "$RELEASE_GUARD" "S0 code writes secondary release mailbox fields"

echo "PASS: S1 review packet records required decisions, evidence, and pre-S1 gates"
