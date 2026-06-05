#!/usr/bin/env bash
# cap_enforce_test.sh — M13 acceptance: VFS access is checked against the
# process capability mask.
#
# Logs in as `guest`, whose principal has only capSpawn (no capFsRead /
# capTmpWrite). The shell still runs (exec is a kernel path), and builtins like
# `echo` work, but opening files for read is denied: `cat /etc/motd` and `ls /`
# fail with EACCES. (root/user, which hold capFsRead, are exercised by
# busybox_test, so the allow path is covered there.)

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

LOG="$(mktemp -t swiftos-cap.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cap-pid.XXXXXX)"
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
  sleep 7;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 2;  printf 'guest\n'
  sleep 1;  printf 'guest\n'
  sleep 2;  printf 'echo GUEST-ECHO-OK\n'   # builtin: no FS access, allowed
  sleep 1;  printf 'cat /etc/motd\n'        # open for read: denied
  sleep 1;  printf 'ls /\n'                 # open dir for read: denied
  sleep 1;  printf '/bin/id\n'              # Swift id: numeric ctx, no name (no fsread)
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
sleep 30
stop_qemu
QP=""

ok=1
grep -qF "session: principal=3 session=3 caps=2" "$LOG" || { echo "FAIL: guest did not log in with the restricted context" >&2; ok=0; }
grep -qF "GUEST-ECHO-OK" "$LOG"        || { echo "FAIL: echo builtin should still work" >&2; ok=0; }
grep -qF "can't open '/etc/motd'" "$LOG" || { echo "FAIL: reading /etc/motd was not denied" >&2; ok=0; }
grep -qF "can't open '/'" "$LOG"      || { echo "FAIL: listing / was not denied" >&2; ok=0; }
# /bin/id (Swift) reports the numeric context even without capFsRead (no name lookup).
grep -qF "principal=3 session=3 caps=0x2" "$LOG" || { echo "FAIL: /bin/id did not report the guest context" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: VFS enforced capabilities — capless guest denied FS reads (M13 acceptance)"
  exit 0
fi
echo "--- serial (guest session) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/principal=3/,$p' >&2
exit 1
