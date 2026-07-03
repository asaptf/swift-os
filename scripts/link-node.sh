#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# link-node.sh — freestanding final link of the Node.js binary for SwiftOS.
#
# Node's gyp `node` target link fails on a hosted-Linux assumption (crt0.o + -ldl)
# that a bare-metal aarch64-elf+newlib target has no business honoring. All of
# Node's objects, libnode.a, and every dependency static lib DID compile, so we
# perform the final link ourselves the same way every SwiftOS userland program is
# linked (userland/user_newlib.ld + crt0_newlib + newlib_syscalls + compat stubs),
# adding the node-compat masquerade implementation (epoll-over-poll, syscall
# router, getrandom/getauxval/dl_iterate_phdr, ...) and libstdc++ for V8.
#
# Runs INSIDE the swiftos-nodebuild image (cross toolchain at /opt/swiftos-toolchain,
# repo bind-mounted at /src). Driven from the host by a `docker run` wrapper.
set -uo pipefail

TC=/opt/swiftos-toolchain
GCC="$TC/bin/aarch64-elf-gcc"
VERSION="${NODE_VERSION:-24.16.0}"
SRC="/src/build/node-docker-work/node-v${VERSION}"
REL="$SRC/out/Release"
OBJ="$REL/obj.target"
B=/tmp/nodelink
mkdir -p "$B"

# Feature macros the node-compat masquerade headers need (mirror the build flags).
CF="-ffreestanding -Os -Wall -D_GNU_SOURCE -D__linux__ -D_REENTRANT -D__DYNAMIC_REENT__ \
 -D_POSIX_THREADS -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 \
 -D_POSIX_BARRIERS=1 -D_UNIX98_THREAD_MUTEX_ATTRIBUTES=1 -D_POSIX_TIMERS \
 -D_POSIX_MONOTONIC_CLOCK -D_POSIX_CLOCK_SELECTION \
 -isystem /src/userland/node-compat -isystem /src/userland/compat -c"

echo "--- compiling SwiftOS bridge objects ---"
$GCC -ffreestanding -Os -Wall -c /src/userland/lib/crt0_newlib.S      -o "$B/crt0.o"      || exit 2
$GCC -ffreestanding -Os -Wall -c /src/userland/lib/newlib_syscalls.c  -o "$B/syscalls.o"  || exit 2
$GCC $CF /src/userland/compat/stubs.c        -o "$B/stubs.o"        || exit 2
$GCC $CF /src/userland/node-compat/node_compat.c -o "$B/node_compat.o" || exit 2

# All Node + dependency static libs (order per node.target.mk LD_INPUTS). Static
# archives among V8/Node have cyclic refs, so wrap them in one --start-group.
LIBS=(
  "$OBJ/deps/histogram/libhistogram.a"
  "$OBJ/libnode.a"
  "$OBJ/tools/v8_gypfiles/libv8_libplatform.a"
  "$OBJ/deps/zlib/libzlib.a"
  "$OBJ/deps/llhttp/libllhttp.a"
  "$OBJ/deps/cares/libcares.a"
  "$OBJ/deps/uv/libuv.a"
  "$OBJ/deps/uvwasi/libuvwasi.a"
  "$OBJ/deps/nghttp2/libnghttp2.a"
  "$OBJ/deps/ada/libada.a"
  "$OBJ/deps/merve/libmerve.a"
  "$OBJ/deps/simdjson/libsimdjson.a"
  "$OBJ/tools/v8_gypfiles/libsimdutf.a"
  "$OBJ/deps/brotli/libbrotli.a"
  "$OBJ/deps/sqlite/libsqlite.a"
  "$OBJ/deps/zstd/libzstd.a"
  "$OBJ/deps/openssl/libopenssl.a"
  "$OBJ/tools/v8_gypfiles/libabseil.a"
  "$OBJ/deps/nbytes/libnbytes.a"
  "$OBJ/deps/ncrypto/libncrypto.a"
  "$OBJ/tools/v8_gypfiles/libv8_base_without_compiler.a"
  "$OBJ/tools/v8_gypfiles/libv8_libbase.a"
  "$OBJ/tools/v8_gypfiles/libv8_zlib.a"
  "$OBJ/tools/v8_gypfiles/libhighway.a"
  "$OBJ/tools/v8_gypfiles/libv8_compiler.a"
  "$OBJ/tools/v8_gypfiles/libv8_initializers.a"
  "$OBJ/deps/zlib/libzlib_data_chunk_simd.a"
  "$OBJ/deps/zlib/libzlib_adler32_simd.a"
  "$OBJ/deps/zlib/libzlib_arm_crc32.a"
)
SNAP="$OBJ/tools/v8_gypfiles/libv8_snapshot.a"

echo "--- linking node (freestanding, drop -ldl) ---"
# --whole-archive on the V8 snapshot: its blob symbols are referenced via extern
# from generated code and would be GC'd otherwise. user_newlib.ld places the
# SwiftOS userland load layout; entry is _start from crt0.
$GCC -nostartfiles -nostdlib -static -T /src/userland/user_newlib.ld \
  -Wl,-z,max-page-size=4096 -L "$TC/aarch64-elf/lib" \
  "$B/crt0.o" \
  "$REL/obj.target/node/src/node_main.o" \
  "$REL/obj.target/node/src/node_snapshot_stub.o" \
  "$B/node_compat.o" "$B/syscalls.o" "$B/stubs.o" \
  -Wl,--start-group \
    "${LIBS[@]}" \
    -Wl,--whole-archive "$SNAP" -Wl,--no-whole-archive \
    -lstdc++ -lc -lm -lgcc \
  -Wl,--end-group \
  -o "$REL/node.elf" 2>&1 | tee /src/build/node-link.log | tail -40
rc=${PIPESTATUS[0]}
echo "--- link rc=$rc ---"
if [ -f "$REL/node.elf" ]; then
  ls -la "$REL/node.elf"
  "$TC/bin/aarch64-elf-size" "$REL/node.elf" 2>/dev/null || true
  file "$REL/node.elf" 2>/dev/null || true
fi
exit $rc
