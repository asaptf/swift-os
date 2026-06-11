#!/usr/bin/env bash
# net_static_ipv6_test.sh - Hetzner-style static IPv6 base-image config proof.
#
# Builds a temporary signed base image with /etc/swos/net-ipv6, boots QEMU with
# IPv6 enabled, and requires the kernel to apply the static /64 address plus
# link-local gateway before userland starts.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-net-static-ipv6.XXXXXX)"
CONFIG="$WORK/net-ipv6"
IMG="$WORK/base-net-static-ipv6.img"
BASE_ROOT="$WORK/base-root"
BUILDLOG="$WORK/base-image.log"
LOG="$WORK/qemu.log"
PIDFILE="$WORK/qemu.pid"
INFIFO="$WORK/qemu.in"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
}

cleanup() {
  stop_qemu
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$CONFIG" <<'EOF'
# Hetzner Cloud style Primary IPv6 config.
address=2001:db8:0:3df1::1/64
gateway=fe80::1
EOF

if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" NET_IPV6_CONFIG_FILE="$CONFIG" base-image ) >"$BUILDLOG" 2>&1; then
  echo "FAIL: could not build static IPv6 base image" >&2
  cat "$BUILDLOG" >&2
  exit 2
fi

mkfifo "$INFIFO"
qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$IMG,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev user,id=n0,ipv6=on
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

marker="net-hc23 OK: static IPv6 2001:0db8:0000:3df1:0000:0000:0000:0001/64 gateway fe80:0000:0000:0000:0000:0000:0000:0001 applied"
if ! await "$marker" 60; then
  echo "FAIL: kernel did not apply static IPv6 config from /etc/swos/net-ipv6" >&2
  echo "--- relevant log ---" >&2
  grep -iE 'net-hc23|net:|ipv6|panic|abort|M7' "$LOG" | tail -80 >&2 || true
  exit 1
fi

exec 3>&-
stop_qemu
QP=""

if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen after static IPv6 config" >&2
  grep -iE 'panic|abort' "$LOG" | tail -20 >&2 || true
  exit 1
fi

echo "PASS: static Hetzner-style IPv6 config was staged into the base image and applied at boot"
