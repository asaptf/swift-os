#!/usr/bin/env bash
# boot_test.sh — non-interactive boot acceptance test.
#
# Boots the kernel in QEMU (headless), captures the serial console, and asserts
# every required substring appears within a timeout. The kernel keeps running
# (the M7 tty demo blocks on input), so we poll the log and then kill QEMU.
#
# Required strings cover M6 (ELF load + exit) and M8a (argv delivery). Override
# the list with EXPECTS (newline-separated) if needed.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
# 90s: every demo program is now loaded from disk (M11d), which is slower than
# the old embedded blob; the reclaim self-test adds several fork/exec rounds —
# give the full demo sequence room to finish.
TIMEOUT="${TIMEOUT:-90}"

EXPECTS="${EXPECTS:-M9 OK: hardware discovered from device tree
hello from ELF userland
M6 OK: ELF process exited, code 7
argv[1]=alpha
M8a OK: argv delivered, argc=3
spawndemo: child exit status 2
M8a OK: spawn parent exited, code 0
SPAWN-ISO-OK
cat /etc/motd: Welcome to swift-os.
cwd2=/etc
tmp/note: hi-tmpfs
CONFINE-IN-OK
CONFINE-OUT-OK
M8b OK: VFS demo exited, code 0
M8c brk: heap read/write OK
newlib: malloc works
newlib motd: Welcome to swift-os.
M8c OK: newlib program exited, code 0
A done
B done
M8d OK: two EL0 processes ran concurrently
forkdemo: child inherited cwd/fd
forkdemo: child sees private marker
forkdemo: IPC-POLL-CLOSED-OK
forkdemo: IPC-POLL-OUT-OK
forkdemo: IPC-POLL-IN-OK
forkdemo: IPC-MSG-OK
forkdemo: IPC-XFER-OK
forkdemo: parent waited child
M8d OK: fork demo exited, code 0
execdemo: before execve
argv[1]=exec-alpha
argv[2]=exec-beta
M8d exec OK: exec demo exited, code 3
fdopsdemo: dup/dup2 shared offsets OK
fdopsdemo: pipe/poll/fork OK
fdopsdemo: pipe-poll preemption stress OK
fdopsdemo: rename/unlink/mkdir/rmdir OK
M8e OK: fdops demo exited, code 0
C1 OK: fds-as-handles preserved
securitydemo: syscall abuse checks OK
security OK: syscall abuse demo exited, code 0
M12a security: boot principal console session 1
identitydemo: boot principal/session/caps OK
identitydemo: child inherited security context
identitydemo: parent observed inherited context
M12a OK: identity demo exited, code 0
reclaim OK: no frame leak across fork/exec/exit/reap
swift-os userland: Swift ps
 PID PPID STATE CMD
   1    0 RUN   ps
UID   PID  PPID STATE CMD
root     1     0 RUN   ps
USER   PID  PPID STAT COMMAND
root     1     0 R    ps
PID PPID STAT CMD
1 0 R ps
ps OK: Swift ps exited, code 0
L0 kernel logger active
level filtering active (min INFO)
log: recent
detail=100
detail=4}"

if [[ ! -f "$KERNEL" ]]; then
    echo "FAIL: $KERNEL not found — run 'make build' first." >&2
    exit 2
fi

LOG="$(mktemp -t swiftos-boot.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
    dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

# Attach the packed base image (modern virtio-mmio transport) so /bin/* and the
# read-only base are served from disk rather than the embedded blob.
DISK="$ROOT/build/base.img"
blk_args=()
if [[ -f "$DISK" ]]; then
    blk_args=(-global virtio-mmio.force-legacy=false \
              -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
              -device virtio-blk-device,drive=swosbase)
fi

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
        "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" >"$LOG" 2>&1 &
QEMU_PID=$!

all_found() {
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qF "$line" "$LOG" 2>/dev/null || return 1
    done <<<"$EXPECTS"
    return 0
}

found=0
for _ in $(seq 1 "$((TIMEOUT * 10))"); do
    if all_found; then found=1; break; fi
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.1
done

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [[ "$found" -eq 1 ]]; then
    echo "PASS: serial console produced all expected lines:"
    while IFS= read -r line; do [[ -n "$line" ]] && echo "  - $line"; done <<<"$EXPECTS"
    exit 0
fi

echo "FAIL: not all expected lines seen within ${TIMEOUT}s. Serial log was:" >&2
echo "---------------------------------------------" >&2
cat -v "$LOG" >&2
echo "---------------------------------------------" >&2
exit 1
