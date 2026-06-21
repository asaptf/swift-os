// SPDX-License-Identifier: Apache-2.0
// Config.swift — the `sctl` config file (the kubeconfig analog) (SC9a).
//
// `sctl` resolves where to talk and how to authenticate from a small config file: the controller
// endpoint plus the client cert / key / CA paths for the SC2 mTLS control API. The format is the
// same compose-like YAML the manifest uses, so it parses through the Foundation-free `Yaml.swift`
// — only the FILE READ (resolving paths, loading the file) is host I/O and lives in main.swift.
//
// A `local: <statedir>` form selects the in-process StoreControlClient over an on-disk cubestore
// (single-node / dev), which is the only client SC9a can actually drive end to end: the remote
// mTLS `WireControlClient` needs `sctld`'s production accept-loop, which is the SC9b seam. So a
// config without `local:` resolves to "remote — not yet wired (SC9b)" rather than pretending.
//
// Example `~/.sctl/config`:
//   endpoint: https://10.0.0.10:7700
//   clientCert: ~/.sctl/client.crt
//   clientKey:  ~/.sctl/client.key
//   ca:         ~/.sctl/ca.crt
//   # or, for single-node/dev:
//   local: ~/.sctl/state

struct SctlConfig: Equatable {
    var endpoint: String = ""
    var clientCert: String = ""
    var clientKey: String = ""
    var ca: String = ""
    var localStateDir: String = ""   // non-empty ⇒ use the in-process store at this path

    var isLocal: Bool { !localStateDir.isEmpty }
}

/// Parse a config document (the bytes of the config file). Pure/Foundation-free so it is unit
/// testable; returns the typed config or a human error.
enum ConfigResult: Equatable {
    case ok(SctlConfig)
    case error(String)
}

func parseConfig(_ bytes: [UInt8]) -> ConfigResult {
    switch parseYaml(bytes) {
    case .error(let m): return .error(m)
    case .ok(let node):
        guard case .mapping = node else { return .error("config root must be a mapping") }
        var c = SctlConfig()
        if let s = node.child("endpoint")?.asScalar { c.endpoint = s }
        if let s = node.child("clientCert")?.asScalar { c.clientCert = s }
        if let s = node.child("clientKey")?.asScalar { c.clientKey = s }
        if let s = node.child("ca")?.asScalar { c.ca = s }
        if let s = node.child("local")?.asScalar { c.localStateDir = s }
        if !c.isLocal && c.endpoint.isEmpty {
            return .error("config must set either 'local: <dir>' or 'endpoint: <url>'")
        }
        return .ok(c)
    }
}
