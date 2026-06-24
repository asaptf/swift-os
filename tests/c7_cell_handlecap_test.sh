#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c7_cell_handlecap_test.sh - C7b: per-cell handle cap enforcement.
#
# Boots the base image and lets the capConsole boot probe (/bin/cellhandleprobe, run
# from kernel/main.swift) exercise the C7b slice: create a cell with a hard handle cap
# (folded into cell_create), launch /bin/cellopener into it, and prove the opener
# cannot grow its OWN handle table past the cap. The opener open()s files until the
# kernel refuses with EMFILE (the cap bites mid-member, at the handle constructor, not
# just at spawn); the supervisor asserts cell_stat's handles stays <= cap. An uncapped
# (global) member — the supervisor itself — opens well past `cap` handles unaffected,
# proving the guard is a no-op for the common case. The probe prints "C7b OK" only when
# every step holds. Non-interactive. Single-core by default; the Makefile target also
# runs it under -smp 4.

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

LOG="$(mktemp -t swiftos-c7b.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c7b-pid.XXXXXX)"
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
  echo "--- serial (C7b cell handlecap region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C7b: per-cell handle cap/,$p' | tail -50 >&2 || true
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

await "C7b OK: per-cell handle cap enforced, uncapped growth unaffected" 120 \
  || fail "cell-handlecap probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

for marker in \
  "C7b probe: created cell=" \
  "CELLOPENER: open refused at the cap (EMFILE)" \
  "C7b probe: cell handles within cap (intra-member cap enforced)" \
  "C7b probe: uncapped global member unaffected by the cell cap" \
  "C7b OK: per-cell handle cap enforced, uncapped growth unaffected"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

for marker in \
  "C7b FAIL:" \
  "CELLOPENER FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C7b per-cell handle cap enforced (EMFILE), uncapped growth unaffected under -smp $SMP_CPU_COUNT"
exit 0
