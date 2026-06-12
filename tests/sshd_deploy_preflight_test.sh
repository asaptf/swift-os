#!/usr/bin/env bash
# sshd_deploy_preflight_test.sh - Hetzner-style SSHD deploy candidate proof.
#
# Builds a temporary signed base image with static Primary IPv6 config,
# deploy-specific SSHD host/KEX seeds, deploy authorized_keys, and an sshd6
# service manifest. The guest must apply the static IPv6 config, expose
# virtio-rng runtime entropy, autostart /bin/sshd -6, and report the same
# network state through /bin/netinfo. When QEMU IPv6 hostfwd works on the host,
# a real OpenSSH client also runs /bin/netinfo through the IPv6 listener.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
SSH_KEYGEN="${SSH_KEYGEN:-ssh-keygen}"
HOST_PORT="${SSHD_DEPLOY_HOST_PORT:-$((31000 + ($$ % 12000)))}"
HOSTFWD_MODE="${SSHD_DEPLOY_IPV6_HOSTFWD:-auto}"
EVIDENCE_DIR="${SSHD_DEPLOY_EVIDENCE_DIR:-}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
if [[ ! -x "$SSHKEY" ]]; then
  ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
fi
command -v "$SSH_KEYGEN" >/dev/null 2>&1 || { echo "FAIL: ssh-keygen not found" >&2; exit 2; }

drive_openssh=1
if [[ "$HOSTFWD_MODE" == "0" || "$HOSTFWD_MODE" == "off" || "$HOSTFWD_MODE" == "false" ]]; then
  drive_openssh=0
elif [[ "$HOSTFWD_MODE" == "auto" && "$(uname -s)" == "Darwin" ]]; then
  drive_openssh=0
fi
if [[ "$drive_openssh" -eq 1 ]]; then
  command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-sshd-deploy.XXXXXX)"
NET_CONFIG="$WORK/net-ipv6"
SERVICES="$WORK/services"
HOST_SEED="$WORK/ssh_host_ed25519_seed"
KEX_SEED="$WORK/ssh_kex_seed"
ALLOW_KEY="$WORK/deploy_ed25519"
AUTHORIZED_KEYS="$WORK/authorized_keys"
KNOWN_HOSTS="$WORK/known-hosts"
IMG="$WORK/base-sshd-deploy.img"
BASE_ROOT="$WORK/base-root"
BUILDLOG="$WORK/base-image.log"
LOG="$WORK/qemu.log"
SSHOUT="$WORK/ssh-stdout"
SSHERR="$WORK/ssh-stderr"
PIDFILE="$WORK/qemu.pid"
INFIFO="$WORK/qemu.in"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
}

cleanup() {
  stop_qemu
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$NET_CONFIG" <<'EOF'
# Hetzner Cloud style Primary IPv6 config.
address=2001:db8:0:3df1::1/64
gateway=fe80::1
EOF
printf 'sshd6\n' >"$SERVICES"

"$SSHKEY" seed --out "$HOST_SEED" \
  || { echo "FAIL: could not generate deploy SSHD host-key seed" >&2; exit 2; }
"$SSHKEY" seed --out "$KEX_SEED" \
  || { echo "FAIL: could not generate deploy SSHD KEX seed" >&2; exit 2; }
"$SSH_KEYGEN" -q -t ed25519 -N '' -C swiftos-hc28-deploy-key -f "$ALLOW_KEY" \
  || { echo "FAIL: could not generate deploy SSH login key" >&2; exit 2; }
{
  printf 'restrict,no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding '
  cat "$ALLOW_KEY.pub"
} >"$AUTHORIZED_KEYS"
chmod 600 "$ALLOW_KEY"

if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" \
    NET_IPV6_CONFIG_FILE="$NET_CONFIG" \
    SWOS_SERVICES_FILE="$SERVICES" \
    SSHD_HOST_SEED_FILE="$HOST_SEED" \
    SSHD_KEX_SEED_FILE="$KEX_SEED" \
    SSHD_AUTHORIZED_KEYS_FILE="$AUTHORIZED_KEYS" \
    base-image ) >"$BUILDLOG" 2>&1; then
  echo "FAIL: could not build SSHD deploy base image" >&2
  cat "$BUILDLOG" >&2
  exit 2
fi

cmp -s "$NET_CONFIG" "$BASE_ROOT/etc/swos/net-ipv6" \
  || { echo "FAIL: deploy IPv6 config was not staged into the base image" >&2; exit 2; }
cmp -s "$SERVICES" "$BASE_ROOT/etc/swos/services" \
  || { echo "FAIL: deploy services manifest was not staged into the base image" >&2; exit 2; }
cmp -s "$HOST_SEED" "$BASE_ROOT/etc/ssh/ssh_host_ed25519_seed" \
  || { echo "FAIL: deploy SSHD host-key seed was not staged into the base image" >&2; exit 2; }
cmp -s "$KEX_SEED" "$BASE_ROOT/etc/ssh/ssh_kex_seed" \
  || { echo "FAIL: deploy SSHD KEX seed was not staged into the base image" >&2; exit 2; }
cmp -s "$AUTHORIZED_KEYS" "$BASE_ROOT/etc/ssh/authorized_keys" \
  || { echo "FAIL: deploy SSHD authorized_keys was not staged into the base image" >&2; exit 2; }

if [[ "$drive_openssh" -eq 1 ]]; then
  "$SSHKEY" known-host --host "[::1]:$HOST_PORT" \
    --seed-file "$HOST_SEED" >"$KNOWN_HOSTS" \
    || { echo "FAIL: could not derive deploy SSHD known_hosts entry" >&2; exit 2; }
fi

mkfifo "$INFIFO"
qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false
  -object rng-random,filename=/dev/urandom,id=rng0
  -device virtio-rng-device,rng=rng0)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
netdev="user,id=n0,ipv6=on"
if [[ "$drive_openssh" -eq 1 ]]; then
  netdev="$netdev,hostfwd=tcp:[::1]:${HOST_PORT}-:22"
fi
qemu_args+=(
  -drive "file=$IMG,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "$netdev"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (sshd deploy) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  if [[ "$drive_openssh" -eq 1 ]]; then
    echo "--- ssh stdout ---" >&2
    cat "$SSHOUT" >&2 2>/dev/null || true
    echo "--- ssh stderr ---" >&2
    cat "$SSHERR" >&2 2>/dev/null || true
  fi
  exit 1
}

send_line() {
  local line="$1" delay="${SSHD_DEPLOY_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${SSHD_DEPLOY_SEND_DELAY:-0.08}"
}

write_evidence_bundle() {
  [[ -n "$EVIDENCE_DIR" ]] || return 0
  mkdir -p "$EVIDENCE_DIR" || return 1

  local head status remote_mode
  head="$(git -C "$ROOT" log -1 --oneline 2>/dev/null || true)"
  status="$(git -C "$ROOT" status --short --branch 2>/dev/null || true)"
  if [[ "$drive_openssh" -eq 1 ]]; then
    remote_mode="OpenSSH-over-IPv6 enabled"
  else
    remote_mode="serial-only on this host"
  fi

  sed 's/\r//' "$LOG" >"$EVIDENCE_DIR/serial.log"
  printf '%s\n' "$head" >"$EVIDENCE_DIR/git-head.txt"
  printf '%s\n' "$status" >"$EVIDENCE_DIR/git-status.txt"
  shasum -a 256 "$KERNEL" "$DTB" "$IMG" >"$EVIDENCE_DIR/artifacts-sha256.txt"
  ls -lh "$KERNEL" "$DTB" "$IMG" >"$EVIDENCE_DIR/artifacts-size.txt"
  cp "$NET_CONFIG" "$EVIDENCE_DIR/net-ipv6"
  cp "$SERVICES" "$EVIDENCE_DIR/services"
  cp "$AUTHORIZED_KEYS" "$EVIDENCE_DIR/authorized_keys"
  [[ -f "$KNOWN_HOSTS" ]] && cp "$KNOWN_HOSTS" "$EVIDENCE_DIR/known_hosts"
  [[ -f "$SSHOUT" ]] && cp "$SSHOUT" "$EVIDENCE_DIR/ssh-stdout.txt"
  [[ -f "$SSHERR" ]] && cp "$SSHERR" "$EVIDENCE_DIR/ssh-stderr.txt"

  cat >"$EVIDENCE_DIR/validation.txt" <<EOF
command: ./tests/sshd_deploy_preflight_test.sh
result: pass
guest gate: /bin/netinfo --check --require-static6
network profile: QEMU virtio-net slirp with ipv6=on
remote ssh mode: $remote_mode
EOF

  cat >"$EVIDENCE_DIR/secrets-omitted.txt" <<'EOF'
The evidence bundle intentionally omits deploy private material:
- ssh_host_ed25519_seed
- ssh_kex_seed
- deploy login private key
Only public authorized_keys and known_hosts material are copied.
EOF

  cat >"$EVIDENCE_DIR/manifest.txt" <<EOF
SwiftOS Hetzner Cloud deploy preflight evidence
revision: $head
profile: hcloud-sshd-static-ipv6
architecture: aarch64
network:
  ipv4: DHCP/fallback verified through /bin/netinfo --check
  ipv6: static Primary IPv6 style config from net-ipv6
  ipv6 gateway: fe80::1
services:
  swos-init manifest: services
  sshd listener: /bin/sshd -6 on guest TCP/22
identity:
  sshd host key: deploy-specific seed staged in image, public known_hosts copied when generated
  sshd kex seed: deploy-specific seed staged in image, private seed omitted from evidence
  login keys: authorized_keys copied, deploy private key omitted from evidence
validation:
  preflight: ./tests/sshd_deploy_preflight_test.sh pass
  guest command: /bin/netinfo --check --require-static6
  serial log: serial.log
artifacts:
  kernel: $KERNEL
  dtb: $DTB
  base image: $IMG
hashes: artifacts-sha256.txt
sizes: artifacts-size.txt
limits:
  This is a local QEMU deploy preflight. Provider-routed Hetzner IPv6 SSH acceptance still requires a real cloud run.
EOF
}

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "net-hc23 OK: static IPv6 2001:0db8:0000:3df1:0000:0000:0000:0001/64 gateway fe80:0000:0000:0000:0000:0000:0000:0001 applied" 90 \
  || drive_fail "static deploy IPv6 config was not applied"
await "virtio-rng: runtime entropy ready" 90 || drive_fail "virtio-rng did not become ready"
await "swos-init: starting configured services" 90 || drive_fail "swos-init did not start"
await "swos-init: started sshd6 pid" 90 || drive_fail "swos-init did not start sshd6"
await "sshd: listening on 22 (IPv6 session exec preflight)" 120 || drive_fail "deploy /bin/sshd -6 did not listen"
await "swift-os login:" 90 || drive_fail "console-login prompt did not appear after sshd6 autostart"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line "/bin/netinfo --check --require-static6"
await "netinfo: check ok" 90 || drive_fail "/bin/netinfo deploy check did not complete in deploy image"

if [[ "$drive_openssh" -eq 1 ]]; then
  ssh_common=(
    -F /dev/null -6 -vvv -p "$HOST_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o GlobalKnownHostsFile=/dev/null
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -o PasswordAuthentication=no
    -o PubkeyAuthentication=yes
    -o NumberOfPasswordPrompts=0
    -o KexAlgorithms=curve25519-sha256
    -o HostKeyAlgorithms=ssh-ed25519
    -o Ciphers=chacha20-poly1305@openssh.com
    -o MACs=hmac-sha2-256
  )
  "$SSH" "${ssh_common[@]}" -i "$ALLOW_KEY" \
    root@::1 "/bin/netinfo --check --require-static6" >"$SSHOUT" 2>"$SSHERR" </dev/null
  ssh_rc=$?
  await "sshd: session exec completed status 0" 30 || true
else
  ssh_rc=0
fi

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "net-hc23 OK: static IPv6 2001:0db8:0000:3df1:0000:0000:0000:0001/64 gateway fe80:0000:0000:0000:0000:0000:0000:0001 applied" <<<"$clean" \
  || { echo "FAIL: deploy static IPv6 marker missing" >&2; ok=0; }
grep -qF "virtio-rng: runtime entropy ready" <<<"$clean" \
  || { echo "FAIL: deploy profile did not expose virtio-rng" >&2; ok=0; }
grep -qF "swos-init: started sshd6 pid" <<<"$clean" \
  || { echo "FAIL: swos-init did not report sshd6 service start" >&2; ok=0; }
grep -qF "sshd: listening on 22 (IPv6 session exec preflight)" <<<"$clean" \
  || { echo "FAIL: /bin/sshd did not report AF_INET6 listen mode" >&2; ok=0; }
grep -qF "netinfo: ipv6 2001:0db8:0000:3df1:0000:0000:0000:0001 prefix 64 source static" <<<"$clean" \
  || { echo "FAIL: guest netinfo did not report deploy static IPv6" >&2; ok=0; }
grep -qF "netinfo: gateway6 fe80:0000:0000:0000:0000:0000:0000:0001" <<<"$clean" \
  || { echo "FAIL: guest netinfo did not report deploy IPv6 gateway" >&2; ok=0; }
grep -qF "netinfo: HC27 OK" <<<"$clean" \
  || { echo "FAIL: guest netinfo completion marker missing" >&2; ok=0; }
grep -qF "netinfo: check ok" <<<"$clean" \
  || { echo "FAIL: guest netinfo deploy check did not succeed" >&2; ok=0; }

if [[ "$drive_openssh" -eq 1 ]]; then
  [[ "$ssh_rc" -eq 0 ]] || { echo "FAIL: host OpenSSH IPv6 deploy command failed with rc=$ssh_rc" >&2; ok=0; }
  grep -qF "netinfo: check ok" "$SSHOUT" \
    || { echo "FAIL: remote /bin/netinfo deploy check over SSHD IPv6 did not complete" >&2; ok=0; }
  grep -qF "netinfo: ipv6 2001:0db8:0000:3df1:0000:0000:0000:0001 prefix 64 source static" "$SSHOUT" \
    || { echo "FAIL: remote /bin/netinfo over SSHD IPv6 did not report static IPv6" >&2; ok=0; }
  grep -qF "Host '[::1]:$HOST_PORT' is known and matches the ED25519 host key." "$SSHERR" \
    || { echo "FAIL: host OpenSSH did not verify the deploy SSHD known_hosts entry" >&2; ok=0; }
  grep -qF "sshd: loaded host key seed /etc/ssh/ssh_host_ed25519_seed" <<<"$clean" \
    || { echo "FAIL: guest did not load deploy SSHD host-key seed during IPv6 SSH" >&2; ok=0; }
  grep -qF "sshd: loaded kex seed /etc/ssh/ssh_kex_seed" <<<"$clean" \
    || { echo "FAIL: guest did not load deploy SSHD KEX seed during IPv6 SSH" >&2; ok=0; }
  grep -qF "sshd: loaded runtime entropy from SYS_RANDOM" <<<"$clean" \
    || { echo "FAIL: guest did not use runtime entropy during IPv6 SSH" >&2; ok=0; }
  grep -qF "sshd: authorized key matched /etc/ssh/authorized_keys" <<<"$clean" \
    || { echo "FAIL: guest did not match deploy authorized_keys during IPv6 SSH" >&2; ok=0; }
  grep -qF "sshd: publickey auth accepted for root" <<<"$clean" \
    || { echo "FAIL: guest did not accept deploy publickey auth over IPv6 SSH" >&2; ok=0; }
  grep -qF "sshd: session exec completed status 0" <<<"$clean" \
    || { echo "FAIL: guest did not complete deploy IPv6 remote exec with status 0" >&2; ok=0; }
fi

if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen during SSHD deploy preflight" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  if ! write_evidence_bundle; then
    echo "FAIL: could not write SSHD deploy evidence bundle" >&2
    exit 1
  fi
  if [[ "$drive_openssh" -eq 1 ]]; then
    echo "PASS: deploy image staged static IPv6 and SSHD keys, autostarted sshd6, and OpenSSH ran /bin/netinfo over IPv6"
  else
    echo "PASS: deploy image staged static IPv6 and SSHD keys, autostarted sshd6, and /bin/netinfo reported deploy network state"
  fi
  exit 0
fi

echo "--- serial (sshd deploy region) ---" >&2
grep -iE 'swos-init:|sshd:|netinfo:|net-hc23|virtio-rng|net:|panic|abort|M7' <<<"$clean" | tail -140 >&2 || true
if [[ "$drive_openssh" -eq 1 ]]; then
  echo "--- ssh stdout ---" >&2; cat "$SSHOUT" >&2
  echo "--- ssh stderr ---" >&2; cat "$SSHERR" >&2
fi
exit 1
