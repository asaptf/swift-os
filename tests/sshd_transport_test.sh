#!/usr/bin/env bash
# sshd_transport_test.sh — SSHD remote-command acceptance.
#
# Boots with a slirp NIC that hostfwds an unprivileged host TCP port to guest
# TCP/22. After login, the shell runs /bin/sshd. A real host OpenSSH client then
# first rejects an old dev Ed25519 key, then accepts the key staged in
# /etc/ssh/authorized_keys, opens a session channel, runs /bin/echo, receives
# stdout, and observes exit-status 0.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
HOST_PORT="${SSHD_HOST_PORT:-$((24000 + ($$ % 20000)))}"
KEY_ALLOW_SRC="$ROOT/fixtures/ssh/sshd_hc5_ed25519"
KEY_DENY_SRC="$ROOT/fixtures/ssh/sshd_hc4_ed25519"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
[[ -f "$KEY_ALLOW_SRC" ]] || { echo "FAIL: $KEY_ALLOW_SRC missing" >&2; exit 2; }
[[ -f "$KEY_DENY_SRC" ]] || { echo "FAIL: $KEY_DENY_SRC missing" >&2; exit 2; }

LOG="$(mktemp -t swiftos-sshd.XXXXXX)"
SSHOUT="$(mktemp -t swiftos-sshd-stdout.XXXXXX)"
SSHERR="$(mktemp -t swiftos-sshd-stderr.XXXXXX)"
DENYOUT="$(mktemp -t swiftos-sshd-deny-stdout.XXXXXX)"
DENYERR="$(mktemp -t swiftos-sshd-deny-stderr.XXXXXX)"
KEY_ALLOW="$(mktemp -t swiftos-sshd-allow-key.XXXXXX)"
KEY_DENY="$(mktemp -t swiftos-sshd-deny-key.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sshd-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sshd-in.XXXXXX)"
mkfifo "$INFIFO"
cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"
cp "$KEY_DENY_SRC" "$KEY_DENY"
chmod 600 "$KEY_ALLOW" "$KEY_DENY"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$SSHOUT" "$SSHERR" "$DENYOUT" "$DENYERR" "$KEY_ALLOW" "$KEY_DENY" "$PIDFILE" "$INFIFO"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
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
  echo "--- serial (sshd driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  echo "--- ssh stdout ---" >&2
  cat "$SSHOUT" >&2 2>/dev/null || true
  echo "--- ssh stderr ---" >&2
  cat "$SSHERR" >&2 2>/dev/null || true
  echo "--- denied ssh stdout ---" >&2
  cat "$DENYOUT" >&2 2>/dev/null || true
  echo "--- denied ssh stderr ---" >&2
  cat "$DENYERR" >&2 2>/dev/null || true
  exit 1
}

ssh_common=(
  -F /dev/null -vvv -p "$HOST_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
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
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line '/bin/sshd'
await "sshd: listening on 22 (session exec preflight)" 120 || drive_fail "/bin/sshd did not listen"

"$SSH" "${ssh_common[@]}" -i "$KEY_DENY" \
  root@127.0.0.1 /bin/echo DENIED >"$DENYOUT" 2>"$DENYERR" </dev/null
deny_rc=$?

"$SSH" "${ssh_common[@]}" -i "$KEY_ALLOW" \
  root@127.0.0.1 /bin/echo HC5-OK >"$SSHOUT" 2>"$SSHERR" </dev/null
ssh_rc=$?

await "sshd: session exec completed status 0" 20 || true
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "sshd: client SSH-2.0-" <<<"$clean" \
  || { echo "FAIL: guest did not receive a host SSH client banner" >&2; ok=0; }
grep -qF "sshd: publickey auth accepted for root" <<<"$clean" \
  || { echo "FAIL: guest did not accept root publickey auth" >&2; ok=0; }
grep -qF "sshd: authorized key matched /etc/ssh/authorized_keys" <<<"$clean" \
  || { echo "FAIL: guest did not load a matching authorized_keys entry" >&2; ok=0; }
grep -qF "sshd: session channel opened" <<<"$clean" \
  || { echo "FAIL: guest did not open a session channel" >&2; ok=0; }
grep -qF "sshd: session exec completed status 0" <<<"$clean" \
  || { echo "FAIL: guest did not complete remote exec with status 0" >&2; ok=0; }
grep -qF "swift-os_sshd-session" "$SSHERR" \
  || { echo "FAIL: host ssh did not report the swift-os SSH banner" >&2; ok=0; }
grep -qF "kex: algorithm: curve25519-sha256" "$SSHERR" \
  || { echo "FAIL: host ssh did not negotiate curve25519-sha256" >&2; ok=0; }
grep -qF "kex: host key algorithm: ssh-ed25519" "$SSHERR" \
  || { echo "FAIL: host ssh did not negotiate the ssh-ed25519 host key" >&2; ok=0; }
grep -qF "will use strict KEX ordering" "$SSHERR" \
  || { echo "FAIL: host ssh did not enable strict KEX ordering" >&2; ok=0; }
grep -qF "resetting read seqnr" "$SSHERR" \
  || { echo "FAIL: host ssh did not reset the receive sequence number after NEWKEYS" >&2; ok=0; }
grep -qF "chacha20-poly1305@openssh.com" "$SSHERR" \
  || { echo "FAIL: host ssh did not negotiate chacha20-poly1305" >&2; ok=0; }
grep -qF "Authenticated to 127.0.0.1" "$SSHERR" \
  || { echo "FAIL: host ssh did not report publickey authentication success" >&2; ok=0; }
grep -qF "Permission denied (publickey)." "$DENYERR" \
  || { echo "FAIL: denied key did not fail with publickey permission denied" >&2; ok=0; }
! grep -qF "DENIED" "$DENYOUT" \
  || { echo "FAIL: denied key unexpectedly executed the remote command" >&2; ok=0; }
[[ "$deny_rc" -ne 0 ]] \
  || { echo "FAIL: denied ssh key unexpectedly exited 0" >&2; ok=0; }
grep -qFx "HC5-OK" "$SSHOUT" \
  || { echo "FAIL: remote stdout was not HC5-OK" >&2; ok=0; }
[[ "$ssh_rc" -eq 0 ]] \
  || { echo "FAIL: ssh exited with $ssh_rc, expected 0" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/sshd loaded authorized_keys, rejected an old key, and executed /bin/echo over a session channel"
  exit 0
fi
echo "--- serial (sshd region) ---" >&2
grep -iE 'sshd:|login:|panic|abort|M7' <<<"$clean" | tail -40 >&2 || true
echo "--- ssh stdout ---" >&2
cat "$SSHOUT" >&2
echo "--- ssh stderr ---" >&2
cat "$SSHERR" >&2
echo "--- denied ssh stdout ---" >&2
cat "$DENYOUT" >&2
echo "--- denied ssh stderr ---" >&2
cat "$DENYERR" >&2
exit 1
