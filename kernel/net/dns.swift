// SPDX-License-Identifier: Apache-2.0
// dns.swift — sans-IO DNS message codec (net-f).
//
// Pure: builds an A-record query and parses a response's first A record. No I/O
// — the kernel resolver (kernel/net/socket.swift) sends/receives the bytes over
// a UDP socket; tests/net_test.swift drives it with crafted messages. Host- and
// kernel-compiled like the rest of kernel/net.
//
// Message format (RFC 1035): 12-byte header, then question(s) and answer(s).
// Header: id[2], flags[2], qdcount[2], ancount[2], nscount[2], arcount[2].
// A name is a sequence of length-prefixed labels ending in a 0 length; in a
// response a name (or a suffix) may instead be a 2-byte compression pointer
// whose top two bits are set (0xC0).

let dnsTypeA: UInt16 = 1
let dnsClassIN: UInt16 = 1

/// Build a standard recursive A-record query for `name` (`nameLen` bytes, dotted
/// form, e.g. "example.com") into `out`. Returns the total message length.
func dnsBuildQuery(name: UnsafeRawPointer, nameLen: Int, id: UInt16,
                   out: UnsafeMutableRawPointer) -> Int {
    be16set(out, 0, id)
    be16set(out, 2, 0x0100)        // flags: standard query, recursion desired
    be16set(out, 4, 1)             // qdcount
    be16set(out, 6, 0)             // ancount
    be16set(out, 8, 0)             // nscount
    be16set(out, 10, 0)            // arcount
    var w = 12
    // Encode QNAME: split on '.' into length-prefixed labels.
    var labelStart = 0
    var i = 0
    while i <= nameLen {
        let atEnd = (i == nameLen)
        let isDot = !atEnd && b8(name, i) == 0x2E   // '.'
        if isDot || atEnd {
            let labelLen = i - labelStart
            if labelLen > 0 && labelLen <= 63 {
                b8set(out, w, UInt8(labelLen)); w += 1
                var j = 0
                while j < labelLen { b8set(out, w, b8(name, labelStart + j)); w += 1; j += 1 }
            }
            labelStart = i + 1
        }
        i += 1
    }
    b8set(out, w, 0); w += 1        // root label terminator
    be16set(out, w, dnsTypeA); w += 2
    be16set(out, w, dnsClassIN); w += 2
    return w
}

/// Skip a DNS name starting at `off`, handling compression pointers. Returns the
/// offset just past the name's in-place bytes (a pointer is 2 bytes; we do not
/// follow it since we only need to advance the cursor). Returns -1 on overrun.
private func dnsSkipName(_ p: UnsafeRawPointer, _ len: Int, _ off: Int) -> Int {
    var i = off
    while i < len {
        let b = b8(p, i)
        if b == 0 { return i + 1 }                 // root terminator
        if (b & 0xC0) == 0xC0 {                     // compression pointer (2 bytes)
            return i + 2 <= len ? i + 2 : -1
        }
        let labelLen = Int(b)
        if labelLen > 63 { return -1 }              // reserved bits set, not a pointer → malformed
        i += 1 + labelLen
    }
    return -1
}

/// Parse a DNS response and return the first A record's IPv4 (host order), or 0
/// if the id mismatches, the message is malformed/an error, or no A record is
/// present. Every read is bounds-checked against `len`.
func dnsParseResponse(_ p: UnsafeRawPointer, _ len: Int, id: UInt16) -> IPv4 {
    if len < 12 { return 0 }
    if be16(p, 0) != id { return 0 }
    let flags = be16(p, 2)
    if (flags & 0x8000) == 0 { return 0 }           // must be a response
    if (flags & 0x000F) != 0 { return 0 }           // rcode != 0 (e.g. NXDOMAIN)
    let qd = Int(be16(p, 4))
    let an = Int(be16(p, 6))
    if an == 0 { return 0 }

    var off = 12
    // Skip the question section: each question is NAME + QTYPE(2) + QCLASS(2).
    var q = 0
    while q < qd {
        off = dnsSkipName(p, len, off)
        if off < 0 || off + 4 > len { return 0 }
        off += 4
        q += 1
    }
    // Walk the answers.
    var a = 0
    while a < an {
        off = dnsSkipName(p, len, off)
        if off < 0 || off + 10 > len { return 0 }
        let rtype = be16(p, off)
        let rdlen = Int(be16(p, off + 8))
        off += 10
        if off + rdlen > len { return 0 }
        if rtype == dnsTypeA && rdlen == 4 {
            return be32(p, off)                     // RDATA = the IPv4 address
        }
        off += rdlen                                 // e.g. a CNAME — skip and continue
        a += 1
    }
    return 0
}
