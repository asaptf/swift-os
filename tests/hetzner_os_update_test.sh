#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# hetzner_os_update_test.sh — OS-1 Hetzner gate: live `swupdate os` on the
# coordinated UEFI topology under the Hetzner-faithful QEMU device model.
#
# Production Hetzner boots the GPT disk on virtio-scsi (H3 ramdisk root) and
# attaches the SWOSBOOT store on virtio-blk-pci. The kernel cannot drive scsi
# for ESP kernel-state I/O, so this gate boots the GPT disk on virtio-blk-pci
# (loader writes kernel-state; OS-1 coordinates) while keeping the Hetzner PCI
# peripherals (virtio-gpu, NIC/RNG behind root ports) and the store volume on
# a second virtio-blk-pci disk. Headless: no host serial input; swos-init applies
# the baked SWSYS fixture at boot (INCLUDE_OS_STAGE_TEST marker) before sshd starts.
#
# Asserts: store selected + base coordinated to ESP slot A, then after apply:
# base staged into slot B, ESP selector flipped to B, and the store-only
# SWOSBOOT activate path was NOT taken.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
AAVMF_CODE="$(host_aavmf_code)" || true
DISK_IMG="$ROOT/build/swift-os.img"
STORE_IMG="$ROOT/build/hetzner-update-store.img"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
LOGINKEY="${LOGINKEY:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED="${HOST_SEED:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"
HOST_PORT="${SSHD_HOST_PORT:-$((34000 + ($$ % 8000)))}"

[[ -f "$AAVMF_CODE" ]] || { echo "SKIP: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 0; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run via 'make hetzner-os-update-test')" >&2; exit 2; }
[[ -f "$STORE_IMG" ]]  || { echo "FAIL: $STORE_IMG missing (run via 'make hetzner-os-update-test')" >&2; exit 2; }
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
[[ -x "$SSHKEY" ]] || { ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: build sshkey" >&2; exit 2; }; }

LOG="$(mktemp -t swiftos-hzos.XXXXXX)"; OUT="$(mktemp -t swiftos-hzos-out.XXXXXX)"
KNOWN="$(mktemp -t swiftos-hzos-known.XXXXXX)"; PIDF="$(mktemp -t swiftos-hzos-pid.XXXXXX)"
"$SSHKEY" known-host --host "[127.0.0.1]:$HOST_PORT" --seed-file "$HOST_SEED" >"$KNOWN" \
  || { echo "FAIL: derive known_hosts" >&2; exit 2; }

QP=""
cleanup() {
  [[ -f "$PIDF" ]] && { p="$(cat "$PIDF" 2>/dev/null||true)"; [[ -n "$p" ]] && { kill "$p" 2>/dev/null||true; sleep 0.3; kill -9 "$p" 2>/dev/null||true; }; }
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null||true
  rm -f "$LOG" "$OUT" "$KNOWN" "$PIDF"
}
trap cleanup EXIT

# Hetzner-faithful PCI peripherals + GPT boot on virtio-blk-pci + SWOSBOOT store.
"$QEMU" -M virt,gic-version=3 -cpu max -m 4G -smp 2 -no-reboot -bios "$AAVMF_CODE" \
  -device virtio-gpu-pci \
  -device pcie-root-port,id=rp0,chassis=0 \
  -drive "file=$DISK_IMG,format=raw,if=none,id=esp,cache=writethrough" \
  -device virtio-blk-pci,drive=esp,bus=rp0 \
  -device pcie-root-port,id=rp1,chassis=1 \
  -netdev "user,id=hn0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22" -device virtio-net-pci,netdev=hn0,bus=rp1 \
  -device pcie-root-port,id=rp2,chassis=2 -device virtio-rng-pci,bus=rp2 \
  -device pcie-root-port,id=rp3,chassis=3 \
  -drive "file=$STORE_IMG,format=raw,if=none,id=swosstore,cache=writethrough" \
  -device virtio-blk-pci,drive=swosstore,bus=rp3 \
  -display none -serial "file:$LOG" -pidfile "$PIDF" & QP=$!

await() { local m="$1" max="${2:-60}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
dump() { echo "--- serial tail ---" >&2; sed 's/\r//' "$LOG" | tail -60 >&2; }
fail() { echo "FAIL: $1" >&2; dump; exit 1; }

await "virtio-gpu: scanout console active" 200 || fail "virtio-gpu console did not come up"
await "V4: virtio-blk-pci disks enumerated" 120 || fail "virtio-blk-pci disks not enumerated"
await "base slot A coordinated with ESP kernel slot A" 120 || fail "base not coordinated to ESP kernel slot A"
await "net-dhcp OK: lease" 180 || fail "NIC behind PCIe root port not found / no DHCP lease"
await "swos-init: supervision active" 120 || fail "supervised sshd not active (headless autostart)"
await "kernel-store: activated kernel slot B" 180 \
  || fail "boot-time os-apply-local did not flip the ESP selector to B"
await "update-store: staged base image" 30 || fail "base not staged into the inactive slot"
await "version 2) into slot B" 30 || fail "staged slot/version not as expected"

# Best-effort SSH reachability (hetzner_deploy_test.sh pattern); not required for PASS.
ssh_common=(-F /dev/null -p "$HOST_PORT" -o BatchMode=yes -o ConnectTimeout=30
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" -o GlobalKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no)
for try in 1 2 3; do
  "$SSH" "${ssh_common[@]}" -i "$LOGINKEY" root@127.0.0.1 /bin/echo HZ-SSH-PROBE >"$OUT" 2>/dev/null
  grep -qF "HZ-SSH-PROBE" "$OUT" && { echo "  SSH probe OK"; break; }
  sleep 3
done

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "kernel-store: activated kernel slot B" <<<"$clean" \
  || { echo "FAIL: ESP kernel-state selector was not flipped to B" >&2; ok=0; }
grep -qF "update-store: activated slot B (on trial)" <<<"$clean" \
  && { echo "FAIL: swupdate used store-only SWOSBOOT activate instead of ESP selector" >&2; ok=0; }
grep -qF "sshd: authorized key matched" <<<"$clean" \
  || { echo "FAIL: SSH never reached key auth over the bridge-found NIC" >&2; ok=0; }

[[ "$ok" -eq 1 ]] || { dump; exit 1; }
echo "PASS: hetzner OS update — SWOSBOOT store on virtio-blk-pci, headless os-apply-local, coordinated ESP activate"