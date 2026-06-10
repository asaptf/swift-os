#!/usr/bin/env bash
# pkg_static_host_repo_install_test.sh - P8 smoke: install from the publishable web root.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU:-qemu-system-aarch64}"
PYTHON="${PYTHON:-python3}"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
PORT="${PORT:-18194}"
REPO_URL="http://10.0.2.2:$PORT/aarch64/current"
BASE="$ROOT/build/base-ports-static-host.img"
STORE_DISK="$ROOT/build/pkgstore-lua-install.img"
REPO_DIR="$ROOT/build/ports-static-host-root"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
rm -f "$BASE"
( cd "$ROOT" && make BASE_IMG=build/base-ports-static-host.img PKG_DEFAULT_REPO_URL="$REPO_URL" base-image ) >/dev/null 2>&1 || {
  echo "FAIL: cannot build static-host default-repo base image" >&2; exit 2;
}
( cd "$ROOT" && make package-lua-install-fixture ) >/dev/null 2>&1 || {
  echo "FAIL: cannot create package store image" >&2; exit 2;
}
[[ -f "$REPO_DIR/hosted-repo.json" && -f "$REPO_DIR/SHA256SUMS" ]] || {
  ( cd "$ROOT" && make ports-static-host-publish ) >/dev/null 2>&1 || {
    echo "FAIL: cannot publish static host repository" >&2; exit 2;
  }
}
( cd "$REPO_DIR" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 || {
  echo "FAIL: static host SHA256SUMS verification failed" >&2; exit 2;
}
command -v "$PYTHON" >/dev/null 2>&1 || { echo "FAIL: $PYTHON not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-pkg-static-host.XXXXXX)"
HTTPLOG="$(mktemp -t swiftos-pkg-static-host-http.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-pkg-static-host-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-pkg-static-host-in.XXXXXX)"; mkfifo "$INFIFO"
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
  rm -f "$LOG" "$HTTPLOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

drive_fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$LOG" ]]; then
    echo "--- serial (static host driver) ---" >&2
    tail -n 260 "$LOG" >&2 || true
  fi
  if [[ -f "$HTTPLOG" ]]; then
    echo "--- http log ---" >&2
    cat "$HTTPLOG" >&2 || true
  fi
  exit 1
}

await() {
  local needle="$1"
  local timeout="${2:-40}"
  local start now
  start="$(date +%s)"
  while true; do
    if grep -qF "$needle" "$LOG"; then return 0; fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then return 1; fi
    sleep 0.2
  done
}

send_line() {
  local line="$1" delay="${PKG_STATIC_HOST_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PKG_STATIC_HOST_SEND_DELAY:-0.08}"
}

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

( cd "$REPO_DIR" && "$PYTHON" -m http.server "$PORT" --bind 0.0.0.0 >"$HTTPLOG" 2>&1 ) &
HTTPPID=$!
disown "$HTTPPID" 2>/dev/null || true
sleep 0.8
kill -0 "$HTTPPID" 2>/dev/null || {
  echo "FAIL: HTTP server did not start" >&2
  sed -n '1,120p' "$HTTPLOG" >&2 || true
  exit 2
}

"$PYTHON" - "$PORT" <<'PY' || drive_fail "hosted-repo.json was not served or did not describe the seed packages"
import json
import sys
import urllib.request

port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/hosted-repo.json", timeout=5) as response:
    manifest = json.load(response)
names = {package["name"] for package in manifest.get("packages", [])}
if manifest.get("kind") != "swift-os-static-host-repository":
    raise SystemExit("wrong manifest kind")
if manifest.get("catalog") != "aarch64/current/catalog.signed":
    raise SystemExit("wrong catalog path")
if not {"lua", "zlib", "ca-certificates", "pcre2", "tzdata", "nginx"}.issubset(names):
    raise SystemExit(f"missing package names: {names}")
PY

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on" \
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

send_line "pkg update"
await "pkg: catalog updated $REPO_URL" 120 || drive_fail "pkg update did not complete from static host repo"
send_line "pkg search lua"
await "lua-5.4.8_1" 60 || drive_fail "pkg search did not find lua"
send_line "pkg search zlib"
await "zlib-1.3.1_1" 60 || drive_fail "pkg search did not find zlib"
send_line "pkg search ca-certificates"
await "ca-certificates-2026.05.14_1" 60 || drive_fail "pkg search did not find ca-certificates"
send_line "pkg search pcre2"
await "pcre2-10.47_1" 60 || drive_fail "pkg search did not find pcre2"
send_line "pkg search tzdata"
await "tzdata-2026b_1" 60 || drive_fail "pkg search did not find tzdata"
send_line "pkg search nginx"
await "nginx-1.30.2_1" 60 || drive_fail "pkg search did not find nginx"
send_line "pkg install lua"
await "pkg: installed lua-5.4.8_1" 120 || drive_fail "lua package was not installed"
send_line "pkg install zlib"
await "pkg: installed zlib-1.3.1_1" 120 || drive_fail "zlib package was not installed"
send_line "/usr/bin/lua -e 'print(21 * 2)'"
await "42" 120 || drive_fail "lua expression did not print 42"
send_line "a=static-host; b=-ok; echo \$a\$b > /tmp/zlib.txt"
send_line "/usr/bin/minigzip /tmp/zlib.txt"
send_line "echo compressed-static-host"
await "compressed-static-host" 60 || drive_fail "minigzip compression did not return"
send_line "/usr/bin/minigzip -d /tmp/zlib.txt.gz"
send_line "cat /tmp/zlib.txt"
await "static-host-ok" 60 || drive_fail "minigzip round-trip output mismatch"
send_line "pkg install ca-certificates"
await "pkg: installed ca-certificates-2026.05.14_1" 120 || drive_fail "ca-certificates package was not installed"
send_line "cat /usr/share/certs/swiftos-ca-bundle.version"
await "curl-ca-bundle 2026-05-14 121 certificates" 60 || drive_fail "ca-certificates marker output mismatch"
send_line "pkg install pcre2"
await "pkg: installed pcre2-10.47_1" 120 || drive_fail "pcre2 package was not installed"
send_line "echo nginx-lighttpd > /tmp/pcre2.txt"
send_line "/usr/bin/pcre2grep 'nginx|lighttpd' /tmp/pcre2.txt"
await "nginx-lighttpd" 60 || drive_fail "pcre2grep did not match the web-server pattern"
send_line "pkg install tzdata"
await "pkg: installed tzdata-2026b_1" 120 || drive_fail "tzdata package was not installed"
send_line "cat /usr/share/zoneinfo/swiftos-tzdata.version"
await "iana-tzdata 2026b 598 compiled-zone-files" 60 || drive_fail "tzdata marker output mismatch"
send_line "cat /usr/share/zoneinfo/zone1970.tab"
await "Europe/Madrid" 60 || drive_fail "zone1970.tab did not include Europe/Madrid"
await "America/Vancouver" 60 || drive_fail "zone1970.tab did not include America/Vancouver"
send_line "pkg install nginx"
await "pkg: installed nginx-1.30.2_1" 120 || drive_fail "nginx package was not installed"
send_line "/usr/sbin/nginx -v"
await "nginx version: nginx/1.30.2" 60 || drive_fail "nginx version command did not run"
send_line "cat /usr/share/nginx/swiftos-nginx.version"
await "nginx 1.30.2 swift-os minimal-http" 60 || drive_fail "nginx marker output mismatch"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_all
QP=""; HTTPPID=""

clean="$(tr -d '\r' < "$LOG")"
ok=1
grep -qF "pkg: catalog updated $REPO_URL" <<<"$clean" || { echo "FAIL: pkg update output missing" >&2; ok=0; }
grep -qF "pkg: installed lua-5.4.8_1" <<<"$clean" || { echo "FAIL: lua install output missing" >&2; ok=0; }
grep -qF "pkg: installed zlib-1.3.1_1" <<<"$clean" || { echo "FAIL: zlib install output missing" >&2; ok=0; }
grep -qF "pkg: installed ca-certificates-2026.05.14_1" <<<"$clean" || { echo "FAIL: ca-certificates install output missing" >&2; ok=0; }
grep -qF "pkg: installed pcre2-10.47_1" <<<"$clean" || { echo "FAIL: pcre2 install output missing" >&2; ok=0; }
grep -qF "pkg: installed tzdata-2026b_1" <<<"$clean" || { echo "FAIL: tzdata install output missing" >&2; ok=0; }
grep -qF "pkg: installed nginx-1.30.2_1" <<<"$clean" || { echo "FAIL: nginx install output missing" >&2; ok=0; }
grep -qF "static-host-ok" <<<"$clean" || { echo "FAIL: minigzip round-trip output missing" >&2; ok=0; }
grep -qF "curl-ca-bundle 2026-05-14 121 certificates" <<<"$clean" || { echo "FAIL: ca-certificates marker output missing" >&2; ok=0; }
grep -qF "nginx-lighttpd" <<<"$clean" || { echo "FAIL: pcre2grep output missing" >&2; ok=0; }
grep -qF "iana-tzdata 2026b 598 compiled-zone-files" <<<"$clean" || { echo "FAIL: tzdata marker output missing" >&2; ok=0; }
grep -qF "America/Vancouver" <<<"$clean" || { echo "FAIL: zone1970 output missing" >&2; ok=0; }
grep -qF "nginx version: nginx/1.30.2" <<<"$clean" || { echo "FAIL: nginx version output missing" >&2; ok=0; }
grep -qF "nginx 1.30.2 swift-os minimal-http" <<<"$clean" || { echo "FAIL: nginx marker output missing" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during static host repo install" >&2; ok=0; }
grep -qF "GET /hosted-repo.json" "$HTTPLOG" || { echo "FAIL: hosted manifest request missing" >&2; ok=0; }
grep -qF "GET /aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: catalog request missing" >&2; ok=0; }
grep -qF "GET /aarch64/current/packages/" "$HTTPLOG" || { echo "FAIL: package request missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/pkg installed Lua, zlib, ca-certificates, pcre2, tzdata, and nginx from the static-host published repository"
  exit 0
fi

echo "--- serial (static host region) ---" >&2
tail -n 260 "$LOG" >&2 || true
echo "--- http log ---" >&2
cat "$HTTPLOG" >&2 || true
exit 1
