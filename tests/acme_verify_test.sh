#!/usr/bin/env bash
# acme_verify_test.sh — /bin/acme with TLS server-certificate verification (--ca).
#
# The guest pastes a trusted root over the console, then runs the ACME flow with
# verification ON against the mock server (whose self-signed TLS cert is a
# CA:TRUE root with an IP:10.0.2.2 SAN, so it both serves TLS and anchors the
# chain by the IP the guest connects to). Positive: trusting the mock's own cert
# → flow completes. Negative: trusting a DIFFERENT cert → the very first TLS
# handshake is rejected and the directory fetch fails.
#
# SKIPs if python3/openssl are unavailable.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"; DTB="$ROOT/build/virt.dtb"; DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
PYTHON="${PYTHON:-python3}"
PORT="${ACME_PORT:-44340}"
DOMAIN="example.test"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "SKIP: python3 not found" >&2; exit 0; }
if [[ ! -x "$OPENSSL" ]]; then
  command -v openssl >/dev/null 2>&1 && OPENSSL="$(command -v openssl)" || { echo "SKIP: openssl" >&2; exit 0; }
fi

W="$(mktemp -d -t swiftos-acmev.XXXXXX)"; LOG="$(mktemp -t swiftos-acmev-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-acmev-pid.XXXXXX)"; INFIFO="$(mktemp -u -t swiftos-acmev-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; SPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then local p; p="$(cat "$PIDFILE" 2>/dev/null||true)"; [[ -n "$p" ]] && { kill "$p" 2>/dev/null||true; sleep 0.2; kill -9 "$p" 2>/dev/null||true; }; fi
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null||true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null||true
}
trap 'stop_all; exec 3>&- 2>/dev/null; rm -rf "$W" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Trusted root = the mock's own self-signed TLS cert: CA:TRUE + IP:10.0.2.2 SAN, P-256.
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$W/key.pem" -out "$W/cert.pem" -days 3650 -subj '/CN=acme-mock' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'subjectAltName=IP:10.0.2.2' >/dev/null 2>&1 \
  || { echo "SKIP: openssl cert" >&2; exit 0; }
# An unrelated cert the guest will (wrongly) trust in the negative case.
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$W/bad.key" -out "$W/bad.pem" -days 3650 -subj '/CN=not-the-mock' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'subjectAltName=IP:10.0.2.2' >/dev/null 2>&1
cp "$W/cert.pem" "$W/issued.pem"

"$PYTHON" "$ROOT/tests/acme_mock_server.py" "$PORT" "$W/cert.pem" "$W/key.pem" \
  "https://10.0.2.2:$PORT" "$W/issued.pem" "$W/csr.der" "$W/reqlog.txt" >/dev/null 2>&1 &
SPID=$!; disown "$SPID" 2>/dev/null||true
listening=0
for _ in $(seq 1 30); do if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; listening=1; break; fi; sleep 0.2; done
[[ "$listening" -eq 1 ]] || { echo "SKIP: mock did not start" >&2; exit 0; }

dtb_args=(); [[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
await(){ local m="$1" mx="${2:-30}" n=0; while ((n<mx*10)); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
require_await(){ await "$1" "$2" || { echo "FAIL: timeout: $1" >&2; sed 's/\r//' "$LOG"|tail -60 >&2; exit 1; }; }
send_line(){ local l="$1" d="${ACME_CHAR_DELAY:-0.008}" i; for ((i=0;i<${#l};i++)); do printf '%s' "${l:i:1}" >&3; sleep "$d"; done; printf '\n' >&3; sleep "${ACME_SEND_DELAY:-0.06}"; }
paste_pem(){ send_line "cat > $1 <<'PEMEOF'"; while IFS= read -r ln; do send_line "$ln"; done < "$2"; send_line "PEMEOF"; }

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

require_await "M7 tty: type a line then Enter" 60; send_line 'tty-line'
require_await "M7 tty: running; press Ctrl-C" 40; printf '\003' >&3
require_await "swift-os login:" 40; send_line 'root'
require_await "Password:" 30; send_line 'swordfish'
require_await "built-in shell (ash)" 60

paste_pem /tmp/ca.pem  "$W/cert.pem"
paste_pem /tmp/bad.pem "$W/bad.pem"

# Positive: trust the mock's own cert.
send_line "/bin/acme 10.0.2.2 $PORT /directory $DOMAIN /tmp/www /tmp/state --ca /tmp/ca.pem"
await "acme: certificate obtained" 120 || true
# Negative: trust an unrelated cert -> the directory TLS handshake must be rejected.
send_line "/bin/acme 10.0.2.2 $PORT /directory $DOMAIN /tmp/www2 /tmp/state2 --ca /tmp/bad.pem"
await "acme: FAIL directory" 60 || true
exec 3>&-; stop_all; QP=""; SPID=""

clean="$(sed 's/\r//' "$LOG")"; ok=1
grep -qF "acme: verification enabled" <<<"$clean" || { echo "FAIL: verification not enabled" >&2; ok=0; }
grep -qF "acme: certificate obtained" <<<"$clean" || { echo "FAIL: verified flow did not obtain a cert" >&2; ok=0; }
grep -qF "acme: FAIL directory"      <<<"$clean" || { echo "FAIL: untrusted CA was not rejected" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/acme --ca verifies the mock server (IP-SAN) and rejects an untrusted root"
  exit 0
fi
echo "--- acme region ---" >&2; sed -n '/acme:/,$p' <<<"$clean" | head -40 >&2
exit 1
