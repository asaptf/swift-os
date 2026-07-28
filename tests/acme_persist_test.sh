#!/usr/bin/env bash
# acme_persist_test.sh — A3 acceptance: /bin/acme persists its account key and
# issued cert/key to /data and is idempotent across reboot.
#
# Boots TWICE against the SAME stamped SWDATAFS data disk, with the mock ACME
# server (tests/acme_mock_server.py) on the host over real TLS 1.3:
#   boot 1: fresh account key generated, full flow runs, /data/acme/account.key
#           and /data/acme/<domain>/{cert.pem,key.pem} written + fsync'd; the
#           guest cats key.pem to the serial log.
#   boot 2: account key LOADED (reused) and the existing cert is kept
#           ("certificate already present") — proving the state survived reboot.
#
# Assertions: the boot-1/boot-2 markers above, the on-device EC key validates
# with `openssl pkey -check`, and the finalize CSR verifies (DNS:<domain>).
#
# SKIPs if python3/openssl are unavailable.

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
PORT="${ACME_PORT:-44330}"
DOMAIN="example.test"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "SKIP: python3 not found" >&2; exit 0; }
if [[ ! -x "$OPENSSL" ]]; then
  command -v openssl >/dev/null 2>&1 && OPENSSL="$(command -v openssl)" \
    || { echo "SKIP: openssl not found" >&2; exit 0; }
fi

WORK="$(mktemp -d -t swiftos-acmep.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-acmep-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-acmep-in.XXXXXX)"; mkfifo "$INFIFO"
DATA_IMG="$WORK/data.img"
QP=""; SPID=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true; QP=""
}
trap 'stop_qemu; [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null; exec 3>&- 2>/dev/null; rm -rf "$WORK" "$PIDFILE" "$INFIFO"' EXIT

# Fresh stamped data disk (persists across both boots since it is the same file).
dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

# mock server (self-signed TLS; client does not verify it)
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 2 -nodes -subj '/CN=acme-mock' >/dev/null 2>&1 \
  || { echo "SKIP: openssl could not generate a cert" >&2; exit 0; }
cp "$WORK/cert.pem" "$WORK/issued.pem"
CSR_OUT="$WORK/captured.csr.der"; REQLOG="$WORK/reqlog.txt"
"$PYTHON" "$ROOT/tests/acme_mock_server.py" "$PORT" "$WORK/cert.pem" "$WORK/key.pem" \
  "https://10.0.2.2:$PORT" "$WORK/issued.pem" "$CSR_OUT" "$REQLOG" >/dev/null 2>&1 &
SPID=$!; disown "$SPID" 2>/dev/null || true
listening=0
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; listening=1; break; fi
  sleep 0.2
done
[[ "$listening" -eq 1 ]] || { echo "SKIP: mock ACME server did not start on $PORT" >&2; exit 0; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local marker="$1" max="${2:-30}" log="$3" n=0
  while (( n < max * 10 )); do grep -qF "$marker" "$log" 2>/dev/null && return 0; sleep 0.1; n=$((n + 1)); done
  return 1; }
send_line() { local line="$1" delay="${ACME_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
  printf '\n' >&3; sleep "${ACME_SEND_DELAY:-0.08}"; }

# Boot, log in, leave fd 3 open on the guest console. $1=log
boot_and_login() {
  local log="$1"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false \
    "${dtb_args[@]}" \
    -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
    -kernel "$KERNEL" <"$INFIFO" >"$log" 2>&1 &
  QP=$!
  exec 3<>"$INFIFO"
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" "$log" || return 1; send_line 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 "$log" || return 1; printf '\003' >&3
  await "swift-os login:" 40 "$log" || return 1; send_line 'root'
  await "Password:" 30 "$log" || return 1; send_line 'swordfish'
  await "M12c: shell ready" 60 "$log" || return 1
}

# --insecure: this test targets a self-signed mock and checks persistence, not TLS
# trust; cert verification (now on by default) is covered by acme_verify_test.sh.
ACMECMD="/bin/acme 10.0.2.2 $PORT /directory $DOMAIN /tmp/www /data/acme --insecure"

# ---- boot 1: issue + persist ----
LOG1="$WORK/boot1.log"
boot_and_login "$LOG1" || { echo "FAIL: boot 1 login" >&2; sed 's/\r//' "$LOG1" | tail -40 >&2; exit 1; }
send_line "$ACMECMD"
await "acme: certificate obtained" 120 "$LOG1" || true
send_line "cat /data/acme/$DOMAIN/key.pem"   # dump the on-device key for openssl
await "END EC PRIVATE KEY" 30 "$LOG1" || true
send_line "sync"
sleep 1
exec 3>&-; stop_qemu

# ---- boot 2: idempotent (cert kept) + account-key reuse (--force re-runs) ----
LOG2="$WORK/boot2.log"
boot_and_login "$LOG2" || { echo "FAIL: boot 2 login" >&2; sed 's/\r//' "$LOG2" | tail -40 >&2; exit 1; }
send_line "$ACMECMD"                          # cert present -> early exit, untouched
await "acme: certificate already present" 60 "$LOG2" || true
send_line "$ACMECMD --force"                  # bypass guard -> loads the persisted account key
await "acme: account key loaded" 120 "$LOG2" || true
await "acme: certificate obtained" 120 "$LOG2" || true
send_line "sync"; sleep 1
exec 3>&-; stop_qemu

c1="$(sed 's/\r//' "$LOG1")"; c2="$(sed 's/\r//' "$LOG2")"
ok=1
grep -qF "acme: account key generated" <<<"$c1" || { echo "FAIL: boot1 did not generate an account key" >&2; ok=0; }
grep -qF "acme: certificate obtained"   <<<"$c1" || { echo "FAIL: boot1 did not obtain a certificate" >&2; ok=0; }
grep -qF "acme: account key loaded"     <<<"$c2" || { echo "FAIL: boot2 did not reuse the account key (not persisted?)" >&2; ok=0; }
grep -qF "acme: certificate already present" <<<"$c2" || { echo "FAIL: boot2 did not find the persisted certificate" >&2; ok=0; }

# On-device EC key must be a valid P-256 private key.
awk '/-----BEGIN EC PRIVATE KEY-----/{f=1} f{print} /-----END EC PRIVATE KEY-----/{f=0}' <<<"$c1" > "$WORK/ondevice.key"
if grep -qF "BEGIN EC PRIVATE KEY" "$WORK/ondevice.key"; then
  "$OPENSSL" pkey -in "$WORK/ondevice.key" -check -noout >/dev/null 2>&1 \
    || { echo "FAIL: on-device EC key did not validate" >&2; ok=0; }
else
  echo "FAIL: on-device key.pem not captured" >&2; ok=0
fi

# The finalize CSR from boot 1 must verify with the right SAN.
if [[ -s "$CSR_OUT" ]]; then
  "$OPENSSL" req -inform DER -in "$CSR_OUT" -noout -verify >/dev/null 2>&1 \
    || { echo "FAIL: captured CSR did not verify" >&2; ok=0; }
  "$OPENSSL" req -inform DER -in "$CSR_OUT" -noout -text 2>/dev/null | grep -qF "DNS:$DOMAIN" \
    || { echo "FAIL: captured CSR missing DNS:$DOMAIN" >&2; ok=0; }
else
  echo "FAIL: mock did not capture a CSR" >&2; ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/acme persists account key + cert/key to /data, reuses them across reboot, on-device EC key valid"
  exit 0
fi
echo "--- boot1 (acme region) ---" >&2; sed -n '/acme:/,$p' <<<"$c1" | head -30 >&2
echo "--- boot2 (acme region) ---" >&2; sed -n '/acme:/,$p' <<<"$c2" | head -20 >&2
exit 1
