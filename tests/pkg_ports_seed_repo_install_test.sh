#!/usr/bin/env bash
# pkg_ports_seed_repo_install_test.sh - P7/P13 smoke: install seed ports from one repo.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU:-qemu-system-aarch64}"
PYTHON="${PYTHON:-python3}"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
PORT="${PORT:-18193}"
REPO_URL="http://10.0.2.2:$PORT/aarch64/current"
BASE="$ROOT/build/base-ports-seed-repo.img"
STORE_DISK="$ROOT/build/pkgstore-lua-install.img"
REPO_DIR="$ROOT/build/ports-seed-repo-root"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
rm -f "$BASE"
( cd "$ROOT" && make BASE_IMG=build/base-ports-seed-repo.img PKG_DEFAULT_REPO_URL="$REPO_URL" base-image ) >/dev/null 2>&1 || {
  echo "FAIL: cannot build default-repo base image" >&2; exit 2;
}
( cd "$ROOT" && make package-lua-install-fixture ) >/dev/null 2>&1 || {
  echo "FAIL: cannot create package store image" >&2; exit 2;
}
[[ -f "$REPO_DIR/aarch64/current/catalog.signed" ]] || {
  ( cd "$ROOT" && make ports-seed-repo-fixture ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build seed ports repository fixture" >&2; exit 2;
  }
}
printf 'curl-fixture-ok\n' > "$REPO_DIR/curl-fixture.txt"
command -v "$PYTHON" >/dev/null 2>&1 || { echo "FAIL: $PYTHON not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-pkg-ports.XXXXXX)"
HTTPLOG="$(mktemp -t swiftos-pkg-ports-http.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-pkg-ports-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-pkg-ports-in.XXXXXX)"; mkfifo "$INFIFO"
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
    echo "--- serial (ports seed driver) ---" >&2
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
  local line="$1" delay="${PKG_PORTS_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PKG_PORTS_SEND_DELAY:-0.08}"
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
await "pkg: catalog updated $REPO_URL" 120 || drive_fail "pkg update did not complete from default repo"
send_line "pkg search zlib"
await "zlib-1.3.1_1" 60 || drive_fail "pkg search did not find zlib"
send_line "pkg search bzip2"
await "bzip2-1.0.8_1" 60 || drive_fail "pkg search did not find bzip2"
send_line "pkg search zstd"
await "zstd-1.5.7_1" 60 || drive_fail "pkg search did not find zstd"
send_line "pkg search xz"
await "xz-5.8.3_1" 60 || drive_fail "pkg search did not find xz"
send_line "pkg search libarchive"
await "libarchive-3.8.7_1" 60 || drive_fail "pkg search did not find libarchive"
send_line "pkg search ca-certificates"
await "ca-certificates-2026.05.14_1" 60 || drive_fail "pkg search did not find ca-certificates"
send_line "pkg search openssl"
await "openssl-3.5.7_1" 60 || drive_fail "pkg search did not find openssl"
send_line "pkg search pcre2"
await "pcre2-10.47_1" 60 || drive_fail "pkg search did not find pcre2"
send_line "pkg search curl"
await "curl-8.20.0_1" 60 || drive_fail "pkg search did not find curl"
send_line "pkg search sqlite"
await "sqlite-3.53.2_1" 60 || drive_fail "pkg search did not find sqlite"
send_line "pkg install lua"
await "pkg: installed lua-5.4.8_1" 120 || drive_fail "lua package was not installed"
send_line "pkg install zlib"
await "pkg: installed zlib-1.3.1_1" 120 || drive_fail "zlib package was not installed"
send_line "a=zlib; b=ok; echo \$a-\$b | /usr/bin/minigzip | /usr/bin/minigzip -d"
await "zlib-ok" 60 || drive_fail "minigzip round-trip output mismatch"
send_line "pkg install bzip2"
await "pkg: installed bzip2-1.0.8_1" 120 || drive_fail "bzip2 package was not installed"
send_line "/usr/bin/bzip2 -V"
await "Version 1.0.8" 60 || drive_fail "bzip2 version output mismatch"
send_line "cat /usr/share/bzip2/swiftos-bzip2.version"
await "bzip2 1.0.8 swift-os static-tools" 60 || drive_fail "bzip2 marker output mismatch"
send_line "pkg install zstd"
await "pkg: installed zstd-1.5.7_1" 120 || drive_fail "zstd package was not installed"
send_line "a=zstd; b=ok; echo \$a-\$b > /tmp/zstd.in"
send_line "/usr/bin/zstd -q -f /tmp/zstd.in -o /tmp/zstd.zst"
send_line "/usr/bin/zstd -q -d -f /tmp/zstd.zst -o /tmp/zstd.out"
send_line "cat /tmp/zstd.out"
await "zstd-ok" 60 || drive_fail "zstd round-trip output mismatch"
send_line "cat /usr/share/zstd/swiftos-zstd.version"
await "zstd 1.5.7 swift-os static-single-thread" 60 || drive_fail "zstd marker output mismatch"
send_line "pkg install xz"
await "pkg: installed xz-5.8.3_1" 120 || drive_fail "xz package was not installed"
send_line "echo xz-ok | /usr/bin/xz -q -c | /usr/bin/xz -q -d -c"
await "xz-ok" 60 || drive_fail "xz round-trip output mismatch"
send_line "cat /usr/share/xz/swiftos-xz.version"
await "xz 5.8.3 swift-os static-small-no-threads" 60 || drive_fail "xz marker output mismatch"
send_line "pkg install libarchive"
await "pkg: installed libarchive-3.8.7_1" 120 || drive_fail "libarchive package was not installed"
send_line "/usr/bin/bsdtar --version"
await "bsdtar 3.8.7" 60 || drive_fail "bsdtar version command did not run"
send_line "cd /tmp && echo libarchive-ok > libarchive.txt && /usr/bin/bsdtar -cf libarchive.tar libarchive.txt && /usr/bin/bsdtar -tf libarchive.tar"
await "libarchive.txt" 60 || drive_fail "bsdtar tar listing output mismatch"
send_line "cat /usr/share/libarchive/swiftos-libarchive.version"
await "libarchive 3.8.7 swift-os static-bsdtar-no-external-programs" 60 || drive_fail "libarchive marker output mismatch"
send_line "pkg install ca-certificates"
await "pkg: installed ca-certificates-2026.05.14_1" 120 || drive_fail "ca-certificates package was not installed"
send_line "cat /usr/share/certs/swiftos-ca-bundle.version"
await "curl-ca-bundle 2026-05-14 121 certificates" 60 || drive_fail "ca-certificates marker output mismatch"
send_line "pkg install openssl"
await "pkg: installed openssl-3.5.7_1" 120 || drive_fail "openssl package was not installed"
send_line "/usr/bin/openssl version"
await "OpenSSL 3.5.7" 60 || drive_fail "openssl version command did not run"
send_line "echo openssl-ok | /usr/bin/openssl dgst -sha256"
await "7964d2210bdef8b3f027cc77b290f175f4b28ff26adcb14f545c1cd6956d3ed1" 60 || drive_fail "openssl sha256 digest mismatch"
send_line "cat /usr/share/openssl/swiftos-openssl.version"
await "openssl 3.5.7 swift-os static-no-dso-no-modules" 60 || drive_fail "openssl marker output mismatch"
send_line "pkg install pcre2"
await "pkg: installed pcre2-10.47_1" 120 || drive_fail "pcre2 package was not installed"
send_line "a=nginx; b=lighttpd; echo \$a-\$b > /tmp/pcre2.txt"
send_line "/usr/bin/pcre2grep 'nginx|lighttpd' /tmp/pcre2.txt"
await "nginx-lighttpd" 60 || drive_fail "pcre2grep output mismatch"
send_line "pkg install curl"
await "pkg: installed curl-8.20.0_1" 120 || drive_fail "curl package was not installed"
send_line "/usr/bin/curl --version"
await "curl 8.20.0" 60 || drive_fail "curl version command did not run"
send_line "/usr/bin/curl -fsS http://10.0.2.2:$PORT/curl-fixture.txt"
await "curl-fixture-ok" 60 || drive_fail "curl HTTP fetch output mismatch"
send_line "cat /usr/share/curl/swiftos-curl.version"
await "curl 8.20.0 swift-os static-http-no-tls" 60 || drive_fail "curl marker output mismatch"
send_line "pkg install tzdata"
await "pkg: installed tzdata-2026b_1" 120 || drive_fail "tzdata package was not installed"
send_line "pkg install nginx"
await "pkg: installed nginx-1.30.2_1" 120 || drive_fail "nginx package was not installed"
send_line "pkg install sqlite"
await "pkg: installed sqlite-3.53.2_1" 120 || drive_fail "sqlite package was not installed"
send_line "pkg list"
await "lua-5.4.8_1" 60 || drive_fail "installed lua package not listed"
await "zlib-1.3.1_1" 60 || drive_fail "installed zlib package not listed"
await "bzip2-1.0.8_1" 60 || drive_fail "installed bzip2 package not listed"
await "zstd-1.5.7_1" 60 || drive_fail "installed zstd package not listed"
await "xz-5.8.3_1" 60 || drive_fail "installed xz package not listed"
await "libarchive-3.8.7_1" 60 || drive_fail "installed libarchive package not listed"
await "ca-certificates-2026.05.14_1" 60 || drive_fail "installed ca-certificates package not listed"
await "openssl-3.5.7_1" 60 || drive_fail "installed openssl package not listed"
await "pcre2-10.47_1" 60 || drive_fail "installed pcre2 package not listed"
await "curl-8.20.0_1" 60 || drive_fail "installed curl package not listed"
await "sqlite-3.53.2_1" 60 || drive_fail "installed sqlite package not listed"
send_line "cat /usr/share/zoneinfo/swiftos-tzdata.version"
await "iana-tzdata 2026b 598 compiled-zone-files" 60 || drive_fail "tzdata marker output mismatch"
send_line "cat /usr/share/zoneinfo/zone1970.tab"
await "Europe/Madrid" 60 || drive_fail "zone1970.tab did not include Europe/Madrid"
await "America/Vancouver" 60 || drive_fail "zone1970.tab did not include America/Vancouver"
send_line "/usr/sbin/nginx -v"
await "nginx version: nginx/1.30.2" 60 || drive_fail "nginx version command did not run"
send_line "cat /usr/share/nginx/swiftos-nginx.version"
await "nginx 1.30.2 swift-os minimal-http" 60 || drive_fail "nginx marker output mismatch"
send_line "/usr/bin/sqlite3 -batch -noheader -cmd '.mode list' :memory: 'select 6*7;'"
await "42" 60 || drive_fail "sqlite SQL smoke output mismatch"
send_line "cat /usr/share/sqlite/swiftos-sqlite.version"
await "sqlite 3.53.2 swift-os static-shell" 60 || drive_fail "sqlite marker output mismatch"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_all
QP=""; HTTPPID=""

clean="$(tr -d '\r' < "$LOG")"
ok=1
grep -qF "pkg: catalog updated" <<<"$clean" || { echo "FAIL: pkg update output missing" >&2; ok=0; }
grep -qF "pkg: installed lua-5.4.8_1" <<<"$clean" || { echo "FAIL: lua install output missing" >&2; ok=0; }
grep -qF "pkg: installed zlib-1.3.1_1" <<<"$clean" || { echo "FAIL: zlib install output missing" >&2; ok=0; }
grep -qF "pkg: installed bzip2-1.0.8_1" <<<"$clean" || { echo "FAIL: bzip2 install output missing" >&2; ok=0; }
grep -qF "pkg: installed zstd-1.5.7_1" <<<"$clean" || { echo "FAIL: zstd install output missing" >&2; ok=0; }
grep -qF "pkg: installed xz-5.8.3_1" <<<"$clean" || { echo "FAIL: xz install output missing" >&2; ok=0; }
grep -qF "pkg: installed libarchive-3.8.7_1" <<<"$clean" || { echo "FAIL: libarchive install output missing" >&2; ok=0; }
grep -qF "pkg: installed ca-certificates-2026.05.14_1" <<<"$clean" || { echo "FAIL: ca-certificates install output missing" >&2; ok=0; }
grep -qF "pkg: installed openssl-3.5.7_1" <<<"$clean" || { echo "FAIL: openssl install output missing" >&2; ok=0; }
grep -qF "pkg: installed pcre2-10.47_1" <<<"$clean" || { echo "FAIL: pcre2 install output missing" >&2; ok=0; }
grep -qF "pkg: installed curl-8.20.0_1" <<<"$clean" || { echo "FAIL: curl install output missing" >&2; ok=0; }
grep -qF "pkg: installed tzdata-2026b_1" <<<"$clean" || { echo "FAIL: tzdata install output missing" >&2; ok=0; }
grep -qF "pkg: installed nginx-1.30.2_1" <<<"$clean" || { echo "FAIL: nginx install output missing" >&2; ok=0; }
grep -qF "pkg: installed sqlite-3.53.2_1" <<<"$clean" || { echo "FAIL: sqlite install output missing" >&2; ok=0; }
grep -qF "zlib-ok" <<<"$clean" || { echo "FAIL: minigzip round-trip output missing" >&2; ok=0; }
grep -qF "Version 1.0.8" <<<"$clean" || { echo "FAIL: bzip2 version output missing" >&2; ok=0; }
grep -qF "bzip2 1.0.8 swift-os static-tools" <<<"$clean" || { echo "FAIL: bzip2 marker output missing" >&2; ok=0; }
grep -qF "zstd-ok" <<<"$clean" || { echo "FAIL: zstd round-trip output missing" >&2; ok=0; }
grep -qF "zstd 1.5.7 swift-os static-single-thread" <<<"$clean" || { echo "FAIL: zstd marker output missing" >&2; ok=0; }
grep -qF "xz-ok" <<<"$clean" || { echo "FAIL: xz round-trip output missing" >&2; ok=0; }
grep -qF "xz 5.8.3 swift-os static-small-no-threads" <<<"$clean" || { echo "FAIL: xz marker output missing" >&2; ok=0; }
grep -qF "bsdtar 3.8.7" <<<"$clean" || { echo "FAIL: bsdtar version output missing" >&2; ok=0; }
grep -qF "libarchive.txt" <<<"$clean" || { echo "FAIL: bsdtar listing output missing" >&2; ok=0; }
grep -qF "libarchive 3.8.7 swift-os static-bsdtar-no-external-programs" <<<"$clean" || { echo "FAIL: libarchive marker output missing" >&2; ok=0; }
grep -qF "curl-ca-bundle 2026-05-14 121 certificates" <<<"$clean" || { echo "FAIL: ca-certificates marker output missing" >&2; ok=0; }
grep -qF "OpenSSL 3.5.7" <<<"$clean" || { echo "FAIL: openssl version output missing" >&2; ok=0; }
grep -qF "7964d2210bdef8b3f027cc77b290f175f4b28ff26adcb14f545c1cd6956d3ed1" <<<"$clean" || { echo "FAIL: openssl digest output missing" >&2; ok=0; }
grep -qF "openssl 3.5.7 swift-os static-no-dso-no-modules" <<<"$clean" || { echo "FAIL: openssl marker output missing" >&2; ok=0; }
grep -qF "nginx-lighttpd" <<<"$clean" || { echo "FAIL: pcre2grep output missing" >&2; ok=0; }
grep -qF "curl 8.20.0" <<<"$clean" || { echo "FAIL: curl version output missing" >&2; ok=0; }
grep -qF "curl-fixture-ok" <<<"$clean" || { echo "FAIL: curl HTTP fetch output missing" >&2; ok=0; }
grep -qF "curl 8.20.0 swift-os static-http-no-tls" <<<"$clean" || { echo "FAIL: curl marker output missing" >&2; ok=0; }
grep -qF "iana-tzdata 2026b 598 compiled-zone-files" <<<"$clean" || { echo "FAIL: tzdata marker output missing" >&2; ok=0; }
grep -qF "America/Vancouver" <<<"$clean" || { echo "FAIL: zone1970 output missing" >&2; ok=0; }
grep -qF "nginx version: nginx/1.30.2" <<<"$clean" || { echo "FAIL: nginx version output missing" >&2; ok=0; }
grep -qF "nginx 1.30.2 swift-os minimal-http" <<<"$clean" || { echo "FAIL: nginx marker output missing" >&2; ok=0; }
grep -qxF "42" <<<"$clean" || { echo "FAIL: sqlite SQL output missing" >&2; ok=0; }
grep -qF "sqlite 3.53.2 swift-os static-shell" <<<"$clean" || { echo "FAIL: sqlite marker output missing" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during ports seed repo install" >&2; ok=0; }
grep -qF "GET /aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: catalog request missing" >&2; ok=0; }
grep -qF "GET /aarch64/current/packages/" "$HTTPLOG" || { echo "FAIL: package request missing" >&2; ok=0; }
grep -qF "GET /curl-fixture.txt" "$HTTPLOG" || { echo "FAIL: curl fixture request missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/pkg installed Lua, zlib, bzip2, zstd, xz, libarchive, ca-certificates, OpenSSL, pcre2, curl, tzdata, nginx, and sqlite from one signed ports seed repo"
  exit 0
fi

echo "--- serial (ports seed region) ---" >&2
tail -n 260 "$LOG" >&2 || true
echo "--- http log ---" >&2
cat "$HTTPLOG" >&2 || true
exit 1
