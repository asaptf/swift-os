#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# node_pc_probe.sh — diagnostic: drive `node -e` and, if it hangs, sample the
# CPU PC via QEMU's HMP monitor several times so we can addr2line where node is
# stuck (busy-loop in EL0 node code vs blocked in EL1 kernel). Not a CI gate.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${NODE_QEMU_MEM:-2048M}"
MON="$(mktemp -u -t swos-mon.XXXXXX)"
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
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO" "$MON"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local m="$1" max="${2:-30}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }

"$QEMU" -M virt -cpu cortex-a72 -m "$MEM" -nographic -no-reboot \
  -pidfile "$PIDFILE" -monitor "unix:$MON,server,nowait" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || { echo "no tty prompt"; sed 's/\r//' "$LOG"|tail -20; exit 2; }
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || { echo "no ctrlc prompt"; exit 2; }
printf '\003' >&3
await "swift-os login:" 90 || { echo "no login"; exit 2; }
send_line 'root'
await "Password:" 90 || { echo "no pw"; exit 2; }
send_line 'swordfish'
await "M12c: shell ready" 120 || { echo "no shell"; exit 2; }

await_shell_ready "$LOG" 60 || { echo "FAIL: guest shell not reading after login" >&2; exit 1; }
send_line '/bin/node -e "console.log(6*7)"'
if await "42" 25; then
  echo "RESULT: PASS (node printed 42)"
  exit 0
fi
echo "RESULT: HANG — sampling PC over HMP monitor"
sample_pc
echo "--- last 45 serial lines ---"
sed 's/\r//' "$LOG" | tail -45
exit 1
