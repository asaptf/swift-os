#!/usr/bin/env bash
# log_export_test.sh — L5 acceptance: userland log tail export/stats are gated
# by capLogExport and produce stable local diagnostics when granted.
#
# Uses a dedicated base image whose root login shell is /bin/logtail-probe so
# the probe runs as the post-login process. That avoids depending on interactive
# busybox ash after console-login (which currently faults on aarch64 Linux CI
# immediately after exec, before any typed command is processed).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base-log-export.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

# Rebuild the probe image when missing or stale relative to sources that change
# the packed shell, probe binary, or packing rules.
need_image=0
if [[ ! -f "$DISK" ]]; then
  need_image=1
elif [[ "$ROOT/userland/logtail-probe.swift" -nt "$DISK" \
     || "$ROOT/userland/logtail.swift" -nt "$DISK" \
     || "$ROOT/Makefile" -nt "$DISK" \
     || "$ROOT/base/etc/swos/passwd" -nt "$DISK" ]]; then
  need_image=1
fi
if [[ "$need_image" -eq 1 ]]; then
  ( cd "$ROOT" && make BASE_IMG=build/base-log-export.img \
      ROOT_LOGIN_SHELL=/bin/logtail-probe base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base-log-export.img" >&2
    exit 2
  }
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

"$QEMU" -M virt -cpu cortex-a72 -m 512M -nographic -no-reboot \
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
await "M12c: shell ready" 120 || drive_fail "shell ready marker missing after login"
await "M11d: exec loaded from disk /bin/logtail-probe" 60 ||
  drive_fail "logtail-probe was not exec'd as the login shell"

await "LOGTAIL-PROBE-DENIED" 60 || drive_fail "probe did not observe initial denial"
await "LOGTAIL-PROBE-GRANTED bytes=" 60 || drive_fail "probe did not read after capLogExport"
await "LOGTAIL-PROBE-RECORD-SHAPE" 60 || drive_fail "probe did not validate record shape"
await "LOGTAIL-PROBE-STATS capacity=256" 60 || drive_fail "probe did not validate log ring stats"
await "LOGTAIL-PROBE-BEGIN" 60 || drive_fail "probe did not print exported log begin marker"
await "LOGTAIL-PROBE-END" 60 || drive_fail "probe did not print exported log end marker"
await "M12c: session ended" 30 || drive_fail "probe session did not end cleanly"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
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
grep -qF "M12c: session ended" <<<"$clean" ||
  { echo "FAIL: probe session did not end" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: userland log export and stats are capLogExport-gated"
  exit 0
fi
echo "--- serial (log export region) ---" >&2
sed -n '/LOGTAIL-PROBE-/,$p' <<<"$clean" | head -120 >&2
exit 1
