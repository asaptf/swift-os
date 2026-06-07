// net_test.swift — host unit test for the sans-IO network core.
//
// Compiled with the host Swift toolchain against the same kernel/net/*.swift the
// kernel uses (they are pure: no MMIO/heap-per-packet/syscalls), then run with
// no arguments. It feeds crafted Ethernet frames into NetStack and asserts the
// parsed result and any reply bytes — proving the protocol logic independent of
// a live network or the virtio-net driver. Mirrors tests/fdt_test.swift.

import Foundation

@main
struct NetTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static let ourMac = MAC(0x52, 0x54, 0x00, 0x12, 0x34, 0x56)
    static let ourIP: IPv4 = 0x0A00_020F   // 10.0.2.15
    static let gwMac = MAC(0x52, 0x55, 0x0A, 0x00, 0x02, 0x02)
    static let gwIP: IPv4 = 0x0A00_0202    // 10.0.2.2

    static func main() {
        let inBuf = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: 16)
        let outBuf = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: 16)
        defer { inBuf.deallocate(); outBuf.deallocate() }

        // --- 1. buildArpRequest -------------------------------------------
        var stack = NetStack(mac: ourMac, ip: ourIP)
        let reqLen = stack.buildArpRequest(targetIP: gwIP, out: outBuf)
        check(reqLen == ethHeaderLen + arpPacketLen, "ARP request length 42, got \(reqLen)")
        check(ethDstMac(outBuf) == .broadcast, "ARP request goes to broadcast")
        check(ethSrcMac(outBuf) == ourMac, "ARP request src is our MAC")
        check(ethType(outBuf) == ethTypeARP, "ARP request ethertype")
        do {
            let a = arpParse(outBuf + ethHeaderLen)
            check(a.oper == arpOpRequest, "oper == request")
            check(a.spa == ourIP, "sender protocol addr is ours")
            check(a.tpa == gwIP, "target protocol addr is the gateway")
            check(a.sha == ourMac, "sender hw addr is ours")
        }

        // --- 2. inbound ARP reply resolves the gateway --------------------
        // Craft as if the gateway answered our request.
        _ = arpBuildFrame(inBuf, op: arpOpReply, srcMac: gwMac, srcIP: gwIP,
                          dstMac: ourMac, dstIP: ourIP, frameDst: ourMac)
        var out = stack.onFrame(inBuf, ethHeaderLen + arpPacketLen, out: outBuf, outCap: 2048)
        check(out.arpResolved, "ARP reply marks the address resolved")
        check(out.resolvedIP == gwIP, "resolved IP is the gateway")
        check(out.resolvedMac == gwMac, "resolved MAC is the gateway's")
        check(out.txLen == 0, "an ARP reply needs no answer")
        check(stack.arp.lookup(gwIP) == gwMac, "gateway is in the ARP cache")

        // --- 3. inbound ARP request for us produces a reply ---------------
        _ = arpBuildFrame(inBuf, op: arpOpRequest, srcMac: gwMac, srcIP: gwIP,
                          dstMac: .zero, dstIP: ourIP, frameDst: .broadcast)
        out = stack.onFrame(inBuf, ethHeaderLen + arpPacketLen, out: outBuf, outCap: 2048)
        check(out.txLen == ethHeaderLen + arpPacketLen, "ARP request gets a 42-byte reply")
        check(ethDstMac(outBuf) == gwMac, "ARP reply unicast back to requester")
        do {
            let a = arpParse(outBuf + ethHeaderLen)
            check(a.oper == arpOpReply, "reply oper == reply")
            check(a.sha == ourMac, "reply advertises our MAC")
            check(a.spa == ourIP, "reply advertises our IP")
            check(a.tpa == gwIP, "reply targets the requester's IP")
        }

        // --- 4. buildEchoRequest has valid IPv4 + ICMP checksums ----------
        let echoLen = stack.buildEchoRequest(toMac: gwMac, toIP: gwIP, id: 0x1234,
                                             seq: 7, payloadLen: 32, out: outBuf)
        check(echoLen == ethHeaderLen + ipv4HeaderLen + icmpHeaderLen + 32,
              "echo request length, got \(echoLen)")
        check(ethType(outBuf) == ethTypeIPv4, "echo request is IPv4")
        do {
            let ip = outBuf + ethHeaderLen
            check(ipValidChecksum(ip), "IPv4 header checksum verifies")
            check(ipProto(ip) == ipProtoICMP, "protocol is ICMP")
            check(ipDst(ip) == gwIP, "destination is the gateway")
            let icmp = ip + ipv4HeaderLen
            check(inetChecksum(icmp, icmpHeaderLen + 32) == 0, "ICMP checksum verifies")
            check(icmpType(icmp) == icmpTypeEchoRequest, "type is echo request")
            check(icmpSeq(icmp) == 7, "sequence preserved")
        }

        // --- 5. inbound ICMP echo reply is recognised ---------------------
        let replyLen = craftEcho(inBuf, type: icmpTypeEchoReply, srcMac: gwMac,
                                 srcIP: gwIP, dstMac: ourMac, dstIP: ourIP,
                                 id: 0x1234, seq: 7, payloadLen: 32)
        out = stack.onFrame(inBuf, replyLen, out: outBuf, outCap: 2048)
        check(out.echoReply, "echo reply recognised")
        check(out.echoSeq == 7, "echo reply sequence")
        check(out.txLen == 0, "an echo reply needs no answer")

        // --- 6. inbound ICMP echo request gets an echo reply --------------
        let rqLen = craftEcho(inBuf, type: icmpTypeEchoRequest, srcMac: gwMac,
                              srcIP: gwIP, dstMac: ourMac, dstIP: ourIP,
                              id: 0xBEEF, seq: 9, payloadLen: 16)
        out = stack.onFrame(inBuf, rqLen, out: outBuf, outCap: 2048)
        check(out.txLen == ethHeaderLen + ipv4HeaderLen + icmpHeaderLen + 16,
              "echo request gets an echo reply, got txLen \(out.txLen)")
        do {
            let ip = outBuf + ethHeaderLen
            check(ipValidChecksum(ip), "reply IPv4 checksum verifies")
            check(ipDst(ip) == gwIP, "reply addressed back to sender IP")
            check(ethDstMac(outBuf) == gwMac, "reply addressed back to sender MAC")
            let icmp = ip + ipv4HeaderLen
            check(inetChecksum(icmp, icmpHeaderLen + 16) == 0, "reply ICMP checksum verifies")
            check(icmpType(icmp) == icmpTypeEchoReply, "reply type is echo reply")
            check(icmpSeq(icmp) == 9, "reply sequence echoes the request")
        }

        // --- 7. malformed frames are rejected without producing output ----
        out = stack.onFrame(inBuf, 6, out: outBuf, outCap: 2048)  // shorter than an Ethernet header
        check(out.txLen == 0 && !out.echoReply && !out.arpResolved, "runt frame ignored")

        // --- 8. a corrupted IPv4 checksum is dropped ----------------------
        _ = craftEcho(inBuf, type: icmpTypeEchoRequest, srcMac: gwMac, srcIP: gwIP,
                      dstMac: ourMac, dstIP: ourIP, id: 1, seq: 1, payloadLen: 8)
        b8set(inBuf, ethHeaderLen + 10, b8(inBuf, ethHeaderLen + 10) ^ 0xFF)  // flip a checksum byte
        out = stack.onFrame(inBuf, ethHeaderLen + ipv4HeaderLen + icmpHeaderLen + 8,
                            out: outBuf, outCap: 2048)
        check(out.txLen == 0, "frame with a bad IPv4 checksum is dropped")

        // --- 9. buildUDP produces a valid IPv4 + UDP datagram -------------
        let payload: [UInt8] = Array("hello-udp".utf8)
        let udpLen = payload.withUnsafeBytes {
            stack.buildUDP(toMac: gwMac, toIP: gwIP, srcPort: 5555, dstPort: 4000,
                           payload: $0.baseAddress, payloadLen: payload.count, out: outBuf)
        }
        check(udpLen == ethHeaderLen + ipv4HeaderLen + udpHeaderLen + payload.count,
              "UDP frame length, got \(udpLen)")
        do {
            let ip = outBuf + ethHeaderLen
            check(ipValidChecksum(ip), "UDP frame IPv4 checksum verifies")
            check(ipProto(ip) == ipProtoUDP, "protocol is UDP")
            let udp = ip + ipv4HeaderLen
            check(udpSrcPort(udp) == 5555 && udpDstPort(udp) == 4000, "UDP ports")
            check(udpChecksumValid(src: ourIP, dst: gwIP, udp: udp,
                                   udpLen: udpHeaderLen + payload.count), "UDP checksum verifies")
        }

        // --- 10. inbound UDP datagram is reported with payload + src ------
        let pl: [UInt8] = Array("swos-udp".utf8)
        let inLen = craftUDP(inBuf, srcMac: gwMac, srcIP: gwIP, dstMac: ourMac, dstIP: ourIP,
                             srcPort: 1234, dstPort: 5555, payload: pl)
        out = stack.onFrame(inBuf, inLen, out: outBuf, outCap: 2048)
        check(out.gotUDP, "UDP datagram recognised")
        check(out.udpSrcIP == gwIP && out.udpSrcPort == 1234, "UDP source addr")
        check(out.udpDstPort == 5555, "UDP destination port")
        check(out.udpSrcMac == gwMac, "UDP source MAC learned for the reply route")
        check(out.udpPayloadLen == pl.count, "UDP payload length, got \(out.udpPayloadLen)")
        check(stack.arp.lookup(gwIP) == gwMac, "inbound IPv4 learns L2 into the ARP cache")
        do {
            var same = true
            for i in 0..<pl.count where b8(inBuf, out.udpPayloadOff + i) != pl[i] { same = false }
            check(same, "UDP payload bytes preserved at the reported offset")
        }

        // --- 11. a corrupted UDP checksum is dropped ----------------------
        _ = craftUDP(inBuf, srcMac: gwMac, srcIP: gwIP, dstMac: ourMac, dstIP: ourIP,
                     srcPort: 1234, dstPort: 5555, payload: pl)
        b8set(inBuf, ethHeaderLen + ipv4HeaderLen + udpHeaderLen,
              b8(inBuf, ethHeaderLen + ipv4HeaderLen + udpHeaderLen) ^ 0xFF)  // flip a payload byte
        out = stack.onFrame(inBuf, inLen, out: outBuf, outCap: 2048)
        check(!out.gotUDP, "UDP datagram with a bad checksum is dropped")

        // --- 12. TCP: sequence arithmetic + checksum ----------------------
        check(seqLT(0xFFFF_FFF0, 0x0000_0010), "seqLT handles wraparound")
        check(seqGT(0x0000_0010, 0xFFFF_FFF0), "seqGT handles wraparound")
        tcpWriteHeader(outBuf, srcPort: 1234, dstPort: 80, seq: 1000, ack: 0,
                       flags: tcpFlagSYN, window: 4096, src: ourIP, dst: gwIP, payloadLen: 0)
        check(tcpChecksumValid(src: ourIP, dst: gwIP, seg: outBuf, segLen: tcpMinHeaderLen),
              "TCP checksum verifies")

        // --- 13. passive open handshake -----------------------------------
        var c = TCPConnection()
        c.passiveOpen(localPort: 5555)
        var e = feed(&c, tcpFlagSYN, 1000, 0)
        check(c.outCount == 1, "SYN gets one reply")
        let s0 = c.outSegment(0)
        check((s0.flags & (tcpFlagSYN | tcpFlagACK)) == (tcpFlagSYN | tcpFlagACK), "reply is SYN|ACK")
        check(s0.ack == 1001, "SYN-ACK acks client ISN+1")
        let iss = s0.seq
        c.clearOut()
        e = feed(&c, tcpFlagACK, 1001, iss &+ 1)
        check(c.state == .established, "ESTABLISHED after the client's ACK")
        check(e.established, "established event fired")
        c.clearOut()

        // --- 14. in-order data receive + cumulative ACK -------------------
        let hello: [UInt8] = Array("hello".utf8)
        e = feed(&c, tcpFlagPSH | tcpFlagACK, 1001, iss &+ 1, hello)
        check(e.dataAvailable, "payload delivered")
        check(c.outCount >= 1 && c.outSegment(c.outCount - 1).ack == 1006, "ACK advanced by 5")
        var rb = [UInt8](repeating: 0, count: 16)
        let rn = rb.withUnsafeMutableBytes { c.read($0.baseAddress!, 16) }
        check(rn == 5, "read 5 delivered bytes")
        var dmatch = true
        for i in 0..<5 where rb[i] != hello[i] { dmatch = false }
        check(dmatch, "delivered bytes match")
        c.clearOut()
        e = feed(&c, tcpFlagACK, 1001, iss &+ 1, hello)   // old/duplicate segment
        check(!e.dataAvailable, "old segment is not re-delivered")
        c.clearOut()

        // --- 15. app send + ACK drains the send buffer --------------------
        let world: [UInt8] = Array("world".utf8)
        let sent = world.withUnsafeBytes { c.appSend($0.baseAddress!, 5, now: 0) }
        check(sent == 5, "appSend accepted 5 bytes")
        check(c.outCount == 1, "one data segment emitted")
        let ds = c.outSegment(0)
        check((ds.flags & tcpFlagPSH) != 0 && ds.seq == iss &+ 1 && ds.payloadLen == 5, "data seg fields")
        var pmatch = true
        for i in 0..<5 where c.segmentPayloadByte(ds, i) != world[i] { pmatch = false }
        check(pmatch, "sent payload matches")
        c.clearOut()
        e = feed(&c, tcpFlagACK, 1006, iss &+ 6)
        c.tick(now: 1000)                                  // well past the RTO
        check(c.outCount == 0, "no retransmit once data is acked")
        c.clearOut()

        // --- 16. RTO retransmit -------------------------------------------
        let xyz: [UInt8] = Array("xyz".utf8)
        _ = xyz.withUnsafeBytes { c.appSend($0.baseAddress!, 3, now: 2000) }
        c.clearOut()
        c.tick(now: 2200)                                  // > rtoTicks (100)
        check(c.outCount == 1, "retransmitted after the RTO fired")
        let rseg = c.outSegment(0)
        check(rseg.payloadLen == 3 && rseg.seq == iss &+ 6, "retransmit from snd.una")
        c.clearOut()
        e = feed(&c, tcpFlagACK, 1006, iss &+ 9)
        c.clearOut()

        // --- 17. passive close (peer FIN, then we close) ------------------
        e = feed(&c, tcpFlagFIN | tcpFlagACK, 1006, iss &+ 9)
        check(e.peerClosed && c.state == .closeWait, "peer FIN → CLOSE_WAIT")
        c.clearOut()
        c.appClose(now: 3000)
        check(c.state == .lastAck && c.outCount == 1 && (c.outSegment(0).flags & tcpFlagFIN) != 0,
              "appClose → FIN, LAST_ACK")
        let myFin = c.outSegment(0)
        c.clearOut()
        e = feed(&c, tcpFlagACK, 1007, myFin.seq &+ 1)
        check(c.state == .closed && e.closed, "CLOSED after our FIN is acked")

        // --- 18. active open + active close -------------------------------
        var a = TCPConnection()
        a.activeOpen(localPort: 40000, remoteIP: gwIP, remotePort: 80, now: 0)
        check(a.outCount == 1 && (a.outSegment(0).flags & tcpFlagSYN) != 0, "active open emits SYN")
        let aiss = a.outSegment(0).seq
        a.clearOut()
        e = feed(&a, tcpFlagSYN | tcpFlagACK, 5000, aiss &+ 1)
        check(a.state == .established && e.established, "active open reaches ESTABLISHED")
        a.clearOut()
        a.appClose(now: 10)
        check(a.state == .finWait1, "active close → FIN_WAIT_1")
        let aFin = a.outSegment(0)
        a.clearOut()
        e = feed(&a, tcpFlagACK, 5001, aFin.seq &+ 1)
        check(a.state == .finWait2, "FIN_WAIT_2 once our FIN is acked")
        a.clearOut()
        e = feed(&a, tcpFlagFIN | tcpFlagACK, 5001, aFin.seq &+ 1)
        check(a.state == .timeWait, "TIME_WAIT after the peer's FIN")

        // --- 19. RST tears the connection down ----------------------------
        var r = TCPConnection()
        r.passiveOpen(localPort: 5555)
        _ = feed(&r, tcpFlagSYN, 100, 0)
        let riss = r.outSegment(0).seq
        r.clearOut()
        _ = feed(&r, tcpFlagACK, 101, riss &+ 1)
        r.clearOut()
        e = feed(&r, tcpFlagRST, 101, 0)
        check(e.reset && r.state == .closed, "RST → reset event + CLOSED")

        // --- 19b. RST from ESTABLISHED → reset + closed (net-rob) ---------
        do {
            var x = TCPConnection()
            x.activeOpen(localPort: 50000, remoteIP: gwIP, remotePort: 80, now: 0)
            let xiss = x.outSegment(0).seq
            x.clearOut()
            _ = feed(&x, tcpFlagSYN | tcpFlagACK, 7000, xiss &+ 1)
            check(x.state == .established, "RST case reaches ESTABLISHED")
            x.clearOut()
            let rev = feed(&x, tcpFlagRST | tcpFlagACK, 7001, xiss &+ 1)
            check(rev.reset && rev.closed && x.state == .closed, "RST from ESTABLISHED → reset+closed+CLOSED")
            check(x.outCount == 0, "RST drops any queued output (no reply)")
        }

        // --- 19c. RST from FIN_WAIT_1 and FIN_WAIT_2 → closed (net-rob) ---
        do {
            // FIN_WAIT_1: we sent a FIN, not yet acked, then peer RSTs.
            var x = TCPConnection()
            x.activeOpen(localPort: 50001, remoteIP: gwIP, remotePort: 80, now: 0)
            let xiss = x.outSegment(0).seq
            x.clearOut()
            _ = feed(&x, tcpFlagSYN | tcpFlagACK, 8000, xiss &+ 1)
            x.clearOut()
            x.appClose(now: 0)
            check(x.state == .finWait1, "RST case reaches FIN_WAIT_1")
            x.clearOut()
            let rev1 = feed(&x, tcpFlagRST, 8001, 0)
            check(rev1.reset && x.state == .closed, "RST from FIN_WAIT_1 → CLOSED")

            // FIN_WAIT_2: our FIN is acked first, then peer RSTs.
            var y = TCPConnection()
            y.activeOpen(localPort: 50002, remoteIP: gwIP, remotePort: 80, now: 0)
            let yiss = y.outSegment(0).seq
            y.clearOut()
            _ = feed(&y, tcpFlagSYN | tcpFlagACK, 9000, yiss &+ 1)
            y.clearOut()
            y.appClose(now: 0)
            let yFin = y.outSegment(0)
            y.clearOut()
            _ = feed(&y, tcpFlagACK, 9001, yFin.seq &+ 1)
            check(y.state == .finWait2, "RST case reaches FIN_WAIT_2")
            let rev2 = feed(&y, tcpFlagRST, 9001, 0)
            check(rev2.reset && y.state == .closed, "RST from FIN_WAIT_2 → CLOSED")
        }

        // --- 19d. full active+passive close reaches TIME_WAIT→CLOSED ------
        do {
            var x = TCPConnection()
            x.activeOpen(localPort: 50003, remoteIP: gwIP, remotePort: 80, now: 0)
            let xiss = x.outSegment(0).seq
            x.clearOut()
            _ = feed(&x, tcpFlagSYN | tcpFlagACK, 11000, xiss &+ 1)
            x.clearOut()
            x.appClose(now: 100)                       // active close → FIN_WAIT_1
            let xFin = x.outSegment(0)
            x.clearOut()
            // Peer acks our FIN, then sends its own FIN (typical active+passive).
            _ = feed(&x, tcpFlagACK, 11001, xFin.seq &+ 1)
            check(x.state == .finWait2, "active close: FIN_WAIT_2 after our FIN acked")
            let cev = feed(&x, tcpFlagFIN | tcpFlagACK, 11001, xFin.seq &+ 1, now: 100)
            check(cev.peerClosed && x.state == .timeWait, "peer FIN → TIME_WAIT")
            x.tick(now: 100)
            check(x.state == .timeWait, "TIME_WAIT holds before the timer expires")
            x.tick(now: 100 + 50 /* tcpTimeWaitTicks */)
            check(x.state == .closed, "TIME_WAIT → CLOSED after the 2MSL timer")
        }

        // --- 19e. simultaneous close (FIN before ACK-of-FIN) → CLOSING ----
        do {
            var x = TCPConnection()
            x.activeOpen(localPort: 50004, remoteIP: gwIP, remotePort: 80, now: 0)
            let xiss = x.outSegment(0).seq
            x.clearOut()
            _ = feed(&x, tcpFlagSYN | tcpFlagACK, 12000, xiss &+ 1)
            x.clearOut()
            x.appClose(now: 0)                         // FIN_WAIT_1, our FIN unacked
            let xFin = x.outSegment(0)
            x.clearOut()
            // Peer's FIN arrives WITHOUT acking our FIN (ack still = our FIN seq).
            let sev = feed(&x, tcpFlagFIN | tcpFlagACK, 12001, xFin.seq)
            check(sev.peerClosed && x.state == .closing, "simultaneous close → CLOSING")
            // Now the peer acks our FIN → TIME_WAIT.
            _ = feed(&x, tcpFlagACK, 12002, xFin.seq &+ 1, now: 0)
            check(x.state == .timeWait, "CLOSING → TIME_WAIT once our FIN is acked")
        }

        // --- 19f. ephemeral-port allocator: rotates + skips in-use --------
        do {
            var cursor: UInt16 = ephemeralPortLow
            let p0 = nextEphemeralPort(cursor: &cursor) { _ in false }
            let p1 = nextEphemeralPort(cursor: &cursor) { _ in false }
            check(p0 == ephemeralPortLow && p1 == ephemeralPortLow + 1, "allocator rotates upward")
            // Skip a busy port: low+2 is taken, so the next free is low+3.
            cursor = ephemeralPortLow + 2
            let p2 = nextEphemeralPort(cursor: &cursor) { $0 == ephemeralPortLow + 2 }
            check(p2 == ephemeralPortLow + 3, "allocator skips an in-use port")
            // Wrap at the top of the range back to the low edge.
            cursor = ephemeralPortHigh
            let pHi = nextEphemeralPort(cursor: &cursor) { _ in false }
            let pWrap = nextEphemeralPort(cursor: &cursor) { _ in false }
            check(pHi == ephemeralPortHigh && pWrap == ephemeralPortLow, "allocator wraps at the range top")
        }

        // --- 20. DNS query build ------------------------------------------
        let qname: [UInt8] = Array("a.bc".utf8)
        let qlen = qname.withUnsafeBytes {
            dnsBuildQuery(name: $0.baseAddress!, nameLen: $0.count, id: 0xABCD, out: outBuf)
        }
        check(qlen == 22, "DNS query length, got \(qlen)")
        check(be16(outBuf, 0) == 0xABCD, "DNS query id")
        check(be16(outBuf, 2) == 0x0100, "DNS recursion-desired flag")
        check(be16(outBuf, 4) == 1, "DNS qdcount 1")
        check(b8(outBuf, 12) == 1 && b8(outBuf, 13) == 0x61 && b8(outBuf, 14) == 2 &&
              b8(outBuf, 15) == 0x62 && b8(outBuf, 16) == 0x63 && b8(outBuf, 17) == 0,
              "DNS QNAME label encoding (1 'a' 2 'b' 'c' 0)")
        check(be16(outBuf, 18) == dnsTypeA && be16(outBuf, 20) == dnsClassIN, "DNS QTYPE A / QCLASS IN")

        // --- 21. DNS response parse (A via a compression pointer) ---------
        func craftDNSHeader(_ id: UInt16, flags: UInt16, an: UInt16) {
            be16set(inBuf, 0, id); be16set(inBuf, 2, flags)
            be16set(inBuf, 4, 1); be16set(inBuf, 6, an)
            be16set(inBuf, 8, 0); be16set(inBuf, 10, 0)
            // question at offset 12: "a.bc" A IN
            var o = 12
            b8set(inBuf, o, 1); o += 1; b8set(inBuf, o, 0x61); o += 1
            b8set(inBuf, o, 2); o += 1; b8set(inBuf, o, 0x62); o += 1; b8set(inBuf, o, 0x63); o += 1
            b8set(inBuf, o, 0); o += 1
            be16set(inBuf, o, dnsTypeA); o += 2; be16set(inBuf, o, dnsClassIN)
        }
        let qend = 12 + 6 + 4   // header + qname(6) + qtype/qclass(4) = 22
        craftDNSHeader(0x1234, flags: 0x8180, an: 1)
        var o = qend
        be16set(inBuf, o, 0xC00C); o += 2          // name = pointer to offset 12
        be16set(inBuf, o, dnsTypeA); o += 2
        be16set(inBuf, o, dnsClassIN); o += 2
        be32set(inBuf, o, 300); o += 4             // TTL
        be16set(inBuf, o, 4); o += 2               // RDLENGTH
        be32set(inBuf, o, 0xC000_0207); o += 4     // 192.0.2.7
        check(dnsParseResponse(inBuf, o, id: 0x1234) == 0xC000_0207, "DNS parsed A record (192.0.2.7)")
        check(dnsParseResponse(inBuf, o, id: 0x9999) == 0, "DNS wrong id rejected")

        // --- 22. NXDOMAIN / no-answer → 0 ---------------------------------
        craftDNSHeader(0x1234, flags: 0x8183, an: 0)   // rcode 3, no answers
        check(dnsParseResponse(inBuf, qend, id: 0x1234) == 0, "DNS NXDOMAIN → 0")

        // --- 23. CNAME then A: skip the CNAME, return the A ---------------
        craftDNSHeader(0x1234, flags: 0x8180, an: 2)
        o = qend
        be16set(inBuf, o, 0xC00C); o += 2          // answer 1 name → pointer
        be16set(inBuf, o, 5); o += 2               // TYPE CNAME
        be16set(inBuf, o, dnsClassIN); o += 2
        be32set(inBuf, o, 300); o += 4
        be16set(inBuf, o, 2); o += 2               // RDLENGTH 2
        be16set(inBuf, o, 0xC00C); o += 2          // RDATA = a (compressed) name
        be16set(inBuf, o, 0xC00C); o += 2          // answer 2 name → pointer
        be16set(inBuf, o, dnsTypeA); o += 2
        be16set(inBuf, o, dnsClassIN); o += 2
        be32set(inBuf, o, 300); o += 4
        be16set(inBuf, o, 4); o += 2
        be32set(inBuf, o, 0x08080808); o += 4      // 8.8.8.8
        check(dnsParseResponse(inBuf, o, id: 0x1234) == 0x0808_0808, "DNS CNAME-then-A returns the A record")

        if failed { exit(1) }
        print("PASS: sans-IO net core (Ethernet/ARP/IPv4/ICMP/UDP/TCP/DNS) parses and builds correctly")
    }

    /// Feed one TCP segment into a connection (optional payload).
    static func feed(_ c: inout TCPConnection, _ flags: UInt8, _ seq: UInt32, _ ack: UInt32,
                     _ payload: [UInt8] = [], window: UInt16 = 4096, now: UInt64 = 0) -> TCPEvent {
        if payload.isEmpty {
            return c.onSegment(flags: flags, seq: seq, ack: ack, window: window,
                               payload: nil, payloadLen: 0, now: now)
        }
        return payload.withUnsafeBytes {
            c.onSegment(flags: flags, seq: seq, ack: ack, window: window,
                        payload: $0.baseAddress, payloadLen: payload.count, now: now)
        }
    }

    /// Build a full UDP frame (Ethernet + IPv4 + UDP) into `p`.
    static func craftUDP(_ p: UnsafeMutableRawPointer, srcMac: MAC, srcIP: IPv4,
                         dstMac: MAC, dstIP: IPv4, srcPort: UInt16, dstPort: UInt16,
                         payload: [UInt8]) -> Int {
        ethWriteHeader(p, dst: dstMac, src: srcMac, type: ethTypeIPv4)
        let ip = p + ethHeaderLen
        let udp = ip + ipv4HeaderLen
        let ulen = payload.withUnsafeBytes {
            udpWrite(udp, src: srcIP, dst: dstIP, srcPort: srcPort, dstPort: dstPort,
                     payload: $0.baseAddress, payloadLen: payload.count)
        }
        let total = ipv4HeaderLen + ulen
        ipWriteHeader(ip, src: srcIP, dst: dstIP, proto: ipProtoUDP, totalLen: total, id: 99)
        return ethHeaderLen + total
    }

    /// Build a full ICMP echo frame (Ethernet + IPv4 + ICMP) into `p`.
    static func craftEcho(_ p: UnsafeMutableRawPointer, type: UInt8,
                          srcMac: MAC, srcIP: IPv4, dstMac: MAC, dstIP: IPv4,
                          id: UInt16, seq: UInt16, payloadLen: Int) -> Int {
        ethWriteHeader(p, dst: dstMac, src: srcMac, type: ethTypeIPv4)
        let ip = p + ethHeaderLen
        let icmp = ip + ipv4HeaderLen
        let icmpLen = icmpWriteEcho(icmp, type: type, id: id, seq: seq, payloadLen: payloadLen)
        let total = ipv4HeaderLen + icmpLen
        ipWriteHeader(ip, src: srcIP, dst: dstIP, proto: ipProtoICMP, totalLen: total, id: id)
        return ethHeaderLen + total
    }
}
