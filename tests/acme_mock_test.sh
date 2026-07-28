#!/usr/bin/env bash
# acme_mock_test.sh — A2b acceptance: the native Swift /bin/acme client runs the
# full ACME (RFC 8555) flow end-to-end over real TLS 1.3 against a tiny host mock
# ACME server (tests/acme_mock_server.py).
#
# Like tls_test.sh, QEMU slirp maps 10.0.2.2 to the host, so the guest reaches
# the mock at 10.0.2.2:<port> with no hostfwd. The mock auto-"validates" the
# http-01 challenge (no inbound fetch into the guest), so the guest writes the
# challenge file to /tmp (tmpfs) and no data disk is needed. The mock captures
# the finalize CSR; the harness validates it with `openssl req -verify` — proof
# the guest produced a correct, self-signed PKCS#10 with the right SAN.
#
# Assertions:
#   - guest serial reaches "acme: certificate obtained bytes=<N>" with N>0, and
#     every stage marker (directory/account/order/challenge/authz/finalize), and
#   - the captured CSR verifies and carries DNS:example.test.
#
# SKIPs (not fails) if python3/openssl are unavailable.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
OPENSSL="$(host_tool openssl "${OPENSSL:-}")" || true
PYTHON="${PYTHON:-python3}"
PORT="${ACME_PORT:-44320}"
DOMAIN="example.test"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "SKIP: python3 not found" >&2; exit 0; }
if [[ ! -x "$OPENSSL" ]]; then
  command -v openssl >/dev/null 2>&1 && OPENSSL="$(command -v openssl)" \
    || { echo "SKIP: openssl not found ($OPENSSL)" >&2; exit 0; }
fi

WORK="$(mktemp -d -t swiftos-acme.XXXXXX)"
LOG="$(mktemp -t swiftos-acme-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-acme-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-acme-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; SPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null; rm -rf "$WORK"; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Self-signed cert for the mock's TLS (the client does not verify it).
if ! "$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
       -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 2 -nodes \
       -subj '/CN=acme-mock' >/dev/null 2>&1; then
  echo "SKIP: openssl could not generate a self-signed cert" >&2; exit 0
fi
cp "$WORK/cert.pem" "$WORK/issued.pem"   # the "issued" cert the mock returns
CSR_OUT="$WORK/captured.csr.der"
REQLOG="$WORK/reqlog.txt"

"$PYTHON" "$ROOT/tests/acme_mock_server.py" "$PORT" "$WORK/cert.pem" "$WORK/key.pem" \
  "https://10.0.2.2:$PORT" "$WORK/issued.pem" "$CSR_OUT" "$REQLOG" >/dev/null 2>&1 &
SPID=$!
disown "$SPID" 2>/dev/null || true
listening=0
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; listening=1; break; fi
  sleep 0.2
done
[[ "$listening" -eq 1 ]] || { echo "SKIP: mock ACME server did not start on $PORT" >&2; exit 0; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do grep -qF "$marker" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n + 1)); done
  return 1; }
require_await() { local marker="$1" max="${2:-30}"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for serial marker: $marker" >&2
    echo "--- serial tail ---" >&2; sed 's/\r//' "$LOG" | tail -80 >&2; exit 1
  fi; }
send_line() { local line="$1" delay="${ACME_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
  printf '\n' >&3; sleep "${ACME_SEND_DELAY:-0.08}"; }

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

require_await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT"; send_line 'tty-line'
require_await "M7 tty: running; press Ctrl-C" 40; printf '\003' >&3
require_await "swift-os login:" 40; send_line 'root'
require_await "Password:" 30; send_line 'swordfish'
require_await "Welcome to swift-os, root" 40
require_await "M12c: shell ready" 60
# --insecure: this test targets a self-signed mock; cert verification (now on by
# default) is covered by acme_verify_test.sh instead.
send_line "/bin/acme 10.0.2.2 $PORT /directory $DOMAIN /tmp/www /tmp/acmestate --insecure"
await "acme: certificate obtained" 120 || true
exec 3>&-
stop_all
QP=""; SPID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for m in "acme: account key generated" "acme: directory ok" "acme: account registered" \
         "acme: order created" "acme: wrote challenge file" "acme: authorization valid" \
         "acme: finalized"; do
  grep -qF "$m" <<<"$clean" || { echo "FAIL: missing stage marker: $m" >&2; ok=0; }
done

bytes="$(grep -oE 'acme: certificate obtained bytes=[0-9]+' <<<"$clean" | grep -oE '[0-9]+$' | tail -1)"
if [[ -z "${bytes:-}" || "$bytes" -le 0 ]]; then
  echo "FAIL: guest did not obtain a certificate" >&2; ok=0
fi

# External validation: the guest's finalize CSR must be a valid PKCS#10 with the SAN.
if [[ -s "$CSR_OUT" ]]; then
  if ! "$OPENSSL" req -inform DER -in "$CSR_OUT" -noout -verify >/dev/null 2>&1; then
    echo "FAIL: captured CSR self-signature did not verify" >&2; ok=0
  fi
  if ! "$OPENSSL" req -inform DER -in "$CSR_OUT" -noout -text 2>/dev/null | grep -qF "DNS:$DOMAIN"; then
    echo "FAIL: captured CSR missing DNS:$DOMAIN" >&2; ok=0
  fi
else
  echo "FAIL: mock did not capture a CSR" >&2; ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/acme completed the ACME flow ($bytes-byte cert) and produced a valid CSR (DNS:$DOMAIN)"
  exit 0
fi
echo "--- serial (acme region) ---" >&2
sed -n '/acme:/,$p' <<<"$clean" | head -40 >&2
echo "--- mock request log ---" >&2; cat "$REQLOG" 2>/dev/null >&2
exit 1
