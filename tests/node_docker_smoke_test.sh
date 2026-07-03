#!/usr/bin/env bash
# node_docker_smoke_test.sh — lightweight gate for the Docker-based Node.js port.
#
# Verifies the NPM35b pivot pipeline is wired and runnable without kicking off the
# multi-hour image/toolchain build. When Docker is absent, prints a clear SKIP and
# exits 0 so host-only CI stays green.
#
# Checks:
#   1. docker CLI + daemon reachable (else SKIP)
#   2. swiftos-nodebuild image exists OR Dockerfile.nodebuild is present
#   3. pinned node distfile present (or fetchable from Port.json)
#   4. build/link driver scripts parse (bash -n)
#   5. optional checkpoint: partial target objects from a prior docker build
#
# Usage: make node-docker-smoke-test

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="swiftos-nodebuild"
VERSION="${NODE_VERSION:-24.16.0}"
PORT_JSON="$ROOT/ports/lang/nodejs/Port.json"
DISTFILES="${NODE_DISTFILES:-$ROOT/build/swport-distfiles}"
TARBALL="$DISTFILES/node-v${VERSION}.tar.gz"
DOCKERFILE="$ROOT/docker/Dockerfile.nodebuild"
BUILD_SCRIPT="$ROOT/scripts/build-node-docker.sh"
LINK_SCRIPT="$ROOT/scripts/link-node.sh"
OBJ_DIR="$ROOT/build/node-docker-work/node-v${VERSION}/out/Release/obj.target"

pass() { printf 'PASS: %s\n' "$*"; }
skip() { printf 'SKIP: %s\n' "$*"; exit 0; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 2; }

# --- 1) Docker availability ---------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    skip "docker CLI not installed — install Docker Desktop or podman-docker, then rerun make node-docker-smoke-test"
fi
if ! docker info >/dev/null 2>&1; then
    skip "docker daemon not running — start Docker Desktop (or system docker), then rerun make node-docker-smoke-test"
fi
pass "docker CLI and daemon reachable"

# --- 2) Toolchain image or build recipe ---------------------------------------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    pass "docker image $IMAGE present"
elif [[ -f "$DOCKERFILE" ]]; then
    pass "docker image $IMAGE absent but $DOCKERFILE present (build via ./scripts/build-node-docker.sh)"
else
    fail "missing $IMAGE and $DOCKERFILE"
fi

# --- 3) Node distfile ---------------------------------------------------------
[[ -f "$PORT_JSON" ]] || fail "missing recipe $PORT_JSON"
read_json_field() {
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$PORT_JSON" | head -1 |
        sed -E "s/\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\1/"
}
URL="$(read_json_field url)"
SHA256_EXPECTED="$(read_json_field sha256)"
[[ -n "$URL" && -n "$SHA256_EXPECTED" ]] || fail "could not read url/sha256 from $PORT_JSON"

if [[ -f "$TARBALL" ]]; then
    if command -v shasum >/dev/null 2>&1; then
        SHA256_GOT="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
        [[ "$SHA256_GOT" == "$SHA256_EXPECTED" ]] ||
            fail "distfile sha256 mismatch: got $SHA256_GOT expected $SHA256_EXPECTED"
        pass "distfile verified: $(basename "$TARBALL")"
    else
        pass "distfile present: $(basename "$TARBALL") (shasum unavailable; checksum not verified)"
    fi
else
    pass "distfile absent; will be fetched on first node-configure-probe ($URL)"
fi

# --- 4) Driver script syntax --------------------------------------------------
[[ -f "$BUILD_SCRIPT" ]] || fail "missing $BUILD_SCRIPT"
[[ -f "$LINK_SCRIPT" ]] || fail "missing $LINK_SCRIPT"
bash -n "$BUILD_SCRIPT" || fail "bash -n failed: $BUILD_SCRIPT"
bash -n "$LINK_SCRIPT" || fail "bash -n failed: $LINK_SCRIPT"
pass "build-node-docker.sh and link-node.sh syntax OK"

# --- 5) Optional partial-compile checkpoint -----------------------------------
if [[ -d "$OBJ_DIR" ]]; then
    obj_count="$(find "$OBJ_DIR" -name '*.o' 2>/dev/null | wc -l | tr -d ' ')"
    lib_count="$(find "$OBJ_DIR" -name '*.a' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$obj_count" -gt 0 ]]; then
        pass "partial compile checkpoint: $obj_count target .o file(s), $lib_count static lib(s) under $OBJ_DIR"
    else
        pass "obj.target dir exists but no .o yet (configure may have run; compile not started)"
    fi
else
    pass "no partial compile checkpoint yet (expected before first ./scripts/build-node-docker.sh run)"
fi

printf 'node-docker-smoke-test: all checks passed\n'
exit 0