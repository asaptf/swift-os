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
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-threads.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-threads-pid.XXXXXX)"
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
  rm -f "$LOG" "$PIDFILE"
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

(
  sleep 7;  printf 'tty-line\n'        # M7 ttydemo: a line
  sleep 1;  printf '\003'              # Ctrl-C -> ttydemo exits, console-login starts
  sleep 2;  printf 'root\n'            # log in at the init prompt
  sleep 1;  printf 'swordfish\n'
  sleep 2;  printf '/bin/threadsdemo\n'
  sleep 3;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
await "threadsdemo: counter=4000" 90 || true
sleep 5
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
