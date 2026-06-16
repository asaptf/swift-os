#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# node-container-build.sh — in-container steps to cross-build Node for SwiftOS.
# Runs INSIDE the swiftos-nodebuild image (Linux host toolset + aarch64-elf cross
# toolchain at /opt/swiftos-toolchain). Driven by scripts/build-node-docker.sh,
# which can run it foreground or detached. Repo is bind-mounted at /src.
#
# Env: NODE_VERSION, NODE_JOBS (parallelism), NODE_RECONFIGURE, NODE_CLEAN_TARGET.
set -uo pipefail

TC=/opt/swiftos-toolchain
VERSION="${NODE_VERSION:-24.16.0}"
JOBS="${NODE_JOBS:-2}"
DIST=/src/build/swport-distfiles
WORK=/src/build/node-docker-work
SRC="$WORK/node-v${VERSION}"
mkdir -p "$WORK"

[ -f "$DIST/node-v${VERSION}.tar.gz" ] || { echo "missing $DIST/node-v${VERSION}.tar.gz"; exit 2; }
[ -d "$SRC" ] || tar xzf "$DIST/node-v${VERSION}.tar.gz" -C "$WORK"

# Compiler wrappers: drop linux driver flags the bare-metal toolchain rejects.
mkdir -p /tmp/wrap
for t in gcc g++; do
  cat > "/tmp/wrap/aarch64-elf-$t" <<WRAP
#!/usr/bin/env bash
new=(); for a in "\$@"; do case "\$a" in -pthread|-rdynamic) continue;; esac; new+=("\$a"); done
exec "$TC/bin/aarch64-elf-$t" "\${new[@]}"
WRAP
  chmod +x "/tmp/wrap/aarch64-elf-$t"
done

# Idempotent source patches (only touch a file when it still needs it, so a
# resume doesn't change mtimes and trigger rebuilds).
ABSL_SYNC="$SRC/deps/v8/third_party/abseil-cpp/absl/synchronization/internal"
if [ -f "$ABSL_SYNC/stdcpp_waiter.cc" ] && ! grep -q 'neutralized for SwiftOS' "$ABSL_SYNC/stdcpp_waiter.cc"; then
  printf '// neutralized for SwiftOS: futex/pthread waiter used\n' > "$ABSL_SYNC/stdcpp_waiter.cc"
fi
if [ -f "$ABSL_SYNC/waiter.h" ] && grep -q '#include "absl/synchronization/internal/stdcpp_waiter.h"' "$ABSL_SYNC/waiter.h"; then
  sed -i 's@#include "absl/synchronization/internal/stdcpp_waiter.h"@// removed for SwiftOS@' "$ABSL_SYNC/waiter.h"
fi
STP="$SRC/deps/v8/src/base/debug/stack_trace_posix.cc"
if [ -f "$STP" ] && grep -q 'info->si_addr\|#define si_addr' "$STP"; then
  sed -i '/#define si_addr/d' "$STP"
  sed -i 's/info->si_addr/reinterpret_cast<void*>(0)/g' "$STP"
fi

cd "$SRC"

# Configure ONCE (re-running regenerates gyp Makefiles and forces rebuilds).
if [ ! -f out/Makefile ] || [ -n "${NODE_RECONFIGURE:-}" ]; then
  echo "--- configure (host=native linux, target=aarch64-elf) ---"
  CC=/tmp/wrap/aarch64-elf-gcc CXX=/tmp/wrap/aarch64-elf-g++ CC_host=gcc CXX_host=g++ \
    python3 configure.py \
      --dest-cpu=arm64 --dest-os=linux --cross-compiling --fully-static \
      --without-npm --without-corepack --v8-lite-mode \
      --without-snapshot --without-node-snapshot --without-node-code-cache \
      --without-inspector --without-intl
else
  echo "--- configure skipped (out/ already generated) ---"
fi

# Node's objects have order-only prereqs we must drop so the node core compiles:
#  - $(builddir)/openssl-cli: an exe we don't ship (can't link freestanding).
#  - gtest_prod.stamp: googletest fails to compile (test-only, newlib gaps) and
#    node never links gtest, yet its stamp gates node's OBJS and the
#    reset_openssl_cnf action. Drop both so libnode.a + node_main.o build.
if [ -f out/node.target.mk ]; then
  grep -q 'builddir)/openssl-cli' out/node.target.mk && sed -i 's@\$(builddir)/openssl-cli@@g' out/node.target.mk
  grep -q 'googletest/gtest_prod.stamp' out/node.target.mk && \
    sed -i 's@\$(obj)\.target/deps/googletest/gtest_prod.stamp@@g' out/node.target.mk
fi

[ -n "${NODE_CLEAN_TARGET:-}" ] && { echo "--- cleaning obj.target ---"; rm -rf out/Release/obj.target; }

# node-compat shims + masquerade/newlib feature macros, target toolset only.
# -O1 (overrides gyp's -O3, which comes earlier on the command line) slashes the
# per-file cc1plus memory on V8's giant TUs, so we can raise -j without OOM in the
# memory-limited container. First-pass node doesn't need -O3.
TF="-O2 -isystem /src/userland/node-compat -isystem /src/userland/compat -D__linux__ -D_GNU_SOURCE -D_REENTRANT -D_POSIX_THREADS -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 -D_POSIX_BARRIERS=1 -D_UNIX98_THREAD_MUTEX_ATTRIBUTES=1 -D_POSIX_TIMERS -D_POSIX_MONOTONIC_CLOCK -D_POSIX_CLOCK_SELECTION -D__TM_GMTOFF=tm_gmtoff -D__TM_ZONE=tm_zone"

# Build 'all' with -k: the target executable LINKS (node, openssl-cli, nop, ...)
# fail freestanding (crt0/-ldl), but -k keeps compiling, so ALL objects + static
# libs -- including libnode.a and node's own objects -- get built. We then link
# node ourselves (freestanding) in scripts/link-node.sh. (Targeting `node`
# directly didn't remake it because of an openssl-cli link error in its graph.)
echo "--- make -k -j${JOBS} -C out all (continuous, -O2 target+host) ---"
CFLAGS="$TF" CXXFLAGS="$TF" CFLAGS_host="-O2" CXXFLAGS_host="-O2" \
  make -k -j"${JOBS}" -C out BUILDTYPE=Release
rc=$?
echo "--- make rc=$rc ---"
echo "--- result ---"
ls -la out/Release/node 2>/dev/null && file out/Release/node 2>/dev/null || echo "node not linked"
echo "=== container build done rc=$rc ==="
