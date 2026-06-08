// SPDX-License-Identifier: Apache-2.0
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

/// Fixed-size Neighbor Cache for IPv6 (RFC 4861). Maps IPv6 → MAC.
/// Round-robin replacement, same small footprint as ARPCache.
struct NeighborCache {
    private struct Entry { var ip: IPv6 = .zero; var mac: MAC = .zero; var used = false }
    private var entries = [Entry](repeating: Entry(), count: 8)
    private var next = 0

    mutating func insert(_ ip: IPv6, _ mac: MAC) {
        for i in 0..<entries.count where entries[i].used && entries[i].ip == ip {
            entries[i].mac = mac
            return
        }
        entries[next] = Entry(ip: ip, mac: mac, used: true)
        next = (next + 1) % entries.count
    }

    func lookup(_ ip: IPv6) -> MAC? {
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

    // IPv6 neighbor discovery resolution (NDP).
    var ndpResolved = false
    var resolvedIPv6: IPv6 = .zero
    var resolvedIPv6Mac: MAC = .zero

    var echoReply = false
    var echoSeq: UInt16 = 0
    var echoReplyIPv6 = false   // true if this was an IPv6 echo reply

    // IPv4 UDP/TCP delivery (unchanged).
    var gotUDP = false
    var udpSrcIP: IPv4 = 0
    var udpSrcPort: UInt16 = 0
    var udpDstPort: UInt16 = 0
    var udpSrcMac: MAC = .zero
    var udpPayloadOff = 0
    var udpPayloadLen = 0

    var gotTCP = false
    var tcpSrcIP: IPv4 = 0
    var tcpSrcMac: MAC = .zero
    var tcpSrcPort: UInt16 = 0
    var tcpDstPort: UInt16 = 0
    var tcpFlags: UInt8 = 0
    var tcpSeqNum: UInt32 = 0
    var tcpAckNum: UInt32 = 0
    var tcpWnd: UInt16 = 0
    var tcpPayloadOff = 0
    var tcpPayloadLen = 0

    // IPv6 UDP/TCP delivery (new for full dual-stack).
    var gotUDPv6 = false
    var udpSrcIPv6: IPv6 = .zero
    var udpSrcPortv6: UInt16 = 0
    var udpDstPortv6: UInt16 = 0
    var udpSrcMacv6: MAC = .zero
    var udpPayloadOffv6 = 0
    var udpPayloadLenv6 = 0

    var gotTCPv6 = false
    var tcpSrcIPv6: IPv6 = .zero
    var tcpSrcMacv6: MAC = .zero
    var tcpSrcPortv6: UInt16 = 0
    var tcpDstPortv6: UInt16 = 0
    var tcpFlagsv6: UInt8 = 0
    var tcpSeqNumv6: UInt32 = 0
    var tcpAckNumv6: UInt32 = 0
    var tcpWndv6: UInt16 = 0
    var tcpPayloadOffv6 = 0
    var tcpPayloadLenv6 = 0
}

struct NetStack {
    let mac: MAC
    let ip: IPv4
    var ipv6: IPv6 = .zero          // our IPv6 address (link-local or global)
    var arp = ARPCache()
    var ndp = NeighborCache()
    private var nextIPID: UInt16 = 0

    init(mac: MAC, ip: IPv4, ipv6: IPv6 = .zero) {
        self.mac = mac
        self.ip = ip
        self.ipv6 = ipv6
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
            } else if proto == ipProtoTCP {
                guard l4Len >= tcpMinHeaderLen,
                      tcpChecksumValid(src: ipSrc(ipp), dst: ipDst(ipp), seg: l4, segLen: l4Len) else { return r }
                let dataOff = tcpDataOffset(l4)
                guard dataOff >= tcpMinHeaderLen, dataOff <= l4Len else { return r }
                r.gotTCP = true
                r.tcpSrcIP = ipSrc(ipp)
                r.tcpSrcMac = ethSrcMac(p)
                r.tcpSrcPort = tcpSrcPort(l4)
                r.tcpDstPort = tcpDstPort(l4)
                r.tcpFlags = tcpFlags(l4)
                r.tcpSeqNum = tcpSeq(l4)
                r.tcpAckNum = tcpAck(l4)
                r.tcpWnd = tcpWindow(l4)
                r.tcpPayloadOff = ethHeaderLen + ihl + dataOff
                r.tcpPayloadLen = l4Len - dataOff
            }
            return r
        }

        // ====================== IPv6 path (full dual-stack + NDP) ======================
        if type == ethTypeIPv6 {
            if payloadLen < ipv6HeaderLen { return r }
            let ip6p = payload
            guard ip6Version(ip6p) == 6 else { return r }

            // For now we accept packets addressed to our configured IPv6 or
            // to the solicited-node multicast derived from it (for NDP).
            let dst6 = ip6Dst(ip6p)
            let our6 = ipv6
            let solNode = ipv6SolicitedNodeMulticast(our6)
            let dstMatchesUs = (dst6 == our6) || (dst6 == solNode) || (dst6 == .loopback && our6 == .loopback)

            // We still learn from any IPv6 packet the source L2 (best-effort).
            // Real learning happens via NDP.
            if dstMatchesUs {
                // Walk next-header chain (very small set of common EHs we skip).
                var nh = ip6NextHeader(ip6p)
                var l4Off = ipv6HeaderLen
                var l4Len = Int(ip6PayloadLen(ip6p))
                var cur = ip6p + ipv6HeaderLen

                // Skip a few common extension headers so we reach the real upper layer.
                var skipped = 0
                while (nh == 0 /* Hop-by-Hop */ || nh == 43 /* Routing */ || nh == 60 /* DestOpts */) && skipped < 4 && l4Len > 2 {
                    let hdrExtLen = Int(b8(cur, 1)) + 1   // in 8-byte units, +1 for the first 8
                    if l4Len < hdrExtLen * 8 { break }
                    nh = b8(cur, 0)
                    l4Off += hdrExtLen * 8
                    l4Len -= hdrExtLen * 8
                    cur += hdrExtLen * 8
                    skipped += 1
                }

                if nh == ipProtoICMPv6 && l4Len >= icmp6HeaderLen {
                    let icmp6 = cur
                    // We validate the ICMPv6 checksum using the real IPv6 src/dst from the base header.
                    let src6 = ip6Src(ip6p)
                    if !icmp6ChecksumValid(src: src6, dst: dst6, msg: icmp6, msgLen: l4Len) {
                        return r
                    }
                    let t = icmp6Type(icmp6)

                    if t == icmp6TypeEchoRequest {
                        // Reply to echo (ping6)
                        if outCap >= ethHeaderLen + ipv6HeaderLen + l4Len {
                            r.txLen = buildICMP6EchoReply(out, outCap: outCap,
                                                          toMac: ethSrcMac(p),
                                                          toIPv6: src6,
                                                          req: icmp6, reqLen: l4Len,
                                                          ourSrc: our6)
                            r.echoReplyIPv6 = true
                            r.echoSeq = icmp6Seq(icmp6)
                        }
                    } else if t == icmp6TypeEchoReply {
                        r.echoReply = true
                        r.echoSeq = icmp6Seq(icmp6)
                        r.echoReplyIPv6 = true
                    } else if t == icmp6TypeNS {
                        // Neighbor Solicitation — answer with NA if target is us
                        let target = icmp6NDTarget(icmp6)
                        if target == our6 && outCap >= ethHeaderLen + ipv6HeaderLen + 32 {
                            // Send NA (Solicited + Override)
                            let naLen = icmp6WriteNA(out + ethHeaderLen + ipv6HeaderLen,
                                                     target: our6,
                                                     tgtLLA: mac,
                                                     flags: ndpNAFlagSolicited | ndpNAFlagOverride,
                                                     src: our6, dst: src6)
                            ethWriteHeader(out, dst: ethSrcMac(p), src: mac, type: ethTypeIPv6)
                            ip6WriteHeader(out + ethHeaderLen, src: our6, dst: src6,
                                           nextHeader: ipProtoICMPv6, payloadLen: naLen)
                            r.txLen = ethHeaderLen + ipv6HeaderLen + naLen
                            // Also learn the sender if they provided SLLA option (we ignore options for now but still learn L2)
                            ndp.insert(src6, ethSrcMac(p))
                        }
                    } else if t == icmp6TypeNA {
                        // Neighbor Advertisement — learn the mapping
                        let target = icmp6NDTarget(icmp6)
                        // For a proper implementation we should parse the TLLA option.
                        // Here we optimistically learn the source L2 for the target address.
                        ndp.insert(target, ethSrcMac(p))
                        if target == our6 {
                            // Someone is advertising about us (possible DAD collision) — ignore for minimal.
                        } else {
                            r.ndpResolved = true
                            r.resolvedIPv6 = target
                            r.resolvedIPv6Mac = ethSrcMac(p)
                        }
                    }
                } else if nh == ipProtoUDP {
                    // Deliver IPv6 UDP
                    guard l4Len >= udpHeaderLen else { return r }
                    // UDP checksum for IPv6: zero field means "no checksum" is allowed but rare.
                    let udpC = udpChecksumField(cur)
                    if udpC != 0 {
                        if !ipv6UpperChecksumValid(src: ip6Src(ip6p), dst: dst6, nextHeader: nh,
                                                   upper: cur, upperLen: l4Len) { return r }
                    }
                    let ul = Int(udpLength(cur))
                    guard ul >= udpHeaderLen && ul <= l4Len else { return r }
                    r.gotUDPv6 = true
                    r.udpSrcIPv6 = ip6Src(ip6p)
                    r.udpSrcPortv6 = udpSrcPort(cur)
                    r.udpDstPortv6 = udpDstPort(cur)
                    r.udpSrcMacv6 = ethSrcMac(p)
                    r.udpPayloadOffv6 = ethHeaderLen + l4Off + udpHeaderLen
                    r.udpPayloadLenv6 = ul - udpHeaderLen
                } else if nh == ipProtoTCP {
                    guard l4Len >= tcpMinHeaderLen else { return r }
                    if !ipv6UpperChecksumValid(src: ip6Src(ip6p), dst: dst6, nextHeader: nh,
                                               upper: cur, upperLen: l4Len) { return r }
                    let doff = tcpDataOffset(cur)
                    guard doff >= tcpMinHeaderLen && doff <= l4Len else { return r }
                    r.gotTCPv6 = true
                    r.tcpSrcIPv6 = ip6Src(ip6p)
                    r.tcpSrcMacv6 = ethSrcMac(p)
                    r.tcpSrcPortv6 = tcpSrcPort(cur)
                    r.tcpDstPortv6 = tcpDstPort(cur)
                    r.tcpFlagsv6 = tcpFlags(cur)
                    r.tcpSeqNumv6 = tcpSeq(cur)
                    r.tcpAckNumv6 = tcpAck(cur)
                    r.tcpWndv6 = tcpWindow(cur)
                    r.tcpPayloadOffv6 = ethHeaderLen + l4Off + doff
                    r.tcpPayloadLenv6 = l4Len - doff
                }
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

    /// Build a TCP segment frame. The caller must have already placed `payloadLen`
    /// payload bytes at `out + ethHeaderLen + ipv4HeaderLen + tcpMinHeaderLen`
    /// (e.g. via TCPConnection.copySegmentPayload). Returns the frame length.
    mutating func buildTCP(toMac: MAC, toIP: IPv4, srcPort: UInt16, dstPort: UInt16,
                           seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16,
                           payloadLen: Int, out: UnsafeMutableRawPointer) -> Int {
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv4)
        let ipp = out + ethHeaderLen
        let seg = ipp + ipv4HeaderLen
        tcpWriteHeader(seg, srcPort: srcPort, dstPort: dstPort, seq: seq, ack: ack,
                       flags: flags, window: window, src: ip, dst: toIP, payloadLen: payloadLen)
        let total = ipv4HeaderLen + tcpMinHeaderLen + payloadLen
        nextIPID &+= 1
        ipWriteHeader(ipp, src: ip, dst: toIP, proto: ipProtoTCP, totalLen: total, id: nextIPID)
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

    // MARK: - IPv6 builders (dual-stack)

    /// Build an IPv6 UDP datagram. Returns total Ethernet frame length.
    mutating func buildUDPv6(toMac: MAC, toIPv6: IPv6, srcPort: UInt16, dstPort: UInt16,
                             payload: UnsafeRawPointer?, payloadLen: Int,
                             out: UnsafeMutableRawPointer) -> Int {
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv6)
        let ip6 = out + ethHeaderLen
        let udp = ip6 + ipv6HeaderLen
        // Write UDP with zero checksum field first, then compute IPv6 pseudo checksum.
        let uLen = udpHeaderLen + payloadLen
        be16set(udp, 0, srcPort)
        be16set(udp, 2, dstPort)
        be16set(udp, 4, UInt16(uLen))
        be16set(udp, 6, 0)
        if let p = payload, payloadLen > 0 {
            var i = 0
            while i < payloadLen { b8set(udp, udpHeaderLen + i, b8(p, i)); i += 1 }
        }
        let cks = ipv6UpperChecksum(src: ipv6, dst: toIPv6, nextHeader: ipProtoUDP,
                                    upper: udp, upperLen: uLen)
        be16set(udp, 6, cks)
        let total = ipv6HeaderLen + uLen
        ip6WriteHeader(ip6, src: ipv6, dst: toIPv6, nextHeader: ipProtoUDP, payloadLen: uLen)
        return ethHeaderLen + total
    }

    /// Build an IPv6 TCP segment. Caller must have placed payload at the right offset.
    mutating func buildTCPv6(toMac: MAC, toIPv6: IPv6, srcPort: UInt16, dstPort: UInt16,
                             seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16,
                             payloadLen: Int, out: UnsafeMutableRawPointer) -> Int {
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv6)
        let ip6 = out + ethHeaderLen
        let seg = ip6 + ipv6HeaderLen
        // Write TCP header (checksum computed inside tcpWriteHeader using IPv4 pseudo — we need v6 version).
        // Use a small inline writer for v6 checksum.
        tcpWriteHeaderV6(seg, srcPort: srcPort, dstPort: dstPort, seq: seq, ack: ack,
                         flags: flags, window: window, src: ipv6, dst: toIPv6, payloadLen: payloadLen)
        let total = ipv6HeaderLen + tcpMinHeaderLen + payloadLen
        ip6WriteHeader(ip6, src: ipv6, dst: toIPv6, nextHeader: ipProtoTCP, payloadLen: tcpMinHeaderLen + payloadLen)
        return ethHeaderLen + total
    }

    /// Build an ICMPv6 Echo Request.
    func buildICMP6EchoRequest(toMac: MAC, toIPv6: IPv6, id: UInt16, seq: UInt16,
                               payloadLen: Int, out: UnsafeMutableRawPointer) -> Int {
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv6)
        let ip6 = out + ethHeaderLen
        let icmp = ip6 + ipv6HeaderLen
        let iLen = icmp6WriteEcho(icmp, type: icmp6TypeEchoRequest, id: id, seq: seq,
                                  payloadLen: payloadLen, src: ipv6, dst: toIPv6)
        ip6WriteHeader(ip6, src: ipv6, dst: toIPv6, nextHeader: ipProtoICMPv6, payloadLen: iLen)
        return ethHeaderLen + ipv6HeaderLen + iLen
    }

    /// Build an ICMPv6 Echo Reply from a received request (copy payload, flip type, recompute cksum).
    private func buildICMP6EchoReply(_ out: UnsafeMutableRawPointer, outCap: Int,
                                     toMac: MAC, toIPv6: IPv6,
                                     req: UnsafeRawPointer, reqLen: Int,
                                     ourSrc: IPv6) -> Int {
        let total = ethHeaderLen + ipv6HeaderLen + reqLen
        if outCap < total { return 0 }
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv6)
        let ip6 = out + ethHeaderLen
        let icmp = ip6 + ipv6HeaderLen
        // Copy the whole received ICMPv6 message then mutate type + checksum.
        var i = 0
        while i < reqLen { b8set(icmp, i, b8(req, i)); i += 1 }
        b8set(icmp, 0, icmp6TypeEchoReply)
        be16set(icmp, 2, 0)
        let ck = ipv6UpperChecksum(src: ourSrc, dst: toIPv6, nextHeader: ipProtoICMPv6,
                                   upper: icmp, upperLen: reqLen)
        be16set(icmp, 2, ck)
        ip6WriteHeader(ip6, src: ourSrc, dst: toIPv6, nextHeader: ipProtoICMPv6, payloadLen: reqLen)
        return total
    }

    /// Build an IPv6 Neighbor Solicitation (used for resolution before sending to a v6 peer).
    func buildNS(target: IPv6, out: UnsafeMutableRawPointer) -> Int {
        // Send to the solicited-node multicast for the target.
        let dstMcast = ipv6SolicitedNodeMulticast(target)
        // For the Ethernet dst we use the well-known solicited-node MAC 33:33:ff:xx:xx:xx
        let ethDst = MAC(0x33, 0x33, 0xff, target.b13, target.b14, target.b15)
        ethWriteHeader(out, dst: ethDst, src: mac, type: ethTypeIPv6)
        let ip6 = out + ethHeaderLen
        // NS is sent with hop-limit 255, dst = solicited-node multicast of target.
        let nsLen = icmp6WriteNS(ip6 + ipv6HeaderLen, target: target, srcLLA: mac,
                                 src: ipv6, dst: dstMcast)
        ip6WriteHeader(ip6, src: ipv6, dst: dstMcast, nextHeader: ipProtoICMPv6, payloadLen: nsLen, hopLimit: 255)
        return ethHeaderLen + ipv6HeaderLen + nsLen
    }

    /// Build a Neighbor Advertisement (usually in reply to NS).
    func buildNA(target: IPv6, toMac: MAC, toIPv6: IPv6, solicited: Bool, out: UnsafeMutableRawPointer) -> Int {
        ethWriteHeader(out, dst: toMac, src: mac, type: ethTypeIPv6)
        let ip6 = out + ethHeaderLen
        let flags: UInt8 = (solicited ? ndpNAFlagSolicited : 0) | ndpNAFlagOverride
        let naLen = icmp6WriteNA(ip6 + ipv6HeaderLen, target: target, tgtLLA: mac,
                                 flags: flags, src: ipv6, dst: toIPv6)
        ip6WriteHeader(ip6, src: ipv6, dst: toIPv6, nextHeader: ipProtoICMPv6, payloadLen: naLen, hopLimit: 255)
        return ethHeaderLen + ipv6HeaderLen + naLen
    }
}

// Small v6 TCP header writer (because the original tcpWriteHeader hardcodes IPv4 pseudo-header).
func tcpWriteHeaderV6(_ p: UnsafeMutableRawPointer, srcPort: UInt16, dstPort: UInt16,
                      seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16,
                      src: IPv6, dst: IPv6, payloadLen: Int) {
    be16set(p, 0, srcPort)
    be16set(p, 2, dstPort)
    be32set(p, 4, seq)
    be32set(p, 8, ack)
    b8set(p, 12, 5 << 4)
    b8set(p, 13, flags)
    be16set(p, 14, window)
    be16set(p, 16, 0)
    be16set(p, 18, 0)
    let segLen = tcpMinHeaderLen + payloadLen
    let ck = ipv6UpperChecksum(src: src, dst: dst, nextHeader: ipProtoTCP, upper: p, upperLen: segLen)
    be16set(p, 16, ck)
}
