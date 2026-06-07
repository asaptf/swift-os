// SPDX-License-Identifier: Apache-2.0
// icmp.swift — ICMP (RFC 792) echo request/reply.
//
// Header layout (8 bytes): type[1], code[1], checksum[2], identifier[2],
//   sequence[2], then the echo payload.

let icmpTypeEchoReply: UInt8 = 0
let icmpTypeEchoRequest: UInt8 = 8
let icmpHeaderLen = 8

@inline(__always) func icmpType(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 0) }
@inline(__always) func icmpId(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 4) }
@inline(__always) func icmpSeq(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 6) }

/// Write an ICMP echo message (type 8 request or 0 reply) with `payloadLen`
/// bytes of a simple data pattern at `p`. Sets the ICMP checksum. Returns the
/// total ICMP message length (8 + payloadLen).
@discardableResult
func icmpWriteEcho(_ p: UnsafeMutableRawPointer, type: UInt8,
                   id: UInt16, seq: UInt16, payloadLen: Int) -> Int {
    b8set(p, 0, type)
    b8set(p, 1, 0)              // code 0
    be16set(p, 2, 0)            // checksum zeroed before computing
    be16set(p, 4, id)
    be16set(p, 6, seq)
    var i = 0
    while i < payloadLen { b8set(p, icmpHeaderLen + i, UInt8(i & 0xFF)); i += 1 }
    let total = icmpHeaderLen + payloadLen
    be16set(p, 2, inetChecksum(p, total))
    return total
}
