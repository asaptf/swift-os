#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build a Hetzner production deploy candidate: kernel + prod base + GPT disk +
# release manifest + public handoff records (P1.2 build stage).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/hetzner-deploy-common.sh
source "$ROOT/scripts/hetzner-deploy-common.sh"
hetzner_deploy_load_env "$ROOT"

mkdir -p "$DEPLOY_DIR" "$HETZNER_EVIDENCE_DIR"

if [[ ! -x "$SSHKEY" ]]; then
  make -C "$ROOT" build/sshkey
fi

hetzner_deploy_require_file "$HETZNER_AUTHORIZED_KEYS" \
  "authorized_keys missing — set HETZNER_AUTHORIZED_KEYS"

if [[ "${HETZNER_ROTATE_HOST_KEY:-0}" == "1" ]] || [[ ! -f "$HETZNER_HOST_SEED" ]]; then
  "$SSHKEY" seed --out "$HETZNER_HOST_SEED"
fi
hetzner_deploy_require_file "$HETZNER_HOST_SEED" "host seed missing"

cp "$HETZNER_AUTHORIZED_KEYS" "$DEPLOY_DIR/authorized_keys"
chmod 600 "$DEPLOY_DIR/authorized_keys"

echo "==> building kernel"
make -C "$ROOT" build

echo "==> building GPT disk (BASE_PROFILE=prod)"
rm -f "$ROOT/build/swift-os.img" "$ROOT/build/esp/EFI/swift-os/kernel"*.bin "$ROOT/build/esp/EFI/swift-os/kernel-boot" 2>/dev/null || true
make -C "$ROOT" disk \
  BASE_PROFILE=prod \
  SSHD_HOST_SEED_FILE="$HETZNER_HOST_SEED" \
  SSHD_AUTHORIZED_KEYS_FILE="$DEPLOY_DIR/authorized_keys"

hetzner_deploy_require_file "$DISK_IMG" "disk image missing after make disk"

echo "==> release manifest"
make -C "$ROOT" release-manifest BASE_PROFILE=prod \
  SSHD_HOST_SEED_FILE="$HETZNER_HOST_SEED" \
  SSHD_AUTHORIZED_KEYS_FILE="$DEPLOY_DIR/authorized_keys" \
  SWOS_PASSWD_FILE=fixtures/prod/swos/passwd \
  SWOS_SERVICES_FILE=fixtures/swos/services-prod

cp "$ROOT/build/release-manifest.json" "$DEPLOY_DIR/release-manifest.json"

if [[ -n "${HETZNER_HOST:-}" ]]; then
  "$SSHKEY" known-host \
    --host "$HETZNER_HOST" \
    --seed-file "$HETZNER_HOST_SEED" >"$HETZNER_KNOWN_HOSTS"
else
  "$SSHKEY" known-host \
    --host "swiftos.example" \
    --seed-file "$HETZNER_HOST_SEED" >"$HETZNER_KNOWN_HOSTS"
fi

disk_sha="$(hetzner_deploy_sha256_file "$DISK_IMG")"
kernel_sha="$(hetzner_deploy_sha256_file "$KERNEL_ELF")"
base_sha="$(hetzner_deploy_sha256_file "$BASE_IMG")"
dtb_sha="$(hetzner_deploy_sha256_file "$DTB")"
git_head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
git_status="$(git -C "$ROOT" status --porcelain 2>/dev/null || true)"

cat >"$DEPLOY_DIR/manifest.txt" <<EOF
SwiftOS Hetzner production deploy candidate
revision: $git_head
profile: hcloud-prod-supervised
architecture: aarch64
services: fixtures/swos/services-prod (nginx, sshd, inputd, llmd)
identity: locked prod passwd + staged authorized_keys
host key: stable seed at $HETZNER_HOST_SEED (public known_hosts in deploy dir)
disk image: $DISK_IMG
remote flash target: $HETZNER_DISK on $HETZNER_HOST
pipeline: build -> local preflight -> upload -> health -> promote
EOF

{
  printf '%s  %s\n' "$disk_sha" "$(basename "$DISK_IMG")"
  printf '%s  %s\n' "$kernel_sha" "kernel.elf"
  printf '%s  %s\n' "$base_sha" "base.img"
  printf '%s  %s\n' "$dtb_sha" "virt.dtb"
} >"$DEPLOY_DIR/artifacts-sha256.txt"

{
  wc -c <"$DISK_IMG" | awk '{print $1 " swift-os.img"}'
  wc -c <"$KERNEL_ELF" | awk '{print $1 " kernel.elf"}'
  wc -c <"$BASE_IMG" | awk '{print $1 " base.img"}'
  wc -c <"$DTB" | awk '{print $1 " virt.dtb"}'
} >"$DEPLOY_DIR/artifacts-size.txt"

printf '%s\n' "$git_head" >"$DEPLOY_DIR/git-head.txt"
printf '%s\n' "$git_status" >"$DEPLOY_DIR/git-status.txt"
cp "$DEPLOY_DIR/authorized_keys" "$HETZNER_EVIDENCE_DIR/authorized_keys"
cp "$DEPLOY_DIR/manifest.txt" "$HETZNER_EVIDENCE_DIR/manifest.txt"
cp "$DEPLOY_DIR/artifacts-sha256.txt" "$HETZNER_EVIDENCE_DIR/artifacts-sha256.txt"
cp "$DEPLOY_DIR/artifacts-size.txt" "$HETZNER_EVIDENCE_DIR/artifacts-size.txt"
cp "$DEPLOY_DIR/release-manifest.json" "$HETZNER_EVIDENCE_DIR/release-manifest.json"
cp fixtures/swos/services-prod "$HETZNER_EVIDENCE_DIR/services"

cat >"$DEPLOY_DIR/secrets-omitted.txt" <<'EOF'
Public handoff only. Omitted private material:
- ssh_host_ed25519_seed (operator retains locally)
- operator SSH private key
EOF
cp "$DEPLOY_DIR/secrets-omitted.txt" "$HETZNER_EVIDENCE_DIR/secrets-omitted.txt"

echo "hetzner-deploy-build: OK"
echo "  disk:      $DISK_IMG ($disk_sha)"
echo "  deploy:    $DEPLOY_DIR"
echo "  evidence:  $HETZNER_EVIDENCE_DIR"