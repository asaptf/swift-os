#!/usr/bin/env bash
# Quick probe: require('http2') triggers nghttp2 calloc/malloc paths.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
LOG="$(mktemp -t swiftos-http2.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-http2-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-http2-in.XXXXXX)"; mkfifo "$INFIFO"
trap 'pkill -x qemu-system-aarch64 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

pkill -x qemu-system-aarch64 2>/dev/null || true
sleep 0.3

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

qemu-system-aarch64 -M virt -cpu cortex-a72 -smp 1 -m 2048M -nographic -no-reboot \
  -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
exec 3<>"$INFIFO"

await() { local m="$1" n=0; while (( n < 600 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0
  grep -qE 'EL0 fault|signal 0x000000000000000B' "$LOG" 2>/dev/null && return 2; sleep 0.1; n=$((n+1)); done; return 1; }
send() { printf '%s\n' "$1" >&3; sleep 0.15; }

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || { echo FAIL:boot; exit 2; }
send 'x'; await "M7 tty: running" 40 || true; printf '\003' >&3
await "swift-os login:" 90 || { echo FAIL:login; exit 2; }
send 'root'; await "Password:" 30 || true; send 'swordfish'
await "built-in shell (ash)" 60 || { echo FAIL:shell; exit 2; }

send 'export UV_THREADPOOL_SIZE=1'
send '/bin/node -e "require('"'"'http2'"'"'); console.log('"'"'HTTP2OK'"'"')"'
rc=0; await 'HTTP2OK' 120 || rc=$?
if (( rc == 2 )); then echo "FAIL: SIGSEGV during http2 require"; sed 's/\r//' "$LOG" | tail -20; exit 1; fi
if (( rc != 0 )); then echo "FAIL: timeout"; sed 's/\r//' "$LOG" | tail -20; exit 1; fi
echo "PASS: http2 require OK"
exit 0