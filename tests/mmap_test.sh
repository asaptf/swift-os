#!/usr/bin/env bash
# mmap_test.sh — Track B acceptance: mmap/munmap/mprotect + W^X.
#
# Boots the kernel (-kernel) with the packed base image attached, satisfies the
# M7 tty demo (a line + Ctrl-C), logs in as root, then runs /bin/mmapdemo, which
# exercises the whole Track B surface and prints one `mmapdemo: <TAG>` line per
# check:
#   B1 — anonymous mmap: a fresh mapping reads as 0, then a write/read pattern
#        round-trips across a page boundary, then munmap.
#   B2 — mprotect + W^X (the JIT pattern): mmap RW, write `mov w0,#42; ret`,
#        mprotect RW->RX, call it -> 42; and both W^X breaches (mmap RWX,
#        mprotect ->RWX on a live mapping) are rejected.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

DISK="$ROOT/build/base.img"
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-mmap.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-mmap-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-mmap-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
  fi
}
cleanup() {
  stop_qemu
  exec 3>&- 2>/dev/null || true
  rm -f "$LOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

blk_args=()
if [[ -f "$DISK" ]]; then
  blk_args=(-global virtio-mmio.force-legacy=false \
            -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
            -device virtio-blk-device,drive=swosbase)
fi

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (mmapdemo driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -80 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${MMAP_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${MMAP_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/mmapdemo'
await "mmapdemo: ALL-OK" 90 || drive_fail "mmapdemo did not finish cleanly"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
# B1 — anonymous mmap.
grep -qF "mmapdemo: B1-OK" <<<"$clean" || { echo "FAIL: B1 anon mmap (zero/write/read/munmap)" >&2; ok=0; }
# B2 — JIT pattern + W^X.
grep -qF "mmapdemo: B2-OK jit RW->RX call returned 42" <<<"$clean" \
  || { echo "FAIL: B2 mprotect RW->RX + call != 42" >&2; ok=0; }
grep -qF "mmapdemo: WX-OK mprotect ->RWX rejected" <<<"$clean" \
  || { echo "FAIL: W^X did not reject mprotect ->RWX" >&2; ok=0; }
grep -qF "mmapdemo: WX-OK mmap RWX rejected" <<<"$clean" \
  || { echo "FAIL: W^X did not reject mmap RWX" >&2; ok=0; }
# I6 — munmap of a file-backed mapping deactivates its demand-page VMA.
grep -qF "mmapdemo: I6-OK file munmap drops stale VMA" <<<"$clean" \
  || { echo "FAIL: stale file VMA survived munmap (old content served)" >&2; ok=0; }
grep -qF "mmapdemo: I6-OK file vma slots recycled" <<<"$clean" \
  || { echo "FAIL: file VMA slots are not recycled by munmap" >&2; ok=0; }
grep -qF "mmapdemo: ALL-OK" <<<"$clean" || { echo "FAIL: mmapdemo did not finish cleanly" >&2; ok=0; }
# A W^X breach (a live RWX mapping) must never have been reported.
grep -qF "W^X breach" <<<"$clean" && { echo "FAIL: a W^X breach was reported" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: mmap/munmap/mprotect + W^X (Track B acceptance)"
  exit 0
fi
echo "--- serial (mmapdemo region) ---" >&2
sed -n '/mmapdemo/,$p' <<<"$clean" | head -30 >&2
echo "--- tail ---" >&2
tail -20 <<<"$clean" >&2
exit 1
