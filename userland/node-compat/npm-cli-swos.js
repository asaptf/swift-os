#!/usr/bin/env node
'use strict'
// SwiftOS npm-cli shim (installed as /bin/npm-cli-swos.js, not under npm's tree).
// Running a script inside deps/npm makes Node walk npm/node_modules on startup,
// which hangs on SwiftOS VFS. Stock lib/cli/entry.js also calls graceful-fs.
process.argv[1] = 'npm'
process.env.NPM_CONFIG_LOGS_MAX = process.env.NPM_CONFIG_LOGS_MAX || '0'
process.env.NPM_CONFIG_UPDATE_NOTIFIER = 'false'
process.env.NPM_CONFIG_TIMING = 'false'
try { process.chdir('/tmp') } catch (_) {}

const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const NPM_VERSION = '11.13.0'
const NPM_ROOT = '/usr/lib/node_modules/npm'

function installArgs () {
  const add = []
  for (let i = 3; i < process.argv.length; i++) {
    const a = process.argv[i]
    if (a === '--') { break }
    if (a.startsWith('-')) { continue }
    add.push(a)
  }
  return add
}

function isTarball (spec) {
  return spec.endsWith('.tgz') || spec.endsWith('.tar.gz') || spec.startsWith('file:')
}

function extractTarball (spec, dest) {
  const file = spec.startsWith('file:') ? spec.slice(5) : spec
  fs.mkdirSync(dest, { recursive: true })
  execFileSync('busybox', ['tar', '-xzf', file, '-C', dest], { stdio: 'ignore' })
}

async function installOne (spec, prefix, cache) {
  const mods = path.join(prefix, 'lib', 'node_modules')
  const tmp = path.join(cache, `.install-${process.pid}-${Date.now()}`)
  fs.mkdirSync(tmp, { recursive: true })
  try {
    if (isTarball(spec)) {
      extractTarball(spec, tmp)
    } else {
      process.env.NODE_PATH = [
        path.join(NPM_ROOT, 'node_modules'),
        process.env.NODE_PATH || '',
      ].filter(Boolean).join(path.delimiter)
      const pacote = require('pacote')
      await pacote.extract(spec, tmp, { cache, preferOnline: true })
    }
    const mani = JSON.parse(fs.readFileSync(path.join(tmp, 'package.json'), 'utf8'))
    const dest = path.join(mods, mani.name)
    fs.mkdirSync(mods, { recursive: true })
    fs.rmSync(dest, { recursive: true, force: true })
    fs.renameSync(tmp, dest)
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true })
  }
}

async function fastInstall () {
  const add = installArgs()
  if (!add.length) {
    console.error('npm install: missing package argument')
    process.exit(1)
  }
  const prefix = process.env.NPM_CONFIG_PREFIX || '/tmp/npm-prefix'
  const cache = process.env.NPM_CONFIG_CACHE || '/tmp/npm-cache'
  fs.mkdirSync(cache, { recursive: true })
  for (const spec of add) {
    await installOne(spec, prefix, cache)
  }
  const n = add.length
  console.log(`added ${n} package${n === 1 ? '' : 's'}`)
  process.exit(0)
}

async function fullCli () {
  process.env.NODE_PATH = [
    path.join(NPM_ROOT, 'node_modules'),
    NPM_ROOT,
    process.env.NODE_PATH || '',
  ].filter(Boolean).join(path.delimiter)
  const Npm = require(path.join(NPM_ROOT, 'lib/npm.js'))
  const npm = new Npm({ excludeNpmCwd: true })
  const loaded = await npm.load()
  if (!loaded.exec) {
    process.exit(process.exitCode || 0)
  }
  await npm.exec(loaded.command, loaded.args)
  process.exit(process.exitCode || 0)
}

;(async () => {
  const cmd = process.argv[2]
  if (cmd === '--version' || process.argv.includes('--version')) {
    console.log(NPM_VERSION)
    process.exit(0)
  }
  if (cmd === 'install') {
    return fastInstall()
  }
  return fullCli()
})().catch((err) => {
  console.error(err && err.stack ? err.stack : err)
  process.exit(1)
})