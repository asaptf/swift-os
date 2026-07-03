#!/usr/bin/env bash
# hetzner_data_pci_test.sh — H7 acceptance: /data (datafs) on virtio-blk-pci
# survives reboot on the Hetzner QEMU device model.
#
# V4b proved a SWDATAFS volume over virtio-blk-pci on plain QEMU virt (mmio base +
# PCI media disk). The real Hetzner Cloud server boots from virtio-scsi-pci with no
# virtio-mmio block devices; extra disks (including /data) are virtio-blk-pci behind
# the same ACPI/GICv3/PCIe topology. This gate boots the GPT disk under UEFI on the
# Hetzner-faithful profile (AAVMF, GICv3, -smp 2, virtio-scsi boot disk, virtio-gpu
# scanout console, NIC behind a PCIe root port, RNG behind a second root port) with an
# unlabeled SWDATAFS disk on virtio-blk-pci as the /data root. Persistence is proven
# by the kernel D0 boot counter on the PCI data disk (D0 acceptance) plus a best-effort
# SSH file round-trip when TCG timing allows (same caveat as hetzner-deploy-test).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_IMG="$ROOT/build/swift-os.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
LOGINKEY="${LOGINKEY:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED="${HOST_SEED:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"
HOST_PORT="${SSHD_HOST_PORT:-$((36000 + ($$ % 8000)))}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

PERSISTMARK="swiftos-HZ-DATA-PCI-8k3m"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk' after 'make base-image')" >&2; exit 2; }
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
[[ -x "$SSHKEY" ]] || { ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: build sshkey" >&2; exit 2; }; }

WORK="$(mktemp -d -t swiftos-hzdata.XXXXXX)"
DISK_WORK="$WORK/swift-os.img"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-hzdata-pid.XXXXXX)"
KNOWN="$(mktemp -t swiftos-hzdata-known.XXXXXX)"
OUT="$(mktemp -t swiftos-hzdata-out.XXXXXX)"
QP=""; CURLOG=""

cp "$DISK_IMG" "$DISK_WORK"
dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
"$SSHKEY" known-host --host "[127.0.0.1]:$HOST_PORT" --seed-file "$HOST_SEED" >"$KNOWN" \
  || { echo "FAIL: derive known_hosts" >&2; exit 2; }

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE" "$KNOWN" "$OUT"; }
trap cleanup EXIT

await() { local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0; sleep 0.1; n=$((n + 1)); done
  return 1
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | tail -60 >&2 || true
  exit 1
}

d0_count() {
  sed 's/\r//' "$1" 2>/dev/null | grep "D0 OK: data disk persistent, boot count" | tail -1 \
    | grep -oE '[0-9]+$' || true
}

ssh_common=(-F /dev/null -p "$HOST_PORT" -o BatchMode=yes -o ConnectTimeout=90
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" -o GlobalKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no)

# Hetzner-faithful: UEFI/GPT boot on virtio-scsi-pci, GICv3, -smp 2, virtio-gpu console
# (skips the blocking serial ttydemo), virtio devices behind PCIe root ports, /data on
# virtio-blk-pci. Serial is output-only — no keystrokes, like a Hetzner Cloud VM.
start_boot() { local log="$1"
  CURLOG="$log"
  "$QEMU" -M virt,gic-version=3 -cpu max -m 4G -smp 2 -no-reboot -bios "$AAVMF_CODE" \
    -pidfile "$PIDFILE" \
    -drive "file=$DISK_WORK,format=raw,if=none,id=hdd" \
    -device virtio-scsi-pci -device scsi-hd,drive=hdd \
    -device virtio-gpu-pci \
    -device pcie-root-port,id=rp1,chassis=1 \
    -netdev "user,id=hn0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22" \
    -device virtio-net-pci,netdev=hn0,bus=rp1 \
    -device pcie-root-port,id=rp2,chassis=2 \
    -device virtio-rng-pci,bus=rp2 \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-pci,drive=swosdata \
    -display none -serial "file:$log" </dev/null 2>&1 &
  QP=$!
}

wait_boot_markers() {
  await "M9 OK: hardware discovered from ACPI" 240 || fail "platform config did not come from ACPI"
  await "V4: virtio-blk-pci disks enumerated" 120 || fail "virtio-blk-pci data disk not enumerated"
  await "D1 OK: datafs mounted at /data" 120 || fail "datafs not mounted at /data"
  await "D0 OK: data disk persistent" 120 || fail "D0 data disk probe did not run"
  await "virtio-gpu: scanout console active" 200 || fail "virtio-gpu console did not come up (headless path)"
  await "net-dhcp OK: lease" 180 || fail "NIC behind PCIe root port did not get a DHCP lease"
  await "swos-init: supervision active" 180 || fail "swos-init did not autostart services"
}

ssh_write_file_best_effort() {
  local ok=0
  for try in 1 2 3; do
    "$SSH" "${ssh_common[@]}" -i "$LOGINKEY" root@127.0.0.1 \
      /bin/sh -c "echo $PERSISTMARK > /data/ssh-mark.txt && sync" >"$OUT" 2>/dev/null \
      && await "sshd: authorized key matched" 30 \
      && ok=1 && break
    sleep 5
  done
  [[ "$ok" -eq 1 ]]
}

# ---- Boot 1: PCI /data enumerated, D0 counter written ------------------------
start_boot "$WORK/b1.log"
wait_boot_markers
C1="$(d0_count "$WORK/b1.log")"
[[ "$C1" == "1" ]] || fail "expected D0 boot count 1 on first boot, got '${C1:-<none>}'"
ssh_wrote=0; ssh_note=""
if ssh_write_file_best_effort; then ssh_wrote=1; ssh_note="; SSH /data write OK"; fi
stop_qemu; sleep 0.5

# ---- Boot 2: same PCI data disk, D0 counter increments -----------------------
start_boot "$WORK/b2.log"
wait_boot_markers
C2="$(d0_count "$WORK/b2.log")"
[[ "$C2" == "2" ]] || fail "expected D0 boot count 2 on second boot (no persistence?), got '${C2:-<none>}'"
if [[ "$ssh_wrote" -eq 1 ]]; then
  for try in 1 2 3; do
    "$SSH" "${ssh_common[@]}" -i "$LOGINKEY" root@127.0.0.1 cat /data/ssh-mark.txt >"$OUT" 2>/dev/null
    grep -qF "$PERSISTMARK" "$OUT" && { ssh_note="${ssh_note}; SSH /data readback OK"; break; }
    sleep 5
  done
fi
stop_qemu

echo "PASS: /data on virtio-blk-pci persists across reboot on Hetzner device model (D0 $C1->$C2${ssh_note})"
exit 0