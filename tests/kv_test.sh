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
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 7;  printf 'tty-line\n'             # M7 ttydemo
  sleep 1;  printf '\003'                   # Ctrl-C -> login (init) prompt
  sleep 2;  printf 'root\n'
  sleep 1;  printf 'swordfish\n'
  sleep 2;  printf '/bin/kv\n'
  sleep 2;  printf '%s\n' 'SET name swift os'   # multi-word value
  sleep 1;  printf '%s\n' 'GET name'            # -> "swift os"
  sleep 1;  printf '%s\n' 'GET missing'         # -> "(nil)"
  sleep 1;  printf '%s\n' 'SET zebra 1'
  sleep 1;  printf '%s\n' 'SET apple 2'
  sleep 1;  printf '%s\n' 'COUNT'               # -> 3
  sleep 1;  printf '%s\n' 'DEL missing'         # -> "(nil)"
  sleep 1;  printf '%s\n' 'DEL zebra'           # -> "deleted"
  sleep 1;  printf '%s\n' 'COUNT'               # -> 2
  sleep 1;  printf '%s\n' 'KEYS'                # sorted: apple, name
  sleep 1;  printf '%s\n' ':stats'              # keys + value bytes
  sleep 1;  printf '%s\n' ':mem'                # heap break A (after warmup)
  for _ in $(seq 1 12); do                      # churn: set then delete a key
    sleep 0.25; printf '%s\n' 'SET churn hello world'
    sleep 0.25; printf '%s\n' 'DEL churn'
  done
  sleep 1;  printf '%s\n' ':mem'                # heap break B (must equal A)
  sleep 1;  printf '%s\n' ':q'
  sleep 1;  printf 'echo BACK-IN-SHELL\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 75
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
