// SPDX-License-Identifier: Apache-2.0
// icmp6.swift — ICMPv6 (RFC 4443 + RFC 4861 NDP).
// Pure, host-testable, zero-allocation on hot path.
//
// Covers:
// - Echo Request/Reply (128/129) for ping6
// - Neighbor Solicitation (135) / Neighbor Advertisement (136) — the core of NDP
//   address resolution (the IPv6 equivalent of ARP)
// - Router Solicitation (133) / Advertisement (134) — minimal support
//
// All checksums use the IPv6 pseudo-header.

let icmp6TypeEchoRequest: UInt8 = 128
let icmp6TypeEchoReply:   UInt8 = 129
let icmp6TypeRS:          UInt8 = 133   // Router Solicitation
let icmp6TypeRA:          UInt8 = 134   // Router Advertisement
let icmp6TypeNS:          UInt8 = 135   // Neighbor Solicitation
let icmp6TypeNA:          UInt8 = 136   // Neighbor Advertisement

let icmp6HeaderLen = 8

@inline(__always) func icmp6Type(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 0) }
@inline(__always) func icmp6Code(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 1) }
@inline(__always) func icmp6Id(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 4) }
@inline(__always) func icmp6Seq(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 6) }

/// Write an ICMPv6 echo request or reply (type 128/129) with a simple incrementing
/// payload pattern. The checksum field is computed over the IPv6 pseudo-header +
/// the entire ICMPv6 message. Returns the ICMPv6 message length (8 + payloadLen).
@discardableResult
func icmp6WriteEcho(_ p: UnsafeMutableRawPointer, type: UInt8,
                    id: UInt16, seq: UInt16, payloadLen: Int,
                    src: IPv6, dst: IPv6) -> Int {
    b8set(p, 0, type)
    b8set(p, 1, 0)          // code
    be16set(p, 2, 0)        // checksum placeholder
    be16set(p, 4, id)
    be16set(p, 6, seq)
    var i = 0
    while i < payloadLen {
        b8set(p, icmp6HeaderLen + i, UInt8(i & 0xFF))
        i += 1
    }
    let total = icmp6HeaderLen + payloadLen
    let ck = ipv6UpperChecksum(src: src, dst: dst, nextHeader: ipProtoICMPv6,
                               upper: p, upperLen: total)
    be16set(p, 2, ck)
    return total
}

/// Validate a received ICMPv6 message checksum (field already filled).
func icmp6ChecksumValid(src: IPv6, dst: IPv6, msg: UnsafeRawPointer, msgLen: Int) -> Bool {
    return ipv6UpperChecksumValid(src: src, dst: dst, nextHeader: ipProtoICMPv6,
                                  upper: msg, upperLen: msgLen)
}

// MARK: - NDP (Neighbor Discovery Protocol) — RFC 4861

/// NDP option type for Source/Target Link-Layer Address.
let ndpOptSrcLLA: UInt8 = 1
let ndpOptTgtLLA: UInt8 = 2

/// Neighbor Solicitation (NS) body after the 8-byte ICMPv6 header:
///   reserved[4], target[16], then options (e.g. Source LLA option).
let ndpNSBodyLen = 20   // reserved + target (no options counted here)

/// Neighbor Advertisement (NA) body:
///   flags[4] (R/S/O), target[16], options.
let ndpNABodyLen = 20

@inline(__always) func icmp6NDTarget(_ p: UnsafeRawPointer) -> IPv6 { ipv6Get(p, 8) } // after type/code/cksum/reserved or flags

/// Parse flags from NA (byte 4 of the ICMPv6 body after header).
@inline(__always) func icmp6NAFlags(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 4) }

let ndpNAFlagRouter    : UInt8 = 0x80
let ndpNAFlagSolicited : UInt8 = 0x40
let ndpNAFlagOverride  : UInt8 = 0x20

/// Write a Neighbor Solicitation.
/// `target` is the address we are resolving (usually the peer's IPv6).
/// If `includeSrcLLA` is true, a Source Link-Layer Address option is appended (20 bytes total ICMP).
/// The `src`/`dst` are used only for the checksum (dst is often the solicited-node multicast).
@discardableResult
func icmp6WriteNS(_ p: UnsafeMutableRawPointer,
                  target: IPv6,
                  srcLLA: MAC?,
                  src: IPv6, dst: IPv6) -> Int {
    b8set(p, 0, icmp6TypeNS)
    b8set(p, 1, 0)                 // code
    be16set(p, 2, 0)               // checksum placeholder
    be32set(p, 4, 0)               // reserved
    ipv6Set(p, 8, target)

    var optLen = 0
    if let mac = srcLLA {
        b8set(p, 24, ndpOptSrcLLA)
        b8set(p, 25, 1)            // length in 8-byte units (1 = 8 bytes)
        macSet(p, 26, mac)
        optLen = 8
    }
    let ck = ipv6UpperChecksum(src: src, dst: dst, nextHeader: ipProtoICMPv6, upper: p, upperLen: 24 + optLen)
    be16set(p, 2, ck)
    return 24 + optLen
}

/// Write a Neighbor Advertisement in response to NS (or unsolicited).
/// `target` is our own address we are advertising.
/// `flags` should usually include Solicited + Override for a reply to NS.
@discardableResult
func icmp6WriteNA(_ p: UnsafeMutableRawPointer,
                  target: IPv6,
                  tgtLLA: MAC,
                  flags: UInt8,
                  src: IPv6, dst: IPv6) -> Int {
    b8set(p, 0, icmp6TypeNA)
    b8set(p, 1, 0)
    be16set(p, 2, 0)
    b8set(p, 4, flags)
    b8set(p, 5, 0); b8set(p, 6, 0); b8set(p, 7, 0)   // reserved bytes after flags
    ipv6Set(p, 8, target)

    // Target LLA option (required for resolution)
    b8set(p, 24, ndpOptTgtLLA)
    b8set(p, 25, 1)
    macSet(p, 26, tgtLLA)

    let total = 24 + 8
    let ck = ipv6UpperChecksum(src: src, dst: dst, nextHeader: ipProtoICMPv6, upper: p, upperLen: total)
    be16set(p, 2, ck)
    return total
}

/// Minimal Router Solicitation (used when we want to discover routers).
@discardableResult
func icmp6WriteRS(_ p: UnsafeMutableRawPointer, srcLLA: MAC?, src: IPv6, dst: IPv6) -> Int {
    b8set(p, 0, icmp6TypeRS)
    b8set(p, 1, 0)
    be16set(p, 2, 0)
    be32set(p, 4, 0)   // reserved

    var optLen = 0
    if let mac = srcLLA {
        b8set(p, 8, ndpOptSrcLLA)
        b8set(p, 9, 1)
        macSet(p, 10, mac)
        optLen = 8
    }
    let total = 8 + optLen
    let ck = ipv6UpperChecksum(src: src, dst: dst, nextHeader: ipProtoICMPv6, upper: p, upperLen: total)
    be16set(p, 2, ck)
    return total
}

/// Write a Router Advertisement (type 134). Base 16 bytes + optional Prefix Information
/// option (type 3, 32B) when a prefix is supplied. Checksum uses IPv6 pseudo-header.
/// Supports build/parse roundtrips and feeding full RAs (with prefixes+options) into onFrame.
@discardableResult
func icmp6WriteRA(_ p: UnsafeMutableRawPointer,
                  hopLimit: UInt8,
                  src: IPv6, dst: IPv6,
                  prefix: IPv6? = nil, prefixLen: UInt8 = 0) -> Int {
    b8set(p, 0, icmp6TypeRA)
    b8set(p, 1, 0)   // code
    be16set(p, 2, 0) // checksum placeholder
    b8set(p, 4, hopLimit)
    b8set(p, 5, 0)   // flags (M/O/H) — minimal, no DHCPv6 etc.
    be16set(p, 6, 1800) // router lifetime (30min, typical)
    be32set(p, 8, 0)    // reachable time
    be32set(p, 12, 0)   // retrans timer
    var total = 16
    if let pre = prefix, prefixLen > 0 && prefixLen <= 128 {
        // Prefix Information option (RFC 4861)
        b8set(p, total + 0, 3)     // type
        b8set(p, total + 1, 4)     // length (4 units of 8B = 32B)
        b8set(p, total + 2, prefixLen)
        b8set(p, total + 3, 0xC0)  // L=1 (on-link), A=1 (autonomous for SLAAC)
        be32set(p, total + 4, 0xFFFFFFFF)  // valid lifetime (infinite for tests)
        be32set(p, total + 8, 0xFFFFFFFF)  // preferred lifetime
        be32set(p, total + 12, 0)          // reserved
        ipv6Set(p, total + 16, pre)
        total += 32
    }
    let ck = ipv6UpperChecksum(src: src, dst: dst, nextHeader: ipProtoICMPv6,
                               upper: p, upperLen: total)
    be16set(p, 2, ck)
    return total
}

/// Very small RA parser — we only care about the current hop limit and whether
/// there is a prefix we could use (for a more complete implementation later).
/// Now exercised with full RAs containing prefixes + options in aggressive host tests.
struct ICMP6RAInfo {
    var hopLimit: UInt8 = 0
    var hasPrefix: Bool = false
    var prefix: IPv6 = .zero
    var prefixLen: UInt8 = 0
}

/// Parse a received RA (very minimal; enough to learn a default hop limit or prefix).
func icmp6ParseRA(_ p: UnsafeRawPointer, len: Int) -> ICMP6RAInfo {
    var info = ICMP6RAInfo()
    if len < 16 { return info }                 // at least base RA
    info.hopLimit = b8(p, 4)
    // Options follow at offset 16 from ICMP start
    var off = 16
    while off + 8 <= len {
        let otype = b8(p, off)
        let olen  = Int(b8(p, off + 1)) * 8
        if olen < 8 || off + olen > len { break }
        if otype == 3 /* Prefix Information */ && olen >= 32 {
            info.hasPrefix = true
            info.prefixLen = b8(p, off + 2)
            info.prefix = ipv6Get(p, off + 16)
        }
        off += olen
    }
    return info
}
