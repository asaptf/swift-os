// SPDX-License-Identifier: Apache-2.0
// NginxApplier.swift — the concrete ConfigApplier that programs a LOCAL nginx (SC6).
//
// This is the real applier behind the `ConfigApplier` seam: it writes per-service config
// fragments, validates the whole config tree with `nginx -t`, atomically swaps the changed
// fragment into the live include directory, and gracefully reloads with `nginx -s reload`
// (which drains old workers so a backend a rollout removed finishes its in-flight requests).
//
// It targets a nginx running on the SAME host (the SC6 testing target). Delivering config to a
// NON-local nginx — SSH, an on-node agent, or a cloud API — is the remote-delivery transport
// seam (deferred): a sibling ConfigApplier implementing the same three calls. Because nginx may
// be absent in CI, the host `lb-test` drives the in-memory FakeApplier instead; this file is
// compiled for coverage and used by the daemon / the conditional on-device gate.
//
// NOT Foundation-free — it shells out and touches the filesystem, so it is the one LB file that
// uses Foundation. It is never linked into the Embedded `sctld` build (the renderer/provider/
// loop are; this applier is host/daemon-side), preserving the Foundation-free core.
//
// Apply flow (validate-before-swap, atomic):
//   1. stage   — render every active fragment + the candidate into a fresh temp tree with a
//                generated main nginx.conf that `include`s it.
//   2. validate— `nginx -t -c <temp main>`; on failure return the error, the live config stays.
//   3. swap    — write the candidate to `<confDir>/<service>.conf.tmp`, then atomically rename
//                over `<confDir>/<service>.conf` (a crash before the rename leaves the old file).
//   4. reload  — `nginx -s reload` (graceful drain). A reload failure is reported; the swapped
//                file is already validated, so nginx keeps serving the previous workers.

import Foundation

final class NginxApplier: ConfigApplier {
    private let nginxBinary: String      // e.g. "/usr/sbin/nginx" or "nginx"
    private let confDir: String          // live include dir, e.g. "/etc/nginx/sctld.d"
    private let stageRoot: String        // scratch dir for validation, e.g. "/tmp/sctld-nginx"
    private let fm = FileManager.default

    init(nginxBinary: String = "nginx",
         confDir: String,
         stageRoot: String = NSTemporaryDirectory() + "sctld-nginx") {
        self.nginxBinary = nginxBinary; self.confDir = confDir; self.stageRoot = stageRoot
        try? fm.createDirectory(atPath: confDir, withIntermediateDirectories: true)
    }

    // MARK: - ConfigApplier

    func apply(service: String, config: String) -> ApplyOutcome {
        // 1. stage the whole tree (active fragments + this candidate) and 2. validate it.
        var fragments = activeFragments()
        fragments[service] = config
        if let err = validate(fragments) { return .failed(err) }

        // 3. atomic swap of just this service's fragment into the live dir.
        let live = livePath(service)
        let tmp = live + ".tmp"
        do {
            try config.write(toFile: tmp, atomically: false, encoding: .utf8)
            // rename(2) is atomic on the same filesystem: never a partial/active fragment.
            if fm.fileExists(atPath: live) { try? fm.removeItem(atPath: live) }
            try fm.moveItem(atPath: tmp, toPath: live)
        } catch {
            return .failed("swap \(service): \(error)")
        }

        // 4. graceful reload (the candidate is already validated).
        if let err = run(nginxBinary, ["-s", "reload"]) { return .failed("reload: \(err)") }
        return .success
    }

    func remove(service: String) -> ApplyOutcome {
        let live = livePath(service)
        if !fm.fileExists(atPath: live) { return .success }      // idempotent

        var fragments = activeFragments()
        fragments[service] = nil
        if let err = validate(fragments) { return .failed(err) }

        try? fm.removeItem(atPath: live)
        if let err = run(nginxBinary, ["-s", "reload"]) { return .failed("reload: \(err)") }
        return .success
    }

    func active(service: String) -> String? {
        try? String(contentsOfFile: livePath(service), encoding: .utf8)
    }

    // MARK: - Internals

    private func livePath(_ service: String) -> String { confDir + "/" + service + ".conf" }

    private func activeFragments() -> [String: String] {
        var out: [String: String] = [:]
        guard let names = try? fm.contentsOfDirectory(atPath: confDir) else { return out }
        for name in names where name.hasSuffix(".conf") {
            let svc = String(name.dropLast(".conf".count))
            if let body = try? String(contentsOfFile: confDir + "/" + name, encoding: .utf8) {
                out[svc] = body
            }
        }
        return out
    }

    /// Stage `fragments` into a fresh temp tree with a generated main config and run `nginx -t`.
    /// Returns nil if valid, else the validator's stderr — the live config is never touched here.
    private func validate(_ fragments: [String: String]) -> String? {
        let dir = stageRoot + "/v"
        try? fm.removeItem(atPath: dir)
        do {
            try fm.createDirectory(atPath: dir + "/conf.d", withIntermediateDirectories: true)
            for (svc, body) in fragments {
                try body.write(toFile: dir + "/conf.d/" + svc + ".conf", atomically: false, encoding: .utf8)
            }
            let main = """
            events {}
            http {
                include \(dir)/conf.d/*.conf;
            }

            """
            try main.write(toFile: dir + "/nginx.conf", atomically: false, encoding: .utf8)
        } catch {
            return "stage: \(error)"
        }
        return run(nginxBinary, ["-t", "-c", dir + "/nginx.conf"])
    }

    /// Run a command; return nil on exit 0, else combined stdout+stderr (or a spawn error).
    private func run(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolve(launch))
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "spawn \(launch): \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Resolve a bare binary name against PATH; pass through absolute paths unchanged.
    private func resolve(_ name: String) -> String {
        if name.hasPrefix("/") { return name }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/sbin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let full = String(dir) + "/" + name
            if fm.isExecutableFile(atPath: full) { return full }
        }
        return name
    }
}
