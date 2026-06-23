#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shmring_test.sh — LA3 acceptance: the shared-memory SPSC ring data path.
#
# Boots at -smp 4 so a missed cross-CPU publish/consume ordering (producer on one
# CPU, consumer on another) would corrupt a record or hang — caught as a mismatch
# marker or an await timeout. /bin/shmringprobe creates a full-duplex channel
# (SYS_SHMRING_CREATE), forks, both sides map it (SYS_SHMRING_MAP), and the parent
# streams records into ring0 while the child echoes them back via ring1; every
# record crosses through the mapped pages with no syscall in the per-record path.
#
# Markers emitted by /bin/shmringprobe:
#   SHMRING OK: ... records round-tripped ...   — every record verified both ways
#   SHMRING FAIL: ...                           — mismatch, map/create error, or timeout

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-120}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-shmring.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-shmring-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-shmring-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M
  -nographic -no-reboot -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-$TIMEOUT}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    if [[ -n "$QP" ]] && ! jobs -pr | grep -qx "$QP"; then
      echo "FAIL: QEMU exited while waiting for marker: $marker" >&2
      echo "--- serial tail ---" >&2
      sed 's/\r//' "$LOG" | tail -80 >&2
      exit 1
    fi
    sleep 0.1; n=$((n + 1))
  done
  echo "FAIL: timed out waiting for marker: $marker" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" | tail -80 >&2
  exit 1
}

send_line() {
  local line="$1" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep 0.02
  done
  printf '\n' >&3
  sleep 0.1
}

# Boot and login.
await "M7 tty: type a line then Enter" 60
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40
printf '\003' >&3
await "swift-os login:" 90
send_line 'root'
await "Password:" 30
send_line 'swordfish'
await "built-in shell (ash)" 120

# Run the full-duplex shared-memory ring round-trip at -smp 4.
send_line '/bin/shmringprobe'
await "SHMRING OK:" 60

send_line 'exit'
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "SHMRING OK:" <<<"$clean" || { echo "FAIL: SHMRING OK marker not seen" >&2; ok=0; }
if grep -qF "SHMRING FAIL" <<<"$clean"; then
  echo "FAIL: a failure marker was emitted" >&2; ok=0
fi
if grep -qF "panic:" <<<"$clean"; then
  echo "FAIL: kernel panic during the test" >&2; ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: LA3 shmring — full-duplex record round-trip over mapped pages (smp=$SMP_CPU_COUNT)"
  exit 0
else
  exit 1
fi
