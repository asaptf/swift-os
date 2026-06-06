// stack.swift — the sans-IO engine façade.
//
// `NetStack` is pure protocol logic: it consumes one received Ethernet frame at
// a time and writes any reply into a caller-provided buffer. It performs NO I/O
// — the kernel driver (kernel/drivers/virtio_net.swift) pumps real DMA frames
// through it, and tests/net_test.swift feeds it crafted bytes. Zero-copy: the
// `onFrame` input pointer points straight into the RX DMA buffer and the `out`
// pointer into the TX DMA buffer, so no payload is copied across the boundary.
//
// The per-packet path does not allocate. The only heap use is the small,
// fixed-size ARP cache below, which is control-plane state, not per-packet.

/// A tiny fixed-capacity ARP table (IPv4 → MAC), replaced round-robin.
struct ARPCache {
    private struct Entry { var ip: IPv4 = 0; var mac: MAC = .zero; var used = false }
    private var entries = [Entry](repeating: Entry(), count: 8)
    private var next = 0

    mutating func insert(_ ip: IPv4, _ mac: MAC) {
        for i in 0..<entries.count where entries[i].used && entries[i].ip == ip {
            entries[i].mac = mac
            return
        }
        entries[next] = Entry(ip: ip, mac: mac, used: true)
        next = (next + 1) % entries.count
    }

    func lookup(_ ip: IPv4) -> MAC? {
        for e in entries where e.used && e.ip == ip { return e.mac }
        return nil
    }
}

/// What processing one received frame produced. `txLen > 0` means a reply was
/// written into the `out` buffer passed to `onFrame` and should be transmitted.
struct RxOutcome {
    var txLen = 0
    var arpResolved = false
    var resolvedIP: IPv4 = 0
    var resolvedMac: MAC = .zero
    var echoReply = false
    var echoSeq: UInt16 = 0
    // A received UDP datagram addressed to us. The payload is reported by its
    // offset into the original frame buffer (zero-copy: the kernel socket layer
    // copies it out of the RX buffer itself).
    var gotUDP = false
    var udpSrcIP: IPv4 = 0
    var udpSrcPort: UInt16 = 0
    var udpDstPort: UInt16 = 0
    var udpSrcMac: MAC = .zero
    var udpPayloadOff = 0
    var udpPayloadLen = 0
}

struct NetStack {
    let mac: MAC
    let ip: IPv4
    var arp = ARPCache()
    private var nextIPID: UInt16 = 0

    init(mac: MAC, ip: IPv4) {
        self.mac = mac
        self.ip = ip
    }

    /// Process one received Ethernet frame `[p, p+len)`. Any reply is written
    /// into `out` (capacity `outCap` bytes) and reported via `RxOutcome.txLen`.
    mutating func onFrame(_ p: UnsafeRawPointer, _ len: Int,
                          out: UnsafeMutableRawPointer, outCap: Int) -> RxOutcome {
        var r = RxOutcome()
        if len < ethHeaderLen { return r }
        let type = ethType(p)
        let payload = p + ethHeaderLen
        let payloadLen = len - ethHeaderLen

        if type == ethTypeARP {
            if payloadLen < arpPacketLen { return r }
            let a = arpParse(payload)
            guard a.htype == arpHTypeEthernet, a.ptype == ethTypeIPv4 else { return r }
            if a.oper == arpOpRequest || a.oper == arpOpReply {
                arp.insert(a.spa, a.sha)  // learn the sender either way
            }
            if a.oper == arpOpReply && a.tpa == ip {
                r.arpResolved = true; r.resolvedIP = a.spa; r.resolvedMac = a.sha
            } else if a.oper == arpOpRequest && a.tpa == ip
                        && outCap >= ethHeaderLen + arpPacketLen {
                r.txLen = arpBuildFrame(out, op: arpOpReply, srcMac: mac, srcIP: ip,
                                        dstMac: a.sha, dstIP: a.spa, frameDst: a.sha)
            }
            return r
        }

        if type == ethTypeIPv4 {
            if payloadLen < ipv4HeaderLen { return r }
            let ipp = payload
            guard ipVersion(ipp) == 4, ipValidChecksum(ipp), ipDst(ipp) == ip else { return r }
            arp.insert(ipSrc(ipp), ethSrcMac(p))   // learn L2 so we can route replies
            let ihl = ipHeaderLenBytes(ipp)
            let total = Int(ipTotalLen(ipp))
            guard total >= ihl, total <= payloadLen else { return r }
            let proto = ipProto(ipp)
            let l4 = ipp + ihl
            let l4Len = total - ihl

            if proto == ipProtoICMP {
                guard l4Len >= icmpHeaderLen, inetChecksum(l4, l4Len) == 0 else { return r }
                let t = icmpType(l4)
                if t == icmpTypeEchoReply {
                    r.echoReply = true; r.echoSeq = icmpSeq(l4)
                } else if t == icmpTypeEchoRequest {
                    r.txLen = buildEchoReply(out, outCap: outCap, toMac: ethSrcMac(p),
                                             toIP: ipSrc(ipp), id: icmpId(l4),
                                             reqICMP: l4, reqICMPLen: l4Len)
                }
            } else if proto == ipProtoUDP {
                guard l4Len >= udpHeaderLen else { return r }
                // A zero checksum field means "not present" (RFC 768); verify only when set.
                if udpChecksumField(l4) != 0 {
                    guard udpChecksumValid(src: ipSrc(ipp), dst: ipDst(ipp),
                                           udp: l4, udpLen: l4Len) else { return r }
                }
                let udpLen = Int(udpLength(l4))
                guard udpLen >= udpHeaderLen, udpLen <= l4Len else { return r }
                r.gotUDP = true
                r.udpSrcIP = ipSrc(ipp)
                r.udpSrcPort = udpSrcPort(l4)
                r.udpDstPort = udpDstPort(l4)
                r.udpSrcMac = ethSrcMac(p)
                r.udpPayloadOff = ethHeaderLen + ihl + udpHeaderLen
                r.udpPayloadLen = udpLen - udpHeaderLen
            }
            return r
        }

        return r
    }

    /// Build a UDP datagram to (`toMac`, `toIP`):`dstPort` from `srcPort`,
    /// carrying `payloadLen` bytes at `payload`. Returns the frame length.
    mutating func buildUDP(toMac: MAC, toIP: IPv4, srcPort: UInt16, dstPort: UInt16,
                           payload: UnsafeRawPointer?, payloadLen: Int,
                           out: UnsafeMutableRawPointer) -> Int {
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv4)
        let ipp = out + ethHeaderLen
        let udp = ipp + ipv4HeaderLen
        let udpLen = udpWrite(udp, src: ip, dst: toIP, srcPort: srcPort, dstPort: dstPort,
                              payload: payload, payloadLen: payloadLen)
        let total = ipv4HeaderLen + udpLen
        nextIPID &+= 1
        ipWriteHeader(ipp, src: ip, dst: toIP, proto: ipProtoUDP, totalLen: total, id: nextIPID)
        return ethHeaderLen + total
    }

    /// Build a broadcast ARP request for `targetIP`. Returns the frame length.
    func buildArpRequest(targetIP: IPv4, out: UnsafeMutableRawPointer) -> Int {
        arpBuildFrame(out, op: arpOpRequest, srcMac: mac, srcIP: ip,
                      dstMac: .zero, dstIP: targetIP, frameDst: .broadcast)
    }

    /// Build an ICMP echo request to (`toMac`, `toIP`). Returns the frame length.
    func buildEchoRequest(toMac: MAC, toIP: IPv4, id: UInt16, seq: UInt16,
                          payloadLen: Int, out: UnsafeMutableRawPointer) -> Int {
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv4)
        let ipp = out + ethHeaderLen
        let icmp = ipp + ipv4HeaderLen
        let icmpLen = icmpWriteEcho(icmp, type: icmpTypeEchoRequest,
                                    id: id, seq: seq, payloadLen: payloadLen)
        let total = ipv4HeaderLen + icmpLen
        ipWriteHeader(ipp, src: ip, dst: toIP, proto: ipProtoICMP, totalLen: total, id: id)
        return ethHeaderLen + total
    }

    /// Turn a received echo request into an echo reply written into `out` (used
    /// by the inbound responder path; exercised by host tests, ready for net-b).
    private func buildEchoReply(_ out: UnsafeMutableRawPointer, outCap: Int,
                                toMac: MAC, toIP: IPv4, id: UInt16,
                                reqICMP: UnsafeRawPointer, reqICMPLen: Int) -> Int {
        let total = ethHeaderLen + ipv4HeaderLen + reqICMPLen
        if outCap < total { return 0 }
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv4)
        let ipp = out + ethHeaderLen
        let icmp = ipp + ipv4HeaderLen
        var i = 0
        while i < reqICMPLen { b8set(icmp, i, b8(reqICMP, i)); i += 1 }  // copy id/seq/payload
        b8set(icmp, 0, icmpTypeEchoReply)
        be16set(icmp, 2, 0)
        be16set(icmp, 2, inetChecksum(icmp, reqICMPLen))
        ipWriteHeader(ipp, src: ip, dst: toIP, proto: ipProtoICMP,
                      totalLen: ipv4HeaderLen + reqICMPLen, id: id)
        return total
    }
}
