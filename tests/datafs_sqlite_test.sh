#!/usr/bin/env bash
# datafs_sqlite_test.sh — D3 acceptance: a SQLite database on /data survives reboot.
#
# The headline of the persistent-storage arc. Boots the base image (with the
# baked-in sqlite3 shell) plus a writable data disk, logs in, creates a table and
# inserts a row into /data/app.db, then reboots against the SAME data disk and
# SELECTs the row back. SQLite uses a rollback journal (SQLITE_OMIT_WAL), so this
# exercises create/write/lseek/fstat/fcntl-locks/fsync/unlink on datafs end to end.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

MARK="DURABLE-SQLITE-MARK-7q2z"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-sqlite.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-sqlite-pid.XXXXXX)"
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

await() {  # await MARKER [MAXSEC]
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
  # Probe values print well before the failure, so a plain tail loses them.
  echo "--- probe values ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | grep -E '^[A-Z0-9-]+(-rc)?=' >&2 || true
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | tail -40 >&2 || true
  exit 1
}

start_boot() {  # start_boot LOGFILE INFIFO
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
  await_shell_ready "$CURLOG" 60 || fail "guest shell not reading after login"
}

# ---- Boot 1: create the database under /data -------------------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 1)"
login
# Probe /data writability before involving SQLite. "attempt to write a readonly
# database" is ambiguous on its own — it looks the same whether the datafs mount
# is missing (so /data resolves to the read-only base image), the volume is full,
# or SQLite itself cannot create its journal / lock / truncate. Each probe prints
# its own greppable rc= line so a CI failure names the missing capability without
# another round trip. Verdicts below are unchanged: only SQLITE-WROTE must be 0.
send 'touch /data/.wprobe; echo DATA-WPROBE-rc=$?'
await "DATA-WPROBE-rc=0" 30 || fail "/data is not writable before sqlite (mount or permissions)"
# SQLite's "readonly database" is set when the pager opens RO: unixOpen tries
# open(O_RDWR[|O_CREAT]), and on failure silently falls back to O_RDONLY.
# touch is O_WRONLY|O_CREAT, so it never exercises that RDWR path.
#
# access(W_OK) note: the image has no test(1)/[ applet (CONFIG_TEST and
# CONFIG_ASH_TEST both off), so `test -w` is not available. SQLite's own
# xAccess(READWRITE) → access(W_OK|R_OK) is only used for PRAGMA
# temp_store_directory (not for opening the main DB). Our libc access() is
# also a mode-ignoring stat stub (userland/compat/stubs.c). ACCESS-W-DIR
# therefore goes through SQLite's real xAccess path; ACCESS-W-FILE uses
# ls/stat on the file (same backend as the access stub). OPEN-RDWR-* is the
# actual RO-fallback path. Greppable only; verdicts below are unchanged.
send "sqlite3 :memory: \"pragma temp_store_directory='/data';\""
send 'echo ACCESS-W-DIR-rc=$?'
await "ACCESS-W-DIR-rc=" 30 || true   # diagnostic only: never gate the verdict
send 'ls /data/.wprobe; echo ACCESS-W-FILE-rc=$?'
await "ACCESS-W-FILE-rc=" 30 || true   # diagnostic only: never gate the verdict
# Await the expected VALUE, not just the prefix. These two are the RO-fallback
# path SQLite actually takes, so a non-zero rc is the answer we are hunting —
# it has to fail the test by name here. Waiting only for the prefix hid the
# values, because fail() dumps just the serial tail and by then they had
# scrolled away.
send 'exec 9<> /data/.wprobe; echo OPEN-RDWR-EXISTING-rc=$?; exec 9>&-'
await "OPEN-RDWR-EXISTING-rc=0" 30 || fail "open(O_RDWR) on an existing /data file failed — SQLite's pager falls back to read-only here"
send 'rm -f /data/.rdwrnew; exec 9<> /data/.rdwrnew; echo OPEN-RDWR-CREATE-rc=$?; exec 9>&-'
await "OPEN-RDWR-CREATE-rc=0" 30 || fail "open(O_RDWR|O_CREAT) on a new /data file failed — this is how SQLite creates the database"
send 'echo LS-DATA=$(ls -ld /data)'
await "LS-DATA=" 30 || true   # diagnostic only: never gate the verdict
send 'echo LS-FILE=$(ls -l /data/.wprobe)'
await "LS-FILE=" 30 || true   # diagnostic only: never gate the verdict
# Exact rollback-journal name SQLite will open next to /data/app.db.
send 'touch /data/app.db-journal; echo JOURNAL-CREATE-rc=$?'
await "JOURNAL-CREATE-rc=" 30 || true   # diagnostic only: never gate the verdict
send 'rm -f /data/app.db-journal'
# Write with journalling disabled — if this works, the failure is not generic
# file create/write; it is something the default DELETE journal path needs.
send "sqlite3 /data/.nojprobe.db \"pragma journal_mode=off; create table t(x); insert into t values(1);\""
send 'echo SQLITE-NOJRNL-rc=$?'
await "SQLITE-NOJRNL-rc=" 60 || true   # diagnostic only: never gate the verdict
# ftruncate path: write non-empty, then O_TRUNC to zero (same datafsTruncate
# backend as SYS_FTRUNCATE for length 0 on datafs).
send 'printf xxxx > /data/.truncprobe; : > /data/.truncprobe; echo FTRUNCATE-rc=$?'
await "FTRUNCATE-rc=" 30 || true   # diagnostic only: never gate the verdict
# fcntl advisory lock: BEGIN EXCLUSIVE with journal_mode=off still takes a
# POSIX lock via F_SETLK without needing the rollback journal file.
send "sqlite3 /data/.lockprobe.db \"pragma journal_mode=off; begin exclusive; create table t(x); insert into t values(1); commit;\""
send 'echo FCNTL-LOCK-rc=$?'
await "FCNTL-LOCK-rc=" 60 || true   # diagnostic only: never gate the verdict
send "sqlite3 /data/app.db \"create table t(x text); insert into t values('$MARK');\""
send 'echo SQLITE-WROTE-rc=$?'
await "SQLITE-WROTE-rc=0" 60 || fail "sqlite3 create/insert did not exit 0 (boot 1)"
send 'exit'
sleep 0.5
stop_qemu

# ---- Boot 2: same data disk, SELECT the row back ---------------------------
start_boot "$WORK/boot2.log" "$WORK/in2"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 2)"
login
send 'sqlite3 /data/app.db "select * from t;"'
await "$MARK" 60 || fail "row did NOT survive reboot — SELECT returned no '$MARK'"
send 'exit'
sleep 0.3
stop_qemu

echo "PASS: SQLite database on /data survived reboot (D3 acceptance)"
exit 0
