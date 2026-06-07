// SPDX-License-Identifier: Apache-2.0
// ipv4.swift — IPv4 (RFC 791) header parse/build. No options, no fragmentation.
//
// Header layout (20 bytes): ver/IHL[1], DSCP/ECN[1], total length[2], id[2],
//   flags/frag[2], TTL[1], protocol[1], header checksum[2], src[4], dst[4].

let ipv4HeaderLen = 20
let ipProtoICMP: UInt8 = 1
let ipProtoUDP: UInt8 = 17

@inline(__always) func ipVersion(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 0) >> 4 }
@inline(__always) func ipHeaderLenBytes(_ p: UnsafeRawPointer) -> Int { Int(b8(p, 0) & 0x0F) * 4 }
@inline(__always) func ipTotalLen(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 2) }
@inline(__always) func ipProto(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 9) }
@inline(__always) func ipSrc(_ p: UnsafeRawPointer) -> IPv4 { be32(p, 12) }
@inline(__always) func ipDst(_ p: UnsafeRawPointer) -> IPv4 { be32(p, 16) }

/// True if the header is well-formed and its checksum verifies (sums to 0).
func ipValidChecksum(_ p: UnsafeRawPointer) -> Bool {
    let ihl = ipHeaderLenBytes(p)
    if ihl < ipv4HeaderLen { return false }
    return inetChecksum(p, ihl) == 0
}

/// Write a 20-byte IPv4 header at `p`. The caller fills the payload after the
/// header and passes `totalLen` (header + payload). Sets the header checksum.
func ipWriteHeader(_ p: UnsafeMutableRawPointer, src: IPv4, dst: IPv4,
                   proto: UInt8, totalLen: Int, id: UInt16) {
    b8set(p, 0, 0x45)                 // version 4, IHL 5 (20 bytes)
    b8set(p, 1, 0)                    // DSCP/ECN
    be16set(p, 2, UInt16(totalLen))
    be16set(p, 4, id)
    be16set(p, 6, 0)                  // flags=0 (no DF), fragment offset 0
    b8set(p, 8, 64)                   // TTL
    b8set(p, 9, proto)
    be16set(p, 10, 0)                 // checksum field zeroed before computing
    be32set(p, 12, src)
    be32set(p, 16, dst)
    be16set(p, 10, inetChecksum(p, ipv4HeaderLen))
}
