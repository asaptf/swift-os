#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_rollback_test.sh — U1d acceptance: attempt-based rollback. An unconfirmed
# active slot that exhausts its boot attempts is marked FAILED and the kernel
# switches to the known-good fallback — persisted across reboots.
#
# Store: active=A, both slots a valid signed base image, neither confirmed. The
# operator never runs /bin/swos-confirm, so slot A keeps accruing attempts:
#   boots 1-3: slot A records attempts 1, 2, 3.
#   boot 4   : attempts exhausted (>= maxBootAttempts=3) -> roll back to slot B,
#              which then records its own first attempt.
# cache=writethrough makes each boot's manifest write durable across kill+reboot.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE="$ROOT/build/base.img"
USTORE="$ROOT/build/updatestore"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE" ]]   || { echo "FAIL: $BASE missing (make base-image)" >&2; exit 2; }
[[ -x "$USTORE" ]] || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

STORE="$(mktemp -t swiftos-abr.XXXXXX)"
LOG="$(mktemp -t swiftos-abr-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-abr-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$STORE" "$LOG" "$PIDFILE"' EXIT

"$USTORE" "$STORE" A "$BASE" "$BASE" >/dev/null || { echo "FAIL: could not build store" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

boot_once() {  # boot_once <marker> — boot the SAME store, wait for marker, kill
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
    -drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writethrough" \
    -device virtio-blk-device,drive=swosstore \
    -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
  QP=$!
  local rc=1
  await "$1" 60 && rc=0
  stop_qemu; QP=""
  return $rc
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

boot_once "update-store: recorded boot attempt 1 for active slot A" || fail "boot 1: attempt 1 not recorded"
boot_once "update-store: recorded boot attempt 2 for active slot A" || fail "boot 2: attempt 2 not recorded"
boot_once "update-store: recorded boot attempt 3 for active slot A" || fail "boot 3: attempt 3 not recorded"

# Boot 4: slot A's attempts are exhausted -> roll back to slot B. Await the final
# marker of the rollback path (B's first attempt), then check the earlier ones.
boot_once "update-store: recorded boot attempt 1 for active slot B" || fail "boot 4: did not roll back to slot B"
grep -qF "rolling back to slot B" "$LOG" || fail "boot 4: rollback marker missing"
grep -qF "exhausted 3 attempts" "$LOG" || fail "boot 4: exhaustion marker missing"
if grep -qF "active slot A" "$LOG"; then
  # After rollback the active slot is B; slot A must no longer be selected active.
  if grep -qF "manifest valid, active slot A" "$LOG"; then fail "boot 4: still booted slot A after rollback"; fi
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B attempt-based rollback — exhausted unconfirmed slot fails over to the fallback (persisted)"
  exit 0
fi
echo "--- serial (boot 4) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|rolling|exhausted' >&2 | tail -20
exit 1
