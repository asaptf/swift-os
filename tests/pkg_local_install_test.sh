#!/usr/bin/env bash
# pkg_local_install_test.sh - P3b/P4-local smoke: /bin/pkg installs a local swpkg.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_DISK="$ROOT/build/base.img"
STORE_DISK="$ROOT/build/pkgstore-install.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$STORE_DISK" ]]; then
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

LOG="$(mktemp -t swiftos-pkg-install.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-pkg-install-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-pkg-install-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (pkg install driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M11c:\|pkg /,$p' >&2 || true
  echo "--- tail ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${PKG_INSTALL_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PKG_INSTALL_SEND_DELAY:-0.08}"
}

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

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line 'pkg list'
await "no packages installed" 60 || drive_fail "empty package list was not reported"
send_line 'pkg install /packages/pkghello.swpkg'
await "pkg: installed pkghello-1.0.0_1" 90 || drive_fail "pkg install did not complete"
send_line 'pkg list'
await "pkghello-1.0.0_1" 60 || drive_fail "installed package not listed"
send_line '/usr/bin/pkghello'
await "pkghello: hello from package overlay" 60 || drive_fail "/usr/bin/pkghello did not execute after install"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "M11c: read-only base mounted from disk" "$LOG" || { echo "FAIL: base was not mounted from disk" >&2; ok=0; }
grep -qF "pkg: installed pkghello-1.0.0_1" "$LOG" || { echo "FAIL: pkg install output missing" >&2; ok=0; }
grep -qF "P3b: package installed and activated" "$LOG" || { echo "FAIL: kernel did not activate installed package" >&2; ok=0; }
grep -qF "P3b: package store payload live-mounted" "$LOG" || { echo "FAIL: live package-store mount missing" >&2; ok=0; }
grep -qF "pkghello: hello from package overlay" "$LOG" || { echo "FAIL: pkghello output missing" >&2; ok=0; }
grep -qF "panic:" "$LOG" && { echo "FAIL: kernel panic during pkg install" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/pkg installed local pkghello into writable package store and ran it"
  exit 0
fi
echo "--- serial (pkg install region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/M11c:/,$p' >&2
exit 1
