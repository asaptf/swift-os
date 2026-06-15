#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build-node-docker.sh — cross-build Node.js for the SwiftOS aarch64 target inside
# a Linux container (host=linux), so Node's host tools build natively while the
# target objects use our aarch64-elf+newlib toolchain + node-compat shims.
#
# Why a container: on macOS the host toolset inherits OS=="linux" source
# selection and can't compile libuv's Linux backend (NPM35b). A Linux host fixes
# that whole class. The image (docker/Dockerfile.nodebuild) bakes an aarch64-elf
# GCC with libstdc++ AND POSIX threads (V8 needs both; fixes -pthread).
#
# Usage:  ./scripts/build-node-docker.sh            # build image (if needed) + build Node
#         REBUILD_IMAGE=1 ./scripts/build-node-docker.sh   # force image rebuild
# Output: build/node-port-work/node-v24.16.0/out/Release/node (target aarch64 ELF)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="swiftos-nodebuild"
VERSION="${NODE_VERSION:-24.16.0}"
JOBS="${JOBS:-8}"

command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not installed" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "FAIL: docker daemon not running" >&2; exit 2; }

if [[ "${REBUILD_IMAGE:-0}" == "1" ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> Building toolchain image $IMAGE (one-time, ~30-60 min)…"
    # Context = docker/ only; the Dockerfile downloads its sources and COPYs
    # nothing, so we keep the giant repo build/ tree out of the build context.
    docker build -t "$IMAGE" -f "$ROOT/docker/Dockerfile.nodebuild" "$ROOT/docker"
fi

echo "==> Cross-building Node $VERSION in the container…"
docker run --rm -v "$ROOT":/src -w /src "$IMAGE" bash -euo pipefail -c '
  TC=/opt/swiftos-toolchain
  VERSION="'"$VERSION"'"
  JOBS="'"$JOBS"'"
  DIST=/src/build/swport-distfiles
  WORK=/src/build/node-docker-work
  SRC="$WORK/node-v${VERSION}"
  mkdir -p "$WORK"

  # Use the already-fetched, checksum-verified distfile from the host tree.
  [ -f "$DIST/node-v${VERSION}.tar.gz" ] || { echo "missing $DIST/node-v${VERSION}.tar.gz (run make node-configure-probe on host once)"; exit 2; }
  [ -d "$SRC" ] || tar xzf "$DIST/node-v${VERSION}.tar.gz" -C "$WORK"

  cd "$SRC"
  echo "--- configure (host=native linux, target=aarch64-elf) ---"
  CC="$TC/bin/aarch64-elf-gcc" CXX="$TC/bin/aarch64-elf-g++" \
  CC_host=gcc CXX_host=g++ \
    python3 configure.py \
      --dest-cpu=arm64 --dest-os=linux --cross-compiling --fully-static \
      --without-npm --without-corepack --v8-lite-mode \
      --without-snapshot --without-node-snapshot --without-node-code-cache \
      --without-inspector --without-intl

  # node-compat shims + masquerade defines, injected to the TARGET toolset only
  # (gyp-make routes env CFLAGS/CXXFLAGS to target; host uses CFLAGS_host).
  TF="-isystem /src/userland/node-compat -isystem /src/userland/compat \
-D__linux__ -D_GNU_SOURCE -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 \
-D_POSIX_BARRIERS=1 -D_UNIX98_THREAD_MUTEX_ATTRIBUTES=1 \
-D__TM_GMTOFF=tm_gmtoff -D__TM_ZONE=tm_zone"

  echo "--- make -j$JOBS ---"
  CFLAGS="$TF" CXXFLAGS="$TF" make -j"$JOBS"

  echo "--- result ---"
  ls -la out/Release/node && file out/Release/node || true
'
echo "==> Done. Target binary: build/node-docker-work/node-v${VERSION}/out/Release/node"
