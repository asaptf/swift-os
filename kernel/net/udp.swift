// SPDX-License-Identifier: Apache-2.0
// udp.swift — UDP (RFC 768) over IPv4 for the sans-IO core.
//
// Header layout (8 bytes): source port[2], destination port[2], length[2]
// (header + data), checksum[2]. The checksum covers an IPv4 pseudo-header
// (src, dst, zero, protocol, UDP length) plus the UDP header and payload.

let udpHeaderLen = 8

@inline(__always) func udpSrcPort(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 0) }
@inline(__always) func udpDstPort(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 2) }
@inline(__always) func udpLength(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 4) }
@inline(__always) func udpChecksumField(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 6) }

/// Validate a received UDP datagram's checksum (the field is already filled).
/// A correct datagram, summed with its checksum, folds to 0.
func udpChecksumValid(src: IPv4, dst: IPv4, udp: UnsafeRawPointer, udpLen: Int) -> Bool {
    var acc: UInt32 = 0
    acc = sumWord(acc, UInt16(src >> 16)); acc = sumWord(acc, UInt16(src & 0xFFFF))
    acc = sumWord(acc, UInt16(dst >> 16)); acc = sumWord(acc, UInt16(dst & 0xFFFF))
    acc = sumWord(acc, UInt16(ipProtoUDP))
    acc = sumWord(acc, UInt16(udpLen))
    acc = sumBytes(acc, udp, udpLen)
    return foldChecksum(acc) == 0
}

/// Compute the UDP checksum over the pseudo-header + the `udpLen` bytes at
/// `udp` (whose checksum field must be zero). A computed 0 is sent as 0xFFFF
/// (RFC 768: zero means "no checksum", so it is never transmitted).
func udpChecksum(src: IPv4, dst: IPv4, udp: UnsafeRawPointer, udpLen: Int) -> UInt16 {
    var acc: UInt32 = 0
    acc = sumWord(acc, UInt16(src >> 16)); acc = sumWord(acc, UInt16(src & 0xFFFF))
    acc = sumWord(acc, UInt16(dst >> 16)); acc = sumWord(acc, UInt16(dst & 0xFFFF))
    acc = sumWord(acc, UInt16(ipProtoUDP))     // high byte is the pseudo-header zero
    acc = sumWord(acc, UInt16(udpLen))
    acc = sumBytes(acc, udp, udpLen)
    let ck = foldChecksum(acc)
    return ck == 0 ? 0xFFFF : ck
}

/// Write a UDP header + payload at `p`. Returns the UDP message length
/// (8 + payloadLen). `src`/`dst` are the IPv4 addresses, needed for the
/// checksum pseudo-header.
@discardableResult
func udpWrite(_ p: UnsafeMutableRawPointer, src: IPv4, dst: IPv4,
              srcPort: UInt16, dstPort: UInt16,
              payload: UnsafeRawPointer?, payloadLen: Int) -> Int {
    let total = udpHeaderLen + payloadLen
    be16set(p, 0, srcPort)
    be16set(p, 2, dstPort)
    be16set(p, 4, UInt16(total))
    be16set(p, 6, 0)                           // checksum zeroed before computing
    if let payload, payloadLen > 0 {
        var i = 0
        while i < payloadLen { b8set(p, udpHeaderLen + i, b8(payload, i)); i += 1 }
    }
    be16set(p, 6, udpChecksum(src: src, dst: dst, udp: p, udpLen: total))
    return total
}
