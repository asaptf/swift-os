#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c7_cell_pagecap_test.sh - C7a: intra-member resident-page cap enforcement.
#
# Boots the base image and lets the capConsole boot probe (/bin/cellgrowprobe, run
# from kernel/main.swift) exercise the C7a slice: create a cell with a hard resident-
# page cap, launch /bin/cellgrower into it, and prove the grower cannot grow its OWN
# heap past the cap. The grower sbrk()s until the kernel refuses the grow (the cap
# bites mid-member, not just at spawn), confirms a fresh anon mmap is ALSO refused
# (cross-path), and the supervisor asserts cell_stat's residentPages stays <= cap. An
# uncapped (global) member — the supervisor itself — grows well past the cap pages,
# proving the guard is a no-op for the common case. The probe prints "C7a OK" only
# when every step holds. Non-interactive. Single-core by default; the Makefile target
# also runs it under -smp 4.

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

LOG="$(mktemp -t swiftos-c7a.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c7a-pid.XXXXXX)"
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
  echo "--- serial (C7a cell pagecap region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C7a: intra-member resident-page cap/,$p' | tail -50 >&2 || true
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

await "C7a OK: intra-member resident-page cap enforced, uncapped growth unaffected" 120 \
  || fail "cell-pagecap probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

for marker in \
  "C7a probe: created cell=" \
  "CELLGROWER: sbrk refused at the cap" \
  "CELLGROWER: mmap also refused (cross-path)" \
  "C7a probe: cell residentPages within cap (intra-member cap enforced)" \
  "C7a probe: uncapped global member unaffected by the cell cap" \
  "C7a OK: intra-member resident-page cap enforced, uncapped growth unaffected"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

for marker in \
  "C7a FAIL:" \
  "CELLGROWER FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C7a intra-member resident-page cap enforced (sbrk + mmap), uncapped growth unaffected under -smp $SMP_CPU_COUNT"
exit 0
