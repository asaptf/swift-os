#!/usr/bin/env bash
# calc_test.sh — acceptance for /bin/calc, the first idiomatic Embedded Swift
# EL0 app on swift-os.
#
# Boots with the packed base image, logs in as root, runs /bin/calc and drives a
# scripted REPL session that exercises the high-level runtime end to end:
#   - operator precedence and parentheses (recursive-descent parser + AST),
#   - variable assignment and lookup (class Env + Dictionary<String,Int64>),
#   - unary minus, modulo, and a division-by-zero error,
#   - :sum (a generic fold taking a closure over the result history),
#   - a churn loop + :mem, asserting the heap break does NOT grow across many
#     allocate/drop cycles — i.e. the bridge's new free-capable allocator
#     actually frees (the old bump-forever allocator would grow monotonically).
# Finally it returns to the shell (proving a clean exit, no kernel panic).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${CALC_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${CALC_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-calc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-calc-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-calc-in.XXXXXX)"
mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_line() {  # await_line LINE [MAXSEC]
  local line="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -qxF -- "$line" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_line_count() {  # await_line_count LINE COUNT [MAXSEC]
  local line="$1" want="$2" max="${3:-60}" n=0 seen=0
  while (( n < max * 10 )); do
    seen="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -cxF -- "$line" || true)"
    [[ "$seen" -ge "$want" ]] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_regex_count() {  # await_regex_count REGEX COUNT [MAXSEC]
  local regex="$1" want="$2" max="${3:-60}" n=0 seen=0
  while (( n < max * 10 )); do
    seen="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -Ec -- "$regex" || true)"
    [[ "$seen" -ge "$want" ]] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (calc driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}


# Pace calc input through the emulated serial line; burst writes can overflow
# the guest-side path and silently drop bytes.
if [[ -f "$DTB" ]]; then
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
    -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
else
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
fi
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
printf 'tty-line\n' >&3                 # M7 ttydemo
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3                       # Ctrl-C -> login (init) prompt
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
printf 'root\n' >&3
await "Password:" 90 || drive_fail "password prompt did not appear"
printf 'swordfish\n' >&3
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
printf '/bin/calc\n' >&3
await "swift-os calc" 120 || drive_fail "calc did not start"
await "for commands" 30 || drive_fail "calc prompt did not become ready"

send_line '2+3*4'                 # precedence -> 14
await_line '= 14' 90 || drive_fail "precedence result did not arrive"
send_line '(2+3)*4'               # parens -> 20
await_line '= 20' 90 || drive_fail "parentheses result did not arrive"
send_line 'x = 10'                # assignment -> 10
await_line '= 10' 90 || drive_fail "assignment result did not arrive"
send_line 'x*x'                   # variable lookup -> 100
await_line '= 100' 90 || drive_fail "variable lookup result did not arrive"
send_line '17 % 5'                # modulo -> 2
await_line '= 2' 90 || drive_fail "modulo result did not arrive"
send_line '-(3+4)*2'              # unary minus + precedence -> -14
await_line '= -14' 90 || drive_fail "unary minus result did not arrive"
send_line '10 / 0'                # division by zero -> error
await 'error: division by zero' 90 || drive_fail "division-by-zero result did not arrive"
send_line ':sum'                  # generic fold over history
await 'sum of 6 results:' 90 || drive_fail ":sum result did not arrive"
send_line ':mem'                  # heap break A (after warmup)
await_regex_count 'heap break: [0-9]+' 1 90 || drive_fail "first :mem result did not arrive"
for i in $(seq 1 24); do          # churn: build + drop an AST per line
  send_line '(1+2)*(3+4)-x'
  await_line_count '= 11' "$i" 90 || drive_fail "churn result $i did not arrive"
done
send_line ':mem'                  # heap break B (must equal A)
await_regex_count 'heap break: [0-9]+' 2 90 || drive_fail "second :mem result did not arrive"
send_line ':q'
await_line 'bye' 90 || drive_fail "calc did not quit cleanly"
printf 'echo BACK-IN-SHELL\n' >&3
printf 'exit\n' >&3

await "BACK-IN-SHELL" 180 || drive_fail "did not return to a working shell"
await "M12c: session ended" 60 || true
exec 3>&-
stop_qemu
QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qF "swift-os calc" <<<"$CLEAN"          || fail "calc did not start"
grep -qxF "= 14" <<<"$CLEAN"                   || fail "precedence (2+3*4) wrong"
grep -qxF "= 20" <<<"$CLEAN"                   || fail "parentheses ((2+3)*4) wrong"
grep -qxF "= 100" <<<"$CLEAN"                  || fail "variable assignment/lookup (x*x) wrong"
grep -qxF "= 2" <<<"$CLEAN"                    || fail "modulo (17 % 5) wrong"
grep -qxF "= -14" <<<"$CLEAN"                  || fail "unary minus (-(3+4)*2) wrong"
grep -qF "error: division by zero" <<<"$CLEAN" || fail "division by zero not reported"
grep -qF "sum of 6 results:" <<<"$CLEAN"       || fail ":sum (generic fold) wrong"
grep -qF "BACK-IN-SHELL" <<<"$CLEAN"           || fail "did not return to a working shell"

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
  echo "PASS: /bin/calc REPL (ARC/AST/Dictionary/generics) works; heap bounded at ${BREAKS[0]} across churn"
  exit 0
fi
echo "--- serial (calc region) ---" >&2
sed -n '/swift-os calc/,$p' <<<"$CLEAN" >&2
exit 1
