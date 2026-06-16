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

# Write the in-container build script to the (bind-mounted, gitignored) build
# dir. A fully single-quoted heredoc means the OUTER shell expands nothing;
# VERSION/JOBS are passed into the container via `docker run -e`.
INSCRIPT="$ROOT/build/node-build-in-container.sh"
mkdir -p "$ROOT/build"
cat > "$INSCRIPT" <<'NODESCRIPT'
#!/usr/bin/env bash
set -euo pipefail
TC=/opt/swiftos-toolchain
DIST=/src/build/swport-distfiles
WORK=/src/build/node-docker-work
SRC="$WORK/node-v${VERSION}"
mkdir -p "$WORK"

# Use the already-fetched, checksum-verified distfile from the host tree.
[ -f "$DIST/node-v${VERSION}.tar.gz" ] || { echo "missing $DIST/node-v${VERSION}.tar.gz (run make node-configure-probe on host once)"; exit 2; }
[ -d "$SRC" ] || tar xzf "$DIST/node-v${VERSION}.tar.gz" -C "$WORK"

# The cross toolchain is built --disable-threads, so it rejects gyp's linux
# -pthread flag. V8 does its own threading via pthread directly (newlib +
# node-compat), so wrap the cross compilers to drop -pthread (compile + link).
mkdir -p /tmp/wrap
for t in gcc g++; do
  cat > "/tmp/wrap/aarch64-elf-$t" <<WRAP
#!/usr/bin/env bash
# Drop linux driver flags the bare-metal aarch64-elf toolchain doesn't accept
# (-pthread: threadless toolchain; -rdynamic: dynamic export, n/a for static).
new=(); for a in "\$@"; do
  case "\$a" in -pthread|-rdynamic) continue;; esac
  new+=("\$a")
done
exec "$TC/bin/aarch64-elf-$t" "\${new[@]}"
WRAP
  chmod +x "/tmp/wrap/aarch64-elf-$t"
done

# Neutralize Abseil's stdcpp waiter: its header unconditionally includes
# <mutex>/<condition_variable>, absent in our threadless libstdc++. Abseil uses
# the futex waiter here (FUTEX_CLOCK_REALTIME is defined in node-compat), so the
# stdcpp waiter is dead code; empty its TU to drop the std::mutex dependency.
SW="$SRC/deps/v8/third_party/abseil-cpp/absl/synchronization/internal/stdcpp_waiter.cc"
[ -f "$SW" ] && printf '// neutralized for SwiftOS: futex waiter used (see build-node-docker.sh)\n' > "$SW"

cd "$SRC"
echo "--- configure (host=native linux, target=aarch64-elf) ---"
CC=/tmp/wrap/aarch64-elf-gcc CXX=/tmp/wrap/aarch64-elf-g++ CC_host=gcc CXX_host=g++ \
  python3 configure.py \
    --dest-cpu=arm64 --dest-os=linux --cross-compiling --fully-static \
    --without-npm --without-corepack --v8-lite-mode \
    --without-snapshot --without-node-snapshot --without-node-code-cache \
    --without-inspector --without-intl

# node-compat shims + masquerade defines, injected to the TARGET toolset only
# (gyp-make routes env CFLAGS/CXXFLAGS to target; host uses CFLAGS_host).
TF="-isystem /src/userland/node-compat -isystem /src/userland/compat -D__linux__ -D_GNU_SOURCE -D_REENTRANT -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 -D_POSIX_BARRIERS=1 -D_UNIX98_THREAD_MUTEX_ATTRIBUTES=1 -D__TM_GMTOFF=tm_gmtoff -D__TM_ZONE=tm_zone"

# Build the `node` gyp target specifically: it pulls in the V8/libuv/OpenSSL
# *libraries* it needs but skips unrelated target executables (e.g. openssl-cli)
# that we don't ship and that would just hit the freestanding-link issues early.
# Phase 1: compile everything (-k keeps going past the target-executable LINK
# failures, which need the freestanding crt0/syscalls/linker-script integration
# handled separately) so all V8/Node *objects* and static libs get built and any
# remaining compile-time shim gaps surface in one pass.
echo "--- make -k -j${JOBS} (compile-all; exe links deferred) ---"
CFLAGS="$TF" CXXFLAGS="$TF" make -k -j"${JOBS}" -C out BUILDTYPE=Release || true
echo "--- objects/libs built: ---"
find out/Release/obj.target -name '*.o' | wc -l
ls -la out/Release/obj.target/*/*.a 2>/dev/null | awk '{print $5, $9}' | head -20

echo "--- result ---"
ls -la out/Release/node && file out/Release/node || true
NODESCRIPT
chmod +x "$INSCRIPT"

echo "==> Cross-building Node $VERSION in the container…"
docker run --rm -e "VERSION=$VERSION" -e "JOBS=$JOBS" -v "$ROOT":/src -w /src "$IMAGE" \
    bash /src/build/node-build-in-container.sh
echo "==> Done. Target binary: build/node-docker-work/node-v${VERSION}/out/Release/node"
