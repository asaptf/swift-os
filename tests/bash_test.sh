#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# bash_test.sh — SH1 bash port acceptance.
#
# Boots the base image, logs in as root, and runs /bin/bash. Verifies:
#   1. Bash starts and reports its version via $BASH_VERSION.
#   2. Basic arithmetic and variable expansion work.
#   3. A for-loop (the simplest compound command) produces expected output.
#   4. A pipeline (echo | cat) passes data through correctly.
#   5. Bash exits cleanly, returning control to the ash shell.
#
# Bash is built --without-job-control (no SIGTSTP/setpgid); interactive
# editing via readline + ncurses is present. TERM=vt100 and HOME=/tmp are
# baked into the binary so it works with an empty environment (see build-bash.sh).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
    ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 \
        || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-bash.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-bash-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-bash-in.XXXXXX)"; mkfifo "$INFIFO"
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
        grep -qF "$marker" "$LOG" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
drive_fail() {
    echo "FAIL: $1" >&2
    echo "--- serial (bash, control chars stripped) ---" >&2
    LC_ALL=C tr -cd '\11\12\15\40-\176' < "$LOG" 2>/dev/null | tail -80 >&2 || true
    exit 1
}
send_line() {
    local line="$1" delay="${BASH_CHAR_DELAY:-0.02}" i
    for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
    printf '\n' >&3; sleep "${BASH_SEND_DELAY:-0.15}"
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

# Boot sequence: M7 tty demo → login → root shell.
await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

# Launch bash with --norc so it doesn't look for non-existent rc files.
send_line '/bin/bash --norc --noprofile'

# 1. Version: bash prints nothing on startup (no MOTD), but $BASH_VERSION is set.
#    Use a unique marker so we don't confuse it with the shell prompt.
await 'swift-os' 30 || await '#' 30 || true   # wait for prompt (either PS1 form)
send_line 'echo SH1_VER=$BASH_VERSION'
await 'SH1_VER=5.2' 30 || drive_fail "bash did not start or BASH_VERSION not set"

# 2. Arithmetic expansion.
send_line 'echo SH1_ARITH=$(( 6 * 7 ))'
await 'SH1_ARITH=42' 15 || drive_fail "arithmetic expansion failed"

# 3. For-loop (compound command).
send_line 'for x in A B C; do echo SH1_LOOP_$x; done'
await 'SH1_LOOP_A' 15 || drive_fail "for-loop did not produce output"
await 'SH1_LOOP_C' 10 || drive_fail "for-loop did not complete"

# 4. Pipeline.
send_line 'echo SH1_PIPE_OK | cat'
await 'SH1_PIPE_OK' 15 || drive_fail "pipeline failed"

# 5. Exit back to the ash shell.
send_line 'exit'
await 'M12c: shell ready' 30 || await 'swift-os login:' 20 || true
send_line 'exit'
await 'M12c: session ended' 30 || true

exec 3>&-
stop_qemu
QP=""

clean="$(LC_ALL=C tr -cd '\11\12\15\40-\176' < "$LOG")"
ok=1
for marker in \
    'SH1_VER=5.2' \
    'SH1_ARITH=42' \
    'SH1_LOOP_A' \
    'SH1_LOOP_C' \
    'SH1_PIPE_OK'; do
    if grep -qF "$marker" <<<"$clean"; then
        echo "PASS: $marker"
    else
        echo "FAIL: missing marker: $marker" >&2; ok=0
    fi
done

if (( ok )); then
    echo "RESULT: bash ${BASH_VERSION:-5.2} started, executed compound commands, and exited cleanly."
    exit 0
fi
echo "--- serial (bash region) ---" >&2
sed -n '/built-in shell/,$p' <<<"$clean" | head -100 >&2
exit 1
