# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env bash
# net_zero_copy_throughput_test.sh — Track C network zero-copy throughput guard.
#
# Boots /bin/httpd with slirp hostfwd, drives a bounded concurrent HTTP burst,
# and asserts the kernel observed the new RX-by-reference + batched drain path.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${NET_ZC_HOST_PORT:-$((24000 + ($$ % 20000)))}"
TOTAL=32
CONC=8
EXPECT="hello from the swift-os static file server"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-net-zc.XXXXXX)"
OUTDIR="$(mktemp -d -t swiftos-net-zc-out.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-net-zc-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-net-zc-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -rf "$LOG" "$OUTDIR" "$PIDFILE" "$INFIFO"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (net zero-copy driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M7 tty:/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${NET_ZC_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${NET_ZC_SEND_DELAY:-0.08}"
}

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

set +u
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
set -u
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 40 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 20 || drive_fail "timed out waiting for tty Ctrl-C prompt"
sleep 0.2; printf '\003' >&3
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
await "built-in shell (ash)" 60 || drive_fail "root shell did not start"
send_line '/bin/httpd'

listening=0
for _ in $(seq 1 60); do
  if grep -qF "httpd: listening on 8080" "$LOG"; then listening=1; break; fi
  sleep 1
done

ok=1
duration=0
if [[ "$listening" -eq 1 ]]; then
  start="$(date +%s)"
  launched=0
  while (( launched < TOTAL )); do
    pids=""
    batch=0
    while (( batch < CONC && launched < TOTAL )); do
      out="$OUTDIR/resp.$launched"
      curl -s -m 8 "http://127.0.0.1:${HOST_PORT}/hello.txt" > "$out" 2>/dev/null &
      pids="$pids $!"
      launched=$((launched + 1))
      batch=$((batch + 1))
    done
    for p in $pids; do wait "$p" 2>/dev/null || ok=0; done
  done
  end="$(date +%s)"
  duration=$((end - start))
  (( duration < 1 )) && duration=1
fi

sleep 2
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/httpd never reported listening" >&2; ok=0; }

good=0
for f in "$OUTDIR"/resp.*; do
  [[ -f "$f" ]] || continue
  if grep -qF "$EXPECT" "$f"; then good=$((good + 1)); fi
done
[[ "$good" -eq "$TOTAL" ]] || { echo "FAIL: only $good/$TOTAL HTTP responses matched" >&2; ok=0; }

if (( duration > 25 )); then
  echo "FAIL: throughput burst took ${duration}s for $TOTAL requests" >&2
  ok=0
fi

zc_line="$(grep -F "net-zc OK:" <<<"$clean" | tail -1)"
if [[ -z "$zc_line" ]]; then
  echo "FAIL: kernel did not report the zero-copy/batched network path" >&2
  ok=0
else
  rx_batch="$(sed -n 's/.*rx_batch=\([0-9][0-9]*\).*/\1/p' <<<"$zc_line")"
  tx_batch="$(sed -n 's/.*tx_batch=\([0-9][0-9]*\).*/\1/p' <<<"$zc_line")"
  rx_refs="$(sed -n 's/.*rx_refs=\([0-9][0-9]*\).*/\1/p' <<<"$zc_line")"
  [[ -n "$rx_batch" ]] || rx_batch=0
  [[ -n "$tx_batch" ]] || tx_batch=0
  [[ -n "$rx_refs" ]] || rx_refs=0
  if (( rx_refs < 16 || (rx_batch < 2 && tx_batch < 2) )); then
    echo "FAIL: weak zero-copy/batch counters: $zc_line" >&2
    ok=0
  fi
fi

if [[ "$ok" -eq 1 ]]; then
  rps=$((TOTAL / duration))
  echo "PASS: net zero-copy throughput path handled $TOTAL HTTP requests in ${duration}s (${rps} req/s); $zc_line"
  exit 0
fi

echo "--- serial (net/http region) ---" >&2
grep -E "net-zc|httpd:|panic|ESR_EL1|ELR_EL1|FAR_EL1|SCTLR_EL1" <<<"$clean" | tail -60 >&2
exit 1
