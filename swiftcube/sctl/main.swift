// SPDX-License-Identifier: Apache-2.0
// main.swift — the host `sctl` binary: a thin shell around the testable command layer (SC9a).
//
// All the logic — argument dispatch, manifest validation, output formatting — lives in
// Command.swift behind the `ControlClient` seam and is tested without any of this. This file is
// only the host I/O the seam cannot be: resolving the config, reading a `-f` manifest file,
// constructing the client, printing, and exiting. Foundation lives here and nowhere else in the
// CLI.
//
// Client selection (SC9a reality, surfaced honestly):
//   • `local: <dir>` config (or `--local <dir>`) ⇒ a StoreControlClient over an on-disk cubestore
//     (single-node / dev). This is fully wired and is what `sctl` drives today.
//   • a remote `endpoint:` ⇒ the mTLS WireControlClient, which needs `sctld`'s production
//     accept-loop — the SC9b seam. Rather than pretend, `sctl` says so and exits non-zero.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func errln(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "."
    return home + String(path.dropFirst(1))
}

/// Resolve the config: an explicit `--config`, then `$SCTL_CONFIG`, then `~/.sctl/config`. A
/// `--local <dir>` flag short-circuits to a local config without a file.
func resolveConfig(_ args: inout [String]) -> SctlConfig? {
    if let dir = takeFlagValue(&args, "--local") {
        return SctlConfig(localStateDir: expandTilde(dir))
    }
    var path = takeFlagValue(&args, "--config")
        ?? ProcessInfo.processInfo.environment["SCTL_CONFIG"]
        ?? expandTilde("~/.sctl/config")
    path = expandTilde(path)
    guard let data = FileManager.default.contents(atPath: path) else {
        errln("error: no config at \(path) (set one, or pass --local <dir> for single-node mode)")
        return nil
    }
    switch parseConfig(Array(data)) {
    case .error(let m): errln("error: config: \(m)"); return nil
    case .ok(let c): return c
    }
}

/// Remove `--flag value` (or `--flag=value`) from `args` and return the value, if present.
func takeFlagValue(_ args: inout [String], _ flag: String) -> String? {
    let pfx = flag + "="
    var i = 0
    while i < args.count {
        if args[i] == flag, i + 1 < args.count {
            let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
        }
        if args[i].hasPrefix(pfx) {
            let v = String(args[i].dropFirst(pfx.count)); args.remove(at: i); return v
        }
        i += 1
    }
    return nil
}

/// The value of `-f`/`--filename` (kept in `args` so the dispatcher still sees the flag).
func manifestPath(_ args: [String]) -> String? {
    for (i, a) in args.enumerated() {
        if (a == "-f" || a == "--filename"), i + 1 < args.count { return args[i + 1] }
    }
    return nil
}

// MARK: - Entry

var args = Array(CommandLine.arguments.dropFirst())

// Global flags first (removed before the verb dispatch sees them).
guard let config = resolveConfig(&args) else { exit(2) }

// Read the manifest file for `apply`, if present.
var manifestBytes: [UInt8]? = nil
if let mp = manifestPath(args) {
    guard let data = FileManager.default.contents(atPath: expandTilde(mp)) else {
        errln("error: cannot read manifest at \(mp)"); exit(1)
    }
    manifestBytes = Array(data)
}

// Build the client.
guard config.isLocal else {
    errln("error: remote endpoint '\(config.endpoint)' needs the mTLS WireControlClient + sctld accept-loop — SC9b.")
    errln("       For single-node use today: sctl --local <statedir> <command>")
    exit(2)
}

let dir = config.localStateDir
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let store: CubeStore<PosixAppendLog, PosixSnapshotStore>
do {
    store = try CubeStore.open(log: PosixAppendLog(path: dir + "/wal.log"),
                               snapshot: PosixSnapshotStore(dir: dir))
} catch {
    errln("error: cannot open cubestore at \(dir): \(error)"); exit(1)
}
let client = StoreControlClient(store: store)

let result = dispatch(args, client: client, manifest: manifestBytes)
store.sync()
if !result.output.isEmpty { print(result.output) }
exit(result.exitCode)
