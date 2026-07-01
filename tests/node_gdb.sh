#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# node_gdb.sh — catch WHERE `node -e` dies using GDB (no UART delays that mask the
# timing bug). Boots free, logs in, THEN attaches GDB + arms death breakpoints
# (post-boot, so boot-demo signals don't trip them), then runs node -e.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"; DTB="$ROOT/build/virt-2048.dtb"; DISK="$ROOT/build/base.img"
GDB=/opt/homebrew/bin/aarch64-elf-gdb
LOG=/tmp/ng_serial.log; GOUT=/tmp/ng_gdb.log; : >"$LOG"; : >"$GOUT"
PIDFILE=$(mktemp -t ng-pid.XXXXXX); INFIFO=$(mktemp -u -t ng-in.XXXXXX); mkfifo "$INFIFO"
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

# Free-run through boot + login FIRST (no GDB yet, so boot-demo faults are ignored).
await "M7 tty: type a line then Enter" 60 || { echo "no tty prompt"; sed 's/\r//' "$LOG"|tail; exit 1; }
send 'x'; await "M7 tty: running" 40; printf '\003' >&3
await "swift-os login:" 90 || { echo "no login"; exit 1; }
send 'root'; await "Password:" 30; send 'swordfish'
await "built-in shell (ash)" 60 || { echo "no shell"; exit 1; }

# NOW attach GDB (halts guest at the idle shell), arm node death points, continue.
cat >/tmp/ng.cmds <<EOF
set pagination off
set confirm off
target remote :1234
symbol-file $ROOT/build/node.elf
# TRACE points (print + continue) through node's bootstrap → run → event loop.
break *0x8000a6a0
commands
 silent
 printf "TRACE InitializeOncePerProcess\n"
 continue
end
break *0x800c86e0
commands
 silent
 printf "TRACE NodeMainInstance::Run()\n"
 continue
end
break *0x800c8440
commands
 silent
 printf "TRACE CreateMainEnvironment\n"
 continue
end
break *0x8029e068
commands
 silent
 printf "TRACE LoadEnvironment(callback) [runs -e script]\n"
 continue
end
break *0x8029a1a4
commands
 silent
 printf "TRACE SpinEventLoopInternal\n"
 continue
end
break *0x802a0bac
commands
 silent
 printf "TRACE CreateEnvironment\n"
 continue
end
break *0x8198f360
commands
 silent
 printf "TRACE abort()!\n"
end
# STOP at exit — this is the death; show where node decided to exit.
break *0x80000c84
commands
 printf "\n==NG-STOP _exit x0=\n"
 p/x \$x0
 printf "==NG-BT==\n"
 bt
 printf "==NG-END==\n"
end
continue
EOF
( $GDB -batch -x /tmp/ng.cmds >"$GOUT" 2>&1 ) & GPID=$!
sleep 4   # let gdb connect, arm, and `continue` (guest resumes)

send "/bin/node -e \"${EVAL_JS:-console.log(6*7)}\""

n=0; while (( n<80 )); do
  grep -q "==NG-BT==" "$GOUT" 2>/dev/null && break
  grep -qE "^42" "$LOG" 2>/dev/null && { echo "NODE PASSED (42)"; break; }
  sleep 0.5; n=$((n+1))
done
echo "=================== GDB OUTPUT ==================="
cat "$GOUT"
echo "=================== SERIAL (node) ================"
sed 's/\r//' "$LOG" | sed -n '/node -e/,$p' | grep -iE "put_evp|MARK|^42|terminate proc|ELR" | tail -8
