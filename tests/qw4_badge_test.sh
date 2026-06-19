#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# qw4_badge_test.sh — QW4 endpoint-badge acceptance.
#
# Boots the base image, logs in, and runs /bin/qw4-badge, which stamps a distinct
# server-chosen badge into two clients' send handles on otherwise-identical
# endpoints, sends a message on each, and proves ipc_recv_badged reports the badge
# that was stamped — and 0 for an unbadged send. No network needed: a reactive
# login over a FIFO drives the serial console, the same harness the other IPC
# tests use.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-qw4-badge.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-qw4-badge-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-qw4-badge-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    if [[ -n "$QP" ]] && ! jobs -pr | grep -qx "$QP"; then
      echo "FAIL: QEMU exited while waiting for marker: $marker" >&2
      echo "--- serial tail ---" >&2
      sed 's/\r//' "$LOG" | tail -80 >&2
      exit 1
    fi
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

send_text() {  # send_text TEXT
  local text="$1" i
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}" >&3 || return 1
    sleep 0.02
  done
}

send_after() {  # send_after MARKER MAXSEC TEXT
  local marker="$1" max="$2" text="$3"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for marker: $marker" >&2
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -80 >&2
    exit 1
  fi
  send_text "$text"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

send_after "M7 tty: type a line then Enter" 60 $'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 $'\003'
send_after "swift-os login:" 60 $'root\n'
send_after "Password:" 40 $'swordfish\n'
send_after "Welcome to swift-os, root" 60 $'/bin/qw4-badge\n'

send_after "QW4 OK: badges distinguish clients on a shared endpoint" 60 $'exit\n'

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "QW4-BADGE-RECVEND-REJECTED-OK" <<<"$clean" \
  || { echo "FAIL: ipc_badge did not reject a recv-end fd" >&2; ok=0; }
grep -qF "QW4-BADGE-A1-OK" <<<"$clean" \
  || { echo "FAIL: client A badge (0xA1) not reported by ipc_recv_badged" >&2; ok=0; }
grep -qF "QW4-BADGE-B2-OK" <<<"$clean" \
  || { echo "FAIL: client B badge (0xB2) not reported by ipc_recv_badged" >&2; ok=0; }
grep -qF "QW4-BADGE-UNBADGED-ZERO-OK" <<<"$clean" \
  || { echo "FAIL: unbadged send did not report badge == 0" >&2; ok=0; }
grep -qF "QW4-BADGE-MIXED-OK" <<<"$clean" \
  || { echo "FAIL: mixed badged/unbadged on one endpoint did not track the per-message badge" >&2; ok=0; }
grep -qF "QW4-BADGE-REUSE-CLEAN-OK" <<<"$clean" \
  || { echo "FAIL: a stale badge bled across endpoint slot reuse" >&2; ok=0; }
grep -qF "QW4 OK: badges distinguish clients on a shared endpoint" <<<"$clean" \
  || { echo "FAIL: final QW4 marker missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: endpoint badges distinguish clients on a shared endpoint (QW4 acceptance)"
  exit 0
fi
echo "--- serial (qw4-badge region) ---" >&2
sed -n '/qw4-badge\|QW4/,$p' <<<"$clean" | head -80 >&2
exit 1
