#!/usr/bin/env bash
# sc2_join_test.sh — SC2 on-device acceptance (case 8): node join + lease expiry.
#
# Boots swift-os in QEMU with a virtio-net NIC (so the real network stack is up),
# logs in, and runs /bin/sctld, which executes the SC2 control-plane self-test
# under Embedded Swift on real aarch64: a bootstrap-token join issues a CA-signed
# node cert over a real mutual-TLS handshake, the node + lease appear in cubestore,
# a heartbeat renews the lease, and when heartbeats stop the leader-gated reaper
# expires the lease — a watcher observing the add and the delete on the framed
# wire. Then /bin/slet runs its node-identity self-check. We assert the lifecycle
# markers on the serial console.
#
# The mTLS bytes move over an in-process loopback inside the guest (guest-local TCP
# cannot loop back through QEMU slirp); the real-NIC split-process transport is the
# documented SC2b/daemon seam. This gate proves the whole SC2 stack — TLS 1.3
# mutual handshake, ECDSA-P256/X25519/ChaCha20-Poly1305, X.509 issuance, cubestore,
# leases, reaper, watch — runs on-device.

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
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-sc2.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sc2-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sc2-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (sc2 driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M7 tty:/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${SC2_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
  printf '\n' >&3
  sleep "${SC2_SEND_DELAY:-0.08}"
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Reach a root shell (skip the M7 tty demo, then log in).
await "M7 tty: type a line then Enter" 40 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 20 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
await "M12c: shell ready" 60 || drive_fail "root shell did not start"

# Run the controller self-test (P-256/X25519-heavy under TCG ⇒ generous timeout).
send_line '/bin/sctld'
await "SC2: SELFTEST PASS" 240 || drive_fail "/bin/sctld self-test did not pass"

# Run the node agent's identity self-check.
send_line '/bin/slet'
await "slet: node identity OK" 60 || drive_fail "/bin/slet identity self-check did not pass"
# SC3: the reconcile loop + Cell seam compile into slet; the self-check runs the image
# verifier + C6 adapter on-device. C6 is not implemented, so the adapter is a documented
# stub and the real Cell path is deferred — assert that honest marker, not a faked Cell.
await "slet: SC3 reconcile loop" 60 || drive_fail "/bin/slet SC3 cell-seam self-check did not run"
# SC8: the persistent-volume object + datafs PV provisioning/binding/fencing compile into
# slet; the self-check runs the VolumeRecord codec, the (app,ordinal) id derivation, and the
# single-writer/fencing-token logic on-device. The live /data PV-into-Cell path needs C6
# (no real Cell to mount into yet), so assert the honest deferred marker, not a faked PV.
await "slet: SC8 PV record" 60 || drive_fail "/bin/slet SC8 volume-seam self-check did not run"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in \
  "SC2: cert issued for node-1" \
  "SC2: mTLS authenticated node-1" \
  "SC2: node-1 registered (lease granted)" \
  "SC2: watch observed node-1 add" \
  "SC2: heartbeat renewed lease" \
  "SC2: lease expired, node-1 removed by reaper" \
  "SC2: watch observed node-1 delete" \
  "SC2: SELFTEST PASS" \
  "slet: node identity OK" \
  "slet: SC3 reconcile loop" \
  "slet: SC8 PV record"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; ok=0; }
done

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: SC2 node join + lease expiry on-device (sctld + slet under Embedded Swift, QEMU)"
  exit 0
fi
echo "--- serial (SC2 region) ---" >&2
sed -n '/sctld:/,$p' <<<"$clean" | head -40 >&2
exit 1
