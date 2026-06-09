#!/usr/bin/env bash
# swift_chmodown_test.sh — native Swift /bin/chmod and /bin/chown.
#
# Changes mode/owner of a tmpfs file and confirms via /bin/ls -l. chmod/chown
# only affect the writable tmpfs (the base FS is read-only) and require
# capTmpWrite. Invoked by absolute path so the busybox shell execs our binaries.

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

LOG="$(mktemp -t swiftos-cm.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cm-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-cm-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

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

BOOT_DRIVE_OK=1
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
    echo "FAIL: did not see boot marker '$marker'" >&2
    BOOT_DRIVE_OK=0
    return 1
  fi
  send_text "$text" || { BOOT_DRIVE_OK=0; return 1; }
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

send_after "M7 tty: type a line then Enter" 40 $'tty-line\n' || true
send_after "M7 tty: running; press Ctrl-C" 30 $'\003' || true
send_after "swift-os login:" 40 $'root\n' || true
send_after "Password:" 40 $'swordfish\n' || true
send_after "Welcome to swift-os, root" 15 '' || true
send_after "built-in shell" 15 '' || true
send_after "# " 15 \
  $'echo hi > /tmp/f\n/bin/chmod 600 /tmp/f\n/bin/ls -l /tmp/f\n/bin/chown 2 /tmp/f\n/bin/ls -l /tmp/f\necho CHOWN\'\'-DONE\nexit\n' || true
await "CHOWN-DONE" 60 || BOOT_DRIVE_OK=0
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$BOOT_DRIVE_OK" -eq 1 ]] || ok=0
check() { grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }; }

D='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]'
check "^-rw------- +1 +root +root +3 +$D +/tmp/f\$"  "chmod 600 not reflected (expected -rw------- root)"
check "^-rw------- +1 +user +user +3 +$D +/tmp/f\$"  "chown 2 not reflected (expected owner/group user)"
check 'CHOWN-DONE'                                   "shell did not survive chmod/chown"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift chmod/chown change tmpfs mode and owner (shown by ls -l)"
  exit 0
fi
echo "--- serial (chmod/chown region) ---" >&2
sed -n '/chmod/,$p' <<<"$clean" | head -30 >&2
exit 1
