#!/bin/sh
# SwiftOS npm shim: Node cannot read packfs-hosted .js (hangs in libuv read).
# Fast paths use busybox tar + /tmp layout; full CLI copies the JS shim to /tmp first.
# Busybox config-minimal: no [, sed, tr, wc — use ash builtins + case only.
set -eu

NPM_VERSION=11.13.0
NPM_ROOT=/usr/lib/node_modules/npm

usage() {
  echo "usage: npm <command>" >&2
  exit 1
}

pkg_name_from_json() {
  pkgline=""
  while read -r line; do
    pkgline="$line"
  done <"$1/package.json"
  name="${pkgline#*\"name\"}"
  name="${name#*:}"
  name="${name#*\"}"
  name="${name%%\"*}"
  echo "$name"
}

install_pkgs() {
  prefix="${NPM_CONFIG_PREFIX:-/tmp/npm-prefix}"
  cache="${NPM_CONFIG_CACHE:-/tmp/npm-cache}"
  gotpkg=""
  mkdir -p "$prefix/lib/node_modules" "$cache"
  for spec in "$@"; do
    case "$spec" in
      -*) continue ;;
    esac
    tmp="$cache/install-$$-${gotpkg}x"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    case "$spec" in
      *.tgz|*.tar.gz|file:*)
        file="$spec"
        case "$file" in
          file:*) file="${file#file:}" ;;
        esac
        busybox gunzip -cf "$file" | busybox tar -xf - -C "$tmp"
        ;;
      *)
        tmpjs="/tmp/npm-pacote-$$.js"
        cat >"$tmpjs" <<'EOF'
const pacote = require(process.env.NPM_PACOTE_PATH || 'pacote');
const spec = process.argv[2];
const dest = process.argv[3];
const cache = process.env.NPM_CONFIG_CACHE || '/tmp/npm-cache';
pacote.extract(spec, dest, { cache, preferOnline: true }).then(() => process.exit(0)).catch((e) => {
  console.error(e && e.stack ? e.stack : e);
  process.exit(1);
});
EOF
        NPM_CONFIG_CACHE="$cache" \
        NODE_PATH="$NPM_ROOT/node_modules" \
        NPM_PACOTE_PATH="$NPM_ROOT/node_modules/pacote/lib/index.js" \
          /bin/node "$tmpjs" "$spec" "$tmp" || return 1
        rm -f "$tmpjs"
        ;;
    esac
    name="$(pkg_name_from_json "$tmp")"
    case "$name" in
      '') echo "npm install: no name in package.json" >&2; return 1 ;;
    esac
    dest="$prefix/lib/node_modules/$name"
    rm -rf "$dest"
    mkdir -p "$prefix/lib/node_modules"
    mv "$tmp" "$dest"
    gotpkg="${gotpkg}x"
  done
  case "$gotpkg" in
    '') echo "npm install: missing package argument" >&2; return 1 ;;
    x) echo "added 1 package" ;;
    xx) echo "added 2 packages" ;;
    xxx) echo "added 3 packages" ;;
    *) echo "added packages" ;;
  esac
}

run_js_shim() {
  tmp="/tmp/npm-cli-$$.js"
  cat >"$tmp" <<'SHIM_EOF'
#!/usr/bin/env node
'use strict'
process.argv[1] = 'npm'
process.env.NPM_CONFIG_LOGS_MAX = process.env.NPM_CONFIG_LOGS_MAX || '0'
process.env.NPM_CONFIG_UPDATE_NOTIFIER = 'false'
process.env.NPM_CONFIG_TIMING = 'false'
try { process.chdir('/tmp') } catch (_) {}
process.env.NODE_PATH = ['/usr/lib/node_modules/npm/node_modules', '/usr/lib/node_modules/npm', process.env.NODE_PATH || ''].filter(Boolean).join(':')
const Npm = require('/usr/lib/node_modules/npm/lib/npm.js')
;(async () => {
  const npm = new Npm({ excludeNpmCwd: true })
  const loaded = await npm.load()
  if (!loaded.exec) process.exit(process.exitCode || 0)
  await npm.exec(loaded.command, loaded.args)
  process.exit(process.exitCode || 0)
})().catch((err) => {
  console.error(err && err.stack ? err.stack : err)
  process.exit(1)
})
SHIM_EOF
  /bin/node "$tmp" "$@"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

case $# in
  0) usage ;;
esac
cmd="$1"
shift
case "$cmd" in
  --version|-v)
    echo "$NPM_VERSION"
    ;;
  install)
    install_pkgs "$@"
    ;;
  *)
    run_js_shim "$cmd" "$@"
    ;;
esac