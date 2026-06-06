#!/usr/bin/env bash
# swift_fileops_test.sh — native Swift /bin/mkdir, /bin/rmdir, /bin/rm, /bin/mv.
#
# Pure-Swift tmpfs-mutation utilities (userland/{mkdir,rmdir,rm,mv}.swift) over
# the kernel mkdir/unlink/rename/rmdir syscalls. Invoked by absolute path so the
# busybox standalone shell execs our binaries.

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

LOG="$(mktemp -t swiftos-fo.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-fo-pid.XXXXXX)"
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

# Sequence (all under /tmp, the writable tmpfs):
#   mkdir /tmp/d      -> ls shows d
#   echo > /tmp/d/f   -> ls shows f
#   mv f -> g, rm g, rmdir d, then ls /tmp to confirm they are gone.
(
  sleep 8;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 3;  printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf '/bin/mkdir /tmp/d\n'
  sleep 2;  printf 'echo hi > /tmp/d/f\n'
  sleep 2;  printf '/bin/mv /tmp/d/f /tmp/d/g\n'
  sleep 2;  printf '/bin/ls /tmp/d\n'                 # expect: g
  sleep 2;  printf '/bin/cat /tmp/d/g\n'              # expect: hi (mv preserved content)
  sleep 2;  printf '/bin/rm /tmp/d/g\n'
  sleep 2;  printf '/bin/rmdir /tmp/d\n'
  sleep 2;  printf '/bin/ls /tmp\n'                   # expect: no d (note remains)
  sleep 2;  printf 'echo FILEOPS-DONE\n'
  sleep 2;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 40
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
# After `mv f g`, ls /tmp/d shows g (and not f).
awk '/# \/bin\/ls \/tmp\/d$/{f=1;next} f&&/^# /{f=0} f' <<<"$clean" | grep -qxF "g" \
  || { echo "FAIL: mv did not rename f->g in /tmp/d" >&2; ok=0; }
grep -qxF "hi" <<<"$clean"        || { echo "FAIL: mv did not preserve file content (cat g != hi)" >&2; ok=0; }
# After rm g + rmdir d, ls /tmp must not list d (but keeps the boot-created note).
awk '/# \/bin\/ls \/tmp$/{f=1;next} f&&/^# /{f=0} f' <<<"$clean" | grep -qxF "d" \
  && { echo "FAIL: /tmp/d still present after rmdir" >&2; ok=0; }
grep -qxF "FILEOPS-DONE" <<<"$clean" || { echo "FAIL: shell did not survive the file ops" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift mkdir/rmdir/rm/mv mutate the tmpfs correctly"
  exit 0
fi
echo "--- serial (fileops region) ---" >&2
sed -n '/\/bin\/mkdir/,$p' <<<"$clean" | head -40 >&2
exit 1
