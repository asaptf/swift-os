#!/usr/bin/env bash
# pkg_repo_install_test.sh - P5 smoke: /bin/pkg installs from a signed HTTP repo.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_DISK="$ROOT/build/base.img"
STORE_DISK="$ROOT/build/pkgstore-install.img"
REPO_DIR="$ROOT/build/pkgrepo-root"
PKGREPO="$ROOT/build/pkgrepo"
SWPKG_TOOL="$ROOT/build/swpkg"
PKGHELLO_PKG="$ROOT/build/pkghello.swpkg"
PKGHELLO_ELF="$ROOT/build/pkghello.elf"
SEED_HEX="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
QEMU="${QEMU:-qemu-system-aarch64}"
PYTHON="${PYTHON:-python3}"
PORT="${PKG_REPO_HOST_PORT:-$((24000 + ($$ % 20000)))}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$STORE_DISK" ]]; then
  ( cd "$ROOT" && make package-local-install-fixture ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build empty package store image" >&2; exit 2;
  }
fi
if [[ ! -d "$REPO_DIR/aarch64/current" ]]; then
  ( cd "$ROOT" && make package-repo-fixture ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build package repository fixture" >&2; exit 2;
  }
fi
[[ -x "$PKGREPO" ]] || { echo "FAIL: $PKGREPO missing (make pkgrepo)" >&2; exit 2; }
[[ -x "$SWPKG_TOOL" ]] || { echo "FAIL: $SWPKG_TOOL missing (make swpkg)" >&2; exit 2; }
[[ -f "$PKGHELLO_PKG" ]] || { echo "FAIL: $PKGHELLO_PKG missing (make package-fixture)" >&2; exit 2; }
[[ -f "$PKGHELLO_ELF" ]] || { echo "FAIL: $PKGHELLO_ELF missing (make package-fixture)" >&2; exit 2; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "FAIL: $PYTHON not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-pkg-repo.XXXXXX)"
HTTPLOG="$(mktemp -t swiftos-pkg-repo-http.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-pkg-repo-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-pkg-repo-in.XXXXXX)"; mkfifo "$INFIFO"
HTTPROOT="$(mktemp -d -t swiftos-pkg-repo-root.XXXXXX)"
QP=""; HTTPPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$HTTPPID" ]] && kill "$HTTPPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
cleanup() {
  stop_all
  exec 3>&- 2>/dev/null || true
  rm -rf "$HTTPROOT"
  rm -f "$LOG" "$HTTPLOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (pkg repo driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M11c:\|pkg /,$p' >&2 || true
  echo "--- http server ---" >&2
  sed -n '1,120p' "$HTTPLOG" >&2 || true
  echo "--- tail ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -140 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${PKG_REPO_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PKG_REPO_SEND_DELAY:-0.08}"
}

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

mkdir -p "$HTTPROOT/pkgdep-root/usr/bin" "$HTTPROOT/pkghello-root/usr/bin" "$HTTPROOT/pkgbad-root/usr/bin"
cp "$PKGHELLO_ELF" "$HTTPROOT/pkgdep-root/usr/bin/pkgdep"
cp "$PKGHELLO_ELF" "$HTTPROOT/pkghello-root/usr/bin/pkghello"
cp "$PKGHELLO_ELF" "$HTTPROOT/pkgbad-root/usr/bin/pkgbad"
cat >"$HTTPROOT/pkgdep.json" <<'JSON'
{"format":1,"name":"pkgdep","version":"1.0.0","revision":1,"summary":"Dependency fixture","license":["swift-os-test"],"arch":"aarch64","target":"swift-os","abi":{"os":"swos-0","syscall":1,"libc":"newlib-4.6-swos","linkage":"static"},"depends":[],"provides":["pkgdep"],"conflicts":[],"files":[{"path":"/usr/bin/pkgdep","mode":"0755","sha256":"","size":0}],"capabilities":{"default":[],"services":[]}}
JSON
cat >"$HTTPROOT/pkghello-dep.json" <<'JSON'
{"format":1,"name":"pkghello","version":"1.0.0","revision":1,"summary":"Dependent package fixture","license":["swift-os-test"],"arch":"aarch64","target":"swift-os","abi":{"os":"swos-0","syscall":1,"libc":"newlib-4.6-swos","linkage":"static"},"depends":[{"name":"pkgdep","constraint":">=1.0.0"}],"provides":["pkghello"],"conflicts":[],"files":[{"path":"/usr/bin/pkghello","mode":"0755","sha256":"","size":0}],"capabilities":{"default":[],"services":[]}}
JSON
cat >"$HTTPROOT/pkgbad.json" <<'JSON'
{"format":1,"name":"pkgbad","version":"1.0.0","revision":1,"summary":"Bad hash fixture","license":["swift-os-test"],"arch":"aarch64","target":"swift-os","abi":{"os":"swos-0","syscall":1,"libc":"newlib-4.6-swos","linkage":"static"},"depends":[],"provides":["pkgbad"],"conflicts":[],"files":[{"path":"/usr/bin/pkgbad","mode":"0755","sha256":"","size":0}],"capabilities":{"default":[],"services":[]}}
JSON
"$SWPKG_TOOL" create --manifest "$HTTPROOT/pkgdep.json" \
  --root "$HTTPROOT/pkgdep-root" --output "$HTTPROOT/pkgdep.swpkg" >/dev/null
"$SWPKG_TOOL" create --manifest "$HTTPROOT/pkghello-dep.json" \
  --root "$HTTPROOT/pkghello-root" --output "$HTTPROOT/pkghello-dep.swpkg" >/dev/null
"$SWPKG_TOOL" create --manifest "$HTTPROOT/pkgbad.json" \
  --root "$HTTPROOT/pkgbad-root" --output "$HTTPROOT/pkgbad.swpkg" >/dev/null

"$PKGREPO" create --package "$HTTPROOT/pkgdep.swpkg" --package "$HTTPROOT/pkghello-dep.swpkg" \
  --output "$HTTPROOT/good" \
  --seed-hex "$SEED_HEX" --generation 1 >/dev/null
"$PKGREPO" create --package "$PKGHELLO_PKG" --output "$HTTPROOT/expired" \
  --seed-hex "$SEED_HEX" --generation 1 --expires 1 >/dev/null
"$PKGREPO" create --package "$PKGHELLO_PKG" --output "$HTTPROOT/wrongarch" \
  --seed-hex "$SEED_HEX" --generation 1 --arch riscv64 >/dev/null
"$PKGREPO" create --package "$HTTPROOT/pkgbad.swpkg" --output "$HTTPROOT/badhash" \
  --seed-hex "$SEED_HEX" --generation 1 \
  --sha256-override 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null

( cd "$HTTPROOT" && "$PYTHON" -m http.server "$PORT" --bind 0.0.0.0 >"$HTTPLOG" 2>&1 ) &
HTTPPID=$!
disown "$HTTPPID" 2>/dev/null || true
sleep 0.8
kill -0 "$HTTPPID" 2>/dev/null || {
  echo "FAIL: HTTP server did not start" >&2
  sed -n '1,120p' "$HTTPLOG" >&2 || true
  exit 2
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE_DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -drive "file=$STORE_DISK,format=raw,if=none,id=swpkgstore" \
  -device virtio-blk-device,drive=swpkgstore \
  -netdev user,id=n0 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line "pkg update http://10.0.2.2:$PORT/expired/aarch64/current"
await "pkg: catalog expired" 120 || drive_fail "expired catalog was not rejected"
send_line "pkg update http://10.0.2.2:$PORT/wrongarch/aarch64/current"
await "pkg: catalog incompatible" 120 || drive_fail "wrong-arch catalog was not rejected"
send_line "pkg repo set http://10.0.2.2:$PORT/good/aarch64/current"
await "pkg: repository set http://10.0.2.2:$PORT/good/aarch64/current" 60 || drive_fail "pkg repo set did not complete"
send_line 'pkg repo show'
await "http://10.0.2.2:$PORT/good/aarch64/current" 60 || drive_fail "pkg repo show did not print configured repo"
send_line "pkg update"
await "pkg: catalog updated http://10.0.2.2:$PORT/good/aarch64/current" 120 || drive_fail "pkg update did not complete"
send_line 'pkg search pkghello'
await "pkghello-1.0.0_1" 60 || drive_fail "pkg search did not find pkghello"
send_line 'pkg info pkghello'
await "sha256:" 60 || drive_fail "pkg info did not show package metadata"
await "depends: pkgdep" 60 || drive_fail "pkg info did not show dependencies"
send_line 'pkg install pkghello'
await "pkg: fetching pkgdep-1.0.0_1" 120 || drive_fail "dependency package was not fetched"
await "pkg: installed pkgdep-1.0.0_1" 120 || drive_fail "dependency package was not installed"
await "pkg: installed pkghello-1.0.0_1" 120 || drive_fail "pkg install by name did not complete"
send_line 'pkg list'
await "pkgdep-1.0.0_1" 60 || drive_fail "installed dependency package not listed"
await "pkghello-1.0.0_1" 60 || drive_fail "installed package not listed"
send_line '/usr/bin/pkghello'
await "pkghello: hello from package overlay" 60 || drive_fail "/usr/bin/pkghello did not execute after repo install"
send_line "pkg update http://10.0.2.2:$PORT/badhash/aarch64/current"
await "pkg: catalog updated http://10.0.2.2:$PORT/badhash/aarch64/current" 120 || drive_fail "bad-hash catalog did not update"
send_line 'pkg install pkgbad'
await "pkg: package SHA-256 mismatch" 120 || drive_fail "package hash mismatch was not rejected"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_all
QP=""; HTTPPID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "M11c: read-only base mounted from disk" <<<"$clean" || { echo "FAIL: base was not mounted from disk" >&2; ok=0; }
grep -qF "pkg: catalog updated" <<<"$clean" || { echo "FAIL: pkg update output missing" >&2; ok=0; }
grep -qF "pkg: catalog expired" <<<"$clean" || { echo "FAIL: expired catalog rejection missing" >&2; ok=0; }
grep -qF "pkg: catalog incompatible" <<<"$clean" || { echo "FAIL: incompatible catalog rejection missing" >&2; ok=0; }
grep -qF "pkg: package SHA-256 mismatch" <<<"$clean" || { echo "FAIL: package hash rejection missing" >&2; ok=0; }
grep -qF "pkg: repository set" <<<"$clean" || { echo "FAIL: repo set output missing" >&2; ok=0; }
grep -qF "depends: pkgdep" <<<"$clean" || { echo "FAIL: dependency info output missing" >&2; ok=0; }
grep -qF "pkg: installed pkgdep-1.0.0_1" <<<"$clean" || { echo "FAIL: dependency install output missing" >&2; ok=0; }
grep -qF "pkg: installed pkghello-1.0.0_1" <<<"$clean" || { echo "FAIL: repo pkg install output missing" >&2; ok=0; }
grep -qF "P3b: package installed and activated" <<<"$clean" || { echo "FAIL: kernel did not activate installed package" >&2; ok=0; }
grep -qF "pkghello: hello from package overlay" <<<"$clean" || { echo "FAIL: pkghello output missing" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during repo pkg install" >&2; ok=0; }
grep -qF "GET /expired/aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: expired catalog request missing" >&2; ok=0; }
grep -qF "GET /wrongarch/aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: wrongarch catalog request missing" >&2; ok=0; }
grep -qF "GET /badhash/aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: badhash catalog request missing" >&2; ok=0; }
grep -qF "GET /badhash/aarch64/current/packages/" "$HTTPLOG" || { echo "FAIL: badhash package request missing" >&2; ok=0; }
grep -qF "GET /good/aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: HTTP catalog request missing" >&2; ok=0; }
grep -qF "GET /good/aarch64/current/packages/" "$HTTPLOG" || { echo "FAIL: HTTP package request missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/pkg rejected bad signed repos, resolved deps, installed pkghello by name, and ran it"
  exit 0
fi
echo "--- serial (pkg repo region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/M11c:/,$p' >&2
echo "--- http server ---" >&2
sed -n '1,120p' "$HTTPLOG" >&2 || true
exit 1
