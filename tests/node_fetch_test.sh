#!/usr/bin/env bash
# node_fetch_test.sh — Node HTTP client smoke to slirp gateway (10.0.2.2).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${NODE_QEMU_MEM:-2048M}"
REG_PORT="${NPM_REGISTRY_PORT:-$((26000 + ($$ % 15000)))}"
MARK="NODEFETCH ok"

[[ -f "$KERNEL" && -f "$DISK" ]] || { echo "FAIL: missing build artifacts" >&2; exit 2; }

LOG="$(mktemp -t swiftos-node-fetch.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-node-fetch-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-node-fetch-in.XXXXXX)"; mkfifo "$INFIFO"
REGPID=""
QP=""
stop_all() {
  [[ -n "$REGPID" ]] && kill "$REGPID" 2>/dev/null || true
  if [[ -f "$PIDFILE" ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

python3 "$ROOT/tests/npm_registry_server.py" "$REG_PORT" >/dev/null 2>&1 &
REGPID=$!; sleep 0.3

await() { local m="$1" n=0; while ((n<300)); do grep -qF "$m" "$LOG" && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
send() { printf '%s\n' "$1" >&3; sleep 0.15; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

"$QEMU" -M virt -cpu cortex-a72 -m "$MEM" -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || { echo FAIL: no tty >&2; exit 1; }
send tty-line
await "M7 tty: running; press Ctrl-C" 40 || exit 1
printf '\003' >&3
await "swift-os login:" 90 || { echo FAIL: no login >&2; exit 1; }
send root; await Password: 90 || exit 1; send swordfish
await "built-in shell" 120 || exit 1
JS="require('http').get('http://10.0.2.2:${REG_PORT}/is-odd',r=>{let b='';r.on('data',c=>b+=c);r.on('end',()=>console.log('${MARK}',b.length))}).on('error',e=>console.log('ERR',e.message))"
send "/bin/node -e \"$JS\""
await "$MARK" 180 || { sed 's/\r//' "$LOG" | tail -40 >&2; echo FAIL: fetch >&2; exit 1; }
echo "PASS: node http.get registry packument"
exit 0