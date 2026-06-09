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
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-calc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-calc-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-calc-in.XXXXXX)"; mkfifo "$INFIFO"
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

send_after() {  # send_after MARKER MAXSEC TEXT
  local marker="$1" max="$2" text="$3"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for marker: $marker" >&2
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -80 >&2
    exit 1
  fi
  printf '%b' "$text" >&3
}

send_line() {
  printf '%s\n' "$1" >&3
}

abort() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" | tail -80 >&2
  exit 1
}

# `printf '%s\n'` for every calc line so shell metacharacters (notably `%`) pass
# through verbatim.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

send_after "M7 tty: type a line then Enter" 60 'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 '\003'
send_after "swift-os login:" 60 'root\n'
send_after "Password:" 40 'swordfish\n'
send_after "Welcome to swift-os, root" 60 '/bin/calc\n'
send_after "swift-os calc" 60 ''

send_line '2+3*4'                 # precedence -> 14
await_line '= 14' 30 || abort "precedence result did not arrive"
send_line '(2+3)*4'               # parens -> 20
await_line '= 20' 30 || abort "parentheses result did not arrive"
send_line 'x = 10'                # assignment -> 10
await_line '= 10' 30 || abort "assignment result did not arrive"
send_line 'x*x'                   # variable lookup -> 100
await_line '= 100' 30 || abort "variable lookup result did not arrive"
send_line '17 % 5'                # modulo -> 2
await_line '= 2' 30 || abort "modulo result did not arrive"
send_line '-(3+4)*2'              # unary minus + precedence -> -14
await_line '= -14' 30 || abort "unary minus result did not arrive"
send_line '10 / 0'                # division by zero -> error
await 'error: division by zero' 30 || abort "division-by-zero result did not arrive"
send_line ':sum'                  # generic fold over history
await 'sum of 6 results:' 30 || abort ":sum result did not arrive"
send_line ':mem'                  # heap break A (after warmup)
await_regex_count 'heap break: [0-9]+' 1 30 || abort "first :mem result did not arrive"
for i in $(seq 1 24); do          # churn: build + drop an AST per line
  send_line '(1+2)*(3+4)-x'
  await_line_count '= 11' "$i" 30 || abort "churn result $i did not arrive"
done
send_line ':mem'                  # heap break B (must equal A)
await_regex_count 'heap break: [0-9]+' 2 30 || abort "second :mem result did not arrive"
send_line ':q'
await_line 'bye' 30 || abort "calc did not quit cleanly"
printf 'echo BACK-IN-SHELL\n' >&3
printf 'exit\n' >&3

# Wait for the shell marker that proves calc exited cleanly, then stop QEMU for
# log inspection.
CALC_TIMEOUT="${CALC_TIMEOUT:-300}"
returned=0
for _ in $(seq 1 "$CALC_TIMEOUT"); do
  if grep -qF "BACK-IN-SHELL" "$LOG"; then returned=1; break; fi
  sleep 1
done
if [[ "$returned" -eq 1 ]]; then
  sleep 1
fi
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
