// SPDX-License-Identifier: Apache-2.0
// ethernet.swift — Ethernet II framing for the sans-IO core.
//
// Layout (14 bytes): dst MAC[6], src MAC[6], ethertype[2, big-endian].

let ethHeaderLen = 14
let ethTypeIPv4: UInt16 = 0x0800
let ethTypeARP: UInt16 = 0x0806
let ethTypeIPv6: UInt16 = 0x86DD

@inline(__always) func ethDstMac(_ p: UnsafeRawPointer) -> MAC { macGet(p, 0) }
@inline(__always) func ethSrcMac(_ p: UnsafeRawPointer) -> MAC { macGet(p, 6) }
@inline(__always) func ethType(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 12) }

/// Write an Ethernet header at the start of `p`. Returns the payload offset.
@discardableResult
func ethWriteHeader(_ p: UnsafeMutableRawPointer, dst: MAC, src: MAC, type: UInt16) -> Int {
    macSet(p, 0, dst)
    macSet(p, 6, src)
    be16set(p, 12, type)
    return ethHeaderLen
}
