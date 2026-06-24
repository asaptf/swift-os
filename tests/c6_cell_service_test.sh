#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c6_cell_service_test.sh - C6e: end-to-end one-service-per-cell.
#
# Boots the base image and lets the capConsole boot probe (/bin/cellsvcprobe, run
# from kernel/main.swift) act as a cell supervisor: it assembles a cell { a /www
# namespace root + a restricted handle set + a resident-page cap }, launches a real
# request/reply service (/bin/cellhello) inside it, drives a live ping/pong
# round-trip over the granted endpoints, confirms the service is isolated (the
# service itself proves a confined namespace + no ambient handles) and charged to
# the cell, then tears it down and reclaims the domain. The probe prints "C6e OK"
# only when every step holds. Non-interactive boot probe.
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

LOG="$(mktemp -t swiftos-c6e.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c6e-pid.XXXXXX)"
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
  echo "--- serial (C6e cell service region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C6e: one-service-per-cell/,$p' | tail -50 >&2 || true
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

await "C6e OK: a real service ran isolated in a cell (namespace + handles + cap) and tore down cleanly" 120 \
  || fail "one-service-per-cell probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

# The cell assembly, the service's own isolation proofs, the live round-trip,
# accounting, and clean teardown must all be present.
for marker in \
  "C6e probe: assembled cell=" \
  "CELLHELLO: namespace confined (/etc denied)" \
  "CELLHELLO: only granted handles (no ambient fd 0)" \
  "CELLHELLO: serving on the granted endpoint" \
  "C6e probe: service replied pong from inside the cell" \
  "C6e probe: cell_stat processes=1" \
  "CELLHELLO: stopped" \
  "C6e probe: cell torn down, accounting reclaimed" \
  "C6e OK: a real service ran isolated in a cell (namespace + handles + cap) and tore down cleanly"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

for marker in \
  "C6e FAIL:" \
  "CELLHELLO FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C6e a real service ran isolated in a cell and tore down cleanly under -smp $SMP_CPU_COUNT"
exit 0
