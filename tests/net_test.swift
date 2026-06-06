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

        if failed { exit(1) }
        print("PASS: sans-IO net core (Ethernet/ARP/IPv4/ICMP) parses and builds correctly")
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
