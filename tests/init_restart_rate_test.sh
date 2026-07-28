#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# init_restart_rate_test.sh — swos-init rate-based restart policy proof.
#
# Builds a temporary base image whose service manifest uses `false-supervised`
# (a supervised child that exits immediately on every start). swos-init must:
#   1. treat each quick death as a startup failure and restart it only a bounded
#      number of times,
#   2. print the existing "crash-looped; giving up after N restarts" line,
#   3. still start console-login so the serial login prompt appears.
#
# Without the rate-based policy (kind-based unbounded restarts), a supervised
# crash-loop keeps exclusive supervision busy and starves the console path —
# the datafs / prod-profile nightly failure mode when accept() fails in a loop.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-init-restart-rate.XXXXXX)"
LOG="$WORK/serial.log"
SERVICES="$WORK/services"
IMG="$WORK/base-init-rate.img"
BASE_ROOT="$WORK/base-root"
PIDFILE="$WORK/qemu.pid"
INFIFO="$WORK/qemu.in"
mkfifo "$INFIFO"
printf 'false-supervised\n' >"$SERVICES"

if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" SWOS_SERVICES_FILE="$SERVICES" base-image ) >"$WORK/base-image.log" 2>&1; then
  echo "FAIL: could not build rate-restart base image" >&2
  cat "$WORK/base-image.log" >&2
  exit 2
fi

QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -rf "$WORK"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (init restart rate) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${INIT_RATE_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${INIT_RATE_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$IMG,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Walk the demo tty, then require the supervised crash-loop to halt and the
# console login path to remain usable.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3

await "swos-init: supervision active" 90 || drive_fail "swos-init did not enter supervision mode"
await "swos-init: service false crash-looped; giving up after 5 restarts" 60 \
  || drive_fail "false service was not rate-limited / given up on"
await "swift-os login:" 90 || drive_fail "no login prompt (console starved by restart loop)"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1

grep -qF "swos-init: supervision active" <<<"$clean" \
  || { echo "FAIL: supervision marker missing" >&2; ok=0; }
grep -qF "swos-init: service false crash-looped; giving up after 5 restarts" <<<"$clean" \
  || { echo "FAIL: give-up message missing" >&2; ok=0; }
grep -qF "swift-os login:" <<<"$clean" \
  || { echo "FAIL: login prompt missing" >&2; ok=0; }

# Bound the spin: initial start + at most MAX_RESTARTS_PER_SERVICE restarts
# (and a small slack). A tight kind-based loop produces hundreds of starts.
starts="$(grep -cF "swos-init: started false pid" <<<"$clean" || true)"
if [[ "$starts" -lt 2 ]]; then
  echo "FAIL: expected multiple false starts before give-up, got $starts" >&2
  ok=0
fi
if [[ "$starts" -gt 12 ]]; then
  echo "FAIL: false restart spin not bounded (started $starts times)" >&2
  ok=0
fi

restarts="$(grep -cF "swos-init: service false pid" <<<"$clean" || true)"
if [[ "$restarts" -gt 12 ]]; then
  echo "FAIL: too many false restart notices ($restarts)" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: swos-init rate-limited quick deaths and kept the login prompt"
  exit 0
fi

echo "--- serial (init restart rate region) ---" >&2
grep -iE 'swos-init:|swift-os login:|panic|abort|M7' <<<"$clean" | tail -80 >&2 || true
exit 1
