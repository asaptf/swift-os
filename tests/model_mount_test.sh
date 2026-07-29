#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# model_mount_test.sh — LM3b acceptance: the signed packed model disk
# (build/model.img) is mounted read-only at /srv/models.
#
# Boots with TWO virtio-blk disks: the normal base image, and the model disk
# (a separate signed SWOSBASE image carrying the model bundle + a MODEL-DISK-ID
# sentinel). The kernel must mount the base as usual and graft the model disk at
# /srv/models. Then, through the normal shell, it asserts:
#   - the boot log reports "LM3b: model disk mounted read-only at /srv/models";
#   - /srv/models/MODEL-DISK-ID reads back the provenance sentinel (so the files
#     genuinely came from the model disk, not the base — the base has no such
#     file); and
#   - the model bundle (stories15M/1/model.bin) is visible under /srv/models.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${SLEEP_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${SLEEP_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
MODEL_IMG="$ROOT/build/model.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SENTINEL="SWOS-MODEL-DISK-v1"

[[ -f "$KERNEL" ]]    || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$MODEL_IMG" ]] || { echo "FAIL: $MODEL_IMG missing (make model-image)" >&2; exit 2; }
if [[ ! -f "$BASE_IMG" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-mmount.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-mmount-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-mmount-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -60 >&2 || true
  exit 1
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -drive "file=$MODEL_IMG,format=raw,if=none,id=swosmodel,readonly=on" \
  -device virtio-blk-device,drive=swosmodel \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "LM3b: model disk mounted read-only at /srv/models" 60 \
  || drive_fail "kernel did not report the model disk mounted at /srv/models"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "no tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "no tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "no login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "no password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line 'cat /srv/models/MODEL-DISK-ID'
await "$SENTINEL" 30 || drive_fail "/srv/models/MODEL-DISK-ID did not read back the sentinel"
send_line 'ls /srv/models/stories15M/1'
await "model.bin" 30 || drive_fail "/srv/models/stories15M/1 does not list model.bin"
send_line 'echo LM3B-CHECKS-DONE'
await "LM3B-CHECKS-DONE" 30 || true
send_line 'exit'

exec 3>&-; stop_qemu; QP=""
clean="$(sed 's/\r//' "$LOG")"

ok=1
grep -qF "LM3b: model disk mounted read-only at /srv/models" <<<"$clean" || { echo "FAIL: no mount log line" >&2; ok=0; }
grep -qF "$SENTINEL" <<<"$clean" || { echo "FAIL: sentinel not read from /srv/models" >&2; ok=0; }
grep -qF "model.bin" <<<"$clean" || { echo "FAIL: model.bin not listed under /srv/models" >&2; ok=0; }

if (( ok )); then
  echo "PASS: model disk mounted read-only at /srv/models (sentinel + bundle present)"
  exit 0
fi
echo "--- serial tail ---" >&2
tail -40 <<<"$clean" >&2
exit 1
