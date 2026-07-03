#!/usr/bin/env bash
# GDB probe: reent pointer at _setenv_r / __getreent during node startup.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt-2048.dtb"
DISK="$ROOT/build/base.img"
GDB="${GDB:-/opt/homebrew/bin/aarch64-elf-gdb}"
LOG=/tmp/npm_reent_gdb_serial.log
GOUT=/tmp/npm_reent_gdb.out
: >"$LOG"; : >"$GOUT"
PIDFILE=$(mktemp -t npmreent-pid.XXXXXX)
INFIFO=$(mktemp -u -t npmreent-in.XXXXXX); mkfifo "$INFIFO"
QP=""; GPID=""
cleanup() {
  [[ -n "$GPID" ]] && kill "$GPID" 2>/dev/null || true
  if [[ -f "$PIDFILE" ]]; then
    local p; p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null || true
  fi
  exec 3>&- 2>/dev/null || true
  rm -f "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

await() {
  local m="$1" mx="${2:-60}" n=0
  while (( n < mx * 10 )); do
    grep -qF "$m" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.15; }

pkill -x qemu-system-aarch64 2>/dev/null || true
sleep 0.3

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2048M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -gdb tcp::1235 -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || { echo "no tty"; exit 2; }
send 'x'
await "M7 tty: running" 40 || true
printf '\003' >&3
await "swift-os login:" 90 || { echo "no login"; exit 2; }
send 'root'
await "Password:" 30 || true
send 'swordfish'
await "built-in shell (ash)" 60 || { echo "no shell"; exit 2; }

cat >/tmp/npm_reent_gdb.cmds <<EOF
set pagination off
set confirm off
target remote :1235
file $ROOT/build/node.elf
break __swos_bind_main_reent
break _setenv_r
commands 1
 silent
 printf "bind: _impure_ptr stored="
 p/x *(void**)&_impure_ptr
 printf "swos_thread_reent should be set next\n"
 continue
end
commands 2
 silent
 printf "_setenv_r reent arg x0="
 p/x \$x0
 printf "_impure_ptr stored="
 p/x *(void**)&_impure_ptr
 printf "_impure_data addr="
 p/x &_impure_data
 continue
end
catch signal SIGSEGV
continue
EOF

"$GDB" -batch -x /tmp/npm_reent_gdb.cmds >"$GOUT" 2>&1 &
GPID=$!
sleep 3

send 'mkdir -p /tmp/npm-prefix /tmp/npm-cache'
send 'export NPM_CONFIG_PREFIX=/tmp/npm-prefix NPM_CONFIG_CACHE=/tmp/npm-cache UV_THREADPOOL_SIZE=1'
send '/bin/node /usr/lib/node_modules/npm/bin/npm-cli.js install /tmp/npm-fixture/swos-smoke-1.0.0.tgz --no-audit --no-fund'

n=0
while (( n < 240 )); do
  grep -qE 'Program received signal|_setenv_r reent|EL0 fault' "$GOUT" "$LOG" 2>/dev/null && break
  sleep 0.5; n=$((n + 1))
done

echo "=== GDB ==="
tail -80 "$GOUT" 2>/dev/null || true
echo "=== SERIAL (tail) ==="
sed 's/\r//' "$LOG" 2>/dev/null | tail -15