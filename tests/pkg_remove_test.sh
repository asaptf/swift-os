#!/usr/bin/env bash
# pkg_remove_test.sh - P4-local smoke: pkg remove writes a next-boot activation.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_DISK="$ROOT/build/base.img"
EMPTY_STORE="$ROOT/build/pkgstore-empty.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$EMPTY_STORE" ]]; then
  ( cd "$ROOT" && make package-local-install-fixture ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build empty package store image" >&2; exit 2;
  }
fi
if [[ ! -f "$DTB" ]]; then
  tmp_dtb="$DTB.tmp"
  mkdir -p "$(dirname "$DTB")"
  "$QEMU" -M "virt,dumpdtb=$tmp_dtb" -cpu cortex-a72 -m 256M -nographic >/dev/null 2>&1
  mv "$tmp_dtb" "$DTB"
fi

STORE_DISK="$(mktemp "$ROOT/build/pkgstore-remove.XXXXXX.img")"
cp "$EMPTY_STORE" "$STORE_DISK"

LOG1="$(mktemp -t swiftos-pkg-remove-1.XXXXXX)"
LOG2="$(mktemp -t swiftos-pkg-remove-2.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-pkg-remove-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-pkg-remove-in.XXXXXX)"; mkfifo "$INFIFO"
LOG="$LOG1"
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
  rm -f "$LOG1" "$LOG2" "$PIDFILE" "$INFIFO" "$STORE_DISK"
}
trap cleanup EXIT

dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (pkg remove driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M11c:\|pkg /,$p' >&2 || true
  echo "--- tail ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${PKG_REMOVE_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PKG_REMOVE_SEND_DELAY:-0.08}"
}

start_qemu() {
  LOG="$1"
  rm -f "$PIDFILE"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    "${dtb_args[@]}" \
    -drive "file=$BASE_DISK,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$STORE_DISK,format=raw,if=none,id=swpkgstore" \
    -device virtio-blk-device,drive=swpkgstore \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!
  exec 3<>"$INFIFO"
}

login_root() {
  await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
  send_line 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
  printf '\003' >&3
  await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
  send_line 'root'
  await "Password:" 90 || drive_fail "timed out waiting for password prompt"
  send_line 'swordfish'
  await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
  await "M12c: shell ready" 120 || drive_fail "root shell did not start"
}

start_qemu "$LOG1"
login_root
send_line 'pkg remove pkghello'
await "pkg: package not installed" 60 || drive_fail "pkg remove did not reject missing package"
send_line 'pkg install /packages/pkghello.swpkg'
await "pkg: installed pkghello-1.0.0_1" 90 || drive_fail "pkg install did not complete"
send_line 'pkg remove pkghello'
await "pkg: deactivated pkghello (effective after reboot)" 90 || drive_fail "pkg remove did not deactivate package"
send_line 'exit'
await "M12c: session ended" 60 || true
exec 3>&-
stop_qemu
QP=""

start_qemu "$LOG2"
login_root
send_line 'pkg list'
await "no packages installed" 60 || drive_fail "removed package was still active after reboot"
send_line 'pkg info pkghello'
await "pkg: package not found" 60 || drive_fail "pkg info still saw removed package after reboot"
send_line 'pkg files pkghello'
await "pkg: package not installed" 60 || drive_fail "pkg files still saw removed package after reboot"
send_line 'exit'
await "M12c: session ended" 60 || true
exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "pkg: deactivated pkghello (effective after reboot)" "$LOG1" || {
  echo "FAIL: pkg remove output missing" >&2; ok=0;
}
grep -qF "P4: package deactivated for next boot" "$LOG1" || {
  echo "FAIL: kernel did not append remove activation" >&2; ok=0;
}
grep -qF "P3: package store active generation" "$LOG2" || {
  echo "FAIL: package store generation was not loaded after reboot" >&2; ok=0;
}
grep -qF "no packages installed" "$LOG2" || {
  echo "FAIL: empty post-remove package list missing" >&2; ok=0;
}
grep -qF "P3: package store payload mounted" "$LOG2" && {
  echo "FAIL: removed package payload was mounted after reboot" >&2; ok=0;
}
grep -qF "panic:" "$LOG1" "$LOG2" && {
  echo "FAIL: kernel panic during pkg remove test" >&2; ok=0;
}

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/pkg remove deactivated pkghello in the next package-store generation"
  exit 0
fi
echo "--- first boot ---" >&2
sed 's/\r//' "$LOG1" | sed -n '/M11c:/,$p' >&2
echo "--- second boot ---" >&2
sed 's/\r//' "$LOG2" | sed -n '/M11c:/,$p' >&2
exit 1
