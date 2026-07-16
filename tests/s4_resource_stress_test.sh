#!/usr/bin/env bash
# s4_resource_stress_test.sh - S4f restricted-SMP resource churn smoke.
#
# Boots with -smp 4, keeps the usual SMP/timer scaffolding live, then runs the
# /bin/s4stress userland workload through the normal console-login path.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-180}"

if [[ ! "$SMP_CPUS" =~ ^[0-9]+$ ]] || (( 10#$SMP_CPUS < 1 )); then
  echo "FAIL: SMP_CPUS must be a positive integer, got '$SMP_CPUS'." >&2
  exit 2
fi
SMP_CPU_COUNT=$((10#$SMP_CPUS))
if (( SMP_CPU_COUNT < 2 )); then
  echo "FAIL: S4f resource stress expects at least 2 CPUs, got '$SMP_CPUS'." >&2
  exit 2
fi
if (( SMP_CPU_COUNT > 8 )); then
  echo "FAIL: SMP_CPUS must be <= 8 for current SMP scaffolding, got '$SMP_CPUS'." >&2
  exit 2
fi

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
# Dedicated image with /bin/s4stress as root's login shell — avoids interactive
# busybox ash after console-login, which faults on aarch64 Linux CI before any
# typed command runs (see tests/log_export_test.sh / tls_truststore_test.sh).
DISK="$ROOT/build/base-s4stress.img"
if [[ ! -f "$DISK" || "$ROOT/userland/s4stress.c" -nt "$DISK" || "$ROOT/Makefile" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make BASE_IMG="$DISK" ROOT_LOGIN_SHELL=/bin/s4stress base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base-s4stress.img" >&2
    exit 2
  }
fi

LOG="$(mktemp -t swiftos-s4f.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-s4f-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-s4f-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    if grep -qF "panic:" "$LOG" 2>/dev/null; then
      return 2
    fi
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (S4f resource stress) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${S4F_CHAR_DELAY:-0.02}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${S4F_SEND_DELAY:-0.12}"
}

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

"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Login only — s4stress is the login shell and runs immediately after auth.
await "M7 tty: type a line then Enter" "$TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M11d: exec loaded from disk /bin/s4stress" 90 || drive_fail "s4stress did not execute"
await "S4F-OK resource stress completed" 180 || drive_fail "s4stress did not finish"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in \
  "[I] smp: S2a OK: per-CPU timer heartbeat ready detail=$SMP_CPU_COUNT" \
  "[I] smp: S4e OK: network lock boundary stayed balanced" \
  "S4F-ALLOC-OK" \
  "S4F-PIPE-OK" \
  "S4F-TMPFS-OK" \
  "S4F-FORK-OK" \
  "S4F-SPAWN-OK" \
  "S4F-OK resource stress completed"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; ok=0; }
done
grep -qF "S4F-FAIL" <<<"$clean" && { echo "FAIL: s4stress reported a failure" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic seen during S4f stress" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: S4f resource stress exercised alloc/pipe/tmpfs/fork/spawn under -smp $SMP_CPU_COUNT"
  exit 0
fi
echo "--- serial (S4f resource stress region) ---" >&2
sed -n '/\/bin\/s4stress/,$p' <<<"$clean" | head -80 >&2
exit 1
