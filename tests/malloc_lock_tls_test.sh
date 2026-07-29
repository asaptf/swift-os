#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# malloc_lock_tls_test.sh — guard the malloc ↔ emulated-TLS recursion fix.
#
# Guarantee this test enforces (and why):
#   1. Source: stubs.c must not declare the malloc lock depth as `__thread`.
#      That is the exact construct GCC lowers to libgcc emutls on aarch64-elf,
#      which allocates with malloc and recurses on the first lock.
#   2. Shipped busybox.elf must not define `__emutls_v.malloc_lock_depth`, and
#      its `__malloc_lock` must not call `__emutls_get_address`. Busybox is the
#      login shell that nightly SMP stress runs; an empty TLS PHDR made this
#      the production failure path.
#   3. Compiled n_compat_stubs.o: `__malloc_lock` reads `tpidr_el0` (TCB slot),
#      not a TLS-reloc / emutls path — covers every newlib-linked probe/app.
#   4. Runtime under -smp 4: login shell starts (first busybox malloc) and
#      /bin/malloclockprobe completes first + concurrent thread mallocs.
#      Proves the per-thread depth still works under SMP (the property a
#      global owner-cache design lost).
#
# This is not a tautology: each check fails if someone reintroduces __thread
# depth, ships an emutls busybox, or breaks the TCB-slot lock under workers.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${MLOCK_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${MLOCK_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
STUBS_SRC="$ROOT/userland/compat/stubs.c"
BUSYBOX="$ROOT/build/busybox.elf"
STUBS_OBJ="$ROOT/build/n_compat_stubs.o"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-4}"
DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
NM="${NM:-aarch64-elf-nm}"
OBJDUMP="${OBJDUMP:-aarch64-elf-objdump}"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "$STUBS_SRC" ]] || fail "$STUBS_SRC missing"
[[ -f "$KERNEL" ]] || fail "$KERNEL missing (make build)"
[[ -f "$BUSYBOX" ]] || fail "$BUSYBOX missing (make busybox)"

# --- 1. Source: no __thread malloc lock depth --------------------------------
if grep -nE 'static[[:space:]]+__thread[[:space:]]+unsigned[[:space:]]+int[[:space:]]+malloc_lock_depth' \
    "$STUBS_SRC" >/dev/null; then
  fail "stubs.c reintroduced __thread malloc_lock_depth (emutls recursion risk)"
fi
if ! grep -q 'SWOS_TCB_MALLOC_DEPTH_OFF' "$STUBS_SRC"; then
  fail "stubs.c missing TCB-slot depth marker SWOS_TCB_MALLOC_DEPTH_OFF"
fi
echo "malloc_lock_tls: source OK (no __thread depth; TCB slot present)"

# --- 2. busybox.elf binary: no emutls control for the depth counter ----------
if ! command -v "$NM" >/dev/null 2>&1; then
  fail "$NM not found"
fi
bb_syms="$("$NM" "$BUSYBOX" 2>/dev/null || true)"
if grep -qE ' __emutls_v\.malloc_lock_depth$' <<<"$bb_syms"; then
  fail "busybox.elf defines __emutls_v.malloc_lock_depth (malloc↔emutls cycle)"
fi
if command -v "$OBJDUMP" >/dev/null 2>&1; then
  bb_mlock="$("$OBJDUMP" -d "$BUSYBOX" 2>/dev/null | sed -n '/<__malloc_lock>:/,/^$/p')"
  if grep -q '__emutls_get_address' <<<"$bb_mlock"; then
    fail "busybox __malloc_lock calls __emutls_get_address"
  fi
  if ! grep -qE 'mrs[[:space:]].*tpidr_el0' <<<"$bb_mlock"; then
    fail "busybox __malloc_lock does not read tpidr_el0"
  fi
fi
echo "malloc_lock_tls: busybox.elf OK (no emutls depth; tpidr depth path)"

# --- 3. n_compat_stubs.o: same property for Makefile-built userland ----------
if [[ ! -f "$STUBS_OBJ" ]]; then
  ( cd "$ROOT" && make build/n_compat_stubs.o ) >/dev/null 2>&1 || fail "cannot build n_compat_stubs.o"
fi
stubs_syms="$("$NM" "$STUBS_OBJ" 2>/dev/null || true)"
if grep -qE ' __emutls_v\.malloc_lock_depth$| malloc_lock_depth$' <<<"$stubs_syms"; then
  # TLS or emutls symbol named malloc_lock_depth must not exist after the fix.
  if grep -qE ' __emutls_v\.malloc_lock_depth$' <<<"$stubs_syms" ||
     "$NM" -S "$STUBS_OBJ" 2>/dev/null | grep -qE '[[:space:]]TLS[[:space:]].*malloc_lock_depth'; then
    fail "n_compat_stubs.o still has TLS/emutls malloc_lock_depth"
  fi
fi
if command -v "$OBJDUMP" >/dev/null 2>&1; then
  st_mlock="$("$OBJDUMP" -d "$STUBS_OBJ" 2>/dev/null | sed -n '/<__malloc_lock>:/,/^$/p')"
  if grep -q '__emutls_get_address' <<<"$st_mlock"; then
    fail "n_compat_stubs __malloc_lock calls __emutls_get_address"
  fi
  if ! grep -qE 'mrs[[:space:]].*tpidr_el0' <<<"$st_mlock"; then
    fail "n_compat_stubs __malloc_lock does not read tpidr_el0"
  fi
fi
echo "malloc_lock_tls: n_compat_stubs.o OK (tpidr TCB-slot path)"

# --- 4. Runtime under SMP: shell + concurrent malloc probe -------------------
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || fail "cannot build base.img"
fi
if [[ ! -f "$DTB" && "$SMP_CPUS" == "4" ]]; then
  ( cd "$ROOT" && make build/virt-smp4.dtb ) >/dev/null 2>&1 || fail "cannot build virt-smp4.dtb"
fi

LOG="$(mktemp -t swiftos-mlock.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-mlock-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-mlock-in.XXXXXX)"; mkfifo "$INFIFO"
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

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    if grep -qE 'EL0 fault|SIGSEGV|signal 0xb|__emutls_get_address' "$LOG" 2>/dev/null; then
      # Fault during boot/login before our markers is the historic failure mode.
      if ! grep -qF "$marker" "$LOG" 2>/dev/null; then
        return 3
      fi
    fi
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (malloc lock tls) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}


"$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPUS" -m 256M -nographic -no-reboot \
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
await "M7 tty: running; press Ctrl-C" 60 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt (busybox first-malloc?)"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
# Login shell is busybox ash — starting it is the first-malloc acceptance for
# the shipped binary that linked the compat stubs.
rc=0
await "M12c: shell ready" 120 || rc=$?
if [[ "$rc" -eq 3 ]]; then
  drive_fail "EL0 fault during login (malloc↔emutls recursion likely)"
elif [[ "$rc" -ne 0 ]]; then
  drive_fail "root shell did not start"
fi
send_line '/bin/malloclockprobe'
rc=0
await "MALLOCLOCKPROBE-OK" 120 || rc=$?
if [[ "$rc" -eq 3 ]]; then
  drive_fail "EL0 fault during malloclockprobe"
elif [[ "$rc" -ne 0 ]]; then
  drive_fail "/bin/malloclockprobe did not report success"
fi
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
if grep -qE 'malloclockprobe: FAIL' <<<"$clean"; then
  echo "FAIL: malloclockprobe assertion failed:" >&2
  grep -F 'malloclockprobe: FAIL' <<<"$clean" >&2
  exit 1
fi
if grep -qE 'EL0 fault|__emutls_get_address' <<<"$clean"; then
  # Allow el0_fault_backtrace tests elsewhere; this run must stay clean.
  if ! grep -qF 'MALLOCLOCKPROBE-OK' <<<"$clean"; then
    fail "unexpected EL0 fault / emutls during malloc lock probe run"
  fi
fi
for marker in "MALLOCLOCK-FIRST-OK" "MALLOCLOCK-THREADS-OK" "MALLOCLOCKPROBE-OK"; do
  grep -qF "$marker" <<<"$clean" || fail "missing marker $marker"
done

echo "PASS: malloc_lock_tls_test (source + busybox binary + SMP runtime)"
exit 0
