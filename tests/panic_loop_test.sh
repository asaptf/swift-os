#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# panic_loop_test.sh — TH6: the panic auto-reboot loop guard.
#
# Boots a TEST-ONLY kernel (built with -D PANIC_LOOP_INJECT) whose hook faults on
# every boot, BEFORE the healthy-boot marker. Each panic auto-reboots via PSCI; the
# guard counts consecutive panic-reboots in a reset-surviving RAM cookie and, on the
# Nth, HALTS instead of resetting. The test asserts the machine reboots a BOUNDED
# number of times (exactly the limit) and then halts — proving (a) the loop is
# broken, and (b) the cookie survived the warm reset (otherwise the count would
# never accumulate and it would loop forever).
#
# Deliberately runs WITHOUT -no-reboot so PSCI SYSTEM_RESET actually warm-resets the
# machine (one QEMU process across reboots, serial accumulates), exercising the
# cross-reset persistence the guard depends on.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="${PANIC_LOOP_KERNEL:-$ROOT/build/kernel-paniclooptest.elf}"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
LIMIT=3   # must match maxConsecutivePanicReboots in kernel/power/power.swift

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (run: make panic-loop-test)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-panicloop.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-panicloop-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER MAXSEC
  local marker="$1" max="${2:-120}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    if [[ -n "$QP" ]] && ! kill -0 "$QP" 2>/dev/null; then return 2; fi
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  ${dtb_args[@]+"${dtb_args[@]}"} \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

HALT_MARK="consecutive auto-reboots; halting to break the loop"
await "$HALT_MARK" 180
rc=$?
if [[ "$rc" -ne 0 ]]; then
  if [[ "$rc" -eq 2 ]]; then
    echo "FAIL: QEMU exited instead of halting in a wfi loop" >&2
  else
    echo "FAIL: guard never halted within the timeout — box is looping (cookie not" >&2
    echo "      surviving the warm reset?) or it booted past the injector" >&2
  fi
  echo "--- serial tail ---" >&2; sed 's/\r//' "$LOG" | tail -30 >&2
  exit 1
fi

# Settle: confirm no further boot happens after the halt marker.
sleep 2
stop_qemu; QP=""
clean="$(sed 's/\r//' "$LOG")"

injections="$(grep -cF 'panic-loop-test: injecting an early panic' <<<"$clean")"
if [[ "$injections" -ne "$LIMIT" ]]; then
  echo "FAIL: expected exactly $LIMIT panic injections before the halt, saw $injections" >&2
  grep -F 'panic-loop-test' <<<"$clean" >&2 || true
  exit 1
fi

# The injector fires before the healthy-boot marker every boot, so the steady-state
# path must never be reached.
if grep -qF "starting swos-init" <<<"$clean"; then
  echo "FAIL: kernel reached the healthy-boot path; injector did not fire pre-healthy" >&2
  exit 1
fi

echo "PASS: panic auto-reboot loop bounded to $LIMIT then halted (cookie survived the warm reset)"
exit 0
