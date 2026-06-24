#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c7_cell_realservice_test.sh - C7d: a real in-tree service (/bin/kv) in a supervised cell.
#
# Boots the base image and lets the capConsole boot probe (/bin/cell-kv-supervisor, run
# from kernel/main.swift) exercise the C7d payoff: it lifts the EXISTING real service
# /bin/kv (the in-memory key-value store) into a cell, unchanged — a /tmp namespace root,
# a restricted handle set (only a stdin pipe + a stdout pipe), and page + handle caps —
# drives a real client round-trip (SET then GET returns the stored value), asserts
# isolation + accounting, then faults the service (closes its stdin), detects the exit
# via waitpid, restarts it in a FRESH cell (a different CellId) whose store is empty
# (GET -> "(nil)", proving a genuinely new process), serves another round-trip, and
# tears the cell down cleanly. The probe prints "C7d OK" only when every step holds.
# Non-interactive. Single-core by default; the Makefile target also runs it under -smp 4.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
SMP_CPU_COUNT="${SMP_CPUS:-1}"
if [[ "$SMP_CPU_COUNT" -gt 1 ]]; then
  DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
fi
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-c7d.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c7d-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (C7d real-service region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C7d: real service/,$p' | tail -60 >&2 || true
  exit 1
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" </dev/null >"$LOG" 2>&1 &
QP=$!

await "C7d OK: a real service (/bin/kv) ran isolated in a supervised cell" 120 \
  || fail "cell-kv-supervisor probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

for marker in \
  "C7d probe: gen 1 /bin/kv up in cell=" \
  "C7d probe: round-trip OK (GET returned the stored value)" \
  "C7d probe: service isolated (handles within cap)" \
  "C7d probe: gen 1 exited, supervisor detected it" \
  "C7d probe: gen 2 /bin/kv restarted in a fresh cell=" \
  "C7d probe: restarted service has fresh state (GET -> (nil))" \
  "C7d probe: gen 1 cell reclaimed, accounting reset" \
  "C7d probe: gen 2 cell torn down cleanly" \
  "C7d OK: a real service (/bin/kv) ran isolated in a supervised cell"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

for marker in \
  "C7d FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C7d real service /bin/kv ran isolated + supervised in a cell, restarted fresh, torn down under -smp $SMP_CPU_COUNT"
exit 0
