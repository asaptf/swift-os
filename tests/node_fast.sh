#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# node_fast.sh — fast node -e reliability probe. Boots QEMU ONCE, then the HOST
# sends `node -e` N times (each a fresh guest process / fresh threads), waits on a
# per-iteration sentinel (so a hung node is bounded, not infinite), and counts the
# expected output. One boot + N evals instead of N boots+logins.
#   N=30 bash tests/node_fast.sh
# NOTE: with many evals per boot, a node that exits leaving orphan threads can
# leak process slots — for a *clean per-process* rate use N=1 in a loop (each a
# fresh boot). For throughput once orphan-reap is fixed, larger N is valid.
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${NODE_QEMU_MEM:-2048M}"
N="${N:-30}"
EVAL_JS="${EVAL_JS:-console.log(6*7)}"
WANT="${WANT:-42}"
LOG="${NF_LOG:-/tmp/node_fast_live.log}"; : > "$LOG"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing"; exit 2; }
[[ -f "$DISK"   ]] || { echo "FAIL: $DISK missing"; exit 2; }

PIDFILE="$(mktemp -t swos-nf-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swos-nf-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local m="$1" max="${2:-30}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
fail() { echo "FAIL: $1" >&2; sed 's/\r//' "$LOG" | tail -30 >&2; exit 1; }
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:i:1}" >&3; sleep 0.012; done; printf '\n' >&3; sleep 0.1; }

"$QEMU" -M virt -cpu cortex-a72 -m "$MEM" -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty prompt (kernel boot?)"
send 'x'
await "M7 tty: running; press Ctrl-C" 40 || fail "no ctrl-c prompt"
printf '\003' >&3
await "swift-os login:" 90 || fail "no login"
send 'root'
await "Password:" 30 || fail "no pw"
send 'swordfish'
await "built-in shell (ash)" 60 || fail "no shell"

hung=0
for ((k=1; k<=N; k++)); do
  # NF''D$k: the typed echo shows "NF''D$k" (no "NFD$k" substring), but the
  # EXECUTED output is "NFD$k" — so await matches the OUTPUT, not the command echo.
  send "/bin/node ${NODE_ARGS:-} -e \"$EVAL_JS\"; echo NF''D$k rc=\$?"
  await "NFD$k" 30 || { hung=$((hung+1)); echo "iter $k: timeout (node hung)"; }
done
if [ -n "${WANT_RC:-}" ]; then
  got="$(sed 's/\r//' "$LOG" | grep -c "rc=${WANT_RC}\$")"
else
  got="$(sed 's/\r//' "$LOG" | grep -c "^${WANT}$")"
fi
echo "==== NF-RESULT pass=$got total=$N (hung=$hung) ===="
exec 3>&-; stop_qemu; QP=""
