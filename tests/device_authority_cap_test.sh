#!/usr/bin/env bash
# device_authority_cap_test.sh - C5g guest cannot enumerate or mint device grants.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${C5G_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${C5G_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-deviceauth.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-deviceauth-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-deviceauth-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (device authority capability probe) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:/,$p' >&2 || true
  exit 1
}


qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'guest'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'guest'
await "session: principal=3 session=3 caps=2" 120 || drive_fail "guest did not log in with the restricted context"
send_line '/bin/deviceauthdemo'
await "C5g OK: non-console principal cannot discover or claim device grants" 60 \
  || drive_fail "device authority capability probe did not finish cleanly"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in \
  "session: principal=3 session=3 caps=2" \
  "DEVICE-AUTH-DISCOVER-DENY-OK err=-13" \
  "DEVICE-AUTH-CLAIM-DENY-OK err=-13" \
  "C5g OK: non-console principal cannot discover or claim device grants"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; ok=0; }
done

for marker in \
  "DEVICE-AUTH-DISCOVER-LEAK" \
  "DEVICE-AUTH-CLAIM-LEAK" \
  "DEVICE-AUTH-DISCOVER-FAIL" \
  "DEVICE-AUTH-CLAIM-FAIL"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; ok=0; }
done

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: C5g device discovery/claim authority is denied to the guest principal"
  exit 0
fi
echo "--- serial (device authority probe region) ---" >&2
sed -n '/deviceauthdemo/,$p' <<<"$clean" >&2
exit 1
