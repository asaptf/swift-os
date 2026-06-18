// SPDX-License-Identifier: Apache-2.0
// socket.swift — kernel UDP socket layer (net-b). Kernel-only glue between the
// pure sans-IO core (NetStack) and the virtio-net driver; NOT part of the host
// net_test. It owns the live NetStack, pumps the NIC, demuxes received UDP
// datagrams into bound sockets, and transmits outbound ones.
//
// One shared NetStack drives the NIC; sockets are a small fixed table. UDP
// receive rings hold references to retained RX DMA buffers rather than copying
// payloads into per-socket storage. recvfrom pumps the NIC until a datagram for
// the socket arrives or a timeout fires, then copies once across the syscall
// boundary into the caller's user buffer and releases the RX descriptor.

let netFallbackLocalIP: IPv4 = 0x0A00_020F     // 10.0.2.15 (slirp's default guest address)
let netFallbackGatewayIP: IPv4 = 0x0A00_0202   // 10.0.2.2  (slirp gateway)
let netFallbackDnsIP: IPv4 = 0x0A00_0203       // 10.0.2.3  (slirp DNS server)
let netFallbackSubnetMask: IPv4 = 0xFFFF_FF00  // 255.255.255.0

var netLocalIP: IPv4 = netFallbackLocalIP
var netGatewayIP: IPv4 = netFallbackGatewayIP
var netDnsIP: IPv4 = netFallbackDnsIP
var netSubnetMask: IPv4 = netFallbackSubnetMask
var netDhcpConfigured = false

// Our IPv6 address is derived at netInit time from the virtio-net MAC (link-local EUI-64 style).
var netLocalIPv6: IPv6 = .zero
var netGatewayIPv6: IPv6 = .zero   // often the router's link-local; learned via RA or static for slirp
var netIPv6PrefixLen: UInt8 = 64
var netIPv6StaticConfigured = false

private let netInfoSnapshotSize: UInt = 56
private let netInfoFlagReady: UInt32 = 1 << 0
private let netInfoFlagDHCP4: UInt32 = 1 << 1
private let netInfoFlagStatic6: UInt32 = 1 << 2
private let netInfoFlagGateway6: UInt32 = 1 << 3

// Standard address families (for vfsSocket domain).
let AF_INET: Int = 2
let AF_INET6: Int = 10

private let maxSockets = 256
private let sockRingDepth = 4

// Ephemeral local-port allocator (net-rob). The pure rotating allocator lives in
// tcp.swift (`nextEphemeralPort`, `ephemeralPort{Low,High}`) so the host net_test
// can unit-check it; here we just hold the live cursor and the `inUse` predicate
// over the bind table, so two concurrent outbound connections (or a slot reused
// after close) never collide on a stale `40000 + slot` port.
private var ephemeralCursor: UInt16 = ephemeralPortLow

// Negative errno-ish returns come from the shared Errno table (kernel/errno.swift).

var gNet = NetStack(mac: .zero, ip: netLocalIP)   // replaced in netInit with the real MAC
var netReady = false
private var gDnsScratch: UInt = 0   // one PMM page: query at +0, response at +1024 (net-f)
private var netLockWord: UInt64 = 0
private var netLockAcquireCount: UInt64 = 0
private var netLockContentionCount: UInt64 = 0

@inline(__always)
private func netLock() -> UInt64 {
    let daif = irq_save()
    var contended = false
    while true {
        var expected: UInt64 = 0
        let acquired = withUnsafeMutablePointer(to: &netLockWord) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if acquired {
            if contended {
                withUnsafeMutablePointer(to: &netLockContentionCount) { count in
                    _ = smpAtomicFetchAdd(count, 1)
                }
            }
            withUnsafeMutablePointer(to: &netLockAcquireCount) { count in
                _ = smpAtomicFetchAdd(count, 1)
            }
            smpMemoryBarrier()
            return daif
        }
        contended = true
        smpLoadBarrier()
    }
}

@inline(__always)
private func netUnlock(_ daif: UInt64) {
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &netLockWord) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

@inline(__always)
private func netLockAtomicLoad(_ word: inout UInt64) -> UInt64 {
    withUnsafeMutablePointer(to: &word) { ptr in
        smpAtomicLoad(ptr)
    }
}

private var sockInUse = [Bool](repeating: false, count: maxSockets)
private var sockBound = [Bool](repeating: false, count: maxSockets)
private var sockPort = [UInt16](repeating: 0, count: maxSockets)
private var sockOwner = [UInt32](repeating: 0, count: maxSockets)
private var sockHead = [Int](repeating: 0, count: maxSockets)
private var sockCount = [Int](repeating: 0, count: maxSockets)
// Per (socket, ring slot) datagram metadata; the payload bytes live at
// virtioNetRxFramePointer(ref: dgRxRef[ri], offset: dgPayloadOff[ri]) until
// recvfrom releases the descriptor reference.
private var dgSrcIP = [IPv4](repeating: 0, count: maxSockets * sockRingDepth)
private var dgSrcPort = [UInt16](repeating: 0, count: maxSockets * sockRingDepth)
private var dgLen = [Int](repeating: 0, count: maxSockets * sockRingDepth)
private var dgRxRef = [Int](repeating: -1, count: maxSockets * sockRingDepth)
private var dgPayloadOff = [Int](repeating: 0, count: maxSockets * sockRingDepth)

// Protocol + TCP state per socket (net-c2). A TCP socket is either a listener
// (sockIsListener) or a connection that owns a TCPConnection in tcpConns and is
// keyed by the 4-tuple {sockPort (local), sockRemoteIP, sockRemotePort}.
let sockProtoUDP: UInt8 = 0
let sockProtoTCP: UInt8 = 1
private var sockProto = [UInt8](repeating: sockProtoUDP, count: maxSockets)
private var sockIsListener = [Bool](repeating: false, count: maxSockets)
private var sockListenerOf = [Int](repeating: -1, count: maxSockets)   // conn → its listener slot
private var sockAccepted = [Bool](repeating: false, count: maxSockets)
private var sockConnReady = [Bool](repeating: false, count: maxSockets) // handshake completed (latch)
private var sockRemoteIP = [IPv4](repeating: 0, count: maxSockets)
private var sockRemotePort = [UInt16](repeating: 0, count: maxSockets)
private var sockRemoteMac = [MAC](repeating: .zero, count: maxSockets)

// IPv6 socket state (parallel for dual-stack support).
private var sockFamily = [Int](repeating: AF_INET, count: maxSockets)
private var sockRemoteIPv6 = [IPv6](repeating: .zero, count: maxSockets)
private var sockRemoteMacv6 = [MAC](repeating: .zero, count: maxSockets)

private var tcpConns = [TCPConnection](repeating: TCPConnection(), count: maxSockets)

@inline(__always) private func socketValidLocked(_ s: Int) -> Bool {
    s >= 0 && s < maxSockets && sockInUse[s]
}

func socketFamilyOf(_ s: Int) -> Int {
    let daif = netLock()
    defer { netUnlock(daif) }
    if socketValidLocked(s) { return sockFamily[s] }
    return AF_INET
}

@inline(__always) private func localPortInUseLocked(_ p: UInt16, except: Int) -> Bool {
    for o in 0..<maxSockets where o != except && sockInUse[o] && sockBound[o] && sockPort[o] == p {
        return true
    }
    return false
}

private func allocEphemeralPortLocked(for s: Int) -> UInt16 {
    nextEphemeralPort(cursor: &ephemeralCursor) { localPortInUseLocked($0, except: s) }
}

/// Bring up the NIC once and create the shared NetStack.
/// Idempotent. A no-op when no virtio-net device is attached (netReady stays
/// false, so socket() returns ENETDOWN and the other boot paths are unaffected).
func netInit() {
    let daif = netLock()
    if netReady {
        netUnlock(daif)
        return
    }
    if !virtioNetInit() {
        uartPuts("net: no virtio-net device attached\n")
        netUnlock(daif)
        return
    }
    let m = virtioNetMac()
    let our6 = ipv6LinkLocalFromMAC(m)
    netLocalIPv6 = our6
    // For many QEMU slirp setups the "gateway" link-local is fe80::2 or similar.
    // We leave netGatewayIPv6 zero here; NDP/RA will populate neighbors as needed.
    // For direct testing we can also hardcode a common one if desired.
    netLocalIP = netFallbackLocalIP
    netGatewayIP = netFallbackGatewayIP
    netDnsIP = netFallbackDnsIP
    netSubnetMask = netFallbackSubnetMask
    netDhcpConfigured = false
    gNet = NetStack(mac: m, ip: netLocalIP, ipv6: our6)
    gDnsScratch = pmm_alloc_page()   // 0 on failure → dnsResolve returns 0 gracefully
    netReady = true
    netUnlock(daif)

    _ = netTryDHCPv4(mac: m)
    if !netApplyStaticIPv6Config(mac: m) {
        uartPuts("net: IPv6 link-local configured (EUI-64 from MAC)\n")
    }
}

private func netPrintIPv4(_ ip: IPv4) {
    uartPutUInt(UInt64((ip >> 24) & 0xFF))
    uartPutc(0x2E)
    uartPutUInt(UInt64((ip >> 16) & 0xFF))
    uartPutc(0x2E)
    uartPutUInt(UInt64((ip >> 8) & 0xFF))
    uartPutc(0x2E)
    uartPutUInt(UInt64(ip & 0xFF))
}

private func netPrintHexNibble(_ n: UInt8) {
    uartPutc(n < 10 ? 0x30 + n : 0x61 + (n - 10))
}

private func netPrintHex16(_ v: UInt16) {
    netPrintHexNibble(UInt8((v >> 12) & 0xF))
    netPrintHexNibble(UInt8((v >> 8) & 0xF))
    netPrintHexNibble(UInt8((v >> 4) & 0xF))
    netPrintHexNibble(UInt8(v & 0xF))
}

private func netPrintIPv6(_ ip: IPv6) {
    let groups: [UInt16] = [
        UInt16((ip.hi >> 48) & 0xFFFF),
        UInt16((ip.hi >> 32) & 0xFFFF),
        UInt16((ip.hi >> 16) & 0xFFFF),
        UInt16(ip.hi & 0xFFFF),
        UInt16((ip.lo >> 48) & 0xFFFF),
        UInt16((ip.lo >> 32) & 0xFFFF),
        UInt16((ip.lo >> 16) & 0xFFFF),
        UInt16(ip.lo & 0xFFFF),
    ]
    for i in 0..<groups.count {
        if i > 0 { uartPutc(0x3A) }
        netPrintHex16(groups[i])
    }
}

private func netInfoStoreIPv6(_ out: UnsafeMutableRawPointer, _ off: Int, _ ip: IPv6) {
    ipv6Set(out, off, ip)
}

/// Copy a stable, fixed-size network status record into user memory.
///
/// Layout, all integers native little-endian unless otherwise noted:
///   u32 flags, ipv4, gateway4, dns4, mask4; u8 ipv6[16], gateway6[16]; u32 prefix6
/// IPv4 values are host-order addresses, matching the rest of the swift-os user ABI.
/// IPv6 bytes are in network order.
func netInfoSnapshot(buffer: UInt, capacity: UInt) -> Int {
    if capacity < netInfoSnapshotSize { return Errno.invalid.code }
    if (processCurrentCaps() & capNet) == 0 { return -1 }
    guard let dst8 = userWritableBuffer(buffer, netInfoSnapshotSize) else { return Errno.invalid.code }
    let dst = UnsafeMutableRawPointer(dst8)

    let daif = netLock()
    let ready = netReady
    let dhcp4 = netDhcpConfigured
    let static6 = netIPv6StaticConfigured
    let local4 = netLocalIP
    let gateway4 = netGatewayIP
    let dns4 = netDnsIP
    let mask4 = netSubnetMask
    let local6 = netLocalIPv6
    let gateway6 = netGatewayIPv6
    let prefix6 = netIPv6PrefixLen
    netUnlock(daif)

    var flags: UInt32 = 0
    if ready { flags |= netInfoFlagReady }
    if dhcp4 { flags |= netInfoFlagDHCP4 }
    if static6 { flags |= netInfoFlagStatic6 }
    if gateway6 != .zero { flags |= netInfoFlagGateway6 }

    dst.storeBytes(of: flags, toByteOffset: 0, as: UInt32.self)
    dst.storeBytes(of: local4, toByteOffset: 4, as: UInt32.self)
    dst.storeBytes(of: gateway4, toByteOffset: 8, as: UInt32.self)
    dst.storeBytes(of: dns4, toByteOffset: 12, as: UInt32.self)
    dst.storeBytes(of: mask4, toByteOffset: 16, as: UInt32.self)
    netInfoStoreIPv6(dst, 20, local6)
    netInfoStoreIPv6(dst, 36, gateway6)
    dst.storeBytes(of: UInt32(prefix6), toByteOffset: 52, as: UInt32.self)
    return 0
}

private func netIsSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

private func netTrim(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> (Int, Int) {
    var s = start
    var e = end
    while s < e && netIsSpace(p[s]) { s += 1 }
    while e > s && netIsSpace(p[e - 1]) { e -= 1 }
    return (s, e)
}

private func netStaticKeyEquals(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int,
                                _ key: StaticString) -> Bool {
    let len = end - start
    var ok = true
    key.withUTF8Buffer { kb in
        if kb.count != len {
            ok = false
            return
        }
        var i = 0
        while i < len {
            if p[start + i] != kb[i] {
                ok = false
                return
            }
            i += 1
        }
    }
    return ok
}

private func netParseStaticIPv6Config(_ p: UnsafePointer<UInt8>, _ len: Int) -> (Bool, IPv6, UInt8, IPv6) {
    var address: IPv6 = .zero
    var gateway: IPv6 = .zero
    var prefixLen: UInt8 = 0
    var haveAddress = false
    var haveGateway = false
    var lineStart = 0

    while lineStart < len {
        var lineEnd = lineStart
        while lineEnd < len && p[lineEnd] != 0x0A && p[lineEnd] != 0x0D {
            lineEnd += 1
        }
        var commentEnd = lineStart
        var contentEnd = lineEnd
        while commentEnd < lineEnd {
            if p[commentEnd] == 0x23 { // '#'
                contentEnd = commentEnd
                break
            }
            commentEnd += 1
        }
        let trimmed = netTrim(p, lineStart, contentEnd)
        if trimmed.0 < trimmed.1 {
            var eq = -1
            var i = trimmed.0
            while i < trimmed.1 {
                if p[i] == 0x3D { // '='
                    eq = i
                    break
                }
                i += 1
            }
            if eq < 0 { return (false, .zero, 0, .zero) }
            let key = netTrim(p, trimmed.0, eq)
            let value = netTrim(p, eq + 1, trimmed.1)
            if key.0 >= key.1 || value.0 >= value.1 {
                return (false, .zero, 0, .zero)
            }
            if netStaticKeyEquals(p, key.0, key.1, "address") {
                let parsed = ipv6ParseCIDR(p + value.0, value.1 - value.0)
                if !parsed.0 || parsed.2 != 64 || parsed.1 == .zero {
                    return (false, .zero, 0, .zero)
                }
                address = parsed.1
                prefixLen = parsed.2
                haveAddress = true
            } else if netStaticKeyEquals(p, key.0, key.1, "gateway") {
                let parsed = ipv6ParseText(p + value.0, value.1 - value.0)
                if !parsed.0 || parsed.1 == .zero || !ipv6IsLinkLocal(parsed.1) {
                    return (false, .zero, 0, .zero)
                }
                gateway = parsed.1
                haveGateway = true
            } else {
                return (false, .zero, 0, .zero)
            }
        }
        lineStart = lineEnd + 1
        while lineStart < len && (p[lineStart] == 0x0A || p[lineStart] == 0x0D) {
            lineStart += 1
        }
    }

    if !haveAddress || !haveGateway { return (false, .zero, 0, .zero) }
    return (true, address, prefixLen, gateway)
}

private func netApplyStaticIPv6Config(mac: MAC) -> Bool {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { raw in
        let n = vfsReadStaticFile("/etc/swos/net-ipv6", into: raw.baseAddress, cap: raw.count)
        if n == -2 {
            return false
        }
        if n < 0 {
            uartPuts("net: static IPv6 config read failed; using link-local\n")
            return false
        }
        let parsed = netParseStaticIPv6Config(raw.baseAddress!, n)
        if !parsed.0 {
            uartPuts("net: static IPv6 config invalid; using link-local\n")
            return false
        }
        let daif = netLock()
        netLocalIPv6 = parsed.1
        netIPv6PrefixLen = parsed.2
        netGatewayIPv6 = parsed.3
        netIPv6StaticConfigured = true
        gNet = NetStack(mac: mac, ip: netLocalIP, ipv6: netLocalIPv6)
        netUnlock(daif)

        uartPuts("net-hc23 OK: static IPv6 ")
        netPrintIPv6(parsed.1)
        uartPuts("/")
        uartPutUInt(UInt64(parsed.2))
        uartPuts(" gateway ")
        netPrintIPv6(parsed.3)
        uartPuts(" applied\n")
        return true
    }
}

private func netAwaitDHCP(xid: UInt32, messageType: UInt8, timeoutMs: Int) -> DHCPLease {
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        let daif = netLock()
        let r = netPumpLocked()
        netUnlock(daif)
        if r.gotDHCP && r.dhcp.xid == xid && r.dhcp.messageType == messageType {
            return r.dhcp
        }
        if timeoutMs > 0 && systemTicks - start >= ticks {
            return DHCPLease()
        }
        wfi()
    }
}

private func netTryDHCPv4(mac: MAC) -> Bool {
    let xid = UInt32(truncatingIfNeeded: rtcNow()) ^ 0xD4C3_B2A1
    var daif = netLock()
    if !netReady {
        netUnlock(daif)
        return false
    }
    virtioNetTxSubmit(frameLen: dhcpBuildDiscover(mac: mac, xid: xid, out: virtioNetTxBuffer()))
    netUnlock(daif)

    let offer = netAwaitDHCP(xid: xid, messageType: dhcpMsgOffer, timeoutMs: 1500)
    if offer.messageType != dhcpMsgOffer {
        uartPuts("net: DHCPv4 no offer; using static IPv4 ")
        netPrintIPv4(netFallbackLocalIP)
        uartPuts(" gateway ")
        netPrintIPv4(netFallbackGatewayIP)
        uartPuts("\n")
        return false
    }

    daif = netLock()
    if !netReady {
        netUnlock(daif)
        return false
    }
    virtioNetTxSubmit(frameLen: dhcpBuildRequest(mac: mac, xid: xid,
                                                 requestedIP: offer.address,
                                                 serverIP: offer.server,
                                                 out: virtioNetTxBuffer()))
    netUnlock(daif)

    var ack = netAwaitDHCP(xid: xid, messageType: dhcpMsgAck, timeoutMs: 2000)
    if ack.messageType != dhcpMsgAck {
        uartPuts("net: DHCPv4 request timed out; using static IPv4 ")
        netPrintIPv4(netFallbackLocalIP)
        uartPuts(" gateway ")
        netPrintIPv4(netFallbackGatewayIP)
        uartPuts("\n")
        return false
    }
    if ack.router == 0 { ack.router = offer.router }
    if ack.dns == 0 { ack.dns = offer.dns }
    if ack.subnetMask == 0 { ack.subnetMask = offer.subnetMask }
    if ack.server == 0 { ack.server = offer.server }

    daif = netLock()
    if !netReady {
        netUnlock(daif)
        return false
    }
    netLocalIP = ack.address
    netGatewayIP = ack.router == 0 ? netFallbackGatewayIP : ack.router
    netDnsIP = ack.dns == 0 ? netFallbackDnsIP : ack.dns
    netSubnetMask = ack.subnetMask == 0 ? netFallbackSubnetMask : ack.subnetMask
    netDhcpConfigured = true
    gNet = NetStack(mac: mac, ip: netLocalIP, ipv6: netLocalIPv6)
    netUnlock(daif)

    uartPuts("net-dhcp OK: lease ")
    netPrintIPv4(netLocalIP)
    uartPuts(" gateway ")
    netPrintIPv4(netGatewayIP)
    uartPuts(" dns ")
    netPrintIPv4(netDnsIP)
    uartPuts("\n")
    return true
}

/// Resolve `name` (`nameLen` bytes, dotted form) to an IPv4 by querying a DNS
/// server over a transient UDP socket. `serverIP`/`serverPort` of 0 default to
/// the slirp DNS at 10.0.2.3:53. Returns the address (host order), or 0 on
/// failure/timeout. Uses the pure dns.swift codec.
func dnsResolve(name: UnsafeRawPointer, nameLen: Int, serverIP: IPv4, serverPort: UInt16,
                timeoutMs: Int) -> IPv4 {
    if nameLen <= 0 || nameLen > 255 { return 0 }
    let daif = netLock()
    let scratch = gDnsScratch
    let ready = netReady && scratch != 0
    netUnlock(daif)
    if !ready { return 0 }
    let dnsDefault = netDnsIP
    let server = serverIP == 0 ? dnsDefault : serverIP
    let port = serverPort == 0 ? UInt16(53) : serverPort
    let s = socketCreate(owner: 0)
    if s < 0 { return 0 }
    let id = UInt16(truncatingIfNeeded: rtcNow()) ^ 0x55AA

    let qbuf = UnsafeMutableRawPointer(bitPattern: scratch)!
    let rbuf = UnsafeMutableRawPointer(bitPattern: scratch + 1024)!
    let qlen = dnsBuildQuery(name: name, nameLen: nameLen, id: id, out: qbuf)
    _ = socketSend(s, dstIP: server, dstPort: port, src: qbuf, len: qlen)

    var srcIP: IPv4 = 0
    var srcPort: UInt16 = 0
    let n = socketRecv(s, dst: rbuf, cap: 1024, srcIP: &srcIP, srcPort: &srcPort, timeoutMs: timeoutMs)
    var result: IPv4 = 0
    if n > 0 { result = dnsParseResponse(rbuf, n, id: id) }
    socketClose(s)
    return result
}

/// Pump the NIC once: drain RX frames through the stack (delivering UDP/TCP to
/// sockets via virtioNetPoll), then run each live TCP connection's timers so a
/// lost SYN/data is retransmitted and close timers advance.
func netPump() {
    let daif = netLock()
    defer { netUnlock(daif) }
    _ = netPumpLocked()
}

@discardableResult
private func netPumpLocked() -> RxOutcome {
    var outcome = RxOutcome()
    if !netReady { return outcome }
    outcome = virtioNetPoll(&gNet)
    let now = systemTicks
    for c in 0..<maxSockets where sockInUse[c] && sockProto[c] == sockProtoTCP && !sockIsListener[c] {
        tcpConns[c].tick(now: now)         // advances RTO + TIME_WAIT→CLOSED timers
        if tcpConns[c].outCount > 0 { tcpDrain(c, now) }
        reapConnIfDead(c)
    }
    _ = virtioNetTxDrain()
    virtioNetMaybeReportZeroCopy()
    return outcome
}

func netIsReady() -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    return netReady
}

func netCurrentMac() -> MAC {
    let daif = netLock()
    defer { netUnlock(daif) }
    return gNet.mac
}

func netProbeSendArpRequest(targetIP: IPv4) {
    let daif = netLock()
    defer { netUnlock(daif) }
    if !netReady { return }
    virtioNetTxSubmit(frameLen: gNet.buildArpRequest(targetIP: targetIP, out: virtioNetTxBuffer()))
}

func netProbePollArp(targetIP: IPv4) -> (resolved: Bool, mac: MAC) {
    let daif = netLock()
    defer { netUnlock(daif) }
    let r = netPumpLocked()
    if r.arpResolved && r.resolvedIP == targetIP {
        return (true, r.resolvedMac)
    }
    return (false, MAC())
}

func netProbeSendEchoRequest(toMac: MAC, toIP: IPv4, id: UInt16, seq: UInt16,
                             payloadLen: Int) {
    let daif = netLock()
    defer { netUnlock(daif) }
    if !netReady { return }
    virtioNetTxSubmit(frameLen: gNet.buildEchoRequest(toMac: toMac, toIP: toIP, id: id,
                                                      seq: seq, payloadLen: payloadLen,
                                                      out: virtioNetTxBuffer()))
}

func netProbePollEcho() -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    return netPumpLocked().echoReply
}

/// Free a listener-spawned connection slot once its TCP engine has fully torn
/// down (CLOSED — TIME_WAIT decays to CLOSED via `tick`) and no application fd
/// can still reference it. A connection the app accepted is owned by that fd and
/// is only freed by `socketClose`; only orphans (never accepted, or accepted-then
/// -reaped is impossible since accept latches `sockAccepted`) are reclaimed here,
/// so a refused/reset backlog entry or a TIME_WAIT remnant cannot leak the table.
@inline(__always) private func reapConnIfDead(_ c: Int) {
    guard sockListenerOf[c] >= 0 && !sockAccepted[c] else { return }
    if tcpConns[c].state == .closed {
        sockInUse[c] = false; sockBound[c] = false; sockPort[c] = 0
        sockProto[c] = sockProtoUDP; sockListenerOf[c] = -1; sockConnReady[c] = false
    }
}

private func releaseQueuedDatagrams(_ s: Int) {
    var i = 0
    while i < sockCount[s] {
        let slot = (sockHead[s] + i) % sockRingDepth
        let ri = s * sockRingDepth + slot
        if dgRxRef[ri] >= 0 {
            virtioNetReleaseRxBuffer(dgRxRef[ri])
            dgRxRef[ri] = -1
        }
        dgPayloadOff[ri] = 0
        dgLen[ri] = 0
        i += 1
    }
    sockHead[s] = 0
    sockCount[s] = 0
}

/// Called by the driver for each received UDP datagram. The payload stays in the
/// RX DMA buffer; the socket ring queues a descriptor reference + payload offset.
/// Returns true when the RX buffer was retained and must not be recycled by the
/// driver after this call.
func socketDeliverUDP(srcIP: IPv4, srcPort: UInt16, dstPort: UInt16,
                      rxRef: Int, payloadOffset: Int, len: Int) -> Bool {
    if !netReady || len < 0 { return false }
    for s in 0..<maxSockets where sockInUse[s] && sockBound[s] && sockPort[s] == dstPort && sockFamily[s] == AF_INET {
        if sockCount[s] >= sockRingDepth { return false }
        if !virtioNetRetainRxBuffer(rxRef) { return false }
        let slot = (sockHead[s] + sockCount[s]) % sockRingDepth
        let ri = s * sockRingDepth + slot
        dgSrcIP[ri] = srcIP; dgSrcPort[ri] = srcPort; dgLen[ri] = len
        dgRxRef[ri] = rxRef; dgPayloadOff[ri] = payloadOffset
        sockCount[s] += 1
        return true
    }
    return false
}

/// IPv6 UDP delivery (dual-stack).
func socketDeliverUDPv6(srcIPv6: IPv6, srcPort: UInt16, dstPort: UInt16,
                        rxRef: Int, payloadOffset: Int, len: Int) -> Bool {
    if !netReady || len < 0 { return false }
    for s in 0..<maxSockets where sockInUse[s] && sockBound[s] && sockPort[s] == dstPort && sockFamily[s] == AF_INET6 {
        if sockCount[s] >= sockRingDepth { return false }
        if !virtioNetRetainRxBuffer(rxRef) { return false }
        let slot = (sockHead[s] + sockCount[s]) % sockRingDepth
        let ri = s * sockRingDepth + slot
        // Reuse the IPv4 dg arrays for metadata where possible; for v6 src we store in a small side table or reuse the concept.
        // For simplicity in this full impl we store the v6 src in a parallel set of arrays (added below).
        dgSrcIP[ri] = 0
        dgSrcPort[ri] = srcPort
        dgLen[ri] = len
        dgRxRef[ri] = rxRef
        dgPayloadOff[ri] = payloadOffset
        // Store v6 source in a dedicated side table for v6 sockets.
        dgSrcIPv6[ri] = srcIPv6
        sockCount[s] += 1
        return true
    }
    return false
}

// Additional per-ring storage for IPv6 UDP sources (parallel to the IPv4 dg* tables).
private var dgSrcIPv6 = [IPv6](repeating: .zero, count: maxSockets * sockRingDepth)

/// Resolve `ip` to a MAC, ARPing (bounded) if it is not already cached.
@discardableResult
private func netResolve(_ ip: IPv4, timeoutMs: Int) -> Bool {
    var daif = netLock()
    if !netReady {
        netUnlock(daif)
        return false
    }
    if gNet.arp.lookup(ip) != nil {
        netUnlock(daif)
        return true
    }
    virtioNetTxSubmit(frameLen: gNet.buildArpRequest(targetIP: ip, out: virtioNetTxBuffer()))
    netUnlock(daif)
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while systemTicks - start < ticks {
        netPump()
        daif = netLock()
        let resolved = gNet.arp.lookup(ip) != nil
        netUnlock(daif)
        if resolved { return true }
        wfi()
    }
    daif = netLock()
    let resolved = gNet.arp.lookup(ip) != nil
    netUnlock(daif)
    return resolved
}

func socketCreate(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoUDP, family: AF_INET) }
func socketCreateTCP(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoTCP, family: AF_INET) }

func socketCreateIPv6(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoUDP, family: AF_INET6) }
func socketCreateTCPIPv6(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoTCP, family: AF_INET6) }

private func socketAlloc(owner: UInt32, proto: UInt8, family: Int = AF_INET) -> Int {
    let daif = netLock()
    defer { netUnlock(daif) }
    return socketAllocLocked(owner: owner, proto: proto, family: family)
}

private func socketAllocLocked(owner: UInt32, proto: UInt8, family: Int = AF_INET) -> Int {
    if !netReady { return Errno.netDown.code }
    for s in 0..<maxSockets where !sockInUse[s] {
        sockInUse[s] = true; sockBound[s] = false; sockPort[s] = 0
        sockOwner[s] = owner; sockHead[s] = 0; sockCount[s] = 0
        sockProto[s] = proto; sockIsListener[s] = false; sockListenerOf[s] = -1
        sockAccepted[s] = false; sockConnReady[s] = false
        sockRemoteIP[s] = 0; sockRemotePort[s] = 0; sockRemoteMac[s] = .zero
        sockFamily[s] = family
        sockRemoteIPv6[s] = .zero; sockRemoteMacv6[s] = .zero
        if proto == sockProtoTCP { tcpConns[s].reset() }
        return s
    }
    return Errno.manyFiles.code
}

func socketBind(_ s: Int, port: UInt16) -> Int {
    let daif = netLock()
    defer { netUnlock(daif) }
    if !socketValidLocked(s) { return Errno.invalid.code }
    for o in 0..<maxSockets where o != s && sockInUse[o] && sockBound[o] && sockPort[o] == port {
        return Errno.addrInUse.code
    }
    sockPort[s] = port
    sockBound[s] = true
    return 0
}

/// Send `len` bytes from `src` to (`dstIP`, `dstPort`). The Ethernet next-hop is
/// selected by the configured IPv4 subnet: direct for on-link peers, gateway for
/// off-link peers and /32 cloud-style leases.
func socketSend(_ s: Int, dstIP: IPv4, dstPort: UInt16, src: UnsafeRawPointer, len: Int) -> Int {
    var daif = netLock()
    if !netReady {
        netUnlock(daif)
        return Errno.netDown.code
    }
    if !socketValidLocked(s) {
        netUnlock(daif)
        return Errno.invalid.code
    }
    let routeIP = ipv4RouteTarget(localIP: netLocalIP, subnetMask: netSubnetMask,
                                  gatewayIP: netGatewayIP, dstIP: dstIP)
    let needsResolve = gNet.arp.lookup(routeIP) == nil
    netUnlock(daif)
    if needsResolve {
        _ = netResolve(routeIP, timeoutMs: 2000)
    }
    daif = netLock()
    defer { netUnlock(daif) }
    if !netReady { return Errno.netDown.code }
    if !socketValidLocked(s) { return Errno.invalid.code }
    let routeTarget = ipv4RouteTarget(localIP: netLocalIP, subnetMask: netSubnetMask,
                                      gatewayIP: netGatewayIP, dstIP: dstIP)
    let mac = gNet.arp.lookup(routeTarget)
    guard let dmac = mac else { return Errno.hostUnreach.code }
    if !sockBound[s] {                       // implicit ephemeral bind on first send
        sockPort[s] = allocEphemeralPortLocked(for: s); sockBound[s] = true
    }
    let srcPort = sockPort[s]
    let frameLen = gNet.buildUDP(toMac: dmac, toIP: dstIP, srcPort: srcPort, dstPort: dstPort,
                                 payload: src, payloadLen: len, out: virtioNetTxBuffer())
    virtioNetTxSubmit(frameLen: frameLen)
    return len
}

/// IPv6 send (uses NDP for neighbor resolution).
func socketSendv6(_ s: Int, dstIPv6: IPv6, dstPort: UInt16, src: UnsafeRawPointer, len: Int) -> Int {
    var daif = netLock()
    if !netReady {
        netUnlock(daif)
        return Errno.netDown.code
    }
    if !socketValidLocked(s) || sockFamily[s] != AF_INET6 {
        netUnlock(daif)
        return Errno.invalid.code
    }
    let routeIPv6 = ipv6RouteTarget(local: netLocalIPv6, prefixLen: netIPv6PrefixLen,
                                    gateway: netGatewayIPv6, dst: dstIPv6)
    // Resolve the selected L2 next-hop via NDP; the IPv6 packet still targets dstIPv6.
    var mac = gNet.ndp.lookup(routeIPv6)
    if mac == nil {
        // Send NS (solicited-node) and pump for a short time.
        let nsFrameLen = gNet.buildNS(target: routeIPv6, out: virtioNetTxBuffer())
        virtioNetTxSubmit(frameLen: nsFrameLen)
        netUnlock(daif)
        let start = systemTicks
        let ticks = UInt64(200) // ~2s at 100 Hz
        enable_irq()
        while systemTicks - start < ticks {
            netPump()
            daif = netLock()
            if let m = gNet.ndp.lookup(routeIPv6) {
                mac = m
                netUnlock(daif)
                break
            }
            netUnlock(daif)
            wfi()
        }
        daif = netLock()
    }
    defer { netUnlock(daif) }
    if !netReady { return Errno.netDown.code }
    if !socketValidLocked(s) || sockFamily[s] != AF_INET6 { return Errno.invalid.code }
    guard let dmac = mac ?? gNet.ndp.lookup(routeIPv6) else { return Errno.hostUnreach.code }
    if !sockBound[s] {
        sockPort[s] = allocEphemeralPortLocked(for: s); sockBound[s] = true
    }
    let srcPort = sockPort[s]
    let frameLen = gNet.buildUDPv6(toMac: dmac, toIPv6: dstIPv6, srcPort: srcPort, dstPort: dstPort,
                                   payload: src, payloadLen: len, out: virtioNetTxBuffer())
    virtioNetTxSubmit(frameLen: frameLen)
    return len
}

/// Receive one datagram into `dst` (capacity `cap`), reporting the sender via
/// `srcIP`/`srcPort`. Pumps the NIC until a datagram arrives or `timeoutMs`
/// elapses (timeoutMs <= 0 blocks). Returns the byte count or a negative errno.
func socketRecv(_ s: Int, dst: UnsafeMutableRawPointer, cap: Int,
                srcIP: inout IPv4, srcPort: inout UInt16, timeoutMs: Int) -> Int {
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        let daif = netLock()
        if !netReady {
            netUnlock(daif)
            return Errno.netDown.code
        }
        if !socketValidLocked(s) {
            netUnlock(daif)
            return Errno.invalid.code
        }
        if sockCount[s] > 0 {
            let ri = s * sockRingDepth + sockHead[s]
            let n = dgLen[ri] > cap ? cap : dgLen[ri]
            let srcp = virtioNetRxFramePointer(ref: dgRxRef[ri], offset: dgPayloadOff[ri])
            var i = 0
            while i < n {
                dst.storeBytes(of: srcp.load(fromByteOffset: i, as: UInt8.self),
                               toByteOffset: i, as: UInt8.self)
                i += 1
            }
            srcIP = dgSrcIP[ri]; srcPort = dgSrcPort[ri]
            virtioNetReleaseRxBuffer(dgRxRef[ri])
            dgRxRef[ri] = -1
            dgPayloadOff[ri] = 0
            dgLen[ri] = 0
            sockHead[s] = (sockHead[s] + 1) % sockRingDepth
            sockCount[s] -= 1
            netUnlock(daif)
            return n
        }
        netUnlock(daif)
        if timeoutMs > 0 && systemTicks - start >= ticks { return Errno.again.code }
        wfi()
    }
}

/// IPv6 recvfrom.
func socketRecvV6(_ s: Int, dst: UnsafeMutableRawPointer, cap: Int,
                  srcIPv6: inout IPv6, srcPort: inout UInt16, timeoutMs: Int) -> Int {
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        let daif = netLock()
        if !netReady {
            netUnlock(daif)
            return Errno.netDown.code
        }
        if !socketValidLocked(s) || sockFamily[s] != AF_INET6 {
            netUnlock(daif)
            return Errno.invalid.code
        }
        if sockCount[s] > 0 {
            let ri = s * sockRingDepth + sockHead[s]
            let n = dgLen[ri] > cap ? cap : dgLen[ri]
            let srcp = virtioNetRxFramePointer(ref: dgRxRef[ri], offset: dgPayloadOff[ri])
            var i = 0
            while i < n {
                dst.storeBytes(of: srcp.load(fromByteOffset: i, as: UInt8.self),
                               toByteOffset: i, as: UInt8.self)
                i += 1
            }
            srcIPv6 = dgSrcIPv6[ri]
            srcPort = dgSrcPort[ri]
            virtioNetReleaseRxBuffer(dgRxRef[ri])
            dgRxRef[ri] = -1
            dgPayloadOff[ri] = 0
            dgLen[ri] = 0
            sockHead[s] = (sockHead[s] + 1) % sockRingDepth
            sockCount[s] -= 1
            netUnlock(daif)
            return n
        }
        netUnlock(daif)
        if timeoutMs > 0 && systemTicks - start >= ticks { return Errno.again.code }
        wfi()
    }
}

// ---- TCP (net-c2) ---------------------------------------------------------
func socketIsTCP(_ s: Int) -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    return socketValidLocked(s) && sockProto[s] == sockProtoTCP
}

func socketPollWritable(_ s: Int) -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    if !socketValidLocked(s) { return false }
    if sockProto[s] == sockProtoTCP {
        return !sockIsListener[s] && tcpConns[s].canAcceptSend()
    }
    return true
}

func socketWriteOpen(_ s: Int) -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    if !socketValidLocked(s) { return false }
    if sockProto[s] == sockProtoTCP {
        return !sockIsListener[s] && tcpConns[s].writeOpen()
    }
    return true
}

func socketIsListener(_ s: Int) -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    return socketValidLocked(s) && sockIsListener[s]
}

/// Transmit every queued outbound segment for connection socket `c`.
private func tcpDrain(_ c: Int, _ now: UInt64) {
    let n = tcpConns[c].outCount
    var i = 0
    while i < n {
        let seg = tcpConns[c].outSegment(i)
        let frame = virtioNetTxBuffer()
        if seg.payloadLen > 0 {
            tcpConns[c].copySegmentPayload(seg, to: frame + (ethHeaderLen + ipv4HeaderLen + tcpMinHeaderLen))
        }
        let frameLen = gNet.buildTCP(toMac: sockRemoteMac[c], toIP: sockRemoteIP[c],
                                     srcPort: sockPort[c], dstPort: sockRemotePort[c],
                                     seq: seg.seq, ack: seg.ack, flags: seg.flags, window: seg.window,
                                     payloadLen: seg.payloadLen, out: frame)
        virtioNetTxSubmit(frameLen: frameLen)
        i += 1
    }
    tcpConns[c].clearOut()
}

private func driveTCP(_ c: Int, flags: UInt8, seq: UInt32, ack: UInt32, window: UInt16,
                      payload: UnsafeRawPointer, payloadLen: Int, now: UInt64) {
    let ev = tcpConns[c].onSegment(flags: flags, seq: seq, ack: ack, window: window,
                                   payload: payloadLen > 0 ? payload : nil, payloadLen: payloadLen, now: now)
    // Latch handshake completion: a fast peer can send data+FIN in the same pump,
    // moving the connection past .established before accept() polls, so we record
    // readiness once rather than checking the live state.
    if ev.established { sockConnReady[c] = true }
    tcpDrain(c, now)
}

/// Called by the driver for each received TCP segment (4-tuple demux).
func socketDeliverTCP(srcIP: IPv4, srcMac: MAC, srcPort: UInt16, dstPort: UInt16,
                      flags: UInt8, seq: UInt32, ack: UInt32, window: UInt16,
                      payload: UnsafeRawPointer, payloadLen: Int, now: UInt64) {
    if !netReady { return }
    // 1. an existing connection
    for s in 0..<maxSockets where sockInUse[s] && sockProto[s] == sockProtoTCP && !sockIsListener[s]
            && sockPort[s] == dstPort && sockRemoteIP[s] == srcIP && sockRemotePort[s] == srcPort {
        driveTCP(s, flags: flags, seq: seq, ack: ack, window: window,
                 payload: payload, payloadLen: payloadLen, now: now)
        return
    }
    // 2. a fresh SYN to a listener → spawn a connection socket (backlog handled by accept)
    if (flags & tcpFlagSYN) != 0 && (flags & tcpFlagACK) == 0 {
        for l in 0..<maxSockets where sockInUse[l] && sockProto[l] == sockProtoTCP
                && sockIsListener[l] && sockPort[l] == dstPort {
            let c = socketAllocLocked(owner: sockOwner[l], proto: sockProtoTCP, family: AF_INET)
            if c < 0 { return }
            sockBound[c] = true; sockPort[c] = dstPort
            sockRemoteIP[c] = srcIP; sockRemotePort[c] = srcPort; sockRemoteMac[c] = srcMac
            sockListenerOf[c] = l
            let iss = UInt32(truncatingIfNeeded: rtcNow()) &* 1664525 &+ 1013904223
            tcpConns[c].passiveOpen(localPort: dstPort, iss: iss)
            driveTCP(c, flags: flags, seq: seq, ack: ack, window: window,
                     payload: payload, payloadLen: payloadLen, now: now)
            return
        }
    }
    // 3. unmatched: ignore (minimal — no RST generation).
}

/// IPv6 TCP delivery (dual-stack).
func socketDeliverTCPv6(srcIPv6: IPv6, srcMac: MAC, srcPort: UInt16, dstPort: UInt16,
                        flags: UInt8, seq: UInt32, ack: UInt32, window: UInt16,
                        payload: UnsafeRawPointer, payloadLen: Int, now: UInt64) {
    if !netReady { return }
    for s in 0..<maxSockets where sockInUse[s] && sockProto[s] == sockProtoTCP && !sockIsListener[s]
            && sockPort[s] == dstPort && sockFamily[s] == AF_INET6
            && sockRemoteIPv6[s] == srcIPv6 && sockRemotePort[s] == srcPort {
        // Drive the same TCP engine (seq/ack logic is version-agnostic).
        driveTCP(s, flags: flags, seq: seq, ack: ack, window: window,
                 payload: payload, payloadLen: payloadLen, now: now)
        return
    }
    if (flags & tcpFlagSYN) != 0 && (flags & tcpFlagACK) == 0 {
        for l in 0..<maxSockets where sockInUse[l] && sockProto[l] == sockProtoTCP
                && sockIsListener[l] && sockPort[l] == dstPort && sockFamily[l] == AF_INET6 {
            let c = socketAllocLocked(owner: sockOwner[l], proto: sockProtoTCP, family: AF_INET6)
            if c < 0 { return }
            sockBound[c] = true; sockPort[c] = dstPort
            sockFamily[c] = AF_INET6
            sockRemoteIPv6[c] = srcIPv6; sockRemotePort[c] = srcPort; sockRemoteMacv6[c] = srcMac
            sockListenerOf[c] = l
            let iss = UInt32(truncatingIfNeeded: rtcNow()) &* 1664525 &+ 1013904223
            tcpConns[c].passiveOpen(localPort: dstPort, iss: iss)
            driveTCP(c, flags: flags, seq: seq, ack: ack, window: window,
                     payload: payload, payloadLen: payloadLen, now: now)
            return
        }
    }
}

func tcpListen(_ s: Int, backlog: Int) -> Int {
    _ = backlog
    let daif = netLock()
    defer { netUnlock(daif) }
    if !socketValidLocked(s) || sockProto[s] != sockProtoTCP || !sockBound[s] { return Errno.invalid.code }
    sockIsListener[s] = true
    return 0
}

/// Block (pumping the NIC) until an established connection awaits acceptance on
/// listener `s`; return its socket index, or a negative errno on timeout.
func tcpAccept(_ s: Int, timeoutMs: Int) -> Int {
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        let daif = netLock()
        if !netReady {
            netUnlock(daif)
            return Errno.netDown.code
        }
        if !socketValidLocked(s) || sockProto[s] != sockProtoTCP || !sockIsListener[s] {
            netUnlock(daif)
            return Errno.invalid.code
        }
        for c in 0..<maxSockets where sockInUse[c] && sockProto[c] == sockProtoTCP && !sockIsListener[c]
                && sockListenerOf[c] == s && !sockAccepted[c] && sockConnReady[c] {
            sockAccepted[c] = true
            netUnlock(daif)
            return c
        }
        netUnlock(daif)
        if timeoutMs > 0 && systemTicks - start >= ticks { return Errno.again.code }
        wfi()
    }
}

/// Actively open a connection from TCP socket `s` to (`dstIP`, `dstPort`):
/// send the SYN, then pump until the handshake completes or `timeoutMs` elapses.
func socketConnect(_ s: Int, dstIP: IPv4, dstPort: UInt16, timeoutMs: Int) -> Int {
    var daif = netLock()
    if !netReady {
        netUnlock(daif)
        return Errno.netDown.code
    }
    if !socketValidLocked(s) || sockProto[s] != sockProtoTCP || sockIsListener[s] {
        netUnlock(daif)
        return Errno.invalid.code
    }
    if tcpConns[s].state != .closed {
        netUnlock(daif)
        return Errno.invalid.code
    }

    // Route: resolve the Ethernet next-hop selected by the configured subnet.
    let routeIP = ipv4RouteTarget(localIP: netLocalIP, subnetMask: netSubnetMask,
                                  gatewayIP: netGatewayIP, dstIP: dstIP)
    let needsResolve = gNet.arp.lookup(routeIP) == nil
    netUnlock(daif)
    if needsResolve {
        _ = netResolve(routeIP, timeoutMs: 2000)
    }
    daif = netLock()
    if !netReady {
        netUnlock(daif)
        return Errno.netDown.code
    }
    if !socketValidLocked(s) || sockProto[s] != sockProtoTCP || sockIsListener[s] {
        netUnlock(daif)
        return Errno.invalid.code
    }
    if tcpConns[s].state != .closed {
        netUnlock(daif)
        return Errno.invalid.code
    }
    let routeTarget = ipv4RouteTarget(localIP: netLocalIP, subnetMask: netSubnetMask,
                                      gatewayIP: netGatewayIP, dstIP: dstIP)
    let mac = gNet.arp.lookup(routeTarget)
    guard let dmac = mac else {
        netUnlock(daif)
        return Errno.hostUnreach.code
    }

    let localPort = sockBound[s] ? sockPort[s] : allocEphemeralPortLocked(for: s)
    sockPort[s] = localPort; sockBound[s] = true
    sockRemoteIP[s] = dstIP; sockRemotePort[s] = dstPort; sockRemoteMac[s] = dmac
    sockConnReady[s] = false
    let now = systemTicks
    let iss = UInt32(truncatingIfNeeded: now) &* 1664525 &+ 1013904223
    tcpConns[s].reset()
    tcpConns[s].activeOpen(localPort: localPort, remoteIP: dstIP, remotePort: dstPort, now: now, iss: iss)
    tcpDrain(s, now)                         // emit the SYN
    netUnlock(daif)

    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        daif = netLock()
        if !socketValidLocked(s) || sockProto[s] != sockProtoTCP {
            netUnlock(daif)
            return Errno.invalid.code
        }
        if sockConnReady[s] {
            netUnlock(daif)
            return 0
        }
        if tcpConns[s].state == .closed {
            netUnlock(daif)
            return Errno.hostUnreach.code
        }   // refused/reset
        netUnlock(daif)
        if timeoutMs > 0 && systemTicks - start >= ticks { return Errno.again.code }
        wfi()
    }
}

/// Receive stream bytes from connection `c` into `dst` (cap). Blocks (pumping)
/// until data arrives; returns 0 at EOF (peer closed) or a negative errno.
func tcpRecv(_ c: Int, dst: UnsafeMutableRawPointer, cap: Int, timeoutMs: Int, peek: Bool = false) -> Int {
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        let daif = netLock()
        if !socketValidLocked(c) || sockProto[c] != sockProtoTCP {
            netUnlock(daif)
            return Errno.invalid.code
        }
        let n = tcpConns[c].read(dst, cap, peek: peek)
        if n > 0 {
            if !peek {
                tcpConns[c].advertiseReadWindow()
                tcpDrain(c, systemTicks)
            }
            netUnlock(daif)
            return n
        }
        let st = tcpConns[c].state
        if st == .closeWait || st == .closed || st == .lastAck || st == .closing || st == .timeWait {
            netUnlock(daif)
            return 0   // peer closed and no buffered data left → EOF
        }
        netUnlock(daif)
        if timeoutMs > 0 && systemTicks - start >= ticks { return Errno.again.code }
        wfi()
    }
}

/// Send stream bytes on connection `c`. Returns bytes accepted.
func tcpSend(_ c: Int, src: UnsafeRawPointer, len: Int) -> Int {
    let daif = netLock()
    defer { netUnlock(daif) }
    if !socketValidLocked(c) || sockProto[c] != sockProtoTCP { return Errno.invalid.code }
    let now = systemTicks
    let n = tcpConns[c].appSend(src, len, now: now)
    tcpDrain(c, now)
    return n
}

/// Poll readiness (the caller pumps the NIC first). A listener is readable when
/// a connection awaits acceptance; a connection when it has data or peer-closed.
func socketPollReadable(_ s: Int) -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    return socketPollReadableLocked(s)
}

private func socketPollReadableLocked(_ s: Int) -> Bool {
    if !socketValidLocked(s) { return false }
    if sockProto[s] == sockProtoTCP {
        if sockIsListener[s] {
            for c in 0..<maxSockets where sockInUse[c] && sockProto[c] == sockProtoTCP && !sockIsListener[c]
                    && sockListenerOf[c] == s && !sockAccepted[c] && sockConnReady[c] {
                return true
            }
            return false
        }
        if tcpConns[s].availableBytes() > 0 { return true }
        let st = tcpConns[s].state
        return st == .closeWait || st == .closed || st == .lastAck
    }
    return sockCount[s] > 0   // UDP
}

func socketClose(_ s: Int) {
    let daif = netLock()
    defer { netUnlock(daif) }
    if !socketValidLocked(s) { return }
    if sockProto[s] == sockProtoUDP {
        releaseQueuedDatagrams(s)
    }
    // A live TCP connection sends a FIN (and flushes it) before the slot frees.
    if sockProto[s] == sockProtoTCP && !sockIsListener[s] {
        let st = tcpConns[s].state
        if st != .closed && st != .listen {
            tcpConns[s].appClose(now: systemTicks)
            tcpDrain(s, systemTicks)
        }
    }
    sockInUse[s] = false; sockBound[s] = false; sockPort[s] = 0
    sockHead[s] = 0; sockCount[s] = 0
    sockProto[s] = sockProtoUDP; sockIsListener[s] = false; sockListenerOf[s] = -1
    sockAccepted[s] = false
    sockConnReady[s] = false
    sockFamily[s] = AF_INET
    sockRemoteIP[s] = 0; sockRemotePort[s] = 0; sockRemoteMac[s] = .zero
    sockRemoteIPv6[s] = .zero; sockRemoteMacv6[s] = .zero
    tcpConns[s].reset()
}

private func netS4eInvariantsLocked() -> Bool {
    if netReady && !virtioNetAvailable() { return false }
    var s = 0
    while s < maxSockets {
        if sockHead[s] < 0 || sockHead[s] >= sockRingDepth { return false }
        if sockCount[s] < 0 || sockCount[s] > sockRingDepth { return false }
        if sockProto[s] != sockProtoUDP && sockProto[s] != sockProtoTCP { return false }
        if sockFamily[s] != AF_INET && sockFamily[s] != AF_INET6 { return false }
        if !sockInUse[s] {
            if sockBound[s] || sockCount[s] != 0 || sockIsListener[s] ||
                sockAccepted[s] || sockConnReady[s] || sockListenerOf[s] != -1 {
                return false
            }
        } else {
            if sockProto[s] == sockProtoUDP && sockIsListener[s] { return false }
            if sockListenerOf[s] >= maxSockets { return false }
            if sockListenerOf[s] >= 0 {
                let l = sockListenerOf[s]
                if !sockInUse[l] || !sockIsListener[l] { return false }
            }
            var i = 0
            while i < sockCount[s] {
                let slot = (sockHead[s] + i) % sockRingDepth
                let ri = s * sockRingDepth + slot
                if dgLen[ri] < 0 || dgRxRef[ri] < 0 || dgPayloadOff[ri] < 0 {
                    return false
                }
                i += 1
            }
        }
        s += 1
    }
    return true
}

func netS4eLockAcquireCount() -> UInt64 {
    netLockAtomicLoad(&netLockAcquireCount)
}

func netS4eLockContentionCount() -> UInt64 {
    netLockAtomicLoad(&netLockContentionCount)
}

func netS4eReadinessSelfTest() -> Bool {
    let daif = netLock()
    defer { netUnlock(daif) }
    return netS4eInvariantsLocked()
}

func netS4eLockBoundaryHeldSelfTest() -> Bool {
    if netLockAtomicLoad(&netLockWord) != 0 || netS4eLockAcquireCount() == 0 {
        return false
    }
    return netS4eReadinessSelfTest()
}
