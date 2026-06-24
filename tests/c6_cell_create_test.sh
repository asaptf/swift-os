#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c6_cell_create_test.sh - C6b: cell creation + spawn-into-cell.
#
# Boots the base image and lets the capConsole boot probe (/bin/cellcreateprobe,
# run from kernel/main.swift) act as a minimal cell supervisor. It refuses a spawn
# into a fd that is not a cell control handle, creates a cell (SYS_cell_create),
# launches /bin/cellchild into it (SYS_cell_spawn) with a pipe barrier, and reads
# SYS_cell_stat to prove the child is charged to the NEW cell and not to globalCell,
# then reaps it and proves the charge is reclaimed. The probe prints "C6b OK: ..."
# only when every assertion holds. Non-interactive boot probe.
# Runs single-core by default; the Makefile target also runs it under -smp 4.

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

LOG="$(mktemp -t swiftos-c6b.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c6b-pid.XXXXXX)"
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
  echo "--- serial (C6b cell create region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C6b: cell-creation/,$p' | tail -40 >&2 || true
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

await "C6b OK: cell created, child charged to it (not globalCell), and reclaimed on reap" 120 \
  || fail "cell-creation probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

# The verdict, the authority-by-handle refusal, the child actually running inside
# the cell, and the per-stage reports must all be present.
for marker in \
  "C6b probe: spawn into non-cell fd refused (authority by handle)" \
  "C6b probe: created cell=" \
  "CELLCHILD: alive in cell" \
  "C6b probe: with-child" \
  "C6b probe: after-reap" \
  "C6b OK: cell created, child charged to it (not globalCell), and reclaimed on reap"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

for marker in \
  "C6b FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C6b cell created, child charged to the new cell (not globalCell), reclaimed on reap under -smp $SMP_CPU_COUNT"
exit 0
