#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# os_stage_test.sh — OS-3b acceptance: /bin/swos-stagebase streams a base image
# from a file into the INACTIVE A/B slot through the capability-gated kernel
# staging syscalls (update_stage_begin/write/commit), and the kernel enforces the
# monotonic anti-rollback floor.
#
# Single store-booted session (no payload disk — the source is a guest file):
#   1. anti-rollback: staging a version <= the store's baked floor (10) is refused
#      at begin (EPERM), before any bytes are written.
#   2. bad header: streaming a non-SWOSBASE file commits-rejects (EINVAL); the slot
#      is NOT marked staged.
#   3. success: streaming the tiny signed SWOSBASE fixture (version 11 > floor)
#      commits — the kernel marks the inactive slot B staged at version 11.
#
# The store is built with --min-version 10 so (1) has a floor to trip. The base
# image carries the fixture at /usr/share/swupdate-test/test-base.img (baked by
# `make base-image INCLUDE_OS_STAGE_TEST=1`). cache=writethrough makes the slot
# write + manifest write-back durable, matching the other A/B tests.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

STORE="$(mktemp -t swiftos-oss.XXXXXX)"
LOG="$(mktemp -t swiftos-oss-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-oss-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-oss-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$STORE" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Active slot A valid (base.img), slot B a same-size placeholder; anti-rollback
# floor baked at 10 so a lower-version stage is refused.
"$USTORE" "$STORE" A "$BASE" "$BASE" --min-version 10 >/dev/null \
  || { echo "FAIL: could not build store" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

: > "$LOG"
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writethrough" \
  -device virtio-blk-device,drive=swosstore \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

send() {
  sleep 0.3
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done
}
to_shell() {
  await "M7 tty: type a line then Enter" 60 || return 1
  send $'tty-line\n'
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  send $'\003'
  await "swift-os login:" 90 || return 1
  send $'root\n'
  await "Password:" 90 || return 1
  send $'swordfish\n'
  await "M12c: shell ready" 120 || return 1
  return 0
}
# Run `cmd` in the guest until `marker` appears, retrying on a dropped serial line.
run_until() {  # run_until "cmd" "marker" [tries] [maxsec]
  local cmd="$1" marker="$2" tries="${3:-5}" max="${4:-20}" i
  for (( i = 0; i < tries; i++ )); do
    send "$cmd"$'\n'
    if await "$marker" "$max"; then return 0; fi
  done
  return 1
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

if to_shell; then
  await "update-store: SWOSBOOT manifest valid, active slot A" 30 || fail "did not boot slot A"

  # 1. Anti-rollback: version 5 <= floor 10 -> refused at begin (EPERM).
  run_until "/bin/swos-stagebase $FIXTURE 5" "swos-stagebase: rejected" 5 15 \
    || fail "anti-rollback: a version below the floor was not refused"

  # 2. Bad header: a non-SWOSBASE file (an ELF) commits-rejects.
  run_until "/bin/swos-stagebase /bin/ls 11" "swos-stagebase: commit rejected" 5 20 \
    || fail "bad-header: a non-SWOSBASE payload was not rejected at commit"

  # 3. Success: the signed fixture (version 11 > floor) stages into slot B.
  run_until "/bin/swos-stagebase $FIXTURE 11" "update-store: staged base image" 5 20 \
    || fail "success: kernel did not stage the fixture into the inactive slot"
  await "version 11) into slot B" 5 || fail "success: staged slot/version not as expected"
  await "swos-stagebase: staged image into the inactive slot" 5 || fail "success: tool did not confirm"
else
  fail "could not reach a shell"
fi
exec 3>&-; stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: OS-3b stage — swos-stagebase streams a base image into the inactive slot; anti-rollback + bad-header rejected, valid image staged"
  exit 0
fi
echo "--- serial ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|swos-stagebase|active slot' >&2 | tail -25
exit 1
