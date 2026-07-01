#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# node_gdb_hang.sh — run a node -e that HANGS, then attach GDB (which halts the
# running guest) and print the backtrace of wherever it's stuck. Reveals the
# hang location (kernel spin / blocked syscall / node code).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"; DTB="$ROOT/build/virt-2048.dtb"; DISK="$ROOT/build/base.img"
GDB=/opt/homebrew/bin/aarch64-elf-gdb
EVAL_JS="${EVAL_JS:-require('fs').writeSync(1,'HANGMARK\\n')}"
LOG=/tmp/ngh_serial.log; GOUT=/tmp/ngh_gdb.log; : >"$LOG"; : >"$GOUT"
PIDFILE=$(mktemp -t ngh-pid.XXXXXX); INFIFO=$(mktemp -u -t ngh-in.XXXXXX); mkfifo "$INFIFO"
QP=""
cleanup(){ [ -f "$PIDFILE" ] && { p=$(cat "$PIDFILE" 2>/dev/null); [ -n "$p" ] && kill -9 "$p" 2>/dev/null; }; exec 3>&- 2>/dev/null; rm -f "$PIDFILE" "$INFIFO"; }
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

await "M7 tty: type a line then Enter" 60 || { echo "no tty"; exit 1; }
send 'x'; await "M7 tty: running" 40; printf '\003' >&3
await "swift-os login:" 90 || { echo "no login"; exit 1; }
send 'root'; await "Password:" 30; send 'swordfish'
await "built-in shell (ash)" 60 || { echo "no shell"; exit 1; }

send "/bin/node -e \"$EVAL_JS\"; echo NGHDONE"
# Let node reach the hang.
sleep 12
if grep -q "NGHDONE" "$LOG"; then echo "NOTE: node did NOT hang this run (completed)"; fi

# Attach GDB — connecting halts the running guest wherever it is.
cat >/tmp/ngh.cmds <<EOF
set pagination off
set confirm off
target remote :1234
symbol-file $ROOT/build/node.elf
echo \n==NGH PC==\n
p/x \$pc
info symbol \$pc
echo \n==NGH BT==\n
bt
echo \n==NGH x0..x3==\n
info registers x0 x1 x2 x3 sp
echo \n==NGH END==\n
EOF
$GDB -batch -x /tmp/ngh.cmds >"$GOUT" 2>&1
echo "================= GDB (hang location) ================="
grep -vE "warning|No executable|determining|Try using" "$GOUT"
echo "================= serial tail ========================="
sed 's/\r//' "$LOG" | tail -4
