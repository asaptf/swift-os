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

        if failed { exit(1) }
        print("PASS: sans-IO net core (Ethernet/ARP/IPv4/ICMP/UDP/TCP) parses and builds correctly")
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
