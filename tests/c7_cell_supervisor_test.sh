#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c7_cell_supervisor_test.sh - C7c: persistent restart/FDIR cell supervisor.
#
# Boots the base image and lets the capConsole boot probe (/bin/cell-supervisor, run
# from kernel/main.swift) exercise the C7c slice: a long-running supervisor hosts the
# demo service /bin/cell-svc inside a cell, detects its exit/crash via waitpid, tears
# the cell down (cell_pids -> reap -> cell_destroy), and restarts in a FRESH cell.
#   Phase A: gen 1 comes up (ping->pong), is faulted (the service exits non-zero on
#     "die"), the supervisor detects it and restarts gen 2 in a different CellId, with
#     the faulted generation's accounting reclaimed.
#   Phase B: a service that crashes immediately is restarted up to the bounded cap (3),
#     each generation reclaimed, then the supervisor halts the crash loop.
# The probe prints "C7c OK" only when every step holds. Non-interactive. Single-core by
# default; the Makefile target also runs it under -smp 4.

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

LOG="$(mktemp -t swiftos-c7c.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c7c-pid.XXXXXX)"
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
  echo "--- serial (C7c cell supervisor region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C7c: persistent restart/,$p' | tail -60 >&2 || true
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

await "C7c OK: supervised restart in a fresh cell, accounting reclaimed, bounded crash loop halted" 120 \
  || fail "cell-supervisor probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

for marker in \
  "C7c probe: gen 1 up, cell=" \
  "C7c probe: gen 1 faulted (detected exit code " \
  "C7c probe: gen 2 up, cell=" \
  "C7c probe: restarted in a fresh CellId" \
  "C7c probe: gen 1 cell reclaimed, accounting reset" \
  "C7c probe: crash-loop attempt 1 reclaimed" \
  "C7c probe: crash-loop attempt 3 reclaimed" \
  "C7c probe: restart cap reached (3), halting crash loop" \
  "C7c OK: supervised restart in a fresh cell, accounting reclaimed, bounded crash loop halted"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

for marker in \
  "C7c FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C7c persistent supervisor restarted the service in a fresh cell + bounded the crash loop under -smp $SMP_CPU_COUNT"
exit 0
