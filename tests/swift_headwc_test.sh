#!/usr/bin/env bash
# swift_headwc_test.sh — native Swift /bin/head, /bin/wc, /bin/touch.
#
# Boots with the packed base image, logs in as root, builds a small file with
# the shell, then exercises the three Swift tools (reached by absolute path so
# the busybox standalone shell execs our binaries):
#   - wc counts lines/words/bytes,
#   - head -n N prints the first N lines (verified by piping head into wc),
#   - touch creates an empty tmpfs file (then wc reports 0 0 0).

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

LOG="$(mktemp -t swiftos-headwc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-headwc-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

(
  sleep 7;  printf 'tty-line\n'           # M7 ttydemo
  sleep 1;  printf '\003'                 # Ctrl-C -> login (init) prompt
  sleep 2;  printf 'root\n'
  sleep 1;  printf 'swordfish\n'
  sleep 2;  printf 'echo one > /tmp/t\n'  # build a 3-line, 14-byte file
  sleep 1;  printf 'echo two >> /tmp/t\n'
  sleep 1;  printf 'echo three >> /tmp/t\n'
  sleep 1;  printf '/bin/wc /tmp/t\n'           # -> 3 3 14 /tmp/t
  sleep 2;  printf '/bin/head -n 2 /tmp/t | /bin/wc\n'  # head stops at 2 -> 2 2 8
  sleep 2;  printf '/bin/touch /tmp/empty\n'    # create empty tmpfs file
  sleep 1;  printf '/bin/wc /tmp/empty\n'       # -> 0 0 0 /tmp/empty
  sleep 2;  printf 'echo HEADWC-DONE\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
await "HEADWC-DONE" 90 || true
sleep 5
stop_qemu
QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qE '^[[:space:]]*3[[:space:]]+3[[:space:]]+14 /tmp/t$' <<<"$CLEAN" \
  || fail "wc /tmp/t did not report 3 lines / 3 words / 14 bytes"
grep -qE '^[[:space:]]*2[[:space:]]+2[[:space:]]+8[[:space:]]*$' <<<"$CLEAN" \
  || fail "head -n 2 | wc did not report 2 lines / 2 words / 8 bytes (head limit wrong)"
grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]+0 /tmp/empty$' <<<"$CLEAN" \
  || fail "touch + wc /tmp/empty did not report an empty file"
grep -qF 'HEADWC-DONE' <<<"$CLEAN" \
  || fail "shell did not survive (no trailing marker)"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift head/wc/touch work on swift-os"
  exit 0
fi
echo "--- serial (tool region) ---" >&2
sed -n '/\/bin\/wc/,$p' <<<"$CLEAN" >&2
exit 1
