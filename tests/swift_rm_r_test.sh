#!/usr/bin/env bash
# swift_rm_r_test.sh — native Swift /bin/rm recursive `-r`/`-R`.
#
# Builds a small tree under /tmp (the writable tmpfs) and exercises the new
# recursive removal in userland/rm.swift: a bare `rm DIR` must refuse (it is a
# directory), while `rm -r DIR` removes the populated tree depth-first. Invoked
# by absolute path so the busybox standalone shell execs our binary.

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

LOG="$(mktemp -t swiftos-rmr.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-rmr-pid.XXXXXX)"
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
#   mkdir /tmp/d, /tmp/d/sub; populate with files at two depths.
#   rm /tmp/d        -> refuses (is a directory); ls /tmp still shows d.
#   rm -r /tmp/d     -> removes the whole tree; ls /tmp no longer shows d.
(
  sleep 8;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 3;  printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf '/bin/mkdir /tmp/d\n'
  sleep 2;  printf '/bin/mkdir /tmp/d/sub\n'
  sleep 2;  printf 'echo hi > /tmp/d/f\n'
  sleep 2;  printf 'echo deep > /tmp/d/sub/g\n'
  sleep 2;  printf '/bin/rm /tmp/d\n'                 # refuses: is a directory
  sleep 2;  printf 'echo RC1=$?\n'                    # expect non-zero
  sleep 2;  printf '/bin/ls /tmp\n'                   # expect: d still present
  sleep 2;  printf '/bin/rm -r /tmp/d\n'              # removes the tree
  sleep 2;  printf 'echo RC2=$?\n'                    # expect 0
  sleep 2;  printf '/bin/ls /tmp\n'                   # expect: no d
  sleep 2;  printf 'echo RMR-DONE\n'
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
sleep 55
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
# Bare `rm /tmp/d` must refuse (directory) and report a non-zero status.
grep -qxF "RC1=0" <<<"$clean" && { echo "FAIL: rm of a directory without -r unexpectedly succeeded" >&2; ok=0; }
grep -q "is a directory" <<<"$clean" || { echo "FAIL: rm did not report 'is a directory'" >&2; ok=0; }
# After the refusal, /tmp/d is still listed.
awk '/# \/bin\/ls \/tmp$/{c++} c==1&&/^# \/bin\/ls/{next} c==1&&/^# /{c=2} c==1' <<<"$clean" | grep -qxF "d" \
  || { echo "FAIL: /tmp/d missing after a refused (no -r) rm" >&2; ok=0; }
# `rm -r /tmp/d` succeeds (status 0).
grep -qxF "RC2=0" <<<"$clean" || { echo "FAIL: rm -r did not exit 0" >&2; ok=0; }
# After rm -r, the *second* `ls /tmp` no longer lists d.
awk '/# \/bin\/ls \/tmp$/{c++} c==2&&/^# \/bin\/ls/{next} c==2&&/^# /{c=3} c==2' <<<"$clean" | grep -qxF "d" \
  && { echo "FAIL: /tmp/d still present after rm -r" >&2; ok=0; }
grep -qxF "RMR-DONE" <<<"$clean" || { echo "FAIL: shell did not survive the rm -r ops" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift rm -r removes a populated directory tree"
  exit 0
fi
echo "--- serial (rm -r region) ---" >&2
sed -n '/\/bin\/mkdir/,$p' <<<"$clean" | head -50 >&2
exit 1
