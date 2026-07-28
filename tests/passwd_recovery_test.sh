#!/usr/bin/env bash
# passwd_recovery_test.sh — K4 acceptance: boot-flag recovery mode.
#
# When the credential overlay on /data has locked an operator out (or fails
# closed after corruption/rollback), booting with the recovery flag in the kernel
# command line (FDT /chosen/bootargs "swos.recovery=1") makes console-login and
# passwd authenticate against the read-only BASE store only — bypassing the
# overlay — so the operator can log in with the factory credentials and
# re-provision. Without the flag the overlay stays authoritative.
#
# Four boots over one persistent data disk:
#   1 (normal):   log in user/swordfish (default), change it to s3cret.
#   2 (normal):   swordfish rejected, s3cret works  (overlay is authoritative).
#   3 (RECOVERY): recovery banner shown; the FACTORY password swordfish works
#                 again (overlay bypassed); re-provision to "rescued".
#   4 (normal):   rescued works, swordfish rejected  (store repaired normally).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
RDTB="$ROOT/build/virt-recovery.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
ITERS="${PASSWD_TEST_ITERS:-4096}"
MAX_BOOTS="${PASSWD_TEST_BOOTS:-5}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
[[ -f "$DTB" ]]    || { echo "FAIL: $DTB missing (make build/virt.dtb)" >&2; exit 2; }

# Build the recovery DTB (plain virt.dtb + /chosen/bootargs="swos.recovery=1").
if [[ ! -f "$RDTB" ]]; then
  command -v dtc >/dev/null || { echo "FAIL: dtc not installed (needed to build the recovery DTB)" >&2; exit 2; }
  dtc -I dtb -O dts "$DTB" 2>/dev/null \
    | awk '/chosen \{/{print; print "\t\tbootargs = \"swos.recovery=1\";"; next} {print}' \
    | dtc -I dts -O dtb 2>/dev/null > "$RDTB"
  strings "$RDTB" | grep -q swos.recovery || { echo "FAIL: could not bake recovery flag into DTB" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-recov.XXXXXX)"
DATA_IMG="$WORK/data.img"
dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

LOG=""; INFIFO=""; PIDFILE=""; QP=""
cleanup_boot() {
  exec 3>&- 2>/dev/null || true
  if [[ -n "$PIDFILE" && -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  rm -f "$PIDFILE" "$INFIFO" 2>/dev/null || true
}
trap 'cleanup_boot; rm -rf "$WORK" 2>/dev/null || true' EXIT

await() { local m="$1" max="${2:-30}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
await_count() { local m="$1" want="$2" max="${3:-30}" n=0 got=0; while (( n < max*10 )); do got="$(grep -cF "$m" "$LOG" 2>/dev/null || true)"; (( got >= want )) && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
send_line() { local line="$1" d="${CONSOLE_LOGIN_CHAR_DELAY:-0.01}" i; for (( i=0; i<${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$d"; done; printf '\n' >&3; sleep "${CONSOLE_LOGIN_SEND_DELAY:-0.08}"; }

launch() {  # launch DTB
  local dtb="$1"
  LOG="$WORK/boot.log"; : >"$LOG"
  PIDFILE="$(mktemp -t swiftos-recov-pid.XXXXXX)"
  INFIFO="$(mktemp -u -t swiftos-recov-in.XXXXXX)"; mkfifo "$INFIFO"; QP=""
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false \
    -device "loader,file=$dtb,addr=0x4FF00000,force-raw=on" \
    -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!
  exec 3<>"$INFIFO"
}

reach_login() {
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || return 2
  send_line 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || return 2
  printf '\003' >&3
  await "swift-os login:" 90 || return 2
  return 0
}

# login NAME PASS WHICH(1|2) — drive one login attempt; expects Welcome on success.
# Returns 0 welcome+shell · 2 retry (boot race / no prompt) · 3 rejected.
login_expect_welcome() {
  local nm="$1" pw="$2" idx="$3"
  await_count "swift-os login:" "$idx" 90 || return 2
  send_line "$nm"
  await_count "Password:" "$idx" 90 || return 2
  send_line "$pw"
  # Welcome or a fresh "Login incorrect"? race on which comes first; poll both.
  local n=0
  while (( n < 1200 )); do
    [[ "$(grep -cF 'Welcome to swift-os, user' "$LOG")" -ge 1 ]] && break
    [[ "$(grep -cF 'Login incorrect' "$LOG")" -ge "$idx" ]] && return 3
    sleep 0.1; n=$((n+1))
  done
  (( n >= 1200 )) && return 2
  if await "console-login: exec of shell failed" 8; then return 2; fi
  send_line 'echo SHELL-OK'
  await_count "SHELL-OK" 1 60 || return 2
  return 0
}

change_password() {  # change_password CURRENT NEW
  send_line "/bin/passwd -i $ITERS"
  await_count "Current password:" 1 60 || return 2
  send_line "$1"
  await_count "New password:" 1 60 || return 2
  send_line "$2"
  await_count "Retype new password:" 1 60 || return 2
  send_line "$2"
  await_count "passwd: password updated" 1 120 || { echo "FAIL: passwd ($1 -> $2) not committed" >&2; return 1; }
  send_line 'sync'; sleep 1
  return 0
}

# ---- phases (each: 0 ok · 2 retry boot · 1 hard fail) --------------------------

phase1() {  # normal: swordfish -> s3cret
  launch "$DTB"; reach_login || { cleanup_boot; return 2; }
  local rc; login_expect_welcome user swordfish 1; rc=$?
  [[ $rc -eq 0 ]] || { cleanup_boot; return $rc; }
  change_password swordfish s3cret; rc=$?
  cleanup_boot; return $rc
}

phase2() {  # normal: swordfish rejected, s3cret works
  launch "$DTB"; reach_login || { cleanup_boot; return 2; }
  local rc; login_expect_welcome user swordfish 1; rc=$?
  if [[ $rc -eq 0 ]]; then echo "FAIL: default password accepted while overlay active" >&2; cleanup_boot; return 1; fi
  [[ $rc -eq 2 ]] && { cleanup_boot; return 2; }   # boot race before the reject
  login_expect_welcome user s3cret 2; rc=$?
  [[ $rc -eq 0 ]] || { [[ $rc -eq 3 ]] && { echo "FAIL: new password rejected (overlay not read)" >&2; cleanup_boot; return 1; }; cleanup_boot; return 2; }
  cleanup_boot; return 0
}

phase3() {  # RECOVERY: banner + factory password works again; re-provision to rescued
  launch "$RDTB"; reach_login || { cleanup_boot; return 2; }
  await "console-login: RECOVERY MODE" 30 || { echo "FAIL: no recovery banner under recovery DTB" >&2; cleanup_boot; return 1; }
  local rc; login_expect_welcome user swordfish 1; rc=$?
  if [[ $rc -eq 3 ]]; then echo "FAIL: factory password rejected in recovery mode" >&2; cleanup_boot; return 1; fi
  [[ $rc -eq 0 ]] || { cleanup_boot; return 2; }
  change_password swordfish rescued; rc=$?
  cleanup_boot; return $rc
}

phase4() {  # normal: rescued works, swordfish rejected (store repaired)
  launch "$DTB"; reach_login || { cleanup_boot; return 2; }
  local rc; login_expect_welcome user swordfish 1; rc=$?
  if [[ $rc -eq 0 ]]; then echo "FAIL: default accepted after recovery re-provision" >&2; cleanup_boot; return 1; fi
  [[ $rc -eq 2 ]] && { cleanup_boot; return 2; }
  login_expect_welcome user rescued 2; rc=$?
  [[ $rc -eq 0 ]] || { [[ $rc -eq 3 ]] && { echo "FAIL: re-provisioned password did not work" >&2; cleanup_boot; return 1; }; cleanup_boot; return 2; }
  cleanup_boot; return 0
}

run_phase() {
  local fn="$1" label="$2" b rc
  for b in $(seq 1 "$MAX_BOOTS"); do
    echo "$label: boot $b/$MAX_BOOTS ..." >&2
    "$fn"; rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    [[ "$rc" -eq 1 ]] && return 1
    echo "  (boot-time shell-exec race; retrying)" >&2
  done
  echo "FAIL: $label never converged across $MAX_BOOTS boots" >&2
  return 1
}

run_phase phase1 "phase1(change)"          || exit 1
run_phase phase2 "phase2(overlay-active)"  || exit 1
run_phase phase3 "phase3(RECOVERY)"        || exit 1
run_phase phase4 "phase4(repaired)"        || exit 1

echo "PASS: recovery mode bypassed the overlay with factory creds and re-provisioned; normal boots stay overlay-authoritative (K4)"
exit 0
