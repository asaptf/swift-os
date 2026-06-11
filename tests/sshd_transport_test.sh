#!/usr/bin/env bash
# sshd_transport_test.sh — SSHD pre-auth transport acceptance.
#
# Boots with a slirp NIC that hostfwds an unprivileged host TCP port to guest
# TCP/22. After login, the shell runs /bin/sshd. A real host OpenSSH client then
# connects and must see the swift-os SSH identification string plus the explicit
# pre-auth disconnect reason. This proves the deploy-critical listener shape
# without pretending KEX, authentication, or session channels exist yet.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
HOST_PORT="${SSHD_HOST_PORT:-$((24000 + ($$ % 20000)))}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-sshd.XXXXXX)"
SSHOUT="$(mktemp -t swiftos-sshd-ssh.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sshd-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sshd-in.XXXXXX)"
mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$SSHOUT" "$PIDFILE" "$INFIFO"' EXIT

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
  echo "--- ssh output ---" >&2
  cat "$SSHOUT" >&2 2>/dev/null || true
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
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line '/bin/sshd'
await "sshd: listening on 22 (transport preflight)" 120 || drive_fail "/bin/sshd did not listen"

"$SSH" -F /dev/null -vvv -p "$HOST_PORT" \
  -o BatchMode=yes \
  -o ConnectTimeout=8 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o PreferredAuthentications=publickey \
  -o NumberOfPasswordPrompts=0 \
  root@127.0.0.1 true >"$SSHOUT" 2>&1 </dev/null
ssh_rc=$?

await "sshd: sent preauth disconnect" 20 || true
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "sshd: client SSH-2.0-" <<<"$clean" \
  || { echo "FAIL: guest did not receive a host SSH client banner" >&2; ok=0; }
grep -qF "sshd: sent preauth disconnect" <<<"$clean" \
  || { echo "FAIL: guest did not send the pre-auth disconnect" >&2; ok=0; }
grep -qF "swift-os_sshd-preauth" "$SSHOUT" \
  || { echo "FAIL: host ssh did not report the swift-os SSH banner" >&2; ok=0; }
grep -qF "transport preflight" "$SSHOUT" \
  || { echo "FAIL: host ssh did not report the explicit pre-auth disconnect reason" >&2; ok=0; }
[[ "$ssh_rc" -ne 0 ]] \
  || { echo "FAIL: ssh unexpectedly authenticated/executed a command" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/sshd accepted OpenSSH on guest TCP/22 and returned a pre-auth SSH disconnect"
  exit 0
fi
echo "--- serial (sshd region) ---" >&2
grep -iE 'sshd:|login:|panic|abort|M7' <<<"$clean" | tail -40 >&2 || true
echo "--- ssh output ---" >&2
cat "$SSHOUT" >&2
exit 1
