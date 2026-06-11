// SPDX-License-Identifier: Apache-2.0
// dhcp.swift — minimal DHCPv4 client packet codec.
//
// This is deliberately sans-IO: it builds DISCOVER/REQUEST Ethernet frames into
// caller-provided buffers and parses BOOTP/DHCP replies from received UDP
// payloads. The live virtio-net glue owns retransmission and lease adoption.

let dhcpServerPort: UInt16 = 67
let dhcpClientPort: UInt16 = 68
let dhcpIPv4Broadcast: IPv4 = 0xFFFF_FFFF

let dhcpMsgDiscover: UInt8 = 1
let dhcpMsgOffer: UInt8 = 2
let dhcpMsgRequest: UInt8 = 3
let dhcpMsgAck: UInt8 = 5

private let dhcpBootpFixedLen = 236
private let dhcpMagicOffset = 236
private let dhcpOptionsOffset = 240
private let dhcpMinPayloadLen = 300
private let dhcpMagicCookie: UInt32 = 0x6382_5363

struct DHCPLease {
    var xid: UInt32
    var messageType: UInt8
    var address: IPv4
    var server: IPv4
    var router: IPv4
    var dns: IPv4
    var subnetMask: IPv4
    var leaseSeconds: UInt32

    init() {
        xid = 0
        messageType = 0
        address = 0
        server = 0
        router = 0
        dns = 0
        subnetMask = 0
        leaseSeconds = 0
    }
}

private func dhcpZero(_ p: UnsafeMutableRawPointer, _ n: Int) {
    var i = 0
    while i < n {
        b8set(p, i, 0)
        i += 1
    }
}

private func dhcpWriteBase(_ p: UnsafeMutableRawPointer, mac: MAC, xid: UInt32) -> Int {
    dhcpZero(p, dhcpMinPayloadLen)
    b8set(p, 0, 1)                 // op: BOOTREQUEST
    b8set(p, 1, 1)                 // htype: Ethernet
    b8set(p, 2, 6)                 // hlen: MAC-48
    b8set(p, 3, 0)                 // hops
    be32set(p, 4, xid)
    be16set(p, 8, 0)               // secs
    be16set(p, 10, 0x8000)         // broadcast replies are acceptable
    macSet(p, 28, mac)             // chaddr[0..5]
    be32set(p, dhcpMagicOffset, dhcpMagicCookie)
    return dhcpOptionsOffset
}

private func dhcpWriteParamRequest(_ p: UnsafeMutableRawPointer, _ off: inout Int) {
    b8set(p, off, 55); off += 1
    b8set(p, off, 4); off += 1
    b8set(p, off, 1); off += 1     // subnet mask
    b8set(p, off, 3); off += 1     // router
    b8set(p, off, 6); off += 1     // DNS server
    b8set(p, off, 51); off += 1    // lease time
}

private func dhcpWriteU8Option(_ p: UnsafeMutableRawPointer, _ off: inout Int,
                               code: UInt8, value: UInt8) {
    b8set(p, off, code); off += 1
    b8set(p, off, 1); off += 1
    b8set(p, off, value); off += 1
}

private func dhcpWriteIPv4Option(_ p: UnsafeMutableRawPointer, _ off: inout Int,
                                 code: UInt8, value: IPv4) {
    b8set(p, off, code); off += 1
    b8set(p, off, 4); off += 1
    be32set(p, off, value); off += 4
}

private func dhcpWriteU16Option(_ p: UnsafeMutableRawPointer, _ off: inout Int,
                                code: UInt8, value: UInt16) {
    b8set(p, off, code); off += 1
    b8set(p, off, 2); off += 1
    be16set(p, off, value); off += 2
}

private func dhcpFinishPayload(_ p: UnsafeMutableRawPointer, _ off: Int) -> Int {
    var end = off
    b8set(p, end, 255)
    end += 1
    while end < dhcpMinPayloadLen {
        b8set(p, end, 0)
        end += 1
    }
    return end
}

private func dhcpBuildFrame(mac: MAC, xid: UInt32, messageType: UInt8,
                            requestedIP: IPv4, serverIP: IPv4,
                            out: UnsafeMutableRawPointer) -> Int {
    ethWriteHeader(out, dst: .broadcast, src: mac, type: ethTypeIPv4)
    let ip = out + ethHeaderLen
    let udp = ip + ipv4HeaderLen
    let payload = udp + udpHeaderLen

    var off = dhcpWriteBase(payload, mac: mac, xid: xid)
    dhcpWriteU8Option(payload, &off, code: 53, value: messageType)
    if requestedIP != 0 {
        dhcpWriteIPv4Option(payload, &off, code: 50, value: requestedIP)
    }
    if serverIP != 0 {
        dhcpWriteIPv4Option(payload, &off, code: 54, value: serverIP)
    }
    dhcpWriteU16Option(payload, &off, code: 57, value: 576)
    dhcpWriteParamRequest(payload, &off)
    let payloadLen = dhcpFinishPayload(payload, off)

    let udpLen = udpHeaderLen + payloadLen
    be16set(udp, 0, dhcpClientPort)
    be16set(udp, 2, dhcpServerPort)
    be16set(udp, 4, UInt16(udpLen))
    be16set(udp, 6, 0)
    be16set(udp, 6, udpChecksum(src: 0, dst: dhcpIPv4Broadcast, udp: udp, udpLen: udpLen))

    let total = ipv4HeaderLen + udpLen
    ipWriteHeader(ip, src: 0, dst: dhcpIPv4Broadcast, proto: ipProtoUDP,
                  totalLen: total, id: UInt16(truncatingIfNeeded: xid))
    return ethHeaderLen + total
}

func dhcpBuildDiscover(mac: MAC, xid: UInt32, out: UnsafeMutableRawPointer) -> Int {
    dhcpBuildFrame(mac: mac, xid: xid, messageType: dhcpMsgDiscover,
                   requestedIP: 0, serverIP: 0, out: out)
}

func dhcpBuildRequest(mac: MAC, xid: UInt32, requestedIP: IPv4, serverIP: IPv4,
                      out: UnsafeMutableRawPointer) -> Int {
    dhcpBuildFrame(mac: mac, xid: xid, messageType: dhcpMsgRequest,
                   requestedIP: requestedIP, serverIP: serverIP, out: out)
}

func dhcpParseReply(_ p: UnsafeRawPointer, _ len: Int,
                    expectedXid: UInt32, mac: MAC) -> DHCPLease {
    var lease = DHCPLease()
    if len < dhcpOptionsOffset { return lease }
    if b8(p, 0) != 2 || b8(p, 1) != 1 || b8(p, 2) < 6 { return lease }
    let xid = be32(p, 4)
    if expectedXid != 0 && xid != expectedXid { return lease }
    if macGet(p, 28) != mac { return lease }
    if be32(p, dhcpMagicOffset) != dhcpMagicCookie { return lease }

    lease.xid = xid
    lease.address = be32(p, 16)       // yiaddr

    var off = dhcpOptionsOffset
    while off < len {
        let code = b8(p, off)
        off += 1
        if code == 0 { continue }
        if code == 255 { break }
        if off >= len { break }
        let optLen = Int(b8(p, off))
        off += 1
        if off + optLen > len { break }
        if code == 53 && optLen >= 1 {
            lease.messageType = b8(p, off)
        } else if code == 54 && optLen >= 4 {
            lease.server = be32(p, off)
        } else if code == 3 && optLen >= 4 {
            lease.router = be32(p, off)
        } else if code == 6 && optLen >= 4 {
            lease.dns = be32(p, off)
        } else if code == 1 && optLen >= 4 {
            lease.subnetMask = be32(p, off)
        } else if code == 51 && optLen >= 4 {
            lease.leaseSeconds = be32(p, off)
        }
        off += optLen
    }

    if lease.messageType == 0 || lease.address == 0 {
        return DHCPLease()
    }
    return lease
}
