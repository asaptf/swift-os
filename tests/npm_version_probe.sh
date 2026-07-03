#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp -t swiftos-npmver.XXXXXX)"
PIDFILE=$(mktemp -t swiftos-npmver-pid.XXXXXX)
INFIFO=$(mktemp -u -t swiftos-npmver-in.XXXXXX); mkfifo "$INFIFO"
trap 'pkill -x qemu-system-aarch64 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT
pkill -x qemu-system-aarch64 2>/dev/null; sleep 0.3
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
dtb_args=(); [[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu-system-aarch64 -M virt -cpu cortex-a72 -smp 1 -m 2048M -nographic -no-reboot \
  -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$ROOT/build/base.img,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$ROOT/build/kernel.elf" <"$INFIFO" >"$LOG" 2>&1 &
exec 3<>"$INFIFO"
await() { local m="$1" n=0; while ((n<900)); do grep -qF "$m" "$LOG" && return 0
  grep -qE 'EL0 fault' "$LOG" && return 2; sleep 0.1; n=$((n+1)); done; return 1; }
send() { printf '%s\n' "$1" >&3; sleep 0.15; }
await "swift-os login:" 120 || { echo FAIL:boot; exit 2; }
send 'root'; await "Password:" 30 || true; send 'swordfish'; await "built-in shell (ash)" 60
send '/bin/node /usr/lib/node_modules/npm/bin/npm-cli.js --version'
rc=0; await '11.13.0' 120 || rc=$?
if (( rc == 2 )); then echo FAIL:SIGSEGV; sed 's/\r//' "$LOG"|tail -10; exit 1; fi
if (( rc != 0 )); then echo FAIL:timeout; sed 's/\r//' "$LOG"|tail -15; exit 1; fi
echo PASS:npm-version
exit 0