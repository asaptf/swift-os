#!/usr/bin/env bash
# httpd_load_test.sh - network overload + recovery smoke (milestone 4 of the
# stress arc).
#
# Boots with a slirp NIC hostfwding host TCP to guest 8080, starts /bin/httpd
# (a single poll() loop, maxConns=8), and drives it past its capacity from the
# host with curl. The pass condition is GRACEFUL DEGRADATION + RECOVERY, not that
# every request wins:
#   - Burst: fire 20 concurrent requests (>> maxConns). The server must serve far
#     more than its 8-slot connection table over the burst (excess connections are
#     accepted-then-dropped or briefly queued in the socket layer, never panic).
#   - Slow reader: while a rate-limited client is mid-download, normal requests
#     must still succeed - a slow consumer must not wedge the single-threaded
#     server (small responses fit the 16 KiB TCP send buffer, so the blocking
#     write returns and the slow client drains the kernel buffer at its leisure).
#   - Recovery: after all that load, a fresh request must still get 200 - the
#     server survived the burst.
#
# The kill+restart-under-traffic recovery angle is already covered separately by
# tests/ns3_net_service_test.sh (netsvc relays frames across two generations over
# an shmring data plane); this test owns the in-kernel-stack httpd overload path.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${HTTPD_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${HTTPD_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${HTTPD_HOST_PORT:-$((24000 + ($$ % 20000)))}"
INDEX_MARK="swift-os httpd"
HELLO_MARK="hello from the swift-os static file server"
BURST="${HTTPD_BURST:-20}"
# Far above maxConns(=8), comfortably below BURST so timing jitter never fails it.
BURST_MIN_OK="${HTTPD_BURST_MIN_OK:-12}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-httpdload.XXXXXX)"
WORK="$(mktemp -d -t swiftos-httpdload.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-httpdload-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-httpdload-in.XXXXXX)"
mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -rf "$LOG" "$WORK" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qaF "panic:" "$LOG" 2>/dev/null && return 2
    grep -qaF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (httpd load driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}


base_url="http://127.0.0.1:${HOST_PORT}"
qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line "/bin/httpd"
await "httpd: listening on 8080" 120 || drive_fail "httpd never reported listening"

# --- Phase 1: burst far beyond maxConns -----------------------------------
burst_pids=()
for i in $(seq 1 "$BURST"); do
  curl -s -m 10 "${base_url}/" > "$WORK/b$i" 2>/dev/null &
  burst_pids+=("$!")
done
wait "${burst_pids[@]}" 2>/dev/null || true
burst_ok=0
for i in $(seq 1 "$BURST"); do
  grep -qF "$INDEX_MARK" "$WORK/b$i" 2>/dev/null && burst_ok=$((burst_ok + 1))
done

# --- Phase 2: slow reader must not wedge the server -----------------------
# A rate-limited client downloads /hello.txt while normal requests run; the
# normal ones must still succeed.
curl -s -m 25 --limit-rate 8 "${base_url}/hello.txt" > "$WORK/slow" 2>/dev/null & slow_pid=$!
sleep 0.3
slow_concurrent_ok=0
for i in 1 2 3; do
  curl -s -m 10 "${base_url}/" > "$WORK/sc$i" 2>/dev/null
  grep -qF "$INDEX_MARK" "$WORK/sc$i" 2>/dev/null && slow_concurrent_ok=$((slow_concurrent_ok + 1))
done
wait "$slow_pid" 2>/dev/null || true

# --- Phase 3: recovery - server still serves after all the load -----------
recover_code="$(curl -s -m 10 -o "$WORK/recover" -w '%{http_code}' "${base_url}/" 2>/dev/null || true)"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
served=$(grep -c "httpd: 200" <<<"$clean" || true)
ok=1

(( burst_ok >= BURST_MIN_OK )) || { echo "FAIL: burst served $burst_ok/$BURST, expected >= $BURST_MIN_OK (>> maxConns=8)" >&2; ok=0; }
(( slow_concurrent_ok == 3 )) || { echo "FAIL: only $slow_concurrent_ok/3 normal requests succeeded while a slow reader was active (server wedged?)" >&2; ok=0; }
[[ "$recover_code" == "200" ]] || { echo "FAIL: post-load recovery request returned '$recover_code', expected 200" >&2; ok=0; }
grep -qF "$HELLO_MARK" "$WORK/recover" 2>/dev/null || grep -qF "$INDEX_MARK" "$WORK/recover" 2>/dev/null || { echo "FAIL: recovery request body was not a served page" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during httpd load" >&2; ok=0; }
(( served >= BURST_MIN_OK )) || { echo "FAIL: server logged $served 200s, expected >= $BURST_MIN_OK" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: httpd served $burst_ok/$BURST burst + stayed responsive under a slow reader + recovered (200), no panic"
  exit 0
fi
echo "--- serial (httpd load region) ---" >&2
grep -iE 'httpd:|net:|panic|abort|login:|M7' <<<"$clean" | tail -30 >&2 || true
echo "--- burst_ok=$burst_ok slow_concurrent_ok=$slow_concurrent_ok recover_code=$recover_code served=$served ---" >&2
exit 1
