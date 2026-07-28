#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# sshd_sftp_test.sh — HC32 SFTP read-only browse acceptance.
#
# Boots the default base image (which autostarts /bin/sshd via /bin/swos-init)
# behind a slirp NIC that hostfwds an unprivileged host TCP port to guest TCP/22.
# A real host OpenSSH `sftp` client then pins the SwiftOS host key through a
# derived known_hosts entry, authenticates with a staged Ed25519 key, requests
# the `sftp` subsystem, and exercises the read-only browse surface: protocol
# handshake, REALPATH (pwd), directory enumeration (ls), file stat, and file
# download. Two small static base files and one ~118 KiB binary (/bin/sshd,
# byte-identical to build/sshd.elf) are downloaded and compared byte-for-byte,
# proving correct multi-chunk reassembly. The guest logs the subsystem start
# and clean completion.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="${SSHD_BASE_IMG:-$ROOT/build/base.img}"
QEMU="${QEMU:-qemu-system-aarch64}"
SFTP="${SFTP:-sftp}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_HOST_PORT:-$((24000 + ($$ % 20000)))}"
KEY_ALLOW_SRC="${SSHD_ALLOW_KEY_SRC:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED_SRC="${SSHD_HOST_SEED_SRC:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"
SSHD_ELF="$ROOT/build/sshd.elf"

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
[[ -f "$SSHD_ELF" ]] || { echo "FAIL: $SSHD_ELF missing (make build/sshd.elf)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-sftp.XXXXXX)"
SFTPOUT="$(mktemp -t swiftos-sftp-stdout.XXXXXX)"
SFTPERR="$(mktemp -t swiftos-sftp-stderr.XXXXXX)"
BATCH="$(mktemp -t swiftos-sftp-batch.XXXXXX)"
DL_README="$(mktemp -t swiftos-sftp-readme.XXXXXX)"
DL_PASSWD="$(mktemp -t swiftos-sftp-passwd.XXXXXX)"
DL_SSHD="$(mktemp -t swiftos-sftp-sshd.XXXXXX)"
KEY_ALLOW="$(mktemp -t swiftos-sftp-allow-key.XXXXXX)"
KNOWN_HOSTS="$(mktemp -t swiftos-sftp-known-hosts.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sftp-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sftp-in.XXXXXX)"
mkfifo "$INFIFO"
cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"
chmod 600 "$KEY_ALLOW"
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
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$SFTPOUT" "$SFTPERR" "$BATCH" "$DL_README" "$DL_PASSWD" "$DL_SSHD" "$KEY_ALLOW" "$KNOWN_HOSTS" "$PIDFILE" "$INFIFO"' EXIT

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
  echo "--- serial (sftp driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  echo "--- sftp stdout ---" >&2
  cat "$SFTPOUT" >&2 2>/dev/null || true
  echo "--- sftp stderr ---" >&2
  cat "$SFTPERR" >&2 2>/dev/null || true
  exit 1
}

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swos-init: started sshd pid" 90 || drive_fail "swos-init did not start sshd"
await "sshd: listening on 22 (session exec preflight)" 120 || drive_fail "autostarted /bin/sshd did not listen"
await "swift-os login:" 90 || drive_fail "console-login prompt did not appear after autostart"

cat >"$BATCH" <<EOF
pwd
ls /
get /readme.txt $DL_README
get /etc/passwd $DL_PASSWD
get /bin/sshd $DL_SSHD
EOF

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
  -b "$BATCH" \
  root@127.0.0.1 >"$SFTPOUT" 2>"$SFTPERR"
sftp_rc=$?

await "sshd: sftp subsystem completed" 20 || true
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1

[[ "$sftp_rc" -eq 0 ]] \
  || { echo "FAIL: sftp batch exited with $sftp_rc, expected 0" >&2; ok=0; }
grep -qF "swift-os_sshd-session" "$SFTPERR" \
  || { echo "FAIL: host sftp did not report the swift-os SSH banner" >&2; ok=0; }
grep -qF "Authenticated to 127.0.0.1" "$SFTPERR" \
  || { echo "FAIL: host sftp did not report publickey authentication success" >&2; ok=0; }
grep -qF "sshd: sftp subsystem started" <<<"$clean" \
  || { echo "FAIL: guest did not start the sftp subsystem" >&2; ok=0; }
grep -qF "sshd: sftp subsystem completed" <<<"$clean" \
  || { echo "FAIL: guest did not cleanly complete the sftp subsystem" >&2; ok=0; }
grep -qF "Remote working directory: /" "$SFTPOUT" \
  || { echo "FAIL: sftp pwd (REALPATH) did not resolve to /" >&2; ok=0; }
grep -qE "/readme\.txt( |\$)" "$SFTPOUT" \
  || { echo "FAIL: sftp ls / did not list readme.txt" >&2; ok=0; }
grep -qE "/bin( |\$)" "$SFTPOUT" \
  || { echo "FAIL: sftp ls / did not list the bin directory" >&2; ok=0; }
cmp -s "$DL_README" "$ROOT/base/readme.txt" \
  || { echo "FAIL: downloaded /readme.txt did not match base/readme.txt" >&2; ok=0; }
cmp -s "$DL_PASSWD" "$ROOT/base/etc/passwd" \
  || { echo "FAIL: downloaded /etc/passwd did not match base/etc/passwd" >&2; ok=0; }
cmp -s "$DL_SSHD" "$SSHD_ELF" \
  || { echo "FAIL: multi-chunk download of /bin/sshd did not match build/sshd.elf" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: sftp subsystem handshake, REALPATH, ls, stat, and byte-exact small + multi-chunk downloads over the SwiftOS host-key-pinned channel"
  exit 0
fi
echo "--- serial (sftp region) ---" >&2
grep -iE 'swos-init:|sshd:|login:|panic|abort|M7' <<<"$clean" | tail -60 >&2 || true
echo "--- sftp stdout ---" >&2
cat "$SFTPOUT" >&2
echo "--- sftp stderr ---" >&2
cat "$SFTPERR" >&2
exit 1
