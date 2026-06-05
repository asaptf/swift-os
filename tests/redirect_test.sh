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
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 8;  printf 'tty-line\n'              # M7 ttydemo
  sleep 1;  printf '\003'                    # Ctrl-C -> login prompt
  sleep 3;  printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf 'echo hello-redir > /tmp/r\n'   # truncating redirect on a builtin
  sleep 2;  printf 'cat /tmp/r\n'
  sleep 2;  printf 'echo world-append >> /tmp/r\n' # append
  sleep 2;  printf 'cat /tmp/r\n'
  sleep 2;  printf 'echo piped-data | cat > /tmp/p\n'  # pipe feeding a redirect
  sleep 2;  printf 'cat /tmp/p\n'
  sleep 2;  printf 'echo SHELL-STILL-ALIVE\n'      # survives the redirects
  sleep 2;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 45
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check() { # <fixed-string> <message>
  grep -qF -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }
}
# No fcntl error from ash's redirect save.
grep -qF "F_DUPFD" <<<"$clean" && { echo "FAIL: ash reported an fcntl(F_DUPFD) error" >&2; ok=0; }
check "hello-redir"        "truncating redirect did not write /tmp/r"
check "world-append"       "append redirect did not append to /tmp/r"
check "piped-data"         "pipe-into-redirect did not write /tmp/p"
check "SHELL-STILL-ALIVE"  "shell did not survive the redirects (stdin closed?)"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: shell redirection works via fcntl and the interactive shell survives"
  exit 0
fi
echo "--- serial (shell region) ---" >&2
sed -n '/SHELL-STILL-ALIVE\|hello-redir\|BusyBox/,$p' <<<"$clean" | head -40 >&2
exit 1
