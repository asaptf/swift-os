#!/usr/bin/env bash
# threads_test.sh — rt-a acceptance: userland threads + futex.
#
# Boots the kernel (-kernel) with the packed base image attached, satisfies the
# M7 tty demo (a line + Ctrl-C), logs in as root, then runs /bin/threadsdemo:
# two EL0 threads share the address space and each increment a shared counter
# 2000 times under a futex mutex, joining via a futex. The final counter must be
# 2*2000 = 4000, printed as `threadsdemo: counter=4000`.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${THREADS_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${THREADS_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-threads.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-threads-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-threads-in.XXXXXX)"; mkfifo "$INFIFO"
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

# Attach the packed base image (modern virtio-mmio) so /bin/threadsdemo comes
# off disk.
DISK="$ROOT/build/base.img"
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
  echo "--- serial (threadsdemo driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -80 >&2 || true
  exit 1
}


"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/threadsdemo'
await "threadsdemo: counter=4000" 90 || drive_fail "threadsdemo did not complete"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "threadsdemo: counter=" "$LOG" || { echo "FAIL: no threadsdemo output" >&2; ok=0; }
grep -qF "threadsdemo: counter=4000" "$LOG" || { echo "FAIL: counter != 4000 (race or join bug)" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: threadsdemo two threads + futex mutex/join, counter=4000 (rt-a acceptance)"
  exit 0
fi
echo "--- serial (threadsdemo region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/threadsdemo/,$p' >&2
echo "--- tail ---" >&2
sed 's/\r//' "$LOG" | tail -20 >&2
exit 1
