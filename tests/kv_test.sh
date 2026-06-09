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
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

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

await_line() {  # await_line LINE [MAXSEC]
  local line="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -qxF -- "$line" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_line_count() {  # await_line_count LINE COUNT [MAXSEC]
  local line="$1" want="$2" max="${3:-30}" n=0 seen=0
  while (( n < max * 10 )); do
    seen="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -cxF -- "$line" || true)"
    [[ "$seen" -ge "$want" ]] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_regex_count() {  # await_regex_count REGEX COUNT [MAXSEC]
  local regex="$1" want="$2" max="${3:-30}" n=0 seen=0
  while (( n < max * 10 )); do
    seen="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -Ec -- "$regex" || true)"
    [[ "$seen" -ge "$want" ]] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

send_text() {  # send_text TEXT
  local text="$1" i
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}" >&3 || return 1
    sleep 0.02
  done
}

send_after() {  # send_after MARKER MAXSEC TEXT
  local marker="$1" max="$2" text="$3"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for marker: $marker" >&2
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -80 >&2
    exit 1
  fi
  send_text "$text"
}

send_line() {
  send_text "$1"$'\n'
}

abort() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" | tail -80 >&2
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

send_after "M7 tty: type a line then Enter" 60 $'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 $'\003'
send_after "swift-os login:" 60 $'root\n'
send_after "Password:" 40 $'swordfish\n'
send_after "Welcome to swift-os, root" 60 $'/bin/kv\n'
send_after "swift-os kv" 60 ''

send_line 'SET name swift os'             # multi-word value
await_line_count 'OK' 1 30 || abort "SET name did not acknowledge"
send_line 'GET name'                      # -> "swift os"
await_line 'swift os' 30 || abort "GET name result did not arrive"
send_line 'GET missing'                   # -> "(nil)"
await_line_count '(nil)' 1 30 || abort "GET missing result did not arrive"
send_line 'SET zebra 1'
await_line_count 'OK' 2 30 || abort "SET zebra did not acknowledge"
send_line 'SET apple 2'
await_line_count 'OK' 3 30 || abort "SET apple did not acknowledge"
send_line 'COUNT'                         # -> 3
await_line '3' 30 || abort "COUNT after 3 sets did not arrive"
send_line 'DEL missing'                   # -> "(nil)"
await_line_count '(nil)' 2 30 || abort "DEL missing result did not arrive"
send_line 'DEL zebra'                     # -> "deleted"
await_line_count 'deleted' 1 30 || abort "DEL zebra result did not arrive"
send_line 'COUNT'                         # -> 2
await_line '2' 30 || abort "COUNT after delete did not arrive"
send_line 'KEYS'                          # sorted: apple, name
await_line 'apple' 30 || abort "KEYS apple result did not arrive"
await_line 'name' 30 || abort "KEYS name result did not arrive"
send_line ':stats'                        # keys + value bytes
await 'keys: 2, value bytes:' 30 || abort ":stats result did not arrive"
send_line ':mem'                          # heap break A (after warmup)
await_regex_count 'heap break: [0-9]+' 1 30 || abort "first :mem result did not arrive"
for i in $(seq 1 12); do                  # churn: set then delete a key
  send_line 'SET churn hello world'
  await_line_count 'OK' "$((3 + i))" 30 || abort "churn SET $i did not acknowledge"
  send_line 'DEL churn'
  await_line_count 'deleted' "$((1 + i))" 30 || abort "churn DEL $i did not arrive"
done
send_line ':mem'                          # heap break B (must equal A)
await_regex_count 'heap break: [0-9]+' 2 30 || abort "second :mem result did not arrive"
send_line ':q'
await_line 'bye' 30 || abort "kv did not quit cleanly"
send_line "echo BACK''-IN-SHELL"
await_line 'BACK-IN-SHELL' 30 || abort "shell did not run after kv"
send_line 'exit'
await 'M12c: session ended' 30 || abort "shell did not exit cleanly"
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
