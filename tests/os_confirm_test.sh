#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# os_confirm_test.sh — OS-5 acceptance: health-confirm + anti-rollback floor bump.
#
# A store-booted session on a store whose active slot A carries system_version 5
# (floor 0):
#   1. `swupdate confirm --auto` with no services up refuses to confirm (the box
#      isn't healthy) — a trial boot that never gets healthy is left to the
#      attempt-based rollback;
#   2. `swupdate confirm` marks slot A CONFIRMED and the kernel raises the
#      anti-rollback floor to 5;
#   3. with the floor now 5, staging version 5 is refused but version 6 succeeds —
#      proving confirm closes the rollback window.
#
# Reuses the signed SWOSBASE fixture baked at /usr/share/swupdate-test/test-base.img
# (INCLUDE_OS_STAGE_TEST=1). cache=writethrough makes the manifest writes durable.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE="$ROOT/build/base.img"
USTORE="$ROOT/build/updatestore"
FIXTURE="/usr/share/swupdate-test/test-base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE" ]]   || { echo "FAIL: $BASE missing (make base-image INCLUDE_OS_STAGE_TEST=1)" >&2; exit 2; }
[[ -x "$USTORE" ]] || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-osc.XXXXXX)"
STORE="$WORK/store.img"; LOG="$WORK/serial.log"; PIDFILE="$WORK/pid"; INFIFO="$WORK/in"; mkfifo "$INFIFO"
QP=""
cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  exec 3>&- 2>/dev/null || true; rm -rf "$WORK"
}
trap cleanup EXIT

# Active slot A carries system_version 5; floor starts at 0.
"$USTORE" "$STORE" A "$BASE" "$BASE" --slot-a-version 5 >/dev/null \
  || { echo "FAIL: could not build store" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local m="$1" max="${2:-30}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
send() { sleep 0.3; local s="$1" i; for (( i=0; i<${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done; }
to_shell() {
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || return 1
  send $'tty-line\n'; await "M7 tty: running; press Ctrl-C" 40 || return 1
  send $'\003'; await "swift-os login:" 90 || return 1
  send $'root\n'; await "Password:" 90 || return 1
  send $'swordfish\n'; await "M12c: shell ready" 120 || return 1
  return 0
}
run_until() {  # run_until "cmd" "marker" [tries] [maxsec]
  local cmd="$1" marker="$2" tries="${3:-5}" max="${4:-20}" i
  for (( i=0; i<tries; i++ )); do send "$cmd"$'\n'; await "$marker" "$max" && return 0; done
  return 1
}

: > "$LOG"
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writethrough" \
  -device virtio-blk-device,drive=swosstore \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

if to_shell; then
  await "update-store: SWOSBOOT manifest valid, active slot A" 30 || fail "did not boot slot A"

  # 1. --auto with no services up must refuse (and not confirm / not bump floor).
  run_until "/bin/swupdate confirm --auto" "leaving slot on trial" 4 15 \
    || fail "confirm --auto did not refuse on an unhealthy box"
  grep -qF "anti-rollback floor raised" "$LOG" && fail "confirm --auto bumped the floor (should not have)"

  # 2. Explicit confirm marks slot A healthy and raises the floor to 5.
  run_until "/bin/swupdate confirm" "base A/B slot confirmed healthy" 4 15 \
    || fail "explicit confirm did not confirm the booted slot"
  await "anti-rollback floor raised to 5" 5 || fail "confirm did not raise the floor to the slot version"

  # 3. Floor now 5: staging version 5 is refused, version 6 succeeds.
  run_until "/bin/swos-stagebase $FIXTURE 5" "swos-stagebase: rejected" 4 15 \
    || fail "staging at the floor (5) was not refused after confirm"
  run_until "/bin/swos-stagebase $FIXTURE 6" "update-store: staged base image" 4 20 \
    || fail "staging above the floor (6) was refused"
  await "version 6) into slot B" 5 || fail "version-6 stage did not record as expected"
else
  fail "could not reach a shell"
fi
exec 3>&-

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: OS-5 confirm — --auto gates on health, explicit confirm raises the anti-rollback floor, floor blocks rollback"
  exit 0
fi
echo "--- serial ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'swupdate|update-store|confirm|floor|active slot' >&2 | tail -30
exit 1
