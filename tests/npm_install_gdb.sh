#!/usr/bin/env bash
# GDB probe: npm install SIGSEGV in _malloc_r (break at crash ELR or catch SIGSEGV).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt-2048.dtb"
DISK="$ROOT/build/base.img"
GDB="${GDB:-/opt/homebrew/bin/aarch64-elf-gdb}"
LOG=/tmp/npm_install_gdb_serial.log
GOUT=/tmp/npm_install_gdb.out
: >"$LOG"; : >"$GOUT"
PIDFILE=$(mktemp -t npmigdb-pid.XXXXXX)
INFIFO=$(mktemp -u -t npmigdb-in.XXXXXX); mkfifo "$INFIFO"
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
  local m="$1" mx="${2:-30}" n=0
  while (( n < mx * 10 )); do
    grep -qF "$m" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() {
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.012; done
  printf '\n' >&3; sleep 0.1
}

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2048M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -gdb tcp::1234 -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || { echo "no tty prompt"; exit 2; }
send 'x'
await "M7 tty: running" 40 || true
printf '\003' >&3
await "swift-os login:" 90 || { echo "no login"; exit 2; }
send 'root'
await "Password:" 30 || true
send 'swordfish'
await "built-in shell (ash)" 60 || { echo "no shell"; exit 2; }

CRASH_ELR=0x81993D40
CALLOC_ENTRY=0x81992320
cat >/tmp/npm_install_gdb.cmds <<EOF
set pagination off
set confirm off
target remote :1234
file $ROOT/build/node.elf
set \$last_calloc_lr = 0
break *$CALLOC_ENTRY
commands
 silent
 set \$last_calloc_lr = \$x30
 continue
end
break *$CRASH_ELR
commands
 silent
 echo NPM-GDB-CRASH at _malloc_r+0x6c0\n
 printf "last calloc caller lr="
 p/x \$last_calloc_lr
 info symbol \$last_calloc_lr
 info registers x0 x1 x2 x5 sp x30
 bt 15
 echo NPM-GDB-STOP\n
end
continue
EOF

( "$GDB" -batch -x /tmp/npm_install_gdb.cmds >"$GOUT" 2>&1 ) &
GPID=$!
sleep 4

send 'mkdir -p /tmp/npm-prefix /tmp/npm-cache'
send 'export NPM_CONFIG_PREFIX=/tmp/npm-prefix NPM_CONFIG_CACHE=/tmp/npm-cache UV_THREADPOOL_SIZE=1'
send '/bin/node /usr/lib/node_modules/npm/bin/npm-cli.js install /tmp/npm-fixture/swos-smoke-1.0.0.tgz --no-audit --no-fund'

n=0
while (( n < 240 )); do
  grep -qE 'NPM-GDB-STOP|EL0 fault' "$GOUT" "$LOG" 2>/dev/null && break
  sleep 0.5; n=$((n + 1))
done

echo "=== GDB (tail) ==="
tail -80 "$GOUT" 2>/dev/null || true
echo "=== SERIAL (tail) ==="
sed 's/\r//' "$LOG" 2>/dev/null | tail -20