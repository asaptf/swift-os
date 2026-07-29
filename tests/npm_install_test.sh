#!/usr/bin/env bash
# npm_install_test.sh — install a pure-JS package into /tmp/npm-prefix.
# Phase 1: local tarball (no registry/network). Phase 2 (NPM_INSTALL_REGISTRY=1):
# HTTP registry fixture via slirp gateway 10.0.2.2.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_LINE_MODE=whole
SEND_SEND_DELAY="${NPM_INSTALL_SEND_DELAY:-0.3}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${NODE_QEMU_MEM:-2048M}"
PKG="${NPM_INSTALL_PKG:-swos-smoke}"
CHECK_MARK="NPMCHK true"
USE_REGISTRY="${NPM_INSTALL_REGISTRY:-0}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK"   ]] || { echo "FAIL: $DISK missing (make base-image INCLUDE_NODE=1)" >&2; exit 2; }

pkill -x qemu-system-aarch64 2>/dev/null || true
sleep 0.5

LOG="$(mktemp -t swiftos-npm-install.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-npm-install-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-npm-install-in.XXXXXX)"; mkfifo "$INFIFO"
REGLOG=""
QP=""
REGPID=""
stop_all() {
  [[ -n "$REGPID" ]] && { kill "$REGPID" 2>/dev/null || true; wait "$REGPID" 2>/dev/null || true; }
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO" "$REGLOG"' EXIT

if [[ "$USE_REGISTRY" == "1" ]]; then
  command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not found" >&2; exit 2; }
  REG_PORT="${NPM_REGISTRY_PORT:-$((25000 + ($$ % 15000)))}"
  REG_HOST="${NPM_REGISTRY_HOST:-10.0.2.2}"
  REGLOG="$(mktemp -t swiftos-npm-reg.XXXXXX)"
  python3 "$ROOT/tests/npm_registry_server.py" "$REG_PORT" >"$REGLOG" 2>&1 &
  REGPID=$!
  sleep 0.3
  kill -0 "$REGPID" 2>/dev/null || { echo "FAIL: registry server did not start" >&2; cat "$REGLOG" >&2; exit 2; }
  INSTALL_CMD="/bin/npm install is-odd --registry http://${REG_HOST}:${REG_PORT} --no-audit --no-fund"
  PKG="is-odd"
  DONE_MARK="added 1 package"
else
  TARBALL="/usr/share/npm-fixture/${PKG}-1.0.0.tgz"
  INSTALL_CMD="/bin/npm install ${TARBALL} --no-audit --no-fund"
  DONE_MARK="added 1 package"
fi

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    grep -qE 'EL0 fault|Segmentation|SIGILL|signal 0x000000000000000B' "$LOG" 2>/dev/null && return 2
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
drive_fail() {
  echo "FAIL: $1" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

SMP="${NODE_QEMU_SMP:-1}"
"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP" -m "$MEM" -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "no tty line prompt"
send_line 'x'
await "M7 tty: running" 40 || drive_fail "no tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "no login prompt"
send_line 'root'
await "Password:" 30 || drive_fail "no password prompt"
send_line 'swordfish'
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"

# console-login line buffer is ~256 chars; keep each line short. sshd serial
# noise can splice into multi-line typing, so run export+install atomically.
send_line 'mkdir -p /tmp/npm-prefix/lib/node_modules /tmp/npm-cache'
await '/tmp/npm-cache' 30 || drive_fail "mkdir did not echo"
send_line "export NPM_CONFIG_PREFIX=/tmp/npm-prefix NPM_CONFIG_CACHE=/tmp/npm-cache UV_THREADPOOL_SIZE=1 && ${INSTALL_CMD}"
rc=0
await "$DONE_MARK" 180 || rc=$?
if (( rc == 2 )); then drive_fail "node/npm crashed during install (SIGSEGV/SIGILL)"
fi
(( rc == 0 )) || drive_fail "npm install did not complete ($DONE_MARK)"
send_line "busybox cat /tmp/npm-prefix/lib/node_modules/${PKG}/package.json"
await "\"name\":\"${PKG}\"" 60 || drive_fail "installed package.json missing or wrong name"
send_line "busybox cat /tmp/npm-prefix/lib/node_modules/${PKG}/index.js && echo NPMCHK true"
await "$CHECK_MARK" 60 || drive_fail "installed package layout invalid"
exec 3>&-; stop_all; QP=""; REGPID=""

clean="$(sed 's/\r//' "$LOG")"
if grep -qF "$CHECK_MARK" <<<"$clean"; then
  echo "PASS: npm installed ${PKG} into /tmp/npm-prefix"
  exit 0
fi
echo "FAIL: npm install smoke incomplete" >&2
grep -iE 'npm|ERR!|Error|panic|abort|SIGILL|Illegal' <<<"$clean" | tail -40 >&2 || true
exit 1