#!/usr/bin/env bash
# pkg_lua_repo_install_test.sh - P6 smoke: install real Lua from a signed repo.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_DISK="$ROOT/build/base.img"
STORE_DISK="$ROOT/build/pkgstore-lua-install.img"
REPO_DIR="$ROOT/build/lua-repo-root"
QEMU="${QEMU:-qemu-system-aarch64}"
PYTHON="${PYTHON:-python3}"
PORT="${PKG_LUA_REPO_HOST_PORT:-$((26000 + ($$ % 18000)))}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$STORE_DISK" ]]; then
  ( cd "$ROOT" && make package-lua-install-fixture ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build Lua package store image" >&2; exit 2;
  }
fi
if [[ ! -d "$REPO_DIR/aarch64/current" ]]; then
  ( cd "$ROOT" && make ports-lua-repo-fixture ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build Lua package repository fixture" >&2; exit 2;
  }
fi
command -v "$PYTHON" >/dev/null 2>&1 || { echo "FAIL: $PYTHON not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-pkg-lua.XXXXXX)"
HTTPLOG="$(mktemp -t swiftos-pkg-lua-http.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-pkg-lua-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-pkg-lua-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (lua repo driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M11c:\|pkg \|Lua /,$p' >&2 || true
  echo "--- http server ---" >&2
  sed -n '1,120p' "$HTTPLOG" >&2 || true
  echo "--- tail ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${PKG_LUA_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${PKG_LUA_SEND_DELAY:-0.08}"
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
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

send_line "pkg repo set http://10.0.2.2:$PORT/aarch64/current"
await "pkg: repository set http://10.0.2.2:$PORT/aarch64/current" 60 || drive_fail "pkg repo set did not complete"
send_line 'pkg update'
await "pkg: catalog updated http://10.0.2.2:$PORT/aarch64/current" 120 || drive_fail "pkg update did not complete"
send_line 'pkg search lua'
await "lua-5.4.8_1" 60 || drive_fail "pkg search did not find lua"
send_line 'pkg info lua'
await "name: lua" 60 || drive_fail "pkg info did not show lua name"
await "depends: none" 60 || drive_fail "pkg info did not show lua dependencies"
send_line 'pkg install lua'
await "pkg: fetching lua-5.4.8_1" 120 || drive_fail "lua package was not fetched"
await "pkg: installed lua-5.4.8_1" 120 || drive_fail "lua package was not installed"
send_line 'pkg list'
await "lua-5.4.8_1" 60 || drive_fail "installed lua package not listed"
send_line '/usr/bin/lua -v'
await "Lua 5.4.8" 120 || drive_fail "lua -v did not run"
send_line "/usr/bin/lua -e 'print(21 * 2)'"
await "42" 120 || drive_fail "lua expression did not print 42"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_all
QP=""; HTTPPID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "pkg: catalog updated" <<<"$clean" || { echo "FAIL: pkg update output missing" >&2; ok=0; }
grep -qF "pkg: installed lua-5.4.8_1" <<<"$clean" || { echo "FAIL: lua install output missing" >&2; ok=0; }
grep -qF "Lua 5.4.8" <<<"$clean" || { echo "FAIL: lua version output missing" >&2; ok=0; }
grep -qF "42" <<<"$clean" || { echo "FAIL: lua expression output missing" >&2; ok=0; }
grep -qF "panic:" <<<"$clean" && { echo "FAIL: kernel panic during lua repo install" >&2; ok=0; }
grep -qF "GET /aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: lua catalog request missing" >&2; ok=0; }
grep -qF "GET /aarch64/current/packages/" "$HTTPLOG" || { echo "FAIL: lua package request missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/pkg installed real Lua from a signed repo and ran lua"
  exit 0
fi
echo "--- serial (lua repo region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/M11c:/,$p' >&2
echo "--- http server ---" >&2
sed -n '1,120p' "$HTTPLOG" >&2 || true
exit 1
