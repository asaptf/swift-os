#!/usr/bin/env bash
# dns_test.sh — net-f acceptance: the DNS resolver + /bin/nslookup.
#
# A tiny host python3 UDP DNS responder answers any A query with 192.0.2.7. The
# guest's /bin/nslookup queries it at 10.0.2.2:5354 (slirp routes guest->10.0.2.2
# to the host, as in the TCP-connect test) and prints the resolved address. Fully
# hermetic — no dependency on real DNS. The host codec unit test (net_test.swift)
# is the primary correctness gate; this proves the end-to-end resolve path.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
DNSPORT=5354
EXPECT="test.swos -> 192.0.2.7"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available (host DNS responder); host codec test covers correctness"
  exit 0
fi

LOG="$(mktemp -t swiftos-dns.XXXXXX)"
PYRESP="$(mktemp -t swiftos-dns-py.XXXXXX).py"
PIDFILE="$(mktemp -t swiftos-dns-pid.XXXXXX)"
QP=""; PYPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$PYPID" ]] && kill "$PYPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; rm -f "$LOG" "$PYRESP" "$PIDFILE"' EXIT

cat > "$PYRESP" <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 5354))
s.settimeout(25)
try:
    while True:
        data, addr = s.recvfrom(2048)
        if len(data) < 13:
            continue
        tid = data[0:2]
        i = 12
        while i < len(data) and data[i] != 0:
            i += 1 + data[i]
        qend = i + 1 + 4                      # 0-byte + QTYPE + QCLASS
        question = data[12:qend]
        # header: id, flags 0x8180, qd=1, an=1, ns=0, ar=0
        resp = tid + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + question
        # answer: name ptr 0xC00C, type A, class IN, ttl 60, rdlen 4, 192.0.2.7
        resp += b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04' + bytes([192, 0, 2, 7])
        s.sendto(resp, addr)
except socket.timeout:
    pass
PY

python3 "$PYRESP" & PYPID=$!
disown "$PYPID" 2>/dev/null || true   # silence the job-control "Terminated" notice on cleanup
sleep 0.5

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 8;   printf 'tty-line\n'
  sleep 1;   printf '\003'
  sleep 3;   printf 'root\n'
  sleep 1.5; printf 'swordfish\n'
  sleep 3;   printf '/bin/nslookup test.swos 10.0.2.2 5354\n'
  sleep 6
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 30
stop_all
QP=""; PYPID=""

clean="$(sed 's/\r//' "$LOG")"
if grep -qF "$EXPECT" <<<"$clean"; then
  echo "PASS: /bin/nslookup resolved a name to an A record via DNS (net-f acceptance)"
  exit 0
fi
echo "FAIL: nslookup did not resolve test.swos to 192.0.2.7" >&2
echo "--- serial (nslookup region) ---" >&2
sed -n '/nslookup\|test\.swos/,$p' <<<"$clean" | head -15 >&2
exit 1
