#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# npm_gdb.sh — catch the npm HandleScope locking abort and inspect tpidr_el0 +
# V8 ThreadId vs mutex_owner (confirms context-switch TLS hypothesis).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"; DTB="$ROOT/build/virt-2048.dtb"; DISK="$ROOT/build/base.img"
GDB=/opt/homebrew/bin/aarch64-elf-gdb
LOG=/tmp/npm_gdb_serial.log; GOUT=/tmp/npm_gdb_out.log; : >"$LOG"; : >"$GOUT"
PIDFILE=$(mktemp -t npmg-pid.XXXXXX); INFIFO=$(mktemp -u -t npmg-in.XXXXXX); mkfifo "$INFIFO"
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
QP=$!; echo "$QP" >"$PIDFILE"; exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || { echo "no tty prompt"; exit 1; }
send 'x'; await "M7 tty: running" 40; printf '\003' >&3
await "swift-os login:" 90 || { echo "no login"; exit 1; }
send 'root'; await "Password:" 30; send 'swordfish'
await "built-in shell (ash)" 60 || { echo "no shell"; exit 1; }

cat >/tmp/npm_gdb.cmds <<EOF
set pagination off
set confirm off
target remote :1234
symbol-file $ROOT/build/node.elf
# HandleScope::Initialize locking check (api.cc ~701): mutex_owner vs ThreadId::Current.
# Break on the cmp; on mismatch path dump tpidr + ids then stop.
break *0x80941028
commands
 silent
 set \$owner = \$w1
 set \$current = \$w0
 if \$owner == \$current
  continue
 end
 printf "NPM-GDB MISMATCH mutex_owner=%d ThreadId::Current()=%d\\n", \$owner, \$current
 printf "NPM-GDB tpidr_el0 "
 p/x \$tpidr_el0
 bt 8
 set \$iso = \$x2
 set \$wl = *(unsigned char*)(\$iso + 0xda5c)
 printf "NPM-GDB was_locker_ever_used=%d\\n", \$wl
 printf "NPM-GDB-STOP\\n"
end
continue
EOF
( $GDB -batch -x /tmp/npm_gdb.cmds >"$GOUT" 2>&1 ) & GPID=$!
sleep 4

send "/bin/node ${NPM_NODE_FLAGS:-} ${NPM_CLI:-/usr/lib/node_modules/npm/bin/npm-cli.js} --version"

n=0; while (( n<120 )); do
  grep -q "NPM-GDB-STOP" "$GOUT" 2>/dev/null && break
  grep -qF "11.13.0" "$LOG" 2>/dev/null && { echo "NPM PASSED"; break; }
  sleep 0.5; n=$((n+1))
done
echo "=================== GDB OUTPUT ==================="
cat "$GOUT"
echo "=================== SERIAL (npm tail) ================"
sed 's/\r//' "$LOG" | grep -iE "Fatal|HandleScope|11\.13|MARK" | tail -12