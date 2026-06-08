#!/usr/bin/env bash
# redirect_test.sh — shell I/O redirection via fcntl(F_DUPFD_CLOEXEC).
#
# busybox ash saves/restores file descriptors around every redirect with
# fcntl(F_DUPFD_CLOEXEC). Until the kernel implemented fcntl, `echo > file`
# failed; a half-implementation (no F_DUPFD_CLOEXEC handling) wrote the file but
# then closed stdin, so the interactive shell exited. This asserts that:
#   - a truncating redirect (`> file`) writes real content,
#   - append (`>> file`) appends,
#   - a pipe feeding a redirect works,
#   - and the interactive shell SURVIVES the redirects (a later `echo` still runs).

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

LOG="$(mktemp -t swiftos-redir.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-redir-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-redir-in.XXXXXX)"; mkfifo "$INFIFO"
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

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 40 && printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 20 && printf '\003' >&3
await "swift-os login:" 20 && printf 'root\n' >&3
await "Password:" 15 && printf 'swordfish\n' >&3
await "Welcome to swift-os, root" 15 && printf 'echo hello-redir > /tmp/r\n' >&3
await "echo hello-redir > /tmp/r" 10 && printf 'cat /tmp/r\n' >&3
await_line "hello-redir" 15 && printf 'echo world-append >> /tmp/r\n' >&3
await "echo world-append >> /tmp/r" 10 && printf 'cat /tmp/r\n' >&3
await_line "world-append" 15 && printf 'echo piped-data | cat > /tmp/p\n' >&3
await "echo piped-data | cat > /tmp/p" 10 && printf 'cat /tmp/p\n' >&3
await_line "piped-data" 15 && printf 'echo SHELL-STILL-ALIVE\n' >&3
await_line "SHELL-STILL-ALIVE" 15 && printf 'exit\n' >&3

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check_line() { # <line> <message>
  grep -qxF -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }
}
# No fcntl error from ash's redirect save.
grep -qF "F_DUPFD" <<<"$clean" && { echo "FAIL: ash reported an fcntl(F_DUPFD) error" >&2; ok=0; }
check_line "hello-redir"        "truncating redirect did not write /tmp/r"
check_line "world-append"       "append redirect did not append to /tmp/r"
check_line "piped-data"         "pipe-into-redirect did not write /tmp/p"
check_line "SHELL-STILL-ALIVE"  "shell did not survive the redirects (stdin closed?)"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: shell redirection works via fcntl and the interactive shell survives"
  exit 0
fi
echo "--- serial (shell region) ---" >&2
sed -n '/SHELL-STILL-ALIVE\|hello-redir\|BusyBox/,$p' <<<"$clean" | head -40 >&2
exit 1
