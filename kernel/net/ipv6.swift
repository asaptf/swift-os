// SPDX-License-Identifier: Apache-2.0
// ipv6.swift — IPv6 (RFC 8200) header parse/build and IPv6 pseudo-header checksum
// support. Pure, host-testable, no allocation on the per-packet path.
//
// Header layout (40 bytes fixed, no options in the base header):
//   version(4)/traffic class(8)/flow label(20) [4 bytes BE]
//   payload length[2], next header[1], hop limit[1]
//   src[16], dst[16]
//
// We provide byte-level accessors (like ipv4.swift) and a struct IPv6 address
// for type safety in the rest of the stack. Upper-layer checksums (UDP6, TCP6,
// ICMPv6) use the IPv6 pseudo-header (RFC 8200 section 8.1 + RFC 2460/8200).

let ipv6HeaderLen = 40
let ipProtoICMPv6: UInt8 = 58

/// 128-bit IPv6 address. Stored in network (big-endian) byte order.
/// Backed by two UInt64 for reliable value semantics, passing, and comparison
/// under Embedded Swift. Byte accessors are provided for wire I/O.
struct IPv6: Equatable {
    // hi = bytes 0..7 (network order), lo = bytes 8..15 (network order)
    var hi: UInt64
    var lo: UInt64

    init() {
        hi = 0
        lo = 0
    }

    init(_ bytes: [UInt8]) {
        precondition(bytes.count == 16)
        hi = (UInt64(bytes[0]) << 56) | (UInt64(bytes[1]) << 48) | (UInt64(bytes[2]) << 40) | (UInt64(bytes[3]) << 32) |
             (UInt64(bytes[4]) << 24) | (UInt64(bytes[5]) << 16) | (UInt64(bytes[6]) <<  8) | UInt64(bytes[7])
        lo = (UInt64(bytes[8]) << 56) | (UInt64(bytes[9]) << 48) | (UInt64(bytes[10]) << 40) | (UInt64(bytes[11]) << 32) |
             (UInt64(bytes[12]) << 24) | (UInt64(bytes[13]) << 16) | (UInt64(bytes[14]) <<  8) | UInt64(bytes[15])
    }

    /// Construct from two 64-bit big-endian words.
    init(hi: UInt64, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    // Byte accessors (for the rare places that need individual bytes, e.g. solicited-node, logging)
    var b0: UInt8  { UInt8((hi >> 56) & 0xFF) }
    var b1: UInt8  { UInt8((hi >> 48) & 0xFF) }
    var b2: UInt8  { UInt8((hi >> 40) & 0xFF) }
    var b3: UInt8  { UInt8((hi >> 32) & 0xFF) }
    var b4: UInt8  { UInt8((hi >> 24) & 0xFF) }
    var b5: UInt8  { UInt8((hi >> 16) & 0xFF) }
    var b6: UInt8  { UInt8((hi >>  8) & 0xFF) }
    var b7: UInt8  { UInt8(hi & 0xFF) }
    var b8: UInt8  { UInt8((lo >> 56) & 0xFF) }
    var b9: UInt8  { UInt8((lo >> 48) & 0xFF) }
    var b10: UInt8 { UInt8((lo >> 40) & 0xFF) }
    var b11: UInt8 { UInt8((lo >> 32) & 0xFF) }
    var b12: UInt8 { UInt8((lo >> 24) & 0xFF) }
    var b13: UInt8 { UInt8((lo >> 16) & 0xFF) }
    var b14: UInt8 { UInt8((lo >>  8) & 0xFF) }
    var b15: UInt8 { UInt8(lo & 0xFF) }

    static let zero = IPv6()
    static let loopback = IPv6(hi: 0, lo: 1)
}

/// Copy 16 bytes from `p` (wire order) into an IPv6 value.
@inline(__always) func ipv6Get(_ p: UnsafeRawPointer, _ off: Int) -> IPv6 {
    let h = (UInt64(b8(p, off+0))<<56) | (UInt64(b8(p, off+1))<<48) | (UInt64(b8(p, off+2))<<40) | (UInt64(b8(p, off+3))<<32) |
            (UInt64(b8(p, off+4))<<24) | (UInt64(b8(p, off+5))<<16) | (UInt64(b8(p, off+6))<<8)  | UInt64(b8(p, off+7))
    let l = (UInt64(b8(p, off+8))<<56) | (UInt64(b8(p, off+9))<<48) | (UInt64(b8(p, off+10))<<40) | (UInt64(b8(p, off+11))<<32) |
            (UInt64(b8(p, off+12))<<24) | (UInt64(b8(p, off+13))<<16) | (UInt64(b8(p, off+14))<<8)  | UInt64(b8(p, off+15))
    return IPv6(hi: h, lo: l)
}

/// Write 16-byte IPv6 address at `p` (wire order).
@inline(__always) func ipv6Set(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: IPv6) {
    b8set(p, off+0,  UInt8((v.hi>>56)&0xFF)); b8set(p, off+1, UInt8((v.hi>>48)&0xFF))
    b8set(p, off+2,  UInt8((v.hi>>40)&0xFF)); b8set(p, off+3, UInt8((v.hi>>32)&0xFF))
    b8set(p, off+4,  UInt8((v.hi>>24)&0xFF)); b8set(p, off+5, UInt8((v.hi>>16)&0xFF))
    b8set(p, off+6,  UInt8((v.hi>>8)&0xFF));  b8set(p, off+7, UInt8(v.hi&0xFF))
    b8set(p, off+8,  UInt8((v.lo>>56)&0xFF)); b8set(p, off+9, UInt8((v.lo>>48)&0xFF))
    b8set(p, off+10, UInt8((v.lo>>40)&0xFF)); b8set(p, off+11, UInt8((v.lo>>32)&0xFF))
    b8set(p, off+12, UInt8((v.lo>>24)&0xFF)); b8set(p, off+13, UInt8((v.lo>>16)&0xFF))
    b8set(p, off+14, UInt8((v.lo>>8)&0xFF));  b8set(p, off+15, UInt8(v.lo&0xFF))
}

/// Derive a link-local IPv6 address from a MAC using modified EUI-64.
/// fe80:: + (MAC with 7th bit inverted) + ff:fe + last 3 bytes of MAC.
func ipv6LinkLocalFromMAC(_ mac: MAC) -> IPv6 {
    let iid0 = mac.a ^ 0x02
    let iid1 = mac.b
    let iid2 = mac.c
    let iid3: UInt8 = 0xff
    let iid4: UInt8 = 0xfe
    let iid5 = mac.d
    let iid6 = mac.e
    let iid7 = mac.f

    let hi: UInt64 = 0xFE80_0000_0000_0000
    let lo: UInt64 = (UInt64(iid0)<<56) | (UInt64(iid1)<<48) | (UInt64(iid2)<<40) | (UInt64(iid3)<<32) |
                     (UInt64(iid4)<<24) | (UInt64(iid5)<<16) | (UInt64(iid6)<<8)  | UInt64(iid7)
    return IPv6(hi: hi, lo: lo)
}

/// Compute the solicited-node multicast address for a unicast IPv6 address.
/// ff02::1:ff00:0/104 + last 24 bits of the address.
func ipv6SolicitedNodeMulticast(_ addr: IPv6) -> IPv6 {
    // ff02::1:ffXX:XXXX  (last 3 bytes of addr)
    let hi: UInt64 = 0xFF02_0000_0000_0000
    let lo: UInt64 = 0x0000_0001_FF00_0000 | (UInt64(addr.b13) << 16) | (UInt64(addr.b14) << 8) | UInt64(addr.b15)
    return IPv6(hi: hi, lo: lo)
}

/// Return true if the address has the link-local prefix fe80::/10.
func ipv6IsLinkLocal(_ a: IPv6) -> Bool {
    // First 10 bits are 1111 1110 10
    return (a.hi >> 54) == 0x3FA   // 0xFE80 >> 6 == 0x3FA (10 bits)
}

@inline(__always) func ip6Version(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 0) >> 4 }
@inline(__always) func ip6TrafficClass(_ p: UnsafeRawPointer) -> UInt8 {
    ((b8(p, 0) & 0x0F) << 4) | (b8(p, 1) >> 4)
}
@inline(__always) func ip6FlowLabel(_ p: UnsafeRawPointer) -> UInt32 {
    (UInt32(b8(p, 1) & 0x0F) << 16) | (UInt32(b8(p, 2)) << 8) | UInt32(b8(p, 3))
}
@inline(__always) func ip6PayloadLen(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 4) }
@inline(__always) func ip6NextHeader(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 6) }
@inline(__always) func ip6HopLimit(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 7) }
@inline(__always) func ip6Src(_ p: UnsafeRawPointer) -> IPv6 { ipv6Get(p, 8) }
@inline(__always) func ip6Dst(_ p: UnsafeRawPointer) -> IPv6 { ipv6Get(p, 24) }

/// Write a minimal 40-byte IPv6 base header (no extension headers).
/// `payloadLen` is the length of the upper-layer payload (excludes the 40-byte IPv6 header).
/// Caller must have already zeroed or prepared the checksum field for upper layers.
func ip6WriteHeader(_ p: UnsafeMutableRawPointer,
                    src: IPv6, dst: IPv6,
                    nextHeader: UInt8,
                    payloadLen: Int,
                    hopLimit: UInt8 = 64) {
    // version=6, traffic class=0, flow label=0
    b8set(p, 0, 0x60)
    b8set(p, 1, 0)
    b8set(p, 2, 0)
    b8set(p, 3, 0)
    be16set(p, 4, UInt16(payloadLen))
    b8set(p, 6, nextHeader)
    b8set(p, 7, hopLimit)
    ipv6Set(p, 8, src)
    ipv6Set(p, 24, dst)
}

/// Accumulate the 16-byte IPv6 address (big-endian bytes) into the running checksum sum.
/// Each 16-bit big-endian word is added as-is (network order contribution).
@inline(__always)
private func sumIPv6(_ acc: UInt32, _ a: IPv6) -> UInt32 {
    var s = acc
    s &+= (UInt32(a.b0) << 8) | UInt32(a.b1)
    s &+= (UInt32(a.b2) << 8) | UInt32(a.b3)
    s &+= (UInt32(a.b4) << 8) | UInt32(a.b5)
    s &+= (UInt32(a.b6) << 8) | UInt32(a.b7)
    s &+= (UInt32(a.b8) << 8) | UInt32(a.b9)
    s &+= (UInt32(a.b10) << 8) | UInt32(a.b11)
    s &+= (UInt32(a.b12) << 8) | UInt32(a.b13)
    s &+= (UInt32(a.b14) << 8) | UInt32(a.b15)
    return s
}

/// IPv6 pseudo-header checksum accumulation (RFC 8200 / 2460).
/// Upper layer (UDP6/TCP6/ICMPv6) checksum is computed over:
///   src(16) + dst(16) + upper-layer-packet-length(4) + zero(3) + next-header(1) + upper-bytes
/// The caller then folds with foldChecksum and applies the usual 0->0xFFFF rule for UDP.
func sumIPv6Pseudo(_ acc: UInt32, src: IPv6, dst: IPv6, upperLen: Int, nextHeader: UInt8) -> UInt32 {
    var s = acc
    s = sumIPv6(s, src)
    s = sumIPv6(s, dst)
    // upper length as 32-bit
    s &+= UInt32((upperLen >> 16) & 0xFFFF)
    s &+= UInt32(upperLen & 0xFFFF)
    // 3 zero bytes + next header
    s &+= UInt32(nextHeader)
    return s
}

/// Compute a full upper-layer checksum given the IPv6 pseudo-header and the upper bytes.
/// Used by UDP6/TCP6/ICMPv6 writers (the upper header's checksum field must be zeroed first).
func ipv6UpperChecksum(src: IPv6, dst: IPv6, nextHeader: UInt8,
                       upper: UnsafeRawPointer, upperLen: Int) -> UInt16 {
    var acc = sumIPv6Pseudo(0, src: src, dst: dst, upperLen: upperLen, nextHeader: nextHeader)
    acc = sumBytes(acc, upper, upperLen)
    let ck = foldChecksum(acc)
    return ck == 0 ? 0xFFFF : ck   // convention for "no checksum" in UDP
}

/// Validate an upper-layer checksum that is already present in the packet.
func ipv6UpperChecksumValid(src: IPv6, dst: IPv6, nextHeader: UInt8,
                            upper: UnsafeRawPointer, upperLen: Int) -> Bool {
    var acc = sumIPv6Pseudo(0, src: src, dst: dst, upperLen: upperLen, nextHeader: nextHeader)
    acc = sumBytes(acc, upper, upperLen)
    return foldChecksum(acc) == 0
}
