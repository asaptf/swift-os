# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env bash
# cow_test.sh — COW fork acceptance.
#
# Boots the kernel, lets the built-in reclaim demo run, then logs in and drives
# ash through a forked subshell. The child mutates a shell variable, then the
# parent proves its copy is unchanged before mutating its own copy;
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
INFIFO="$(mktemp -u -t swiftos-cow-in.XXXXXX)"; mkfifo "$INFIFO"
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
  exec 3>&- 2>/dev/null || true
  rm -f "$LOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

blk_args=(-global virtio-mmio.force-legacy=false \
          -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
          -device virtio-blk-device,drive=swosbase)

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
  echo "--- serial (COW driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:\|cow-parent\|cow-child\|forkdemo/,$p' >&2 || true
  echo "--- tail ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" i
  sleep 0.1
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep 0.005
  done
  printf '\n' >&3
  sleep 0.05
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line "tty-line"
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
sleep 0.2
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line "root"
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line "swordfish"
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
send_line "echo cow-shell-ready"
await "cow-shell-ready" 60 || drive_fail "root shell did not accept commands"
send_line "COWV=before"
send_line '( COWV=child; echo cow-child-after:$COWV )'
await "cow-child-after:child" 60 || drive_fail "child shell did not print isolated value"
send_line 'echo cow-parent-before:$COWV'
await "cow-parent-before:before" 60 || drive_fail "parent shell did not keep pre-child value"
send_line "COWV=parent"
send_line 'echo cow-parent-after:$COWV'
await "cow-parent-after:parent" 60 || drive_fail "parent shell did not print post-write value"
send_line "/bin/forkdemo"
await "forkdemo: parent waited child" 90 || drive_fail "forkdemo did not complete"
send_line "exit"
await "M12c: session ended" 60 || true

exec 3>&-
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
