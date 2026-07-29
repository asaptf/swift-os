#!/usr/bin/env bash
# kv_test.sh — acceptance for /bin/kv, the second idiomatic Embedded Swift EL0
# app on swift-os (an in-memory key-value store).
#
# Boots with the packed base image, logs in as root, runs /bin/kv and drives a
# scripted session that exercises the String/Unicode runtime on user input:
#   - SET / GET with a multi-word value (the value keeps interior spaces),
#   - GET / DEL of a missing key -> "(nil)",
#   - DEL of a present key, then COUNT,
#   - KEYS, which sorts arbitrary user keys (Unicode `Comparable`),
#   - :stats (a reduce/closure over Dictionary.values),
#   - a SET/DEL churn loop + two :mem readings, asserting the heap break does NOT
#     grow across many allocate/drop cycles (the bridge's free-capable allocator
#     actually frees; the old bump-forever allocator would grow monotonically).
# Finally it returns to the shell (proving a clean exit, no kernel panic).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${KV_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${KV_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-kv.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-kv-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-kv-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_line_count() {  # await_line_count LINE COUNT [MAXSEC]
  local line="$1" want="$2" max="${3:-30}" n=0 got=0
  while (( n < max * 10 )); do
    got="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -cxF -- "$line" || true)"
    (( got >= want )) && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_regex() {  # await_regex REGEX [MAXSEC]
  local regex="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -Eq -- "$regex" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_regex_count() {  # await_regex_count REGEX COUNT [MAXSEC]
  local regex="$1" want="$2" max="${3:-30}" n=0 got=0
  while (( n < max * 10 )); do
    got="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -Ec -- "$regex" || true)"
    (( got >= want )) && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (kv driver) ---" >&2
  local clean
  clean="$(sed 's/\r//' "$LOG" 2>/dev/null || true)"
  if grep -qF "swift-os login:" <<<"$clean"; then
    sed -n '/swift-os login:/,$p' <<<"$clean" >&2
  else
    tail -80 <<<"$clean" >&2
  fi
  exit 1
}


"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line '/bin/kv'
await "swift-os kv" 60 || drive_fail "kv did not start"

STEP_WAIT=180

send_line 'SET name swift os'
await_line_count "OK" 1 "$STEP_WAIT" || drive_fail "SET name did not acknowledge"
send_line 'GET name'
await_line_count "swift os" 1 "$STEP_WAIT" || drive_fail "GET name returned wrong value"
send_line 'GET missing'
await_line_count "(nil)" 1 "$STEP_WAIT" || drive_fail "GET missing did not report nil"
send_line 'SET zebra 1'
await_line_count "OK" 2 "$STEP_WAIT" || drive_fail "SET zebra did not acknowledge"
send_line 'SET apple 2'
await_line_count "OK" 3 "$STEP_WAIT" || drive_fail "SET apple did not acknowledge"
send_line 'COUNT'
await_line_count "3" 1 "$STEP_WAIT" || drive_fail "COUNT after three SETs was wrong"
send_line 'DEL missing'
await_line_count "(nil)" 2 "$STEP_WAIT" || drive_fail "DEL missing did not report nil"
send_line 'DEL zebra'
await_line_count "deleted" 1 "$STEP_WAIT" || drive_fail "DEL zebra did not report deleted"
send_line 'COUNT'
await_line_count "2" 1 "$STEP_WAIT" || drive_fail "COUNT after delete was wrong"
send_line 'KEYS'
await_line_count "apple" 1 "$STEP_WAIT" || drive_fail "KEYS did not list apple"
await_line_count "name" 1 "$STEP_WAIT" || drive_fail "KEYS did not list name"
send_line ':stats'
await "keys: 2, value bytes:" "$STEP_WAIT" || drive_fail ":stats did not report store stats"
send_line ':mem'
await_regex_count 'heap break: [0-9]+' 1 "$STEP_WAIT" || drive_fail "first :mem did not report heap break"
ok_want=3
deleted_want=1
for _ in $(seq 1 12); do
  send_line 'SET churn hello world'
  ok_want=$((ok_want + 1))
  await_line_count "OK" "$ok_want" "$STEP_WAIT" || drive_fail "churn SET did not acknowledge"
  send_line 'DEL churn'
  deleted_want=$((deleted_want + 1))
  await_line_count "deleted" "$deleted_want" "$STEP_WAIT" || drive_fail "churn DEL did not delete"
done
send_line ':mem'
await_regex_count 'heap break: [0-9]+' 2 "$STEP_WAIT" || drive_fail "second :mem did not report heap break"
send_line ':q'
await_line_count "bye" 1 "$STEP_WAIT" || drive_fail "kv did not exit"
send_line 'echo BACK-IN-SHELL'
await_line_count "BACK-IN-SHELL" 1 "$STEP_WAIT" || drive_fail "shell did not run after kv"
send_line 'exit'
await "M12c: session ended" 60 || drive_fail "shell did not exit cleanly"

exec 3>&-
stop_qemu
QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qF "swift-os kv" <<<"$CLEAN"             || fail "kv did not start"
grep -qxF "OK" <<<"$CLEAN"                      || fail "SET did not acknowledge"
grep -qxF "swift os" <<<"$CLEAN"                || fail "GET (multi-word value) wrong"
grep -qxF "(nil)" <<<"$CLEAN"                   || fail "GET/DEL of a missing key not reported"
grep -qxF "deleted" <<<"$CLEAN"                 || fail "DEL of a present key not reported"
grep -qxF "apple" <<<"$CLEAN"                   || fail "KEYS did not list keys"
grep -qF "keys: 2, value bytes:" <<<"$CLEAN"    || fail ":stats (reduce over values) wrong"
grep -qF "BACK-IN-SHELL" <<<"$CLEAN"            || fail "did not return to a working shell"

# COUNT reports 3 (after three SETs) then 2 (after a DEL), each on its own line.
grep -qxF "3" <<<"$CLEAN"                        || fail "COUNT after 3 sets wrong"
grep -qxF "2" <<<"$CLEAN"                        || fail "COUNT after a delete wrong"

# Bounded-heap proof: the two :mem readings must be identical (portable to
# bash 3.2 — no mapfile / negative indices).
BREAKS=()
while IFS= read -r b; do BREAKS+=("$b"); done < <(grep -oE 'heap break: [0-9]+' <<<"$CLEAN" | grep -oE '[0-9]+')
nbreaks="${#BREAKS[@]}"
if [[ "$nbreaks" -lt 2 ]]; then
  fail "expected two :mem readings, got $nbreaks"
else
  first="${BREAKS[0]}"; last="${BREAKS[$((nbreaks-1))]}"
  [[ "$first" == "$last" ]] || fail "heap grew under churn ($first -> $last); allocator is not freeing"
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/kv (Dictionary<String,String>/sort/reduce) works; heap bounded at ${BREAKS[0]} across churn"
  exit 0
fi
echo "--- serial (kv region) ---" >&2
sed -n '/swift-os kv/,$p' <<<"$CLEAN" >&2
exit 1
