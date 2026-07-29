#!/usr/bin/env bash
# node_test.sh - runtime check that the cross-built Node.js 24.16 binary
# (/bin/node, V8 --v8-lite-mode, jitless) actually executes on SwiftOS.
# Smoke: `node --version` prints the version; `node -e` runs JS through V8.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${NODE_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${NODE_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${NODE_QEMU_MEM:-2048M}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK"   ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-node.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-node-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-node-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
drive_fail() {
  echo "FAIL: $1" >&2
  cp "$LOG" /tmp/node_full.log 2>/dev/null || true
  echo "--- serial (node driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

"$QEMU" -M virt -cpu cortex-a72 -m "$MEM" -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "no tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "no tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "no login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "no password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

# 0) runtime entropy probe: does SYS_RANDOM-backed /dev/urandom yield bytes?
send_line 'head -c 8 /dev/urandom | od -An -tx1'
sleep 1

# 1) version smoke (lightest path: argv parse, print, exit)
send_line '/bin/node --version'
await "v24.16.0" 120 || drive_fail "node --version did not print v24.16.0"

# 2) execute JS through V8 (full Isolate init)
send_line '/bin/node -e "console.log(6*7)"'
await "42" 120 || drive_fail "node -e did not evaluate 6*7"

send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-; stop_qemu; QP=""
clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in "v24.16.0" "42"; do
  if grep -qF "$marker" <<<"$clean"; then echo "PASS: $marker"; else echo "FAIL: missing $marker" >&2; ok=0; fi
done
(( ok )) && exit 0
echo "--- serial (node region) ---" >&2
sed -n '/node/,$p' <<<"$clean" | head -80 >&2
exit 1
