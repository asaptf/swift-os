#!/usr/bin/env bash
# netinfo_test.sh - HC27 network status deploy preflight.
#
# Boots with the normal virtio-net slirp profile, logs in as root, runs
# /bin/netinfo, and asserts that the guest can report the network state needed
# before a cloud deploy: link readiness, IPv4 address/prefix, gateway, DNS, and
# IPv6 address/prefix source.

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
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-netinfo.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-netinfo-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-netinfo-in.XXXXXX)"
mkfifo "$INFIFO"
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

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (netinfo driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${NETINFO_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${NETINFO_SEND_DELAY:-0.08}"
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev user,id=n0
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line "/bin/netinfo"
await "netinfo: HC27 OK" 90 || true
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "netinfo: ready yes" <<<"$clean" \
  || { echo "FAIL: netinfo did not report ready link state" >&2; ok=0; }
grep -Eq "netinfo: ipv4 10\.0\.2\.15/24 source (dhcp|fallback)" <<<"$clean" \
  || { echo "FAIL: netinfo did not report the expected slirp IPv4 address/prefix/source" >&2; ok=0; }
grep -qF "netinfo: gateway4 10.0.2.2" <<<"$clean" \
  || { echo "FAIL: netinfo did not report the slirp IPv4 gateway" >&2; ok=0; }
grep -qF "netinfo: dns4 10.0.2.3" <<<"$clean" \
  || { echo "FAIL: netinfo did not report the slirp DNS server" >&2; ok=0; }
grep -Eq "netinfo: ipv6 fe80:[0-9a-f:]+ prefix 64 source (link-local|static)" <<<"$clean" \
  || { echo "FAIL: netinfo did not report the IPv6 address/prefix/source" >&2; ok=0; }
grep -qF "netinfo: gateway6 " <<<"$clean" \
  || { echo "FAIL: netinfo did not report IPv6 gateway status" >&2; ok=0; }
grep -qF "netinfo: HC27 OK" <<<"$clean" \
  || { echo "FAIL: netinfo completion marker missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/netinfo reports guest network status for deploy preflight"
  exit 0
fi

echo "--- netinfo serial region ---" >&2
grep -iE 'netinfo:|net-dhcp|net:|panic|abort' <<<"$clean" | tail -80 >&2 || true
exit 1
