#!/usr/bin/env bash
# Probe which npm/node commands crash on SwiftOS (full boot + login).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
CMD="${1:-}"
MARKER="${2:-NPM_SUBCMD_OK}"
[[ -n "$CMD" ]] || { echo "usage: $0 '<shell cmd>' [marker]" >&2; exit 2; }

LOG="$(mktemp -t swiftos-npm-subcmd.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-npm-subcmd-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-npm-subcmd-in.XXXXXX)"; mkfifo "$INFIFO"
trap '[[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

qemu-system-aarch64 -M virt -cpu cortex-a72 -smp "${NODE_QEMU_SMP:-1}" -m 2048M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
exec 3<>"$INFIFO"

await() {
  local m="$1" mx="${2:-60}" n=0
  while ((n<mx*10)); do
    grep -qF "$m" "$LOG" 2>/dev/null && return 0
    grep -qE 'EL0 fault|signal 0x000000000000000B' "$LOG" 2>/dev/null && return 2
    sleep 0.1; n=$((n+1))
  done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.15; }

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || { echo "FAIL: no tty"; exit 1; }
send 'x'; await "M7 tty: running" 40 || true; printf '\003' >&3
await "swift-os login:" 90 || { echo "FAIL: no login"; exit 1; }
send 'root'; await "Password:" 30 || true; send 'swordfish'
await "built-in shell (ash)" 120 || { echo "FAIL: no shell"; exit 1; }

send "$CMD"
rc=0
await "$MARKER" 180 || rc=$?
if (( rc == 2 )); then echo "FAIL: $CMD (SIGSEGV)"; exit 1; fi
(( rc == 0 )) && { echo "PASS: $CMD"; exit 0; }
echo "FAIL: $CMD" >&2
grep -iE 'EL0 fault|Segmentation|SIGILL|IOT|ERR!' "$LOG" | tail -5 >&2
sed 's/\r//' "$LOG" | tail -12 >&2
exit 1