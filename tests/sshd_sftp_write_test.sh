#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# sshd_sftp_write_test.sh — HC33 SFTP write-path acceptance.
#
# Boots the default base image (which autostarts /bin/sshd) behind a slirp NIC
# that hostfwds an unprivileged host TCP port to guest TCP/22. A real host
# OpenSSH `sftp` client pins the SwiftOS host key, authenticates with a staged
# Ed25519 key, and exercises the writable tmpfs surface: mkdir, a multi-chunk
# upload (>4 KiB, forcing several bounded SFTP WRITE frames), a byte-exact
# round-trip download, rename, remove, and rmdir. A second invocation proves the
# read-only base is honored: uploading onto /readme.txt is denied. The client
# uses the limits@openssh.com extension we advertise to bound its write size.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="${SSHD_BASE_IMG:-$ROOT/build/base.img}"
QEMU="${QEMU:-qemu-system-aarch64}"
SFTP="${SFTP:-sftp}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_HOST_PORT:-$((24000 + ($$ % 20000)))}"
KEY_ALLOW_SRC="${SSHD_ALLOW_KEY_SRC:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED_SRC="${SSHD_HOST_SEED_SRC:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  if [[ -n "${SSHD_BASE_IMG:-}" ]]; then
    echo "FAIL: $DISK missing (custom SSHD_BASE_IMG was requested)" >&2
    exit 2
  fi
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v "$SFTP" >/dev/null 2>&1 || { echo "FAIL: sftp client not found" >&2; exit 2; }
if [[ ! -x "$SSHKEY" ]]; then
  ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
fi
[[ -f "$KEY_ALLOW_SRC" ]] || { echo "FAIL: $KEY_ALLOW_SRC missing" >&2; exit 2; }
[[ -f "$HOST_SEED_SRC" ]] || { echo "FAIL: $HOST_SEED_SRC missing" >&2; exit 2; }

LOG="$(mktemp -t swiftos-sftpw.XXXXXX)"
SRC="$(mktemp -t swiftos-sftpw-src.XXXXXX)"
DL_ROUND="$(mktemp -t swiftos-sftpw-round.XXXXXX)"
DL_RENAMED="$(mktemp -t swiftos-sftpw-renamed.XXXXXX)"
OUT1="$(mktemp -t swiftos-sftpw-out1.XXXXXX)"
ERR1="$(mktemp -t swiftos-sftpw-err1.XXXXXX)"
OUT2="$(mktemp -t swiftos-sftpw-out2.XXXXXX)"
ERR2="$(mktemp -t swiftos-sftpw-err2.XXXXXX)"
BATCH1="$(mktemp -t swiftos-sftpw-batch1.XXXXXX)"
BATCH2="$(mktemp -t swiftos-sftpw-batch2.XXXXXX)"
KEY_ALLOW="$(mktemp -t swiftos-sftpw-allow-key.XXXXXX)"
KNOWN_HOSTS="$(mktemp -t swiftos-sftpw-known-hosts.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sftpw-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sftpw-in.XXXXXX)"
mkfifo "$INFIFO"
cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"
chmod 600 "$KEY_ALLOW"
# Deterministic 10000-byte payload: spans several bounded SFTP WRITE frames.
( i=0; while [ "$i" -lt 250 ]; do printf 'HC33-sftp-write-path-payload-line-%04d\n' "$i"; i=$((i+1)); done ) >"$SRC"
"$SSHKEY" known-host --host "[127.0.0.1]:$HOST_PORT" \
  --seed-file "$HOST_SEED_SRC" >"$KNOWN_HOSTS" \
  || { echo "FAIL: could not derive SwiftOS SSHD known_hosts entry" >&2; exit 2; }

QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$SRC" "$DL_ROUND" "$DL_RENAMED" "$OUT1" "$ERR1" "$OUT2" "$ERR2" "$BATCH1" "$BATCH2" "$KEY_ALLOW" "$KNOWN_HOSTS" "$PIDFILE" "$INFIFO"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22"
  -device virtio-net-device,netdev=n0
)
qemu_args+=(-kernel "$KERNEL")

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
  echo "--- serial (sftp-write driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  echo "--- sftp write stdout ---" >&2; cat "$OUT1" >&2 2>/dev/null || true
  echo "--- sftp write stderr ---" >&2; cat "$ERR1" >&2 2>/dev/null || true
  exit 1
}

sftp_run() {
  local batch="$1" out="$2" err="$3"
  "$SFTP" \
    -F /dev/null -v -P "$HOST_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o GlobalKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes \
    -o NumberOfPasswordPrompts=0 \
    -o KexAlgorithms=curve25519-sha256 \
    -o HostKeyAlgorithms=ssh-ed25519 \
    -o Ciphers=chacha20-poly1305@openssh.com \
    -o MACs=hmac-sha2-256 \
    -i "$KEY_ALLOW" \
    -b "$batch" \
    root@127.0.0.1 >"$out" 2>"$err"
}

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "tty demo did not become ready"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swos-init: started sshd pid" 90 || drive_fail "swos-init did not start sshd"
await "sshd: listening on 22 (session exec preflight)" 120 || drive_fail "autostarted /bin/sshd did not listen"
await "swift-os login:" 90 || drive_fail "console-login prompt did not appear after autostart"

cat >"$BATCH1" <<EOF
mkdir /tmp/hc33
put $SRC /tmp/hc33/up.bin
get /tmp/hc33/up.bin $DL_ROUND
rename /tmp/hc33/up.bin /tmp/hc33/renamed.bin
get /tmp/hc33/renamed.bin $DL_RENAMED
rm /tmp/hc33/renamed.bin
rmdir /tmp/hc33
EOF
sftp_run "$BATCH1" "$OUT1" "$ERR1"
rc1=$?

# Read-only base must reject an upload (separate session; -b aborts on failure).
cat >"$BATCH2" <<EOF
put $SRC /readme.txt
EOF
sftp_run "$BATCH2" "$OUT2" "$ERR2"
rc2=$?

await "sshd: sftp subsystem completed" 20 || true
exec 3>&-
stop_qemu
QP=""

ok=1
[[ "$rc1" -eq 0 ]] \
  || { echo "FAIL: write-path sftp batch exited with $rc1, expected 0" >&2; ok=0; }
cmp -s "$DL_ROUND" "$SRC" \
  || { echo "FAIL: uploaded /tmp/hc33/up.bin did not round-trip byte-for-byte" >&2; ok=0; }
cmp -s "$DL_RENAMED" "$SRC" \
  || { echo "FAIL: renamed file did not download identical to the upload" >&2; ok=0; }
[[ "$rc2" -ne 0 ]] \
  || { echo "FAIL: upload onto the read-only base unexpectedly succeeded" >&2; ok=0; }
grep -qiE "permission denied|remote open.*: Permission" "$ERR2" \
  || { echo "FAIL: read-only upload did not report permission denied" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: sftp mkdir/put/rename/rm/rmdir on tmpfs with byte-exact multi-chunk round-trip, and read-only base upload denied"
  exit 0
fi
echo "--- serial (sftp-write region) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'swos-init:|sshd:|login:|panic|abort' | tail -40 >&2 || true
echo "--- write batch stdout ---" >&2; cat "$OUT1" >&2
echo "--- write batch stderr ---" >&2; cat "$ERR1" >&2
echo "--- deny batch stderr ---" >&2; cat "$ERR2" >&2
exit 1
