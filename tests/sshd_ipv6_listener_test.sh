#!/usr/bin/env bash
# sshd_ipv6_listener_test.sh - SSHD AF_INET6 listener deploy preflight.
#
# Builds a temporary signed base image whose /etc/swos/services contains the
# `sshd6` token, boots QEMU with IPv6 enabled, and requires swos-init to launch
# /bin/sshd -6 as an AF_INET6 TCP/22 listener. On QEMU builds with working IPv6
# hostfwd, the test also drives a host OpenSSH remote exec through ::1.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_IPV6_HOST_PORT:-$((25000 + ($$ % 20000)))}"
HOSTFWD_MODE="${SSHD_IPV6_HOSTFWD:-auto}"
KEY_ALLOW_SRC="${SSHD_ALLOW_KEY_SRC:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED_SRC="${SSHD_HOST_SEED_SRC:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"

# shellcheck source=tests/lib/ipv6_hostfwd.sh
source "$ROOT/tests/lib/ipv6_hostfwd.sh"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

# Explicit HOSTFWD_MODE wins; only "auto" consults the IPv6 hostfwd capability probe.
drive_openssh=1
if [[ "$HOSTFWD_MODE" == "0" || "$HOSTFWD_MODE" == "off" || "$HOSTFWD_MODE" == "false" ]]; then
  drive_openssh=0
elif [[ "$HOSTFWD_MODE" == "auto" ]]; then
  if ! qemu_ipv6_hostfwd_available >/dev/null; then
    drive_openssh=0
  fi
fi

if [[ "$drive_openssh" -eq 1 ]]; then
  command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
  if [[ ! -x "$SSHKEY" ]]; then
    ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
  fi
  [[ -f "$KEY_ALLOW_SRC" ]] || { echo "FAIL: $KEY_ALLOW_SRC missing" >&2; exit 2; }
  [[ -f "$HOST_SEED_SRC" ]] || { echo "FAIL: $HOST_SEED_SRC missing" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-sshd-ipv6.XXXXXX)"
SERVICES="$WORK/services"
IMG="$WORK/base-sshd-ipv6.img"
BASE_ROOT="$WORK/base-root"
BUILDLOG="$WORK/base-image.log"
LOG="$WORK/qemu.log"
SSHOUT="$WORK/ssh-stdout"
SSHERR="$WORK/ssh-stderr"
KEY_ALLOW="$WORK/sshd-key"
KNOWN_HOSTS="$WORK/known-hosts"
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

printf 'sshd6\n' >"$SERVICES"
if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" SWOS_SERVICES_FILE="$SERVICES" base-image ) >"$BUILDLOG" 2>&1; then
  echo "FAIL: could not build SSHD IPv6 service base image" >&2
  cat "$BUILDLOG" >&2
  exit 2
fi

if [[ "$drive_openssh" -eq 1 ]]; then
  cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"
  chmod 600 "$KEY_ALLOW"
  "$SSHKEY" known-host --host "[::1]:$HOST_PORT" \
    --seed-file "$HOST_SEED_SRC" >"$KNOWN_HOSTS" \
    || { echo "FAIL: could not derive SwiftOS SSHD IPv6 known_hosts entry" >&2; exit 2; }
fi

mkfifo "$INFIFO"
qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
netdev="user,id=n0,ipv6=on"
if [[ "$drive_openssh" -eq 1 ]]; then
  netdev="$netdev,hostfwd=tcp:[::1]:${HOST_PORT}-:22"
fi
qemu_args+=(
  -drive "file=$IMG,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "$netdev"
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

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (sshd IPv6 driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  if [[ "$drive_openssh" -eq 1 ]]; then
    echo "--- ssh stdout ---" >&2
    cat "$SSHOUT" >&2 2>/dev/null || true
    echo "--- ssh stderr ---" >&2
    cat "$SSHERR" >&2 2>/dev/null || true
  fi
  exit 1
}

send_line() {
  local line="$1" delay="${SSHD_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${SSHD_SEND_DELAY:-0.08}"
}

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swos-init: starting configured services" 90 || drive_fail "swos-init did not start"
await "swos-init: started sshd6 pid" 90 || drive_fail "swos-init did not start sshd6"
await "sshd: listening on 22 (IPv6 session exec preflight)" 120 || drive_fail "autostarted /bin/sshd -6 did not listen"
await "swift-os login:" 90 || drive_fail "console-login prompt did not appear after IPv6 SSHD autostart"

if [[ "$drive_openssh" -eq 1 ]]; then
  ssh_common=(
    -F /dev/null -6 -vvv -p "$HOST_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o GlobalKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -o PasswordAuthentication=no
    -o PubkeyAuthentication=yes
    -o NumberOfPasswordPrompts=0
    -o KexAlgorithms=curve25519-sha256
    -o HostKeyAlgorithms=ssh-ed25519
    -o Ciphers=chacha20-poly1305@openssh.com
    -o MACs=hmac-sha2-256
  )
  "$SSH" "${ssh_common[@]}" -i "$KEY_ALLOW" \
    root@::1 /bin/echo HC24-V6-OK >"$SSHOUT" 2>"$SSHERR" </dev/null
  ssh_rc=$?
else
  ssh_rc=0
fi

await "sshd: session exec completed status 0" 20 || true
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "net: IPv6 link-local configured" <<<"$clean" \
  || { echo "FAIL: kernel did not configure IPv6 link-local before SSHD IPv6 listen" >&2; ok=0; }
grep -qF "swos-init: started sshd6 pid" <<<"$clean" \
  || { echo "FAIL: swos-init did not report sshd6 service start" >&2; ok=0; }
grep -qF "sshd: listening on 22 (IPv6 session exec preflight)" <<<"$clean" \
  || { echo "FAIL: /bin/sshd did not report AF_INET6 listen mode" >&2; ok=0; }

if [[ "$drive_openssh" -eq 1 ]]; then
  [[ "$ssh_rc" -eq 0 ]] || { echo "FAIL: host OpenSSH IPv6 command failed with rc=$ssh_rc" >&2; ok=0; }
  grep -qF "HC24-V6-OK" "$SSHOUT" \
    || { echo "FAIL: host OpenSSH IPv6 command did not receive expected stdout" >&2; ok=0; }
  grep -qF "sshd: publickey auth accepted for root" <<<"$clean" \
    || { echo "FAIL: guest did not accept root publickey auth over IPv6 listener" >&2; ok=0; }
  grep -qF "sshd: session exec completed status 0" <<<"$clean" \
    || { echo "FAIL: guest did not complete IPv6 remote exec with status 0" >&2; ok=0; }
  grep -qF "Host '[::1]:$HOST_PORT' is known and matches the ED25519 host key." "$SSHERR" \
    || { echo "FAIL: host OpenSSH did not verify the SwiftOS IPv6 known_hosts entry" >&2; ok=0; }
fi

if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen after SSHD IPv6 listener start" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  if [[ "$drive_openssh" -eq 1 ]]; then
    echo "PASS: /bin/sshd -6 autostarted and OpenSSH completed IPv6 remote exec"
  else
    echo "PASS: /bin/sshd -6 autostarted as an AF_INET6 listener under ipv6=on"
  fi
  exit 0
fi

echo "--- serial (sshd IPv6 region) ---" >&2
grep -iE 'swos-init:|sshd:|net:|panic|abort|M7' <<<"$clean" | tail -100 >&2 || true
if [[ "$drive_openssh" -eq 1 ]]; then
  echo "--- ssh stdout ---" >&2; cat "$SSHOUT" >&2
  echo "--- ssh stderr ---" >&2; cat "$SSHERR" >&2
fi
exit 1
