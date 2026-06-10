#!/usr/bin/env bash
# spawn_self_exec_test.sh - bad user pointers must not panic EL1.

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

LOG="$(mktemp -t swiftos-selfexec.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-selfexec-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-selfexec-in.XXXXXX)"; mkfifo "$INFIFO"
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

send_after() {  # send_after MARKER MAXSEC TEXT
  local marker="$1" max="$2" text="$3"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for marker: $marker" >&2
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -100 >&2
    exit 1
  fi
  sleep 0.05
  printf '%b' "$text" >&3
}

abort() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" | tail -100 >&2
  exit 1
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

send_after "M7 tty: type a line then Enter" 60 'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 '\003'
send_after "swift-os login:" 60 'root\n'
send_after "Password:" 40 'swordfish\n'
send_after "Welcome to swift-os, root" 60 '/bin/selfexecdemo\n'

await "selfexec: open+exec same file OK" 60 || abort "open+exec same file scenario did not complete"
await "selfexec: garbage-argv-pointer survived" 60 || abort "garbage argv pointer was not handled"
await "selfexec: unterminated-argv survived" 60 || abort "unterminated argv was not handled"
await "selfexec OK: open+exec same file and malformed argv handled" 60 || abort "selfexecdemo did not complete"
printf 'echo SELFEXEC-SHELL-ALIVE\n' >&3
await "SELFEXEC-SHELL-ALIVE" 30 || abort "shell did not survive selfexecdemo"
printf 'exit\n' >&3

sleep 1
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during selfexec hardening test" >&2; ok=0; }
grep -qF "selfexec FAIL" <<<"$clean" && { echo "FAIL: selfexecdemo reported failure" >&2; ok=0; }
grep -qF "SELFEXEC-SHELL-ALIVE" <<<"$clean" || { echo "FAIL: shell did not survive selfexecdemo" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: open+exec same file and malformed argv handled without panicking EL1"
  exit 0
fi
echo "--- serial (selfexec region) ---" >&2
sed -n '/\/bin\/selfexecdemo/,$p' <<<"$clean" | head -120 >&2
exit 1
