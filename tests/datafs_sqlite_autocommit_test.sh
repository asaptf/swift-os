#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# datafs_sqlite_autocommit_test.sh — regression for D3 "readonly database".
#
# Diagnosis (fix/datafs-open-race): the CI failure was NOT an intermittent
# datafs open/create race. Every /data primitive (O_RDWR open, create, ftruncate,
# fcntl lock, fsync) already worked; one SQLite write with BEGIN EXCLUSIVE
# succeeded in the same boot as two autocommit writes that failed with
# "attempt to write a readonly database".
#
# Root cause: _fstat/_stat left st_ino/st_dev as stack garbage. SQLite's unix
# VFS stores st_ino at open (findInodeInfo) and later re-stats the path via
# SQLITE_FCNTL_HAS_MOVED when re-opening the rollback journal between
# autocommit transactions. Mismatched garbage → SQLITE_READONLY_DBMOVED, whose
# user-facing message is the same "attempt to write a readonly database" as a
# true O_RDWR open fallback. BEGIN EXCLUSIVE packs CREATE+INSERT into one
# transaction (journal opened once while dbSize==0, which skips the check),
# so it passed; plain "create; insert" re-opens the journal and failed.
#
# This harness is the deterministic reproduction: default journal mode, two
# autocommit statements, no BEGIN EXCLUSIVE. It must stay green.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

MARK="AUTOCOMMIT-SQLITE-MARK-3k9p"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-sqlite-ac.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-sqlite-ac-pid.XXXXXX)"
QP=""; CURLOG=""

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=32 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""
  exec 3>&- 2>/dev/null || true
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.2; }

fail() {
  echo "FAIL: $1" >&2
  echo "--- probe values ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | grep -E '^[A-Z0-9-]+(-rc)?=' >&2 || true
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | tail -40 >&2 || true
  exit 1
}

start_boot() {
  local log="$1" fifo="$2"
  rm -f "$fifo"; mkfifo "$fifo"
  CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    ${dtb_args[@]+"${dtb_args[@]}"} \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!
  exec 3<>"$fifo"
}

login() {
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'
  await "Password:" 90 || fail "no password prompt"
  send 'swordfish'
  await "Welcome to swift-os, root" 120 || fail "root login did not complete"
}

start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted"
login

# The exact failing sequence from D3 probes: default DELETE journal, two
# autocommit statements (CREATE then INSERT), no BEGIN EXCLUSIVE.
send "sqlite3 /data/ac.db \"create table t(x text); insert into t values('$MARK');\""
send 'echo AUTOCOMMIT-WROTE-rc=$?'
await "AUTOCOMMIT-WROTE-rc=0" 60 || fail "autocommit create/insert did not exit 0 (SQLITE_READONLY_DBMOVED regression)"

# Second connection: prove the row is durable within the same boot (and that
# re-open of an existing non-empty DB still works).
send 'sqlite3 /data/ac.db "select * from t;"'
await "$MARK" 60 || fail "SELECT did not return the autocommit-written row"

send 'exit'
sleep 0.3
stop_qemu

echo "PASS: SQLite autocommit create+insert on /data (D3 readonly regression)"
exit 0
