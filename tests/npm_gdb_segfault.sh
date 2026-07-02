#!/usr/bin/env bash
# Catch npm segfault at Factory::AllocateRaw after tpidr fix.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"; DTB="$ROOT/build/virt-2048.dtb"; DISK="$ROOT/build/base.img"
GDB=/opt/homebrew/bin/aarch64-elf-gdb
LOG=/tmp/npm_sf_serial.log; GOUT=/tmp/npm_sf_gdb.log; : >"$LOG"; : >"$GOUT"
PIDFILE=$(mktemp -t npmsf-pid.XXXXXX); INFIFO=$(mktemp -u -t npmsf-in.XXXXXX); mkfifo "$INFIFO"
QP=""; GPID=""
cleanup(){ [ -n "$GPID" ] && kill "$GPID" 2>/dev/null; [ -f "$PIDFILE" ] && { p=$(cat "$PIDFILE" 2>/dev/null); [ -n "$p" ] && kill -9 "$p" 2>/dev/null; }; exec 3>&- 2>/dev/null; rm -f "$PIDFILE" "$INFIFO"; }
trap cleanup EXIT
await(){ local m="$1" mx="${2:-30}" n=0; while (( n<mx*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
send(){ local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:i:1}" >&3; sleep 0.012; done; printf '\n' >&3; sleep 0.1; }

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2048M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -gdb tcp::1234 -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"
await "M7 tty: type a line then Enter" 60; send 'x'; await "M7 tty: running" 40; printf '\003' >&3
await "swift-os login:" 90; send 'root'; await "Password:" 30; send 'swordfish'
await "built-in shell (ash)" 60

cat >/tmp/npm_sf.cmds <<EOF
set pagination off
set confirm off
target remote :1234
symbol-file $ROOT/build/node.elf
break *0x80a6b140
commands
 silent
 printf "SF-GDB at AllocateRaw x0="
 p/x \$x0
 printf "SF-GDB sp_el0="
 p/x \$sp
 printf "SF-GDB tpidr_el0="
 p/x \$tpidr_el0
 bt 6
 printf "SF-GDB-STOP\\n"
end
continue
EOF
( $GDB -batch -x /tmp/npm_sf.cmds >"$GOUT" 2>&1 ) & GPID=$!
sleep 4
send "/bin/node ${NPM_NODE_FLAGS:-} /usr/lib/node_modules/npm/bin/npm-cli.js --version"
n=0; while (( n<120 )); do grep -q "SF-GDB-STOP" "$GOUT" 2>/dev/null && break; sleep 0.5; n=$((n+1)); done
echo "=== GDB ==="; cat "$GOUT"
echo "=== SERIAL tail ==="; sed 's/\r//' "$LOG" | tail -8