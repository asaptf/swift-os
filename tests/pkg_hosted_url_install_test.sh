#!/usr/bin/env bash
# pkg_hosted_url_install_test.sh - install seed packages from an already-hosted repo URL.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU:-qemu-system-aarch64}"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
REPO_URL="${PKG_HOSTED_REPO_URL:-}"
DNS_SERVER="${PKG_HOSTED_DNS_SERVER:-}"
BASE_REL="${PKG_HOSTED_BASE_IMG:-build/base-hosted-url.img}"
BASE="$ROOT/$BASE_REL"
STORE_DISK="$ROOT/build/pkgstore-lua-install.img"

[[ -n "$REPO_URL" ]] || { echo "FAIL: set PKG_HOSTED_REPO_URL=http://host/aarch64/current" >&2; exit 2; }
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
rm -f "$BASE"
( cd "$ROOT" && make BASE_IMG="$BASE_REL" PKG_DEFAULT_REPO_URL="$REPO_URL" PKG_DEFAULT_DNS_SERVER="$DNS_SERVER" base-image ) >/dev/null 2>&1 || {
  echo "FAIL: cannot build hosted-url default-repo base image" >&2; exit 2;
}
( cd "$ROOT" && make package-lua-install-fixture ) >/dev/null 2>&1 || {
  echo "FAIL: cannot create package store image" >&2; exit 2;
}

LOG="$(mktemp -t swiftos-pkg-hosted-url.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-pkg-hosted-url-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-pkg-hosted-url-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

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
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}

cleanup() {
  stop_all
  exec 3>&- 2>/dev/null || true
  rm -f "$LOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

drive_fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$LOG" ]]; then
    echo "--- serial (hosted URL driver) ---" >&2
    tail -n 260 "$LOG" >&2 || true
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
  local line="$1" delay="${PKG_HOSTED_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PKG_HOSTED_SEND_DELAY:-0.08}"
}

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

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

send_line "pkg repo show"
await "$REPO_URL" 60 || drive_fail "pkg repo show did not print hosted URL"
send_line "pkg update"
await "pkg: catalog updated $REPO_URL" 120 || drive_fail "pkg update did not complete from hosted repo"
send_line "pkg search lua"
await "lua-5.4.8_1" 60 || drive_fail "pkg search did not find lua"
send_line "pkg search zlib"
await "zlib-1.3.1_1" 60 || drive_fail "pkg search did not find zlib"
send_line "pkg search bzip2"
await "bzip2-1.0.8_1" 60 || drive_fail "pkg search did not find bzip2"
send_line "pkg search zstd"
await "zstd-1.5.7_1" 60 || drive_fail "pkg search did not find zstd"
send_line "pkg search ca-certificates"
await "ca-certificates-2026.05.14_1" 60 || drive_fail "pkg search did not find ca-certificates"
send_line "pkg search pcre2"
await "pcre2-10.47_1" 60 || drive_fail "pkg search did not find pcre2"
send_line "pkg search sqlite"
await "sqlite-3.53.2_1" 60 || drive_fail "pkg search did not find sqlite"
send_line "pkg install lua"
await "pkg: installed lua-5.4.8_1" 120 || drive_fail "lua package was not installed"
send_line "pkg install zlib"
await "pkg: installed zlib-1.3.1_1" 120 || drive_fail "zlib package was not installed"
send_line "echo hosted-url-ok | /usr/bin/minigzip | /usr/bin/minigzip -d"
await "hosted-url-ok" 60 || drive_fail "minigzip round-trip output mismatch"
send_line "pkg install bzip2"
await "pkg: installed bzip2-1.0.8_1" 120 || drive_fail "bzip2 package was not installed"
send_line "echo bzip2-hosted-url-ok | /usr/bin/bzip2 -c | /usr/bin/bzip2 -dc"
await "bzip2-hosted-url-ok" 60 || drive_fail "bzip2 round-trip output mismatch"
send_line "cat /usr/share/bzip2/swiftos-bzip2.version"
await "bzip2 1.0.8 swift-os static-tools" 60 || drive_fail "bzip2 marker output mismatch"
send_line "pkg install zstd"
await "pkg: installed zstd-1.5.7_1" 120 || drive_fail "zstd package was not installed"
send_line "echo zstd-hosted-url-ok | /usr/bin/zstd -q -c | /usr/bin/zstd -q -d -c"
await "zstd-hosted-url-ok" 60 || drive_fail "zstd round-trip output mismatch"
send_line "cat /usr/share/zstd/swiftos-zstd.version"
await "zstd 1.5.7 swift-os static-single-thread" 60 || drive_fail "zstd marker output mismatch"
send_line "pkg install ca-certificates"
await "pkg: installed ca-certificates-2026.05.14_1" 120 || drive_fail "ca-certificates package was not installed"
send_line "cat /usr/share/certs/swiftos-ca-bundle.version"
await "curl-ca-bundle 2026-05-14 121 certificates" 60 || drive_fail "ca-certificates marker output mismatch"
send_line "pkg install pcre2"
await "pkg: installed pcre2-10.47_1" 120 || drive_fail "pcre2 package was not installed"
send_line "printf 'nginx-lighttpd\nother\n' | /usr/bin/pcre2grep 'nginx|lighttpd'"
await "nginx-lighttpd" 60 || drive_fail "pcre2grep output mismatch"
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
send_line "pkg install sqlite"
await "pkg: installed sqlite-3.53.2_1" 120 || drive_fail "sqlite package was not installed"
send_line "/usr/bin/sqlite3 -batch -noheader -cmd '.mode list' :memory: 'select 6*7;'"
await "42" 60 || drive_fail "sqlite SQL smoke output mismatch"
send_line "cat /usr/share/sqlite/swiftos-sqlite.version"
await "sqlite 3.53.2 swift-os static-shell" 60 || drive_fail "sqlite marker output mismatch"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_all
QP=""

clean="$(tr -d '\r' < "$LOG")"
ok=1
grep -qF "pkg: catalog updated $REPO_URL" <<<"$clean" || { echo "FAIL: pkg update output missing" >&2; ok=0; }
grep -qF "pkg: installed lua-5.4.8_1" <<<"$clean" || { echo "FAIL: lua install output missing" >&2; ok=0; }
grep -qF "pkg: installed zlib-1.3.1_1" <<<"$clean" || { echo "FAIL: zlib install output missing" >&2; ok=0; }
grep -qF "pkg: installed bzip2-1.0.8_1" <<<"$clean" || { echo "FAIL: bzip2 install output missing" >&2; ok=0; }
grep -qF "pkg: installed zstd-1.5.7_1" <<<"$clean" || { echo "FAIL: zstd install output missing" >&2; ok=0; }
grep -qF "pkg: installed ca-certificates-2026.05.14_1" <<<"$clean" || { echo "FAIL: ca-certificates install output missing" >&2; ok=0; }
grep -qF "pkg: installed pcre2-10.47_1" <<<"$clean" || { echo "FAIL: pcre2 install output missing" >&2; ok=0; }
grep -qF "pkg: installed tzdata-2026b_1" <<<"$clean" || { echo "FAIL: tzdata install output missing" >&2; ok=0; }
grep -qF "pkg: installed nginx-1.30.2_1" <<<"$clean" || { echo "FAIL: nginx install output missing" >&2; ok=0; }
grep -qF "pkg: installed sqlite-3.53.2_1" <<<"$clean" || { echo "FAIL: sqlite install output missing" >&2; ok=0; }
grep -qF "hosted-url-ok" <<<"$clean" || { echo "FAIL: minigzip round-trip output missing" >&2; ok=0; }
grep -qF "bzip2-hosted-url-ok" <<<"$clean" || { echo "FAIL: bzip2 round-trip output missing" >&2; ok=0; }
grep -qF "bzip2 1.0.8 swift-os static-tools" <<<"$clean" || { echo "FAIL: bzip2 marker output missing" >&2; ok=0; }
grep -qF "zstd-hosted-url-ok" <<<"$clean" || { echo "FAIL: zstd round-trip output missing" >&2; ok=0; }
grep -qF "zstd 1.5.7 swift-os static-single-thread" <<<"$clean" || { echo "FAIL: zstd marker output missing" >&2; ok=0; }
grep -qF "curl-ca-bundle 2026-05-14 121 certificates" <<<"$clean" || { echo "FAIL: ca-certificates marker output missing" >&2; ok=0; }
grep -qF "nginx-lighttpd" <<<"$clean" || { echo "FAIL: pcre2grep output missing" >&2; ok=0; }
grep -qF "iana-tzdata 2026b 598 compiled-zone-files" <<<"$clean" || { echo "FAIL: tzdata marker output missing" >&2; ok=0; }
grep -qF "America/Vancouver" <<<"$clean" || { echo "FAIL: zone1970 output missing" >&2; ok=0; }
grep -qF "nginx version: nginx/1.30.2" <<<"$clean" || { echo "FAIL: nginx version output missing" >&2; ok=0; }
grep -qF "nginx 1.30.2 swift-os minimal-http" <<<"$clean" || { echo "FAIL: nginx marker output missing" >&2; ok=0; }
grep -qxF "42" <<<"$clean" || { echo "FAIL: sqlite SQL output missing" >&2; ok=0; }
grep -qF "sqlite 3.53.2 swift-os static-shell" <<<"$clean" || { echo "FAIL: sqlite marker output missing" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during hosted repo install" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/pkg installed Lua, zlib, bzip2, zstd, ca-certificates, pcre2, tzdata, nginx, and sqlite from hosted repository URL $REPO_URL"
  exit 0
fi

echo "--- serial (hosted URL region) ---" >&2
tail -n 260 "$LOG" >&2 || true
exit 1
