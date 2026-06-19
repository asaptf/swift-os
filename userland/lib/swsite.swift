// SPDX-License-Identifier: Apache-2.0
// swsite.swift — pure, freestanding parsing/validation for the signed SWSITE
// site-bundle format (SU-B/SU-C), shared by /bin/swupdate.
//
// These routines carry NO syscall or crypto dependencies — they only inspect
// in-memory byte buffers — so they compile both into the freestanding Embedded
// Swift `swupdate` binary and, unchanged, into the host test (tests/swsite_test.swift)
// where they can be exercised exhaustively against malformed input without QEMU.
//
// The trust boundary lives here: a SWSITE bundle arrives over the network (SU-C)
// or a local file (SU-B) and, after its Ed25519 signature + payload SHA-256 are
// checked by the caller, the layout and every entry name must be validated before
// a single byte is unpacked onto /data. `swsiteParseEntries` is that gate, and
// `safeName` is the path-traversal defense.
//
// Like the rest of swupdate, this is freestanding Embedded Swift with no full
// stdlib: it avoids Swift `String` (its `==`/interpolation pull in Unicode tables
// that aren't linked) and works over raw [UInt8] / [CChar] buffers.

// SWSITE signed-bundle layout (must match tools/sitepack.swift):
//   [64B Ed25519 signature][body]
//   body: 64B header (magic/version/counts/payloadSha256) then
//         entryCount * 24B entry records, a string table, and a blob region.
let sigSize = 64           // leading Ed25519 detached signature
let hdrSize = 64           // body header
let entrySize = 24         // per-entry record
// Inode budget: datafs holds 256 inodes total across current+next+prev (~3x the
// site) plus /data overhead, so cap a single site's entry count well under 256/3.
let maxSiteEntries = 64
let siteMagic: StaticString = "SWSITE01"

// Little-endian u32 read at byte offset `off`.
func le32(_ b: [UInt8], _ off: Int) -> Int {
    Int(UInt32(b[off]) | (UInt32(b[off + 1]) << 8)
        | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24))
}

func magicMatches(_ b: [UInt8], _ at: Int) -> Bool {
    let n = siteMagic.utf8CodeUnitCount
    var i = 0
    while i < n { if b[at + i] != siteMagic.utf8Start[i] { return false }; i += 1 }
    return true
}

// A relative entry name must stay within the docroot: no absolute paths and no
// ".." traversal. Defense-in-depth; sitepack only emits clean relative names.
func safeName(_ name: [UInt8]) -> Bool {
    if name.isEmpty { return false }
    if name[0] == 0x2F { return false }                 // leading '/'
    var i = 0
    while i + 1 < name.count {
        // reject "/.." and a leading ".." (the only ways to escape upward)
        if name[i] == 0x2E && name[i + 1] == 0x2E {
            let prevSlash = (i == 0) || name[i - 1] == 0x2F
            let nextEndOrSlash = (i + 2 == name.count) || name[i + 2] == 0x2F
            if prevSlash && nextEndOrSlash { return false }
        }
        i += 1
    }
    return true
}

// ---- layout validation -----------------------------------------------------

// Why a parsed entry was rejected, or `.ok`. A flat enum (no associated values)
// keeps this usable from freestanding Embedded Swift; the caller maps each case
// to its operator-facing message.
enum SWSiteLayoutError: Equatable {
    case ok
    case entryCountRange    // entryCount < 1 or > the inode budget
    case layoutBounds       // header/entries/strings/blobs regions overlap or overflow the body
    case badEntryName       // an entry's name offset/length escapes the string table
    case badEntryBlob       // a file entry's blob offset/length escapes the blob region
    case unsafeName         // an entry name is absolute or contains a ".." component
}

// A validated entry, ready to unpack. `blobFileOff` is an absolute offset into the
// original `bundle` buffer, so the caller can write the blob without re-deriving
// the region base.
struct SWSiteEntry {
    let name: [UInt8]       // safe relative path
    let isDir: Bool
    let blobFileOff: Int    // absolute offset of the file content within `bundle`
    let blobLen: Int        // 0 for directories
}

// Validate the body layout of an SWSITE bundle whose signature + payload SHA-256
// the caller has ALREADY verified, and return its entries in pre-order. `bundle`
// is the whole file (signature included); the body begins at `sigSize`. The caller
// must have ensured `bundle.count >= sigSize + hdrSize` before calling.
//
// Every offset/length is checked against the body so a malicious or corrupt bundle
// can never point the unpacker outside the buffer; names are checked with
// `safeName` so it can never write outside the staging directory.
func swsiteParseEntries(_ bundle: [UInt8]) -> (entries: [SWSiteEntry], error: SWSiteLayoutError) {
    let bodyOff = sigSize
    let bodyLen = bundle.count - sigSize

    let entryCount = le32(bundle, bodyOff + 12)
    let stringsOff = le32(bundle, bodyOff + 16)
    let stringsLen = le32(bundle, bodyOff + 20)
    let blobsOff = le32(bundle, bodyOff + 24)
    let blobsLen = le32(bundle, bodyOff + 28)

    if entryCount < 1 || entryCount > maxSiteEntries { return ([], .entryCountRange) }
    let entriesEnd = hdrSize + entryCount * entrySize
    if entriesEnd > stringsOff || stringsOff + stringsLen > blobsOff
        || blobsOff + blobsLen > bodyLen {
        return ([], .layoutBounds)
    }

    var out: [SWSiteEntry] = []
    var i = 0
    while i < entryCount {
        let e = bodyOff + hdrSize + i * entrySize
        let nameOff = le32(bundle, e + 0)
        let nameLen = le32(bundle, e + 4)
        let blobOff = le32(bundle, e + 8)
        let blobLen = le32(bundle, e + 12)
        let type = le32(bundle, e + 16)
        if nameLen < 1 || nameOff + nameLen > stringsLen { return ([], .badEntryName) }
        if type == 0 && blobOff + blobLen > blobsLen { return ([], .badEntryBlob) }
        var name: [UInt8] = []
        var j = 0
        let nameBase = bodyOff + stringsOff + nameOff
        while j < nameLen { name.append(bundle[nameBase + j]); j += 1 }
        if !safeName(name) { return ([], .unsafeName) }
        out.append(SWSiteEntry(name: name, isDir: type == 1,
                               blobFileOff: bodyOff + blobsOff + blobOff, blobLen: blobLen))
        i += 1
    }
    return (out, .ok)
}

// ---- URL / HTTP parsing (SU-C) ---------------------------------------------

// Parse a dotted-decimal IPv4 from raw bytes, or nil.
func parseIPv4Bytes(_ b: [UInt8]) -> UInt32? {
    var octets = [UInt32](repeating: 0, count: 4)
    var idx = 0, cur: UInt32 = 0, digits = 0, i = 0
    while true {
        let ch: UInt8 = i < b.count ? b[i] : 0
        if ch >= 0x30 && ch <= 0x39 {
            cur = cur * 10 + UInt32(ch - 0x30)
            if cur > 255 { return nil }
            digits += 1
        } else if ch == 0x2E || ch == 0 {
            if digits == 0 || idx > 3 { return nil }
            octets[idx] = cur; idx += 1; cur = 0; digits = 0
            if ch == 0 { break }
        } else { return nil }
        i += 1
    }
    if idx != 4 { return nil }
    return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
}

// Parse "https://host[:port]/path" from a C string into (host, port, path).
func parseHTTPSURL(_ url: UnsafeMutablePointer<CChar>)
    -> (host: [UInt8], port: UInt16, path: [UInt8])? {
    var u: [UInt8] = []
    var i = 0
    while url[i] != 0 { u.append(UInt8(bitPattern: url[i])); i += 1 }
    let scheme: [UInt8] = Array("https://".utf8)
    if u.count < scheme.count { return nil }
    var k = 0
    while k < scheme.count { if u[k] != scheme[k] { return nil }; k += 1 }
    var p = scheme.count
    var host: [UInt8] = []
    while p < u.count && u[p] != 0x3A && u[p] != 0x2F { host.append(u[p]); p += 1 }   // until ':' or '/'
    if host.isEmpty { return nil }
    var port: UInt16 = 443
    if p < u.count && u[p] == 0x3A {
        p += 1
        var v = 0
        while p < u.count && u[p] >= 0x30 && u[p] <= 0x39 { v = v * 10 + Int(u[p] - 0x30); p += 1 }
        if v < 1 || v > 65535 { return nil }
        port = UInt16(v)
    }
    var path: [UInt8] = []
    if p < u.count && u[p] == 0x2F {
        while p < u.count { path.append(u[p]); p += 1 }
    } else {
        path.append(0x2F)   // "/"
    }
    return (host, port, path)
}

// Split an HTTP response: require a 200 status, return the body bytes.
func httpBody(_ resp: [UInt8]) -> [UInt8]? {
    // Status line: "HTTP/1.x SP code ...". Accept 200.
    if resp.count < 12 { return nil }
    // Find the first space, then require "200" immediately after it.
    var sp = 0
    while sp < resp.count && resp[sp] != 0x20 { sp += 1 }
    if sp + 4 > resp.count { return nil }
    if !(resp[sp + 1] == 0x32 && resp[sp + 2] == 0x30 && resp[sp + 3] == 0x30) {
        return nil
    }
    // Body starts after the first CRLFCRLF.
    var i = 0
    while i + 3 < resp.count {
        if resp[i] == 0x0D && resp[i + 1] == 0x0A && resp[i + 2] == 0x0D && resp[i + 3] == 0x0A {
            var body: [UInt8] = []
            var j = i + 4
            while j < resp.count { body.append(resp[j]); j += 1 }
            return body
        }
        i += 1
    }
    return nil
}
