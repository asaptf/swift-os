// SPDX-License-Identifier: Apache-2.0
//
// releasemanifest.swift — Foundation-free host tool that emits a release manifest
// JSON for swift-os build artifacts (kernel, base image, DTB, …).
//
// Usage: releasemanifest <output.json> <artifact> [<artifact> …]
//
// Reads VERSION from the repository root (walks up from cwd). Honors
// SOURCE_DATE_EPOCH for reproducible built_at timestamps. Toolchain metadata is
// supplied via SWOS_SWIFT_VERSION / SWOS_CLANG_VERSION (the Makefile captures
// `swiftc --version` / `clang --version` before invoking this tool). Target triple
// from SWOS_TARGET_TRIPLE (default aarch64-none-none-elf). Git metadata from
// SWOS_GIT_COMMIT / SWOS_GIT_DIRTY, with a .git/HEAD filesystem fallback for
// commit. signing_profile is "dev" unless SWOS_SIGNING_PROFILE=prod.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let schemaVersion = 1
private let projectName = "swift-os"
private let defaultTargetTriple = "aarch64-none-none-elf"

private func die(_ msg: String) -> Never {
    _ = msg.withCString { fputs($0, stderr) }
    fputs("\n", stderr)
    exit(1)
}

private func env(_ name: String) -> String? {
    name.withCString { p in
        guard let v = getenv(p) else { return nil }
        return String(cString: v)
    }
}

private func trimWS(_ s: String) -> String {
    var start = s.startIndex
    var end = s.endIndex
    while start < end {
        let c = s[start]
        if c == " " || c == "\t" || c == "\n" || c == "\r" { start = s.index(after: start) }
        else { break }
    }
    while end > start {
        let i = s.index(before: end)
        let c = s[i]
        if c == " " || c == "\t" || c == "\n" || c == "\r" { end = i }
        else { break }
    }
    return String(s[start..<end])
}

private func parseBoolEnv(_ raw: String?) -> Bool? {
    guard let raw else { return nil }
    switch trimWS(raw).lowercased() {
    case "1", "true", "yes": return true
    case "0", "false", "no": return false
    default: return nil
    }
}

private func findRepoRoot() -> String {
    var cwd = [CChar](repeating: 0, count: 4096)
    guard getcwd(&cwd, cwd.count) != nil else { die("cannot getcwd") }
    var dir = String(cString: cwd)
    while true {
        let versionPath = dir + "/VERSION"
        if fileExists(versionPath) { return dir }
        if dir == "/" { break }
        guard let slash = dir.lastIndex(of: "/") else { break }
        if slash == dir.startIndex { dir = "/"; continue }
        dir = String(dir[..<slash])
    }
    die("cannot find repo root (no VERSION file)")
}

private func fileExists(_ path: String) -> Bool {
    path.withCString { access($0, F_OK) == 0 }
}

private func readWholeFile(_ path: String) -> [UInt8]? {
    path.withCString { p in
        let fd = open(p, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let sz = Int(st.st_size)
        guard sz >= 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: sz)
        var off = 0
        while off < sz {
            let n = read(fd, &buf[off], sz - off)
            if n <= 0 { return nil }
            off += n
        }
        return buf
    }
}

private func writeWholeFile(_ path: String, _ bytes: [UInt8]) -> Bool {
    path.withCString { p in
        let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var off = 0
        while off < bytes.count {
            let n = write(fd, bytes[off..<bytes.count].withUnsafeBytes { $0.baseAddress! }, bytes.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

private func fileSize(_ path: String) -> Int64? {
    path.withCString { (p) -> Int64? in
        var st = stat()
        guard stat(p, &st) == 0 else { return nil }
        // Linux st_size is off_t; cast so the closure type is consistently Int64?.
        return Int64(st.st_size)
    }
}

private func sha256FileHex(_ path: String) -> String? {
    guard let data = readWholeFile(path) else { return nil }
    var hex = [UInt8](repeating: 0, count: 64)
    data.withUnsafeBytes { raw in
        hex.withUnsafeMutableBytes { out in
            let base = raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!
            sha256Hex(base, data.count, out.baseAddress!)
        }
    }
    return String(decoding: hex, as: UTF8.self)
}

private func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 8)
    for ch in s.unicodeScalars {
        switch ch.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0..<0x20:
            var hex = String(UInt32(ch.value), radix: 16)
            while hex.count < 4 { hex = "0" + hex }
            out += "\\u" + hex
        default: out.append(Character(ch))
        }
    }
    return out
}

private func pad2(_ n: Int32) -> String {
    let v = Int(n)
    return v < 10 ? "0\(v)" : "\(v)"
}

private func pad4(_ n: Int32) -> String {
    var s = "\(Int(n))"
    while s.count < 4 { s = "0" + s }
    return s
}

private func formatISO8601UTC(_ epoch: time_t) -> String {
    var t = epoch
    var tm = tm()
    #if canImport(Glibc)
    guard gmtime_r(&t, &tm) != nil else { return "1970-01-01T00:00:00Z" }
    #else
    guard let p = gmtime(&t) else { return "1970-01-01T00:00:00Z" }
    tm = p.pointee
    #endif
    return "\(pad4(tm.tm_year + 1900))-\(pad2(tm.tm_mon + 1))-\(pad2(tm.tm_mday))T\(pad2(tm.tm_hour)):\(pad2(tm.tm_min)):\(pad2(tm.tm_sec))Z"
}

private func builtAtISO8601() -> String {
    if let raw = env("SOURCE_DATE_EPOCH"), let v = Int64(raw) {
        return formatISO8601UTC(time_t(v))
    }
    return formatISO8601UTC(time(nil))
}

private func signingProfile() -> String {
    if env("SWOS_SIGNING_PROFILE") == "prod" { return "prod" }
    return "dev"
}

private func readGitCommit(_ repo: String) -> String {
    if let commit = env("SWOS_GIT_COMMIT"), !commit.isEmpty { return commit }
    guard let headBytes = readWholeFile(repo + "/.git/HEAD") else { return "unknown" }
    let line = trimWS(String(decoding: headBytes, as: UTF8.self))
    if line.hasPrefix("ref: ") {
        let ref = trimWS(String(line.dropFirst(5)))
        if let refBytes = readWholeFile(repo + "/.git/" + ref) {
            return trimWS(String(decoding: refBytes, as: UTF8.self))
        }
        if let packed = readWholeFile(repo + "/.git/packed-refs") {
            let packedStr = String(decoding: packed, as: UTF8.self)
            for raw in packedStr.split(separator: "\n") {
                let row = trimWS(String(raw))
                if row.isEmpty || row.hasPrefix("#") || row.hasPrefix("^") { continue }
                let parts = row.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, parts[1] == Substring(ref) {
                    return String(parts[0])
                }
            }
        }
        return "unknown"
    }
    return line
}

private func readGitDirty(_ repo: String) -> Bool {
    if let parsed = parseBoolEnv(env("SWOS_GIT_DIRTY")) { return parsed }
    _ = repo
    return false
}

@main
struct ReleaseManifestTool {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            die("usage: releasemanifest <output.json> <artifact> [<artifact> …]")
        }
        let outPath = args[0]
        let artifactPaths = Array(args.dropFirst())

        let repo = findRepoRoot()
        guard let versionBytes = readWholeFile(repo + "/VERSION") else {
            die("cannot read VERSION")
        }
        let version = trimWS(String(decoding: versionBytes, as: UTF8.self))
        guard !version.isEmpty else { die("VERSION is empty") }

        var artifactsJSON = ""
        for (i, path) in artifactPaths.enumerated() {
            guard let size = fileSize(path) else { die("cannot stat \(path)") }
            guard let sha = sha256FileHex(path) else { die("cannot hash \(path)") }
            if i > 0 { artifactsJSON += ",\n" }
            artifactsJSON += "    {\"path\": \"\(jsonEscape(path))\", \"size\": \(size), \"sha256\": \"\(sha)\"}"
        }

        let targetTriple = env("SWOS_TARGET_TRIPLE") ?? defaultTargetTriple
        let swiftVer = env("SWOS_SWIFT_VERSION") ?? "unknown"
        let clangVer = env("SWOS_CLANG_VERSION") ?? "unknown"
        let commit = readGitCommit(repo)
        let dirty = readGitDirty(repo)
        let builtAt = builtAtISO8601()
        let profile = signingProfile()

        let json = """
        {
          "schema_version": \(schemaVersion),
          "name": "\(projectName)",
          "version": "\(jsonEscape(version))",
          "git_commit": "\(jsonEscape(commit))",
          "git_dirty": \(dirty ? "true" : "false"),
          "built_at": "\(builtAt)",
          "target_triple": "\(jsonEscape(targetTriple))",
          "swift_version": "\(jsonEscape(swiftVer))",
          "clang_version": "\(jsonEscape(clangVer))",
          "signing_profile": "\(profile)",
          "artifacts": [
        \(artifactsJSON)
          ]
        }
        """

        let bytes = Array((json + "\n").utf8)
        guard writeWholeFile(outPath, bytes) else { die("cannot write \(outPath)") }
        fputs("releasemanifest: wrote \(outPath) (\(artifactPaths.count) artifacts, version \(version))\n", stderr)
    }
}