// SPDX-License-Identifier: Apache-2.0
// arp.swift — ARP (RFC 826) over Ethernet for IPv4.
//
// ARP packet layout (28 bytes, after the 14-byte Ethernet header):
//   htype[2]=1(Ethernet)  ptype[2]=0x0800(IPv4)  hlen[1]=6  plen[1]=4
//   oper[2]  sha[6]  spa[4]  tha[6]  tpa[4]

let arpPacketLen = 28
let arpHTypeEthernet: UInt16 = 1
let arpOpRequest: UInt16 = 1
let arpOpReply: UInt16 = 2

/// A parsed ARP packet (host-order IPs).
struct ARPView {
    let htype: UInt16
    let ptype: UInt16
    let hlen: UInt8
    let plen: UInt8
    let oper: UInt16
    let sha: MAC   // sender hardware address
    let spa: IPv4  // sender protocol address
    let tha: MAC   // target hardware address
    let tpa: IPv4  // target protocol address
}

func arpParse(_ p: UnsafeRawPointer) -> ARPView {
    ARPView(htype: be16(p, 0), ptype: be16(p, 2), hlen: b8(p, 4), plen: b8(p, 5),
            oper: be16(p, 6), sha: macGet(p, 8), spa: be32(p, 14),
            tha: macGet(p, 18), tpa: be32(p, 24))
}

/// Build a full ARP frame (Ethernet header + ARP packet) into `out`. `frameDst`
/// is the Ethernet destination (broadcast for a request, the requester for a
/// reply). Returns the total frame length (14 + 28 = 42).
func arpBuildFrame(_ out: UnsafeMutableRawPointer, op: UInt16,
                   srcMac: MAC, srcIP: IPv4, dstMac: MAC, dstIP: IPv4,
                   frameDst: MAC) -> Int {
    ethWriteHeader(out, dst: frameDst, src: srcMac, type: ethTypeARP)
    let a = out + ethHeaderLen
    be16set(a, 0, arpHTypeEthernet)
    be16set(a, 2, ethTypeIPv4)
    b8set(a, 4, 6)
    b8set(a, 5, 4)
    be16set(a, 6, op)
    macSet(a, 8, srcMac); be32set(a, 14, srcIP)
    macSet(a, 18, dstMac); be32set(a, 24, dstIP)
    return ethHeaderLen + arpPacketLen
}
