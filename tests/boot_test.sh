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
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
# Poll ceiling for the full pre-login demo sequence (role = DEMO_BOOT_TIMEOUT).
# Override via DEMO_BOOT_TIMEOUT or legacy TIMEOUT.

EXPECTS="${EXPECTS:-[I] platform: M9 OK: hardware discovered from device tree
[I] vfs: base image signature verified (ed25519)
hello from ELF userland
M6 OK: ELF process exited, code 7
argv[1]=alpha
M8a OK: argv delivered, argc=3
SPAWN-ISO-PARENT-FD3
SPAWN-ISO-OK
SPAWN-EXPLICIT-OK
C3-FSTAT-ALLOW-OK
C3-WRITE-DENY-OK
C3-DUP-DENY-OK
C3-GETDENTS-DENY-OK
C3-FSTAT-DENY-OK
spawndemo: child exit status 2
spawndemo: explicit child exit status 2
C4A-ENDPOINT-WRITE-DENY-OK err=-9
C4A-ENDPOINT-READ-DENY-OK err=-9
C4A-ENDPOINT-SEND-XFER-DENY-OK err=-13
C4A-ENDPOINT-RECV-XFER-DENY-OK err=-13
C4A-XFER-RIGHTS-OK
spawndemo: C4A endpoint rights child exit status 2
M8a OK: spawn parent exited, code 0
cat /etc/motd: Welcome to swift-os.
cwd2=/etc
tmp/note: hi-tmpfs
CONFINE-IN-OK
CONFINE-OUT-OK
C3-SCOPE-IN-OK
C3-SCOPE-OPEN-OUT-OK err=-13
C3-SCOPE-STAT-OUT-OK err=-13
C3-SCOPE-WIDEN-OK err=-13
C3-SCOPE-CREATE-OUT-OK err=-13
C3-SCOPE-OK
M8b OK: VFS demo exited, code 0
C3 OK: per-handle rights enforced
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
C4A-BYTES-OK
forkdemo: IPC-XFER-OK
C4A-XFER-READ-OK
forkdemo: IPC-MOVE-ONLY-OK err=-9
C4A-XFER-MOVE-OK
forkdemo: parent waited child
M8d OK: fork demo exited, code 0
C2 OK: explicit handle inheritance preserved
C4a OK: endpoint IPC moved handles safely
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
drvsvc: C5a supervisor starting
drvsvc: generation 1 ready
drvsvc: generation 1 event
drvsvc: generation 1 stopped
drvsvc: generation 2 ready
drvsvc: generation 2 event
drvsvc: C5c device manifest matched
drvsvc: C5c discovery exhausted
drvsvc: C5b device grant claimed
drvsvc: C5f device grant rights metadata-only
drvsvc: C5b device grant moved
drvinputd: C5b device grant accepted
drvsvc: C5b device busy while service owns grant
drvsvc: generation 2 stopped
drvsvc: C5b device grant reclaimed
C5a OK: restartable driver service recovered over IPC
C5b OK: opaque device handle transferred and released
C5c OK: device discovery manifest matched pseudo input
C5e OK: device authority withheld until explicit handoff
C5f OK: device grant rights stayed metadata-only
C5a driver service demo exited, code 0
securitydemo: syscall abuse checks OK
security OK: syscall abuse demo exited, code 0
M12a security: boot principal console session 1
identitydemo: boot principal/session/caps OK
identitydemo: child inherited security context
identitydemo: parent observed inherited context
M12a OK: identity demo exited, code 0
[I] boot: reclaim OK: no frame leak across fork/exec/exit/reap
[I] boot: swift-os userland: Swift ps
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
source filtering active
source override allows error
sink indirection active
sink capability hook active
log: recent
detail=100
detail=4
LOG-EXPORT bytes=
LOG-EXPORT-BEGIN
source=log_export msg=\"tail serialization ready\"
LOG-EXPORT-END}"

FORBIDS="${FORBIDS:-SPAWN-ISO-LEAK
SPAWN-ISO-SETUP-FAIL
SPAWN-EXPLICIT-FAIL
this source-filtered info line should be hidden
C3-FSTAT-ALLOW-FAIL
C3-WRITE-DENY-LEAK
C3-DUP-DENY-LEAK
C3-GETDENTS-DENY-LEAK
C3-FSTAT-DENY-LEAK
C3-SCOPE-CONFINE-FAIL
C3-SCOPE-IN-FAIL
C3-SCOPE-OPEN-OUT-LEAK
C3-SCOPE-STAT-OUT-LEAK
C3-SCOPE-WIDEN-LEAK
C3-SCOPE-CREATE-OUT-LEAK
C4A-ENDPOINT-RIGHTS-SETUP-FAIL
C4A-ENDPOINT-WRITE-DENY-LEAK
C4A-ENDPOINT-WRITE-DENY-FAIL
C4A-ENDPOINT-READ-DENY-LEAK
C4A-ENDPOINT-READ-DENY-FAIL
C4A-ENDPOINT-SEND-XFER-DENY-LEAK
C4A-ENDPOINT-SEND-XFER-DENY-FAIL
C4A-ENDPOINT-RECV-XFER-DENY-LEAK
C4A-ENDPOINT-RECV-XFER-DENY-FAIL
forkdemo: IPC-MOVE-ONLY-LEAK
forkdemo: IPC-MOVE-ONLY-FAIL
drvinputd: missing endpoint args
drvinputd: invalid generation
drvinputd: ready send failed
drvinputd: command receive failed
drvinputd: event send failed
drvinputd: device handle missing
drvinputd: duplicate device grant
drvinputd: device info failed
drvinputd: device info mismatch
drvinputd: device ack send failed
drvinputd: unknown command
drvsvc: endpoint_create failed
drvsvc: fork failed
drvsvc: exec drvinputd failed
drvsvc: ready message mismatch
drvsvc: ping send failed
drvsvc: event message mismatch
drvsvc: device discovery failed
drvsvc: device manifest mismatch
drvsvc: device discovery exhaustion failed
drvsvc: device claim failed
drvsvc: device info mismatch
drvsvc: device dup unexpectedly succeeded
drvsvc: device grant send failed
drvsvc: moved device fd still valid
drvsvc: device ack mismatch
drvsvc: busy claim failed
drvsvc: reclaim claim failed
drvsvc: reclaim info mismatch
drvsvc: stop send failed
drvsvc: service wait failed}"

if [[ ! -f "$KERNEL" ]]; then
    echo "FAIL: $KERNEL not found — run 'make build' first." >&2
    exit 2
fi

LOG="$(mktemp -t swiftos-boot.XXXXXX)"
QEMU_PID=""

stop_qemu() {
    if [[ -n "$QEMU_PID" ]]; then
        kill "$QEMU_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$QEMU_PID" 2>/dev/null && kill -9 "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}

cleanup() {
    stop_qemu
    rm -f "$LOG"
}
trap cleanup EXIT

qemu_args=(-M virt -cpu cortex-a72 -m 256M -nographic -no-reboot)
if [[ ! -f "$DTB" ]]; then
    tmp_dtb="$DTB.tmp"
    mkdir -p "$(dirname "$DTB")"
    "$QEMU" -M "virt,dumpdtb=$tmp_dtb" -cpu cortex-a72 -m 256M -nographic >/dev/null 2>&1
    mv "$tmp_dtb" "$DTB"
fi
if [[ -f "$DTB" ]]; then
    qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

# Attach the packed base image (modern virtio-mmio transport) so /bin/* and the
# read-only base are served from disk rather than the embedded blob.
DISK="$ROOT/build/base.img"
if [[ -f "$DISK" ]]; then
    qemu_args+=(-global virtio-mmio.force-legacy=false
                -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
                -device virtio-blk-device,drive=swosbase)
fi

"$QEMU" "${qemu_args[@]}" -kernel "$KERNEL" >"$LOG" 2>&1 &
QEMU_PID=$!

all_found() {
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qF "$line" "$LOG" 2>/dev/null || return 1
    done <<<"$EXPECTS"
    return 0
}

forbidden_found() {
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qF "$line" "$LOG" 2>/dev/null && return 0
    done <<<"$FORBIDS"
    return 1
}

found=0
for _ in $(seq 1 "$((DEMO_BOOT_TIMEOUT * 10))"); do
    if forbidden_found; then found=2; break; fi
    if all_found; then found=1; break; fi
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.1
done

stop_qemu

if [[ "$found" -eq 1 ]]; then
    echo "PASS: serial console produced all expected lines:"
    while IFS= read -r line; do [[ -n "$line" ]] && echo "  - $line"; done <<<"$EXPECTS"
    exit 0
fi

if [[ "$found" -eq 2 ]]; then
    echo "FAIL: forbidden C2 line seen. Serial log was:" >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
fi

echo "FAIL: not all expected lines seen within ${DEMO_BOOT_TIMEOUT}s. Serial log was:" >&2
echo "---------------------------------------------" >&2
cat -v "$LOG" >&2
echo "---------------------------------------------" >&2
exit 1
