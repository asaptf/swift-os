#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# sshd_interactive_test.sh — HC35 interactive PTY shell over SSH.
#
# Boots the base image (autostarts /bin/sshd) behind a slirp NIC with a hostfwd
# to guest TCP/22, then a real host OpenSSH client requests a pty + shell
# (ssh -tt) and drives an interactive busybox ash session: it runs a command
# whose OUTPUT (not the echoed command line) carries a unique marker, then
# exits. Asserts the marker round-trips through the PTY and the guest logs a
# clean interactive-shell completion.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="${SSHD_BASE_IMG:-$ROOT/build/base.img}"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_HOST_PORT:-$((26000 + ($$ % 20000)))}"
KEY_ALLOW_SRC="${SSHD_ALLOW_KEY_SRC:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED_SRC="${SSHD_HOST_SEED_SRC:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
[[ -f "$DTB" ]] || ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
[[ -x "$SSHKEY" ]] || ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1
[[ -f "$KEY_ALLOW_SRC" ]] || { echo "FAIL: $KEY_ALLOW_SRC missing" >&2; exit 2; }
[[ -f "$HOST_SEED_SRC" ]] || { echo "FAIL: $HOST_SEED_SRC missing" >&2; exit 2; }

LOG="$(mktemp -t swiftos-int.XXXXXX)"
OUT="$(mktemp -t swiftos-int-out.XXXXXX)"
ERR="$(mktemp -t swiftos-int-err.XXXXXX)"
KEY_ALLOW="$(mktemp -t swiftos-int-key.XXXXXX)"
KNOWN_HOSTS="$(mktemp -t swiftos-int-kh.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-int-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-int-in.XXXXXX)"; mkfifo "$INFIFO"
cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"; chmod 600 "$KEY_ALLOW"
"$SSHKEY" known-host --host "[127.0.0.1]:$HOST_PORT" --seed-file "$HOST_SEED_SRC" >"$KNOWN_HOSTS" \
  || { echo "FAIL: could not derive SwiftOS SSHD known_hosts entry" >&2; exit 2; }

QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$OUT" "$ERR" "$KEY_ALLOW" "$KNOWN_HOSTS" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

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
  echo "--- serial (interactive driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  echo "--- ssh stdout ---" >&2; cat "$OUT" >&2 2>/dev/null || true
  echo "--- ssh stderr ---" >&2; cat "$ERR" >&2 2>/dev/null || true
  exit 1
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo not ready"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swos-init: started sshd pid" 90 || drive_fail "swos-init did not start sshd"
await "sshd: listening on 22 (session exec preflight)" 120 || drive_fail "sshd did not listen"
await "swift-os login:" 90 || drive_fail "login prompt did not appear"

# Drive an interactive shell. The command's OUTPUT carries the marker "hc35ok",
# produced by shell quote-removal from "hc35''ok" — so the contiguous marker
# only appears in the command's output, never in the echoed command line.
{
  printf "echo hc35''ok\n"
  sleep 1
  printf 'exit\n'
} | "$SSH" \
    -F /dev/null -tt -p "$HOST_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o GlobalKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o KexAlgorithms=curve25519-sha256 \
    -o HostKeyAlgorithms=ssh-ed25519 \
    -o Ciphers=chacha20-poly1305@openssh.com \
    -o MACs=hmac-sha2-256 \
    -i "$KEY_ALLOW" \
    root@127.0.0.1 >"$OUT" 2>"$ERR"
ssh_rc=$?

await "sshd: interactive shell completed status" 20 || true
exec 3>&-
stop_qemu
QP=""

clean_out="$(sed 's/\r//' "$OUT")"
clean_log="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "hc35ok" <<<"$clean_out" \
  || { echo "FAIL: interactive command output marker not seen in ssh stdout" >&2; ok=0; }
grep -qF "sshd: interactive pty shell session" <<<"$clean_log" \
  || { echo "FAIL: guest did not log an interactive pty shell session" >&2; ok=0; }
grep -qF "sshd: interactive shell completed status 0" <<<"$clean_log" \
  || { echo "FAIL: guest did not log a clean interactive shell completion" >&2; ok=0; }

if (( ok )); then
  echo "PASS: ssh -tt allocated a pty, ran an interactive busybox shell, round-tripped command output, and exited cleanly (ssh_rc=$ssh_rc)"
  exit 0
fi
echo "--- ssh stdout ---" >&2; cat "$OUT" >&2
echo "--- ssh stderr ---" >&2; cat "$ERR" >&2
echo "--- serial (sshd region) ---" >&2
sed -n '/sshd:/,$p' <<<"$clean_log" | grep -iE 'sshd:|interactive|panic' | tail -40 >&2
exit 1
