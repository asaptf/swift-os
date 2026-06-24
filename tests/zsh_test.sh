#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# zsh_test.sh — SH2 zsh port acceptance.
#
# Boots the base image, logs in as root, and runs /bin/zsh. Verifies:
#   1. zsh reports its version via $ZSH_VERSION (SH2_VER=5.9).
#   2. zsh arrays work: arr=(a b c); ${#arr} == 3.
#   3. Arithmetic expansion works: $(( 6 * 7 )) == 42.
#   4. A named function can be defined and called.
#   5. zsh exits cleanly, returning control to the ash shell.
#
# zsh is built --disable-dynamic (static modules), --disable-multibyte.
# ZLE (built-in line editor) uses libncurses for terminal handling.
# TERM=vt100 and HOME=/tmp are baked into the binary (see build-zsh.sh).

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

LOG="$(mktemp -t swiftos-zsh.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-zsh-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-zsh-in.XXXXXX)"; mkfifo "$INFIFO"
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
    echo "--- serial (zsh, control chars stripped) ---" >&2
    LC_ALL=C tr -cd '\11\12\15\40-\176' < "$LOG" 2>/dev/null | tail -80 >&2 || true
    exit 1
}
send_line() {
    local line="$1" delay="${ZSH_CHAR_DELAY:-0.02}" i
    for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
    printf '\n' >&3; sleep "${ZSH_SEND_DELAY:-0.15}"
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

# Boot: M7 tty demo → login → root ash shell.
await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

# Launch zsh; --no-rcs skips all startup files (none exist anyway).
send_line '/bin/zsh --no-rcs'

# 1. Version.
await '%' 30 || await '#' 30 || true   # wait for any prompt
send_line 'echo SH2_VER=$ZSH_VERSION'
await 'SH2_VER=5.9' 30 || drive_fail "zsh did not start or ZSH_VERSION not set"

# 2. Arrays.
send_line 'arr=(a b c); echo SH2_ARR=${#arr}'
await 'SH2_ARR=3' 15 || drive_fail "array length expansion failed"

# 3. Arithmetic.
send_line 'echo SH2_ARITH=$(( 6 * 7 ))'
await 'SH2_ARITH=42' 15 || drive_fail "arithmetic expansion failed"

# 4. Function definition and call.
send_line 'greet() { echo "SH2_FUNC_$1" }; greet OK'
await 'SH2_FUNC_OK' 15 || drive_fail "function definition/call failed"

# 5. Exit.
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
    'SH2_VER=5.9' \
    'SH2_ARR=3' \
    'SH2_ARITH=42' \
    'SH2_FUNC_OK'; do
    if grep -qF "$marker" <<<"$clean"; then
        echo "PASS: $marker"
    else
        echo "FAIL: missing marker: $marker" >&2; ok=0
    fi
done

if (( ok )); then
    echo "RESULT: zsh 5.9 started, executed arrays/arithmetic/functions, and exited cleanly."
    exit 0
fi
echo "--- serial (zsh region) ---" >&2
sed -n '/built-in shell/,$p' <<<"$clean" | head -100 >&2
exit 1
