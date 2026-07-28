#!/usr/bin/env bash
# Quick probe: after npm install tarball, can busybox cat and node read the module?
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
LOG="$(mktemp)"
INFIFO="$(mktemp -u)"
mkfifo "$INFIFO"
trap 'exec 3>&- 2>/dev/null || true; pkill -x qemu-system-aarch64 2>/dev/null || true; rm -f "$LOG" "$INFIFO"' EXIT

pkill -x qemu-system-aarch64 2>/dev/null || true
sleep 0.5

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2048M -nographic -no-reboot \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
exec 3<>"$INFIFO"

send() { printf '%s\n' "$1" >&3; sleep 0.25; }
await() {
  local m="$1" n=0
  while (( n < 800 )); do
    grep -qF "$m" "$LOG" && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}
fail() { echo "FAIL: $1"; tail -30 "$LOG"; exit 1; }

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty"
send 'x'
await "M7 tty: running" 40 || fail "no tty running"
printf '\003' >&3
await "swift-os login:" 90 || fail "no login"
send root
await "Password:" || fail "no password"
send swordfish
await "built-in shell" || fail "no shell"
send 'mkdir -p /tmp/npm-prefix/lib/node_modules /tmp/npm-cache'
send 'export NPM_CONFIG_PREFIX=/tmp/npm-prefix NPM_CONFIG_CACHE=/tmp/npm-cache'
send '/bin/npm install /usr/share/npm-fixture/swos-smoke-1.0.0.tgz --no-audit --no-fund'
await "added 1 package" 200 || fail "install"
echo "INSTALL_OK"
send 'busybox cat /tmp/npm-prefix/lib/node_modules/swos-smoke/index.js'
await "module.exports" 40 || fail "cat"
echo "CAT_OK"
send 'echo console.log\(42\) >/tmp/t.js'
send '/bin/node /tmp/t.js </dev/null'
await "42" 90 || fail "simple node"
echo "NODE_OK"
send 'echo "const fs=require('"'"'fs'"'"');console.log('"'"'READ'"'"',fs.readFileSync('"'"'/tmp/npm-prefix/lib/node_modules/swos-smoke/index.js'"'"','"'"'utf8'"'"'))" >/tmp/r.js'
send '/bin/node /tmp/r.js </dev/null'
await "READ" 120 || fail "fs read"
echo "FS_OK"
send 'echo "console.log('"'"'REQ'"'"',require('"'"'/tmp/npm-prefix/lib/node_modules/swos-smoke'"'"')())" >/tmp/q.js'
send '/bin/node /tmp/q.js </dev/null'
await "REQ" 120 || fail "require"
echo "PASS: npm install probe complete"