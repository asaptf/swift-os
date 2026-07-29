#!/usr/bin/env bash
# h4_ssh_pci_test.sh — H4 acceptance: a bounded SSH command succeeds end-to-end
# over virtio-net on the PCI transport.
#
# Boots on the Hetzner network/IRQ model — GICv3 (H1) with the NIC on
# virtio-net-pci (H2 transport + H4 driver port) and virtio-rng-pci for KEX
# entropy. The guest brings the NIC up over PCIe, gets a DHCP lease, autostarts
# /bin/sshd, and a host OpenSSH client runs a bounded `/bin/id` over the network
# (QEMU hostfwd → guest :22). Proves the full path: PCI NIC → DHCP → TCP → SSH
# publickey auth → bounded remote exec.
#
# The root FS comes from the virtio-blk base here so the boot is fast; booting
# the same userland from a RAM base on virtio-scsi is the separate H3 gate. This
# gate isolates "virtio-net over PCI + SSH".

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt-gicv3.dtb"
BASE_DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_HOST_PORT:-$((27000 + ($$ % 16000)))}"
KEY_ALLOW_SRC="${SSHD_ALLOW_KEY_SRC:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED_SRC="${SSHD_HOST_SEED_SRC:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_DISK" ]] || { ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 \
  || { echo "FAIL: cannot build base.img" >&2; exit 2; }; }
if [[ ! -f "$DTB" ]]; then
  "$QEMU" -M virt,gic-version=3,dumpdtb="$DTB" -cpu cortex-a72 -m 256M -nographic >/dev/null 2>&1 \
    || { echo "FAIL: cannot dump GICv3 DTB" >&2; exit 2; }
fi
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
[[ -x "$SSHKEY" ]] || { ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 \
  || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }; }
[[ -f "$KEY_ALLOW_SRC" ]] || { echo "FAIL: $KEY_ALLOW_SRC missing" >&2; exit 2; }
[[ -f "$HOST_SEED_SRC" ]] || { echo "FAIL: $HOST_SEED_SRC missing" >&2; exit 2; }

LOG="$(mktemp -t swiftos-h4.XXXXXX)"
SSHOUT="$(mktemp -t swiftos-h4-out.XXXXXX)"
SSHERR="$(mktemp -t swiftos-h4-err.XXXXXX)"
KEY_ALLOW="$(mktemp -t swiftos-h4-key.XXXXXX)"
KNOWN_HOSTS="$(mktemp -t swiftos-h4-known.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-h4-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-h4-in.XXXXXX)"
mkfifo "$INFIFO"
cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"; chmod 600 "$KEY_ALLOW"
"$SSHKEY" known-host --host "[127.0.0.1]:$HOST_PORT" --seed-file "$HOST_SEED_SRC" >"$KNOWN_HOSTS" \
  || { echo "FAIL: could not derive SwiftOS known_hosts entry" >&2; exit 2; }

QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
cleanup() { stop_qemu; exec 3>&- 2>/dev/null || true
  rm -f "$LOG" "$SSHOUT" "$SSHERR" "$KEY_ALLOW" "$KNOWN_HOSTS" "$PIDFILE" "$INFIFO"; }
trap cleanup EXIT

# GICv3 + the NIC and RNG on PCIe — the Hetzner network/IRQ device model. The
# base FS rides on virtio-blk (mmio) for a fast boot.
qemu_args=("$QEMU" -M virt,gic-version=3 -cpu max -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on"
  -drive "file=$BASE_DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22"
  -device virtio-net-pci,netdev=n0
  -device virtio-rng-pci
  -kernel "$KERNEL")

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
drive_fail() { echo "FAIL: $1" >&2; echo "--- serial ---" >&2; sed 's/\r//' "$LOG" | tail -120 >&2; exit 1; }

ssh_common=(-F /dev/null -p "$HOST_PORT" -o BatchMode=yes -o ConnectTimeout=8
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no
  -o PubkeyAuthentication=yes -o NumberOfPasswordPrompts=0)

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Confirm the NIC came up over PCI and got a lease before sshd is reachable.
await "net-dhcp OK: lease" 120 || drive_fail "no DHCP lease over virtio-net-pci"
# Drive past the interactive tty demo so the init program reaches sshd autostart.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" && send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 60 && printf '\003' >&3
await "swos-init: started sshd pid" 120 || drive_fail "swos-init did not start sshd"
await "sshd: listening on 22" 120 || drive_fail "autostarted /bin/sshd did not listen"

"$SSH" "${ssh_common[@]}" -i "$KEY_ALLOW" root@127.0.0.1 /bin/id >"$SSHOUT" 2>"$SSHERR" </dev/null
ssh_rc=$?
await "sshd: session exec completed status 0" 20 || true
exec 3>&-; stop_qemu; QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
chk() { grep -qF "$1" <<<"$clean" || { echo "FAIL: missing serial marker '$1'" >&2; ok=0; }; }
chk "net-dhcp OK: lease"                          # NIC up + DHCP over virtio-net-pci
chk "swos-init: started sshd pid"                 # sshd autostarted
chk "sshd: publickey auth accepted for root"      # publickey auth over the network
chk "sshd: session exec completed status 0"       # bounded remote exec ran
grep -qF "principal=1(root)" "$SSHOUT" || { echo "FAIL: /bin/id stdout unexpected" >&2; ok=0; }
[[ "$ssh_rc" -eq 0 ]] || { echo "FAIL: ssh /bin/id exited $ssh_rc, expected 0" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: bounded SSH /bin/id succeeded over virtio-net-pci (GICv3 profile)"
  exit 0
fi
echo "--- ssh stdout ---" >&2; cat "$SSHOUT" >&2
echo "--- ssh stderr ---" >&2; tail -20 "$SSHERR" >&2
echo "--- serial ---" >&2; grep -iE 'net-|sshd:|swos-init:|panic|H2 OK|virtio-net' <<<"$clean" | tail -60 >&2
exit 1
