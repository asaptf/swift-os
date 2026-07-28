#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# llm_run_test.sh — acceptance for /bin/llm, the native Embedded Swift CPU
# inference demo (I1 of the AI-hosting proof arc).
#
# Boots with the packed base image, logs in as root, runs /bin/llm (which reads
# the stories260K checkpoint + tok512 tokenizer from /models in the base image
# into anonymous mmap'd RAM and greedily generates text), and asserts:
#   - the generated story matches the llama2.c reference text (real inference,
#     end to end, as an isolated EL0 process on the OS), and
#   - a tokens/sec figure is reported (the engine ran and was timed),
# then returns to a working shell (clean exit, no kernel panic).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-llm.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-llm-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-llm-in.XXXXXX)"
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

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (llm driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${LLM_RUN_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${LLM_RUN_SEND_DELAY:-0.08}"
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3                       # Ctrl-C -> login (init) prompt
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

send_line '/bin/llm'
await "llm: stories260K" 60 || drive_fail "llm did not start / could not load the model"
# Generation runs scalar FP under TCG emulation; give it a generous budget.
await "llm: done" 300 || drive_fail "llm did not finish generating"

send_line 'echo BACK-IN-SHELL'
send_line 'exit'
await "BACK-IN-SHELL" 60 || drive_fail "did not return to a working shell after llm"
await "M12c: session ended" 60 || true
exec 3>&-
stop_qemu
QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qF "llm: stories260K" <<<"$CLEAN"                         || fail "llm banner missing"
# I2: weights came in via file-backed mmap, not a read-into-anonymous copy.
grep -qF "file-backed" <<<"$CLEAN"                              || fail "weights not loaded via file-backed mmap"
# I2b: demand paging engaged — the kernel serviced lazy page faults from disk.
grep -qF "demand-paged file mmap active" <<<"$CLEAN"            || fail "demand paging (I2b) did not engage"
# Real inference: the reference llama2.c text for the default prompt.
grep -qF "there was a little girl named Lily" <<<"$CLEAN"        || fail "generated story does not match the llama2.c reference output"
grep -qF "She loved to play outside in the park" <<<"$CLEAN"     || fail "generated story diverged from reference"
# Throughput was measured and reported.
grep -qE "llm: [0-9]+ tokens in [0-9]+ ms" <<<"$CLEAN"           || fail "tokens/timing line missing"
grep -qF "BACK-IN-SHELL" <<<"$CLEAN"                            || fail "did not return to a working shell"

if [[ "$ok" -eq 1 ]]; then
  TPS="$(grep -oE '\([0-9]+ tok/s\)' <<<"$CLEAN" | head -1)"
  echo "PASS: /bin/llm ran stories260K inference end-to-end in QEMU, output matches llama2.c reference ${TPS:+($TPS)}"
  exit 0
fi
echo "--- serial (llm region) ---" >&2
sed -n '/llm: stories260K/,$p' <<<"$CLEAN" | head -80 >&2
exit 1
