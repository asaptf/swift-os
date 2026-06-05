#!/usr/bin/env bash
# swift_coreutils_test.sh — native Swift /bin/echo, /bin/cat, /bin/pwd.
#
# Pure-Swift coreutils (userland/{echo,cat,pwd}.swift) over the userland bridge.
# Invoked by absolute path so the busybox standalone shell execs our binaries
# (bare echo/cat/pwd stay the busybox builtin/applet).

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

LOG="$(mktemp -t swiftos-cu.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cu-pid.XXXXXX)"
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

(
  sleep 8;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 3;  printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf '/bin/echo hello swift echo\n'
  sleep 2;  printf '/bin/cat /etc/motd\n'
  sleep 2;  printf 'cd /etc\n'
  sleep 1;  printf '/bin/pwd\n'
  sleep 2;  printf '/bin/echo -n no-newline-here\n'
  sleep 2;  printf '\n'
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
sleep 32
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check() { grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }; }

check '^hello swift echo$'        "/bin/echo did not print its arguments"
check '^Welcome to swift-os\.$'   "/bin/cat did not print /etc/motd"
check '^/etc$'                    "/bin/pwd did not print the cwd after cd /etc"
check 'no-newline-here#'          "/bin/echo -n still emitted a trailing newline"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift echo/cat/pwd work on swift-os"
  exit 0
fi
echo "--- serial (coreutils region) ---" >&2
sed -n '/hello swift echo\|BusyBox/,$p' <<<"$clean" | head -30 >&2
exit 1
