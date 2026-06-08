# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env bash
# cow_test.sh — COW fork acceptance.
#
# Boots the kernel, lets the built-in reclaim demo run, then logs in and drives
# ash through a forked pipeline subshell. The child mutates a shell variable,
# then the parent proves its copy is unchanged before mutating its own copy;
# /bin/forkdemo adds the existing static-data marker check and waitpid path. The
# boot reclaim line guards against leaked or double-freed frames across repeated
# fork/exec/reap.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

DISK="$ROOT/build/base.img"
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-cow.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cow-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
  fi
}
cleanup() {
  stop_qemu
  rm -f "$LOG" "$PIDFILE"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

blk_args=(-global virtio-mmio.force-legacy=false \
          -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
          -device virtio-blk-device,drive=swosbase)

(
  sleep 7;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 2;  printf 'root\n'
  sleep 1;  printf 'swordfish\n'
  sleep 2;  printf 'COWV=before\n'
  sleep 1;  printf 'echo gate | ( read gate; COWV=child; echo cow-child-after:$COWV )\n'
  sleep 1;  printf 'echo cow-parent-before:$COWV\n'
  sleep 1;  printf 'COWV=parent\n'
  sleep 1;  printf 'echo cow-parent-after:$COWV\n'
  sleep 1;  printf '/bin/forkdemo\n'
  sleep 3;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 35
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "cow-parent-before:before" <<<"$clean" || { echo "FAIL: child write leaked into parent" >&2; ok=0; }
grep -qF "cow-parent-after:parent" <<<"$clean" || { echo "FAIL: parent post-fork write not observed" >&2; ok=0; }
grep -qF "cow-child-after:child" <<<"$clean" || { echo "FAIL: child post-fork write not observed" >&2; ok=0; }
grep -qF "forkdemo: child sees private marker" <<<"$clean" || { echo "FAIL: forkdemo child marker isolation missing" >&2; ok=0; }
grep -qF "forkdemo: parent waited child" <<<"$clean" || { echo "FAIL: forkdemo parent marker/waitpid check missing" >&2; ok=0; }
grep -qF "reclaim OK: no frame leak across fork/exec/exit/reap" <<<"$clean" || { echo "FAIL: reclaim regression after COW" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during COW test" >&2; ok=0; }
grep -qF "reclaim FAIL" <<<"$clean" && { echo "FAIL: reclaim self-test reported failure" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: COW fork parent/child writes isolated; reclaim remains balanced"
  exit 0
fi

echo "--- serial (COW region) ---" >&2
sed -n '/cow-parent/,$p' <<<"$clean" | head -80 >&2
echo "--- tail ---" >&2
tail -40 <<<"$clean" >&2
exit 1
