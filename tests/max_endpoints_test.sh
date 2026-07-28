#!/usr/bin/env bash
# max_endpoints_test.sh — prove IPC endpoint capacity is above the historic 16.
#
# Runs /bin/epcapprobe, which allocates endpoint pairs until the kernel pool
# refuses, then recovers. Requires EPCAP-OK n= with n > 16 (maxEndpoints=32).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MIN_ENDPOINTS=17

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" \
   || "$ROOT/userland/epcapprobe.c" -nt "$DISK" \
   || "$ROOT/kernel/vfs/vfs.swift" -nt "$DISK" \
   || "$ROOT/Makefile" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base.img" >&2
    exit 2
  }
fi

LOG="$(mktemp -t swiftos-maxep.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-maxep-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-maxep-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    if grep -qF "panic:" "$LOG" 2>/dev/null; then
      return 2
    fi
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (max endpoints) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${MAXEP_CHAR_DELAY:-0.02}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${MAXEP_SEND_DELAY:-0.12}"
}

DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || true
fi
dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/epcapprobe'
await "EPCAP-OK n=" 60 || drive_fail "epcapprobe did not report EPCAP-OK"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "EPCAP-START" <<<"$clean" || { echo "FAIL: missing EPCAP-START" >&2; ok=0; }
grep -qF "EPCAP-FAIL" <<<"$clean" && { echo "FAIL: epcapprobe reported EPCAP-FAIL" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during endpoint capacity probe" >&2; ok=0; }

n_line="$(grep -oE 'EPCAP-OK n=[0-9]+' <<<"$clean" | head -1 || true)"
n_val="${n_line##*=}"
if [[ -z "$n_val" ]]; then
  echo "FAIL: could not parse endpoint count from epcapprobe output" >&2
  ok=0
elif ! [[ "$n_val" =~ ^[0-9]+$ ]]; then
  echo "FAIL: non-numeric endpoint count: $n_val" >&2
  ok=0
elif (( 10#$n_val < MIN_ENDPOINTS )); then
  echo "FAIL: endpoint capacity n=$n_val is not above the historic limit of 16 (need >= $MIN_ENDPOINTS)" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: IPC endpoint capacity n=$n_val > 16 (maxEndpoints raised; epcapprobe ceiling engaged)"
  exit 0
fi
echo "--- serial (endpoint capacity region) ---" >&2
sed -n '/\/bin\/epcapprobe/,$p' <<<"$clean" | head -80 >&2
exit 1
