#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# llm_smp_test.sh — LM2 acceptance: multi-thread matmul under -smp 4.
#
# Boots with S5g default multi-CPU EL0 placement, runs /bin/llm, and asserts:
#   - the matmul pool starts with more than one worker;
#   - greedy generation still matches the llama2.c golden story (bit-identical
#     int32 group dots + same fp32 path as the serial engine);
#   - a tokens/sec figure is reported.
#
# Requires AAVMF-free -kernel path, base image with /bin/llm + stories260K.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${LLM_RUN_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${LLM_RUN_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"

if [[ ! "$SMP_CPUS" =~ ^[0-9]+$ ]] || (( 10#$SMP_CPUS < 2 )); then
  echo "FAIL: SMP_CPUS must be >= 2 for LM2, got '$SMP_CPUS'." >&2
  exit 2
fi
SMP_CPU_COUNT=$((10#$SMP_CPUS))

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" || "$ROOT/userland/llm.swift" -nt "$DISK" ||
      "$ROOT/userland/lib/llama_matmul_pool.swift" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base.img" >&2
    exit 2
  }
fi

DTB="${SMP_DTB:-$ROOT/build/virt-smp-${SMP_CPU_COUNT}.dtb}"
if [[ -z "${SMP_DTB:-}" ]]; then
  tmp_dtb="$DTB.tmp"
  mkdir -p "$(dirname "$DTB")"
  "$QEMU" -M "virt,dumpdtb=$tmp_dtb" -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic >/dev/null 2>&1
  mv "$tmp_dtb" "$DTB"
elif [[ ! -f "$DTB" ]]; then
  echo "FAIL: SMP_DTB points to missing file: $DTB" >&2
  exit 2
fi

LOG="$(mktemp -t swiftos-llm-smp.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-llm-smp-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-llm-smp-in.XXXXXX)"
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

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (llm smp) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}


await() {
  local marker="$1" max="${2:-90}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# SMP demos (S5a–S5g) lengthen boot; give the tty demo generous time.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 60 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 180 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 180 || drive_fail "root shell did not start"

send_line '/bin/llm'
await "LM2: matmul pool workers=" 90 || drive_fail "LM2 pool banner missing"
await "llm: done" 360 || drive_fail "llm did not finish generating"

send_line 'echo BACK-IN-SHELL'
await "BACK-IN-SHELL" 60 || drive_fail "did not return to a working shell after llm"
exec 3>&-
stop_qemu
QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qF "S5g OK: default multi-CPU EL0 placement enabled" <<<"$CLEAN" \
  || fail "S5g permanent multi-CPU EL0 not enabled"
grep -qE "LM2: matmul pool workers=[2-9]" <<<"$CLEAN" \
  || fail "matmul pool did not start with multiple workers"
grep -qF "there was a little girl named Lily" <<<"$CLEAN" \
  || fail "generated story does not match the llama2.c reference"
grep -qF "She loved to play outside in the park" <<<"$CLEAN" \
  || fail "generated story diverged from reference"
grep -qE "llm: [0-9]+ tokens in [0-9]+ ms" <<<"$CLEAN" \
  || fail "tokens/timing line missing"
grep -qF "BACK-IN-SHELL" <<<"$CLEAN" || fail "did not return to a working shell"

if [[ "$ok" -eq 1 ]]; then
  WORKERS="$(grep -oE 'LM2: matmul pool workers=[0-9]+' <<<"$CLEAN" | head -1)"
  TPS="$(grep -oE '\([0-9]+ tok/s\)' <<<"$CLEAN" | head -1)"
  echo "PASS: LM2 multi-thread matmul under -smp $SMP_CPU_COUNT ($WORKERS) ${TPS:+$TPS}, golden output intact"
  exit 0
fi
echo "--- serial (llm smp region) ---" >&2
sed -n '/S5g OK:/,/BACK-IN-SHELL/p' <<<"$CLEAN" | head -100 >&2
exit 1
