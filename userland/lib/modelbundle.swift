// SPDX-License-Identifier: Apache-2.0
//
// modelbundle.swift — verified model bundles (I5): the manifest schema and
// integrity checks for /models/<name>/<generation>/ directories, as recorded
// in ARCHITECTURE.md ("Model storage should use signed immutable bundles").
//
// This file is I/O-free and Foundation-free so the identical source compiles
// on the host (tests/llm_bundle_test.swift) and as Embedded Swift inside
// /bin/llmd, like llama2.swift and tls13.swift. Callers do the I/O (read the
// manifest bytes, mmap the payload files) and hand bytes in; this file owns
// parsing and verification policy. SHA-256 comes from kernel/crypto/
// sha256.swift, compiled alongside (the console-login pattern).
//
// Manifest: the OS-preferred small TOML subset (docs/ARCHITECTURE.md):
//
//   name = "stories15M"
//   generation = 1
//   format = "llama2c-q8"
//
//   [file.model]
//   path = "model.bin"
//   sha256 = "<64 hex chars>"
//   size = 17101696
//
//   [file.tokenizer]
//   path = "tokenizer.bin"
//   sha256 = "<64 hex chars>"
//   size = 433869
//
// Subset rules: `key = value` lines (value = "string" or integer), `[table]`
// headers, `#` comments, blank lines. No escapes, no arrays, no nesting beyond
// the [file.*] tables. Unknown keys/tables are ignored (forward compatible);
// missing required fields fail the parse. Signatures are future work — the
// schema deliberately leaves room for a [signature] table once an Ed25519
// primitive exists; verification today is integrity (sha256), not authenticity.

struct ModelBundleFile {
    var path: String = ""
    var sha256: String = ""
    var size: Int = -1

    var isComplete: Bool { !path.isEmpty && sha256.count == 64 && size >= 0 }
}

struct ModelManifest {
    var name: String = ""
    var generation: Int = -1
    var format: String = ""
    var model = ModelBundleFile()
    var tokenizer = ModelBundleFile()

    var isComplete: Bool {
        !name.isEmpty && generation >= 0 && model.isComplete && tokenizer.isComplete
    }
}

/// Parse a manifest.toml (the subset above) from raw bytes. Returns nil when
/// the required fields are missing or a line is malformed.
func modelManifestParse(_ bytes: UnsafeRawBufferPointer) -> ModelManifest? {
    var m = ModelManifest()
    var section = ""            // "", "file.model", "file.tokenizer", or other
    var i = 0
    let n = bytes.count

    func skipSpaces(_ j: inout Int) { while j < n, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 } }

    while i < n {
        // Take one line [i, eol).
        var eol = i
        while eol < n && bytes[eol] != 0x0A { eol += 1 }
        var j = i
        var end = eol
        if end > j && bytes[end - 1] == 0x0D { end -= 1 }   // strip \r
        i = eol + 1

        skipSpaces(&j)
        if j >= end || bytes[j] == 0x23 { continue }        // blank or # comment

        if bytes[j] == 0x5B {                                // '[' table header
            var k = j + 1
            var name: [UInt8] = []
            while k < end && bytes[k] != 0x5D { name.append(bytes[k]); k += 1 }
            if k >= end { return nil }                       // unterminated [
            section = String(decoding: name, as: UTF8.self)
            continue
        }

        // key = value
        var key: [UInt8] = []
        while j < end, bytes[j] != 0x20, bytes[j] != 0x09, bytes[j] != 0x3D {
            key.append(bytes[j]); j += 1
        }
        skipSpaces(&j)
        if j >= end || bytes[j] != 0x3D { return nil }       // missing '='
        j += 1
        skipSpaces(&j)
        if j >= end { return nil }

        var strVal: String? = nil
        var intVal: Int? = nil
        if bytes[j] == 0x22 {                                // "string"
            j += 1
            var v: [UInt8] = []
            while j < end && bytes[j] != 0x22 { v.append(bytes[j]); j += 1 }
            if j >= end { return nil }                       // unterminated "
            strVal = String(decoding: v, as: UTF8.self)
        } else {                                             // integer
            var v = 0
            var any = false
            while j < end, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                v = v * 10 + Int(bytes[j] - 0x30); j += 1; any = true
            }
            if !any { return nil }
            intVal = v
        }

        let k = String(decoding: key, as: UTF8.self)
        switch section {
        case "":
            if k == "name", let s = strVal { m.name = s }
            else if k == "generation", let v = intVal { m.generation = v }
            else if k == "format", let s = strVal { m.format = s }
        case "file.model":
            if k == "path", let s = strVal { m.model.path = s }
            else if k == "sha256", let s = strVal { m.model.sha256 = s }
            else if k == "size", let v = intVal { m.model.size = v }
        case "file.tokenizer":
            if k == "path", let s = strVal { m.tokenizer.path = s }
            else if k == "sha256", let s = strVal { m.tokenizer.sha256 = s }
            else if k == "size", let v = intVal { m.tokenizer.size = v }
        default:
            break                                            // unknown table: ignore
        }
    }
    return m.isComplete ? m : nil
}

/// Verify one bundle payload against its manifest entry: size first (cheap),
/// then SHA-256 over the bytes (for an mmap'd file this also faults the whole
/// payload in — verified means resident). Case-insensitive hex compare.
func modelBundleVerify(_ entry: ModelBundleFile, _ bytes: UnsafeRawPointer, _ len: Int) -> Bool {
    if len != entry.size { return false }
    var hex = [UInt8](repeating: 0, count: 64)
    hex.withUnsafeMutableBytes { out in
        sha256Hex(bytes, len, out.baseAddress!)
    }
    let want = Array(entry.sha256.utf8)
    if want.count != 64 { return false }
    for i in 0..<64 {
        var w = want[i]
        if w >= 0x41 && w <= 0x46 { w += 32 }   // A-F -> a-f
        if hex[i] != w { return false }
    }
    return true
}

/// Order candidate generation numbers newest-first (the load policy is "serve
/// the highest generation that verifies; fall back on failure").
func modelGenerationsNewestFirst(_ gens: [Int]) -> [Int] {
    var g = gens
    // Insertion sort, descending (tiny arrays; no stdlib sort dependency).
    var i = 1
    while i < g.count {
        let v = g[i]
        var j = i - 1
        while j >= 0 && g[j] < v { g[j + 1] = g[j]; j -= 1 }
        g[j + 1] = v
        i += 1
    }
    return g
}
