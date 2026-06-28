#!/usr/bin/env bash
# fb_vi_test.sh — busybox vi renders on the framebuffer text console.
#
# The framebuffer console (kernel/drivers/fb.c) mirrors every console byte, so a
# full-screen program drives it with VT100 escape sequences. Without an escape
# interpreter vi's output is garbage glyphs; this test boots the graphical
# (ramfb + UEFI) path headless, drives vi over the serial console, screendumps
# the framebuffer (QMP -> PPM), and asserts vi's layout actually rendered:
#   - a column of '~' down the left over otherwise-blank lines (CUP worked),
#   - a non-empty status line near the bottom of the 80x24 editor,
#   - and no kernel panic.
# It is the framebuffer counterpart of the serial-console tests/vi_test.sh.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK="$ROOT/build/swift-os.img"
BASE="$ROOT/build/base.img"
AAVMF="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$DISK" ]]  || { echo "FAIL: $DISK missing (make disk)" >&2; exit 2; }
[[ -f "$BASE" ]]  || { echo "FAIL: $BASE missing (make base-image)" >&2; exit 2; }
[[ -f "$AAVMF" ]] || { echo "SKIP: AAVMF firmware $AAVMF not found" >&2; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not found" >&2; exit 0; }

WORK="$(mktemp -d -t swos-fb.XXXXXX)"
SER="$WORK/ser.sock"
QMP="$WORK/qmp.sock"
PPM="$WORK/fbvi.ppm"
PIDFILE="$WORK/pid"
cleanup() {
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null; sleep 0.2; kill -9 "$pid" 2>/dev/null; }
  rm -rf "$WORK"
}
trap cleanup EXIT

"$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -bios "$AAVMF" -drive file="$DISK",format=raw,if=virtio \
  -drive file="$BASE",format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -device ramfb -device virtio-keyboard-device \
  -display none \
  -serial unix:"$SER",server,nowait \
  -qmp unix:"$QMP",server,nowait \
  -pidfile "$PIDFILE" >/dev/null 2>&1 &
sleep 1

SER="$SER" QMP="$QMP" PPM="$PPM" python3 - <<'PY'
import socket, time, threading, json, os, sys

SER=os.environ["SER"]; QMP=os.environ["QMP"]; PPM=os.environ["PPM"]

def conn(path, tries=60):
    for _ in range(tries):
        try:
            s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path); return s
        except OSError: time.sleep(0.2)
    print("FAIL: cannot connect", path); sys.exit(1)

ser=conn(SER); mon=conn(QMP)
log=bytearray()
def reader():
    while True:
        try: d=ser.recv(4096)
        except OSError: break
        if not d: break
        log.extend(d)
threading.Thread(target=reader, daemon=True).start()

def send(b, dt=0.0):
    ser.sendall(b.encode()); time.sleep(dt)
def qmp(obj):
    mon.sendall((json.dumps(obj)+"\r\n").encode()); time.sleep(0.4)
    try: return mon.recv(65536)
    except OSError: return b""

time.sleep(0.5); mon.recv(65536)            # QMP greeting
qmp({"execute":"qmp_capabilities"})

# UEFI boot goes straight to the login prompt (the -kernel M7 tty demo is skipped
# when swos-init + services are present). Wait for the prompt, then log in. The
# inputd driver injects test bytes at boot that can trigger a spurious failed
# login, so retry root/swordfish keyed on "shell ready" (extra sends after
# success are harmless shell no-ops).
def await_(marker, secs=120):
    n=0
    while n < secs*10:
        if marker.encode() in bytes(log): return True
        time.sleep(0.1); n+=1
    print("FAIL: timed out waiting for %r"%marker); sys.exit(1)
await_("swift-os login:")
for _ in range(10):
    time.sleep(1.2); send("root\n")
    time.sleep(1.2); send("swordfish\n")
    time.sleep(1.5)
    if b"shell ready" in bytes(log): break
else:
    print("FAIL: could not log in"); sys.exit(1)
time.sleep(1.0); send("vi /tmp/fbvi\n",3)
send("iHELLO-FB-VI",1); send("\x1b",2)      # insert text, ESC to command mode

r=qmp({"execute":"screendump","arguments":{"filename":PPM,"format":"ppm"}})
if b'"return"' not in r:
    print("FAIL: QMP screendump:", r.decode(errors='replace')); sys.exit(1)
time.sleep(0.5)

if b"panic" in bytes(log):
    print("FAIL: kernel panic during fb vi:\n", bytes(log)[-300:].decode(errors='replace')); sys.exit(1)

# --- parse the PPM (P6) and check vi's layout rendered ----------------------
data=open(PPM,"rb").read()
def token(buf, i):
    while i < len(buf) and buf[i] in b" \t\r\n": i+=1
    j=i
    while j < len(buf) and buf[j] not in b" \t\r\n": j+=1
    return buf[i:j], j
assert data[:2]==b"P6", "not a P6 PPM"
i=2
w,i=token(data,i); h,i=token(data,i); mx,i=token(data,i)
W=int(w); H=int(h); i+=1   # one whitespace after maxval
px=data[i:]
def ink(cx, cy):  # any bright pixel in the 8x16 cell at text col cx,row cy?
    for y in range(cy*16, min(cy*16+16, H)):
        base=(y*W + cx*8)*3
        for x in range(8):
            o=base+x*3
            if o+2 < len(px) and px[o] > 100: return True
    return False

cols=W//8; rows=H//16
# Tilde column: rows whose col 0 has ink but cols 2..40 are blank (empty lines).
tilde_rows=0
for r in range(1, min(rows, 24)):
    if ink(0, r) and not any(ink(c, r) for c in range(2, min(cols, 40))):
        tilde_rows += 1
# Status line: a row in the bottom band of the 80x24 editor with several inked
# cells near the left ("- /tmp/fbvi [Modified] 1/1 100%").
status=False
for r in range(20, min(rows, 28)):
    if sum(1 for c in range(0, min(cols, 30)) if ink(c, r)) >= 6:
        status=True; break
# Top line should carry the inserted text, not a wall of escape glyphs.
top_text = any(ink(c, 0) for c in range(0, 11))

print(f"fb {W}x{H} ({cols}x{rows} cells): tilde_rows={tilde_rows} status={status} top_text={top_text}")
if tilde_rows < 12:
    print("FAIL: tilde column not rendered (escape sequences not interpreted?)"); sys.exit(1)
if not status:
    print("FAIL: vi status line not rendered"); sys.exit(1)
print("PASS: busybox vi rendered on the framebuffer console")
PY
rc=$?
exit $rc
