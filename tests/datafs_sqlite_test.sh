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
}

# ---- Boot 1: create the database under /data -------------------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 1)"
login
# Probe /data writability before involving SQLite. "attempt to write a readonly
# database" is ambiguous on its own — it looks the same whether the datafs mount
# is missing (so /data resolves to the read-only base image), the volume is full,
# or SQLite itself cannot create its journal. This separates them in the log.
send 'touch /data/.wprobe; echo DATA-WPROBE-rc=$?'
await "DATA-WPROBE-rc=0" 30 || fail "/data is not writable before sqlite (mount or permissions)"
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
