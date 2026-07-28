#!/usr/bin/env bash
# sshd_usr_bin_exec_test.sh - SSHD exec acceptance for package-installed tools.
#
# Boots with the base image plus the pkghello package payload image. The guest
# autostarts /bin/sshd from /etc/swos/services, then a host OpenSSH client runs
# /usr/bin/pkghello from the read-only package overlay.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_DISK="${SSHD_BASE_IMG:-$ROOT/build/base.img}"
PKG_DISK="${SSHD_PKG_IMG:-$ROOT/build/pkghello-payload.img}"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_HOST_PORT:-$((26000 + ($$ % 16000)))}"
KEY_ALLOW_SRC="${SSHD_ALLOW_KEY_SRC:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED_SRC="${SSHD_HOST_SEED_SRC:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_DISK" ]]; then
  if [[ -n "${SSHD_BASE_IMG:-}" ]]; then
    echo "FAIL: $BASE_DISK missing (custom SSHD_BASE_IMG was requested)" >&2
    exit 2
  fi
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$PKG_DISK" ]]; then
  if [[ -n "${SSHD_PKG_IMG:-}" ]]; then
    echo "FAIL: $PKG_DISK missing (custom SSHD_PKG_IMG was requested)" >&2
    exit 2
  fi
  ( cd "$ROOT" && make package-fixture ) >/dev/null 2>&1 || { echo "FAIL: cannot build pkghello payload image" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
if [[ ! -x "$SSHKEY" ]]; then
  ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
fi
[[ -f "$KEY_ALLOW_SRC" ]] || { echo "FAIL: $KEY_ALLOW_SRC missing" >&2; exit 2; }
[[ -f "$HOST_SEED_SRC" ]] || { echo "FAIL: $HOST_SEED_SRC missing" >&2; exit 2; }

LOG="$(mktemp -t swiftos-sshd-usrbin.XXXXXX)"
SSHOUT="$(mktemp -t swiftos-sshd-usrbin-stdout.XXXXXX)"
SSHERR="$(mktemp -t swiftos-sshd-usrbin-stderr.XXXXXX)"
KEY_ALLOW="$(mktemp -t swiftos-sshd-usrbin-key.XXXXXX)"
KNOWN_HOSTS="$(mktemp -t swiftos-sshd-usrbin-known-hosts.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sshd-usrbin-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sshd-usrbin-in.XXXXXX)"
mkfifo "$INFIFO"
cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"
chmod 600 "$KEY_ALLOW"
"$SSHKEY" known-host --host "[127.0.0.1]:$HOST_PORT" \
  --seed-file "$HOST_SEED_SRC" >"$KNOWN_HOSTS" \
  || { echo "FAIL: could not derive SwiftOS SSHD known_hosts entry" >&2; exit 2; }

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
  rm -f "$LOG" "$SSHOUT" "$SSHERR" "$KEY_ALLOW" "$KNOWN_HOSTS" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$BASE_DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -drive "file=$PKG_DISK,format=raw,if=none,id=swospkg0,readonly=on"
  -device virtio-blk-device,drive=swospkg0
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22"
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
  echo "--- serial (sshd /usr/bin driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -140 >&2 || true
  echo "--- ssh stdout ---" >&2
  cat "$SSHOUT" >&2 2>/dev/null || true
  echo "--- ssh stderr ---" >&2
  cat "$SSHERR" >&2 2>/dev/null || true
  exit 1
}

ssh_common=(
  -F /dev/null -vvv -p "$HOST_PORT"
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

send_line() {
  local line="$1" delay="${SSHD_USRBIN_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${SSHD_USRBIN_SEND_DELAY:-0.08}"
}

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swos-init: starting configured services" 90 || drive_fail "swos-init did not start"
await "swos-init: started sshd pid" 90 || drive_fail "swos-init did not start sshd"
await "sshd: listening on 22 (session exec preflight)" 120 || drive_fail "autostarted /bin/sshd did not listen"
await "swift-os login:" 90 || drive_fail "console-login prompt did not appear after autostart"

"$SSH" "${ssh_common[@]}" -i "$KEY_ALLOW" \
  root@127.0.0.1 /usr/bin/pkghello >"$SSHOUT" 2>"$SSHERR" </dev/null
ssh_rc=$?

await "sshd: session exec completed status 0" 20 || true
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "swos-init: started sshd pid" <<<"$clean" \
  || { echo "FAIL: guest did not autostart sshd from swos-init" >&2; ok=0; }
grep -qF "sshd: publickey auth accepted for root" <<<"$clean" \
  || { echo "FAIL: guest did not accept root publickey auth" >&2; ok=0; }
grep -qF "sshd: authorized key matched /etc/ssh/authorized_keys" <<<"$clean" \
  || { echo "FAIL: guest did not load a matching authorized_keys entry" >&2; ok=0; }
grep -qF "sshd: session exec completed status 0" <<<"$clean" \
  || { echo "FAIL: guest did not complete /usr/bin remote exec with status 0" >&2; ok=0; }
grep -qF "Authenticated to 127.0.0.1" "$SSHERR" \
  || { echo "FAIL: host ssh did not report publickey authentication success" >&2; ok=0; }
grep -qF "Host '[127.0.0.1]:$HOST_PORT' is known and matches the ED25519 host key." "$SSHERR" \
  || { echo "FAIL: host ssh did not verify the SwiftOS host key through known_hosts" >&2; ok=0; }
grep -qFx "pkghello: hello from package overlay" "$SSHOUT" \
  || { echo "FAIL: remote /usr/bin/pkghello stdout was unexpected" >&2; ok=0; }
[[ "$ssh_rc" -eq 0 ]] \
  || { echo "FAIL: ssh /usr/bin/pkghello exited with $ssh_rc, expected 0" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/sshd executed package-overlay /usr/bin/pkghello over pinned OpenSSH remote exec"
  exit 0
fi
echo "--- serial (sshd /usr/bin region) ---" >&2
grep -iE 'swos-init:|sshd:|login:|panic|abort|M7|pkg' <<<"$clean" | tail -80 >&2 || true
echo "--- ssh stdout ---" >&2
cat "$SSHOUT" >&2
echo "--- ssh stderr ---" >&2
cat "$SSHERR" >&2
exit 1
