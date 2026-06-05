#!/usr/bin/env bash
# swift_ls_test.sh — native Swift /bin/ls (with -l) on swift-os.
#
# /bin/ls is a pure-Swift userland tool (userland/ls.swift) built on the kernel
# getdents/stat ABI; `-l` formats mode/owner/group/size, resolving owner and
# group names from /etc/passwd and /etc/group. It is invoked by absolute path so
# the busybox standalone shell execs our binary rather than its own ls applet.

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

LOG="$(mktemp -t swiftos-sls.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sls-pid.XXXXXX)"
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
  sleep 3;  printf '/bin/ls /etc\n'                # plain listing
  sleep 3;  printf '/bin/ls -l /etc\n'             # long: modes + owner/group names
  sleep 3;  printf '/bin/ls -l /bin/busybox\n'     # single-file long format
  sleep 3;  printf 'exit\n'
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

check '^motd$'                                   "plain /bin/ls did not list /etc/motd"
check '^drwxr-xr-x +1 +root +root +0 +swos$'     "ls -l did not show /etc/swos dir (root, drwxr-xr-x)"
check '^-rw-r--r-- +1 +root +root +21 +motd$'    "ls -l did not show motd (root, -rw-r--r--, size 21)"
check '^-rwxr-xr-x +1 +root +root +[0-9]+ +/bin/busybox$' "ls -l of a single executable file wrong"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift /bin/ls lists and long-formats with resolved owner/group"
  exit 0
fi
echo "--- serial (ls region) ---" >&2
sed -n '/\/bin\/ls/,$p' <<<"$clean" | head -30 >&2
exit 1
