// SPDX-License-Identifier: Apache-2.0
// sitepack_test.swift — fast host proof of the signed SWSITE bundle format (SU-B).
//
// The reflash-free site-update path has a trust-critical seam: the host tool
// `sitepack` (tools/sitepack.swift) WRITES a signed SWSITE bundle and the on-box
// `/bin/swupdate` (userland/swupdate.swift) READS it back byte-for-byte. The two
// sides share no code — only a layout documented in both files — so any drift
// silently breaks updates or, worse, a security check.
//
// This test is an INDEPENDENT third implementation of the SWSITE reader: it packs
// the fixture site with `sitepack create`, then parses the bundle from scratch and
// reconstructs every file/dir, asserting it round-trips the source tree exactly.
// It also drives `sitepack verify` to prove the trust anchors reject tampering:
//   - a flipped signature byte           -> signature INVALID, nonzero exit;
//   - a flipped payload byte             -> INVALID, nonzero exit;
//   - the wrong public key               -> signature INVALID;
//   - a truncated bundle                 -> rejected before parsing.
// All host-side, no QEMU — it runs in `make test` in well under a second.
//
//   usage: sitepack_test <sitepack-bin> <seed-32> <pubkey-32> <fixtures-dir>

import Foundation

// ---- harness ---------------------------------------------------------------

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var combined: String {
        (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func run(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { fail("could not run \(executable): \(error)") }
    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus,
        stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

private func requireSuccess(_ r: CommandResult, _ ctx: String) {
    guard r.status == 0 else { fail("\(ctx) failed (status \(r.status)): \(r.combined)") }
}

private func requireRejected(_ r: CommandResult, _ ctx: String, contains needle: String) {
    guard r.status != 0 else { fail("\(ctx) unexpectedly succeeded: \(r.combined)") }
    guard r.combined.contains(needle) else {
        fail("\(ctx) rejected but without \"\(needle)\": \(r.combined)")
    }
}

private func readFile(_ path: String) -> [UInt8] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fail("cannot read \(path)") }
    return [UInt8](d)
}

private func writeFile(_ bytes: [UInt8], _ path: String) {
    do { try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic) }
    catch { fail("cannot write \(path): \(error)") }
}

// ---- SWSITE layout (mirrors tools/sitepack.swift + userland/swupdate.swift) --

private let sigSize = 64
private let hdrSize = 64
private let entrySize = 24
private let magic = Array("SWSITE01".utf8)

private func le32(_ b: [UInt8], _ off: Int) -> Int {
    Int(UInt32(b[off]) | (UInt32(b[off + 1]) << 8)
        | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24))
}

// The relative-name safety invariant `/bin/swupdate` enforces (safeName): a name
// must be non-empty, not absolute, and contain no ".." path component.
private func nameIsSafe(_ name: String) -> Bool {
    if name.isEmpty || name.hasPrefix("/") { return false }
    for comp in name.split(separator: "/", omittingEmptySubsequences: false) {
        if comp == ".." { return false }
    }
    return true
}

struct Parsed {
    var files: [String: [UInt8]] = [:]   // relative path -> content
    var dirs: Set<String> = []
}

// Independent SWSITE unpacker: validate the layout and reconstruct the tree, the
// way swupdate.swift does on the device. Any field that is out of bounds is a
// hard failure — this is exactly the validation the unpacker must not skip.
private func parseBundle(_ bundle: [UInt8]) -> Parsed {
    guard bundle.count >= sigSize + hdrSize else { fail("bundle smaller than sig+header") }
    let bodyOff = sigSize
    let bodyLen = bundle.count - sigSize

    var i = 0
    while i < magic.count { if bundle[bodyOff + i] != magic[i] { fail("bad magic") }; i += 1 }
    guard le32(bundle, bodyOff + 8) == 1 else { fail("unexpected version") }

    let entryCount = le32(bundle, bodyOff + 12)
    let stringsOff = le32(bundle, bodyOff + 16)
    let stringsLen = le32(bundle, bodyOff + 20)
    let blobsOff = le32(bundle, bodyOff + 24)
    let blobsLen = le32(bundle, bodyOff + 28)
    guard entryCount >= 1 else { fail("entryCount must be >= 1") }

    // Bounds: header -> entries -> strings -> blobs, each within the body. These
    // are the same inequalities applyBundleBytes() checks before unpacking.
    let entriesEnd = hdrSize + entryCount * entrySize
    guard entriesEnd <= stringsOff,
          stringsOff + stringsLen <= blobsOff,
          blobsOff + blobsLen <= bodyLen
    else { fail("layout out of bounds (entries=\(entriesEnd) strings=\(stringsOff)+\(stringsLen) blobs=\(blobsOff)+\(blobsLen) body=\(bodyLen))") }

    var out = Parsed()
    var e = 0
    while e < entryCount {
        let rec = bodyOff + hdrSize + e * entrySize
        let nameOff = le32(bundle, rec + 0)
        let nameLen = le32(bundle, rec + 4)
        let blobOff = le32(bundle, rec + 8)
        let blobLen = le32(bundle, rec + 12)
        let type = le32(bundle, rec + 16)
        guard nameLen >= 1, nameOff + nameLen <= stringsLen else { fail("entry \(e) name out of bounds") }
        let nameBase = bodyOff + stringsOff + nameOff
        let name = String(decoding: bundle[nameBase ..< nameBase + nameLen], as: UTF8.self)
        guard nameIsSafe(name) else { fail("entry \(e) has an unsafe name: \(name)") }
        if type == 1 {
            out.dirs.insert(name)
        } else if type == 0 {
            guard blobOff + blobLen <= blobsLen else { fail("entry \(e) blob out of bounds") }
            let base = bodyOff + blobsOff + blobOff
            out.files[name] = blobLen == 0 ? [] : Array(bundle[base ..< base + blobLen])
        } else {
            fail("entry \(e) has unknown type \(type)")
        }
        e += 1
    }
    return out
}

// The on-disk fixture tree (sitepack's view: relative paths, dotfiles skipped).
private func walkFixtures(_ root: String) -> Parsed {
    var out = Parsed()
    let rootURL = URL(fileURLWithPath: root)
    guard let en = FileManager.default.enumerator(at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]) else { fail("cannot enumerate \(root)") }
    for case let url as URL in en {
        let rel = String(url.path.dropFirst(rootURL.path.count + 1))
        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { out.dirs.insert(rel) }
        else { out.files[rel] = readFile(url.path) }
    }
    return out
}

// ---- main ------------------------------------------------------------------

let argv = CommandLine.arguments
guard argv.count == 5 else {
    fail("usage: sitepack_test <sitepack-bin> <seed-32> <pubkey-32> <fixtures-dir>")
}
let sitepack = argv[1], seed = argv[2], pubkey = argv[3], fixtures = argv[4]

guard FileManager.default.isExecutableFile(atPath: sitepack) else { fail("missing \(sitepack); run make sitepack") }

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("sitepack-test-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
func tmp(_ n: String) -> String { work.appendingPathComponent(n).path }

// 1. Pack the fixtures and confirm `verify` accepts the fresh bundle.
let bundlePath = tmp("site.swsite")
requireSuccess(run(sitepack, ["create", fixtures, bundlePath, "--seed", seed]), "sitepack create")
let okVerify = run(sitepack, ["verify", bundlePath, "--pubkey", pubkey])
requireSuccess(okVerify, "sitepack verify (valid)")
guard okVerify.combined.contains("signature: OK"),
      okVerify.combined.contains("payload-sha256: OK") else {
    fail("verify of a valid bundle did not report OK/OK: \(okVerify.combined)")
}

// 2. Independently unpack the bundle and prove it round-trips the source tree.
let bundle = readFile(bundlePath)
let parsed = parseBundle(bundle)
let onDisk = walkFixtures(fixtures)

if parsed.dirs != onDisk.dirs {
    fail("dir set mismatch: bundle \(parsed.dirs.sorted()) vs fixtures \(onDisk.dirs.sorted())")
}
if Set(parsed.files.keys) != Set(onDisk.files.keys) {
    fail("file set mismatch: bundle \(parsed.files.keys.sorted()) vs fixtures \(onDisk.files.keys.sorted())")
}
for (name, content) in onDisk.files {
    guard parsed.files[name] == content else { fail("content mismatch for \(name)") }
}
guard !onDisk.files.isEmpty else { fail("fixtures had no files — test would be vacuous") }
print("ok: bundle round-trips \(parsed.files.count) file(s) + \(parsed.dirs.count) dir(s) from \(fixtures)")

// 3. A flipped SIGNATURE byte (byte 0) — the trust anchor must reject it.
var badSig = bundle
badSig[0] ^= 0x01
let badSigPath = tmp("bad-sig.swsite")
writeFile(badSig, badSigPath)
requireRejected(run(sitepack, ["verify", badSigPath, "--pubkey", pubkey]),
                "verify tampered-signature bundle", contains: "signature: INVALID")
print("ok: flipped signature byte rejected")

// 4. A flipped PAYLOAD byte (last byte of the body) — covered by the signature.
var badBody = bundle
badBody[badBody.count - 1] ^= 0x01
let badBodyPath = tmp("bad-body.swsite")
writeFile(badBody, badBodyPath)
requireRejected(run(sitepack, ["verify", badBodyPath, "--pubkey", pubkey]),
                "verify tampered-payload bundle", contains: "INVALID")
print("ok: flipped payload byte rejected")

// 5. The WRONG public key — the same valid bundle must not verify under it.
var badPub = readFile(pubkey)
badPub[0] ^= 0x01
let badPubPath = tmp("wrong.pub")
writeFile(badPub, badPubPath)
requireRejected(run(sitepack, ["verify", bundlePath, "--pubkey", badPubPath]),
                "verify under the wrong pubkey", contains: "signature: INVALID")
print("ok: bundle does not verify under the wrong key")

// 6. A TRUNCATED bundle — rejected before any parsing.
let truncPath = tmp("trunc.swsite")
writeFile(Array(bundle.prefix(sigSize + hdrSize - 1)), truncPath)
requireRejected(run(sitepack, ["verify", truncPath, "--pubkey", pubkey]),
                "verify truncated bundle", contains: "too small")
print("ok: truncated bundle rejected")

print("PASS: SWSITE bundle round-trips and verify rejects signature/payload/key/length tampering")
