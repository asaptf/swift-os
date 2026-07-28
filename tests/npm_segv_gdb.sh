#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
GDB="${GDB:-/opt/homebrew/bin/aarch64-elf-gdb}"
LOG=/tmp/npm_segv_serial.log
GOUT=/tmp/npm_segv_gdb.out
: >"$LOG"; : >"$GOUT"
PIDFILE=$(mktemp -t npmsegv-pid.XXXXXX)
INFIFO=$(mktemp -u -t npmsegv-in.XXXXXX); mkfifo "$INFIFO"
trap 'kill -9 $(cat "$PIDFILE" 2>/dev/null) 2>/dev/null; exec 3>&-; rm -f "$PIDFILE" "$INFIFO"' EXIT

pkill -x qemu-system-aarch64 2>/dev/null; sleep 0.3
qemu-system-aarch64 -M virt -cpu cortex-a72 -smp 1 -m 2048M -nographic -no-reboot \
  -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false \
  -device "loader,file=$ROOT/build/virt-2048.dtb,addr=0x4FF00000,force-raw=on" \
  -drive "file=$ROOT/build/base.img,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -gdb tcp::1236 -kernel "$ROOT/build/kernel.elf" <"$INFIFO" >"$LOG" 2>&1 &
exec 3<>"$INFIFO"
await() { local m="$1" n=0; while ((n<900)); do grep -qF "$m" "$LOG" && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
send() { printf '%s\n' "$1" >&3; sleep 0.15; }

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT"
send 'x'; await "M7 tty: running" 40 || true; printf '\003' >&3
await "swift-os login:" 90; send 'root'; await "Password:" 30 || true; send 'swordfish'
await "built-in shell (ash)" 60

cat >/tmp/npm_segv_gdb.cmds <<EOF
set pagination off
target remote :1236
file $ROOT/build/node.elf
catch signal SIGSEGV
commands
 silent
 echo === SEGV ===\n
 info registers x0 x1 x19 x20 sp elr
 bt 20
 echo ===\n
 quit 1
end
continue
EOF

"$GDB" -batch -x /tmp/npm_segv_gdb.cmds >"$GOUT" 2>&1 &
GPID=$!
sleep 3
send 'mkdir -p /tmp/npm-prefix /tmp/npm-cache'
send 'export NPM_CONFIG_PREFIX=/tmp/npm-prefix NPM_CONFIG_CACHE=/tmp/npm-cache UV_THREADPOOL_SIZE=1'
send '/bin/node /usr/lib/node_modules/npm/bin/npm-cli.js install /tmp/npm-fixture/swos-smoke-1.0.0.tgz --no-audit --no-fund'
wait "$GPID" 2>/dev/null || true
echo "=== GDB ==="; cat "$GOUT"
echo "=== SERIAL tail ==="; sed 's/\r//' "$LOG" | tail -25