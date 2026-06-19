// SPDX-License-Identifier: Apache-2.0
// swsite_test.swift — exhaustive host unit tests for the pure SWSITE parsers in
// userland/lib/swsite.swift (the device-side validation in /bin/swupdate).
//
// These functions are the trust gate between an untrusted site bundle and /data,
// but in the OS they only run inside QEMU on the happy path. Here they are linked
// directly and hit with hostile input that the integration tests never produce:
// path-traversal entry names, out-of-budget entry counts, offsets that point past
// the buffer, malformed URLs, and non-200 / headerless HTTP responses.
//
//   compiled as:  swiftc tests/swsite_test.swift userland/lib/swsite.swift

import Foundation

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("ok: \(what)") }
    else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8)) }
}

// ---- little-endian helpers for building/mutating bundles -------------------

func u32le(_ v: Int) -> [UInt8] {
    [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
}
func setU32(_ b: inout [UInt8], _ off: Int, _ v: Int) {
    let le = u32le(v)
    b[off] = le[0]; b[off + 1] = le[1]; b[off + 2] = le[2]; b[off + 3] = le[3]
}

struct E { let name: [UInt8]; let isDir: Bool; let data: [UInt8] }
func file(_ n: String, _ d: String) -> E { E(name: Array(n.utf8), isDir: false, data: Array(d.utf8)) }
func dir(_ n: String) -> E { E(name: Array(n.utf8), isDir: true, data: []) }

// Build a well-formed bundle ([64B sig][body]) from entries, laying out the body
// exactly as tools/sitepack.swift does. Magic/version/payload-sha are left zero —
// swsiteParseEntries does not inspect them (the caller checks those first).
func buildBundle(_ es: [E]) -> [UInt8] {
    var strings: [UInt8] = [], nameOffs: [Int] = []
    for e in es { nameOffs.append(strings.count); strings += e.name }
    var blobs: [UInt8] = [], blobOffs: [Int] = []
    for e in es { if e.isDir { blobOffs.append(0) } else { blobOffs.append(blobs.count); blobs += e.data } }

    let stringsOff = 64 + es.count * 24
    let blobsOff = stringsOff + strings.count

    var entriesData: [UInt8] = []
    for (i, e) in es.enumerated() {
        entriesData += u32le(nameOffs[i])
        entriesData += u32le(e.name.count)
        entriesData += u32le(e.isDir ? 0 : blobOffs[i])
        entriesData += u32le(e.isDir ? 0 : e.data.count)
        entriesData += u32le(e.isDir ? 1 : 0)
        entriesData += u32le(e.isDir ? 0o755 : 0o644)
    }

    var header = [UInt8](repeating: 0, count: 64)
    setU32(&header, 12, es.count)
    setU32(&header, 16, stringsOff)
    setU32(&header, 20, strings.count)
    setU32(&header, 24, blobsOff)
    setU32(&header, 28, blobs.count)

    return [UInt8](repeating: 0, count: 64) + header + entriesData + strings + blobs
}

// Bundle-absolute offsets of header / entry-record fields (sig 64 + header 64).
let HDR = 64                              // start of body within the bundle
func entryField(_ i: Int, _ within: Int) -> Int { HDR + 64 + i * 24 + within }

func safe(_ s: String) -> Bool { safeName(Array(s.utf8)) }
func ip(_ s: String) -> UInt32? { parseIPv4Bytes(Array(s.utf8) + [0]) }
func url(_ s: String) -> (host: [UInt8], port: UInt16, path: [UInt8])? {
    var c = s.utf8CString.map { $0 }   // NUL-terminated [CChar]
    return c.withUnsafeMutableBufferPointer { parseHTTPSURL($0.baseAddress!) }
}
func hs(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
func bodyOf(_ s: String) -> [UInt8]? { httpBody(Array(s.utf8)) }

@main
struct SWSiteTest {
    static func main() {
        // ---- 1. swsiteParseEntries: valid round-trip ------------------------
        do {
            let es = [dir("sub"), file("index.html", "<h1>hi</h1>"), file("sub/note.txt", "note")]
            let b = buildBundle(es)
            let (entries, err) = swsiteParseEntries(b)
            check(err == .ok, "valid bundle parses (.ok)")
            check(entries.count == 3, "valid bundle yields 3 entries")
            if let idx = entries.first(where: { hs($0.name) == "index.html" }) {
                let got = Array(b[idx.blobFileOff ..< idx.blobFileOff + idx.blobLen])
                check(got == Array("<h1>hi</h1>".utf8), "index.html blob round-trips via blobFileOff")
            } else { check(false, "index.html entry present") }
            let sub = entries.first { hs($0.name) == "sub" }
            check(sub?.isDir == true, "sub is marked a directory")
        }

        // ---- 2. layout / budget rejection -----------------------------------
        do { var b = buildBundle([file("a", "x")]); setU32(&b, HDR + 12, 0)
             check(swsiteParseEntries(b).error == .entryCountRange, "entryCount 0 rejected") }
        do { var b = buildBundle([file("a", "x")]); setU32(&b, HDR + 12, maxSiteEntries + 1)
             check(swsiteParseEntries(b).error == .entryCountRange, "entryCount > budget rejected") }
        do { var b = buildBundle([file("a", "x")]); setU32(&b, HDR + 16, 0)
             check(swsiteParseEntries(b).error == .layoutBounds, "stringsOff before entries rejected") }
        do { var b = buildBundle([file("a", "x")]); setU32(&b, HDR + 28, 1 << 20)
             check(swsiteParseEntries(b).error == .layoutBounds, "blobs region past body rejected") }
        do { var b = buildBundle([file("a", "x")]); setU32(&b, entryField(0, 4), 1 << 20)
             check(swsiteParseEntries(b).error == .badEntryName, "name length past string table rejected") }
        do { var b = buildBundle([file("a", "x")]); setU32(&b, entryField(0, 12), 1 << 20)
             check(swsiteParseEntries(b).error == .badEntryBlob, "blob length past blob region rejected") }

        // ---- 3. path-traversal rejection (the security gate) ----------------
        for bad in ["../evil", "../../etc/passwd", "/etc/passwd", "sub/../../etc", "..", "a/.."] {
            let b = buildBundle([file(bad, "x")])
            check(swsiteParseEntries(b).error == .unsafeName, "unsafe name rejected: \(bad)")
        }
        for okName in ["a..b", "..a", "a/b..c/d", "file.tar.gz"] {
            let b = buildBundle([file(okName, "x")])
            check(swsiteParseEntries(b).error == .ok, "benign name accepted: \(okName)")
        }

        // ---- 4. safeName directly -------------------------------------------
        check(!safe(""), "empty name unsafe")
        check(!safe("/abs"), "absolute name unsafe")
        check(!safe(".."), "bare .. unsafe")
        check(!safe("../x"), "leading ../ unsafe")
        check(!safe("x/.."), "trailing /.. unsafe")
        check(!safe("x/../y"), "interior /../ unsafe")
        check(safe("a/b/c.html"), "normal nested path safe")
        check(safe("..foo"), "..foo (not a component) safe")

        // ---- 5. parseIPv4Bytes ----------------------------------------------
        check(ip("10.0.2.2") == 0x0A00_0202, "10.0.2.2 parses")
        check(ip("255.255.255.255") == 0xFFFF_FFFF, "255.255.255.255 parses")
        check(ip("0.0.0.0") == 0, "0.0.0.0 parses")
        check(ip("1.2.3") == nil, "too few octets rejected")
        check(ip("1.2.3.4.5") == nil, "too many octets rejected")
        check(ip("256.0.0.1") == nil, "octet > 255 rejected")
        check(ip("1.2.3.x") == nil, "non-digit rejected")
        check(ip("example.com") == nil, "hostname is not an IPv4")

        // ---- 6. parseHTTPSURL -----------------------------------------------
        if let u = url("https://10.0.2.2/site.swsite") {
            check(hs(u.host) == "10.0.2.2" && u.port == 443 && hs(u.path) == "/site.swsite",
                  "https://host/path -> default port 443")
        } else { check(false, "https://host/path parses") }
        if let u = url("https://host.example:8443/a/b?q=1") {
            check(hs(u.host) == "host.example" && u.port == 8443 && hs(u.path) == "/a/b?q=1",
                  "explicit port + query path parsed")
        } else { check(false, "https://host:port/path parses") }
        if let u = url("https://host") {
            check(hs(u.host) == "host" && u.port == 443 && hs(u.path) == "/", "no path defaults to /")
        } else { check(false, "https://host (no path) parses") }
        check(url("http://host/x") == nil, "non-https scheme rejected")
        check(url("ftp://host") == nil, "ftp scheme rejected")
        check(url("https://") == nil, "empty host rejected")
        check(url("https://host:0/x") == nil, "port 0 rejected")
        check(url("https://host:70000/x") == nil, "port > 65535 rejected")

        // ---- 7. httpBody ----------------------------------------------------
        if let body = bodyOf("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nDATA") {
            check(hs(body) == "DATA", "200 response body extracted after CRLFCRLF")
        } else { check(false, "200 response parses") }
        check(bodyOf("HTTP/1.1 404 Not Found\r\n\r\nnope") == nil, "404 response rejected")
        check(bodyOf("HTTP/1.1 500 Err\r\n\r\nx") == nil, "500 response rejected")
        check(bodyOf("HTTP/1.1 200 OK\r\nno terminator here") == nil, "missing CRLFCRLF rejected")
        check(bodyOf("short") == nil, "too-short response rejected")
        if let body = bodyOf("HTTP/1.1 200 OK\r\n\r\nline1\r\nline2") {
            check(hs(body) == "line1\r\nline2", "body preserves embedded CRLF")
        } else { check(false, "200 with embedded CRLF parses") }

        // ---- summary --------------------------------------------------------
        if failures == 0 {
            print("PASS: swsite parsers validate layout, reject path traversal, and parse URLs/HTTP")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("FAIL: \(failures) swsite assertion(s) failed\n".utf8))
            exit(1)
        }
    }
}
