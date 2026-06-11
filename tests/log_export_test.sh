#!/usr/bin/env bash
# log_export_test.sh — L5 acceptance: userland log tail export/stats are gated
# by capLogExport and produce stable local diagnostics when granted.

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

LOG="$(mktemp -t swiftos-log-export.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-log-export-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-log-export-in.XXXXXX)"; mkfifo "$INFIFO"
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

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_line() {  # await_line LINE [MAXSEC]
  local line="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -qxF -- "$line" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (log export driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${LOG_EXPORT_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${LOG_EXPORT_SEND_DELAY:-0.08}"
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

await "M7 tty: type a line then Enter" 120 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"

send_line '/bin/logtail 8'
await "logtail: permission denied (need capLogExport)" 60 ||
  drive_fail "logtail was not denied before capLogExport"

send_line '/bin/logtail --stats'
await "logtail: stats permission denied (need capLogExport)" 60 ||
  drive_fail "logtail stats were not denied before capLogExport"

send_line '/bin/logtail-probe'
await "LOGTAIL-PROBE-DENIED" 60 || drive_fail "probe did not observe initial denial"
await "LOGTAIL-PROBE-GRANTED bytes=" 60 || drive_fail "probe did not read after capLogExport"
await "LOGTAIL-PROBE-RECORD-SHAPE" 60 || drive_fail "probe did not validate record shape"
await "LOGTAIL-PROBE-STATS capacity=256" 60 || drive_fail "probe did not validate log ring stats"
await "LOGTAIL-PROBE-BEGIN" 60 || drive_fail "probe did not print exported log begin marker"
await "LOGTAIL-PROBE-END" 60 || drive_fail "probe did not print exported log end marker"

send_line 'echo LOGTAIL-SHELL-ALIVE'
await_line "LOGTAIL-SHELL-ALIVE" 20 || drive_fail "shell did not respond after log export"
send_line 'exit'
await "M12c: session ended" 20 || drive_fail "shell did not exit cleanly"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "logtail: permission denied (need capLogExport)" <<<"$clean" ||
  { echo "FAIL: missing denial marker" >&2; ok=0; }
grep -qF "logtail: stats permission denied (need capLogExport)" <<<"$clean" ||
  { echo "FAIL: missing stats denial marker" >&2; ok=0; }
grep -qF "LOGTAIL-PROBE-DENIED" <<<"$clean" ||
  { echo "FAIL: missing probe denial marker" >&2; ok=0; }
grep -qF "LOGTAIL-PROBE-GRANTED bytes=" <<<"$clean" ||
  { echo "FAIL: missing probe granted marker" >&2; ok=0; }
grep -qF "LOGTAIL-PROBE-RECORD-SHAPE" <<<"$clean" ||
  { echo "FAIL: missing record shape marker" >&2; ok=0; }
grep -qF "LOGTAIL-PROBE-STATS capacity=256" <<<"$clean" ||
  { echo "FAIL: missing stats marker" >&2; ok=0; }
grep -Eq 'tick=[0-9]+ level=[A-Z] source=[^ ]+ msg="' <<<"$clean" ||
  { echo "FAIL: exported log did not contain key=value records" >&2; ok=0; }
grep -qxF "LOGTAIL-SHELL-ALIVE" <<<"$clean" ||
  { echo "FAIL: shell did not survive log export" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: userland log export and stats are capLogExport-gated"
  exit 0
fi
echo "--- serial (log export region) ---" >&2
sed -n '/logtail:/,$p' <<<"$clean" | head -120 >&2
exit 1
