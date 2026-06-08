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

let netLocalIP: IPv4 = 0x0A00_020F     // 10.0.2.15 (slirp's default guest address)
let netGatewayIP: IPv4 = 0x0A00_0202   // 10.0.2.2  (slirp gateway)
let netDnsIP: IPv4 = 0x0A00_0203       // 10.0.2.3  (slirp DNS server)

// Our IPv6 address is derived at netInit time from the virtio-net MAC (link-local EUI-64 style).
var netLocalIPv6: IPv6 = .zero
var netGatewayIPv6: IPv6 = .zero   // often the router's link-local; learned via RA or static for slirp

// Standard address families (for vfsSocket domain).
let AF_INET: Int = 2
let AF_INET6: Int = 10

private let maxSockets = 32
private let sockRingDepth = 4

// Ephemeral local-port allocator (net-rob). The pure rotating allocator lives in
// tcp.swift (`nextEphemeralPort`, `ephemeralPort{Low,High}`) so the host net_test
// can unit-check it; here we just hold the live cursor and the `inUse` predicate
// over the bind table, so two concurrent outbound connections (or a slot reused
// after close) never collide on a stale `40000 + slot` port.
private var ephemeralCursor: UInt16 = ephemeralPortLow

// Negative errno-ish returns shared with the syscall layer.
let netErrDown = -100      // ENETDOWN: no NIC
let netErrUnreach = -101   // EHOSTUNREACH: no route/MAC
let netErrMany = -24       // EMFILE
let netErrInval = -22      // EINVAL
let netErrInUse = -98      // EADDRINUSE
let netErrAgain = -11      // EAGAIN / timed out

var gNet = NetStack(mac: .zero, ip: netLocalIP)   // replaced in netInit with the real MAC
var netReady = false
private var gDnsScratch: UInt = 0   // one PMM page: query at +0, response at +1024 (net-f)

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

@inline(__always) private func socketValid(_ s: Int) -> Bool {
    s >= 0 && s < maxSockets && sockInUse[s]
}

func socketFamilyOf(_ s: Int) -> Int {
    if socketValid(s) { return sockFamily[s] }
    return AF_INET
}

/// True if any bound socket other than `except` already holds local port `p`.
@inline(__always) private func localPortInUse(_ p: UInt16, except: Int) -> Bool {
    for o in 0..<maxSockets where o != except && sockInUse[o] && sockBound[o] && sockPort[o] == p {
        return true
    }
    return false
}

/// Allocate a free ephemeral local port for socket `s` from the rotating
/// allocator, skipping ports another socket already uses.
private func allocEphemeralPort(for s: Int) -> UInt16 {
    nextEphemeralPort(cursor: &ephemeralCursor) { localPortInUse($0, except: s) }
}

/// Bring up the NIC once and create the shared NetStack.
/// Idempotent. A no-op when no virtio-net device is attached (netReady stays
/// false, so socket() returns ENETDOWN and the other boot paths are unaffected).
func netInit() {
    if netReady { return }
    if !virtioNetInit() {
        uartPuts("net: no virtio-net device attached\n")
        return
    }
    let m = virtioNetMac()
    let our6 = ipv6LinkLocalFromMAC(m)
    netLocalIPv6 = our6
    // For many QEMU slirp setups the "gateway" link-local is fe80::2 or similar.
    // We leave netGatewayIPv6 zero here; NDP/RA will populate neighbors as needed.
    // For direct testing we can also hardcode a common one if desired.
    gNet = NetStack(mac: m, ip: netLocalIP, ipv6: our6)
    gDnsScratch = pmm_alloc_page()   // 0 on failure → dnsResolve returns 0 gracefully
    netReady = true
    uartPuts("net: IPv6 link-local configured (EUI-64 from MAC)\n")
}

/// Resolve `name` (`nameLen` bytes, dotted form) to an IPv4 by querying a DNS
/// server over a transient UDP socket. `serverIP`/`serverPort` of 0 default to
/// the slirp DNS at 10.0.2.3:53. Returns the address (host order), or 0 on
/// failure/timeout. Uses the pure dns.swift codec.
func dnsResolve(name: UnsafeRawPointer, nameLen: Int, serverIP: IPv4, serverPort: UInt16,
                timeoutMs: Int) -> IPv4 {
    if !netReady || gDnsScratch == 0 || nameLen <= 0 || nameLen > 255 { return 0 }
    let server = serverIP == 0 ? netDnsIP : serverIP
    let port = serverPort == 0 ? UInt16(53) : serverPort
    let s = socketCreate(owner: 0)
    if s < 0 { return 0 }
    _ = socketBind(s, port: allocEphemeralPort(for: s))
    let id = UInt16(truncatingIfNeeded: rtcNow()) ^ 0x55AA

    let qbuf = UnsafeMutableRawPointer(bitPattern: gDnsScratch)!
    let rbuf = UnsafeMutableRawPointer(bitPattern: gDnsScratch + 1024)!
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
    if !netReady { return }
    _ = virtioNetPoll(&gNet)
    let now = systemTicks
    for c in 0..<maxSockets where sockInUse[c] && sockProto[c] == sockProtoTCP && !sockIsListener[c] {
        tcpConns[c].tick(now: now)         // advances RTO + TIME_WAIT→CLOSED timers
        if tcpConns[c].outCount > 0 { tcpDrain(c, now) }
        reapConnIfDead(c)
    }
    _ = virtioNetTxDrain()
    virtioNetMaybeReportZeroCopy()
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
    if gNet.arp.lookup(ip) != nil { return true }
    virtioNetTxSubmit(frameLen: gNet.buildArpRequest(targetIP: ip, out: virtioNetTxBuffer()))
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while systemTicks - start < ticks {
        netPump()
        if gNet.arp.lookup(ip) != nil { return true }
        wfi()
    }
    return gNet.arp.lookup(ip) != nil
}

func socketCreate(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoUDP, family: AF_INET) }
func socketCreateTCP(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoTCP, family: AF_INET) }

func socketCreateIPv6(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoUDP, family: AF_INET6) }
func socketCreateTCPIPv6(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoTCP, family: AF_INET6) }

private func socketAlloc(owner: UInt32, proto: UInt8, family: Int = AF_INET) -> Int {
    if !netReady { return netErrDown }
    for s in 0..<maxSockets where !sockInUse[s] {
        sockInUse[s] = true; sockBound[s] = false; sockPort[s] = 0
        sockOwner[s] = owner; sockHead[s] = 0; sockCount[s] = 0
        sockProto[s] = proto; sockIsListener[s] = false; sockListenerOf[s] = -1
        sockAccepted[s] = false; sockConnReady[s] = false
        sockRemoteIP[s] = 0; sockRemotePort[s] = 0; sockRemoteMac[s] = .zero
        sockFamily[s] = family
        sockRemoteIPv6[s] = .zero; sockRemoteMacv6[s] = .zero
        if proto == sockProtoTCP { tcpConns[s] = TCPConnection() }
        return s
    }
    return netErrMany
}

func socketBind(_ s: Int, port: UInt16) -> Int {
    if !socketValid(s) { return netErrInval }
    for o in 0..<maxSockets where o != s && sockInUse[o] && sockBound[o] && sockPort[o] == port {
        return netErrInUse
    }
    sockPort[s] = port
    sockBound[s] = true
    return 0
}

/// Send `len` bytes from `src` to (`dstIP`, `dstPort`). Routes via the cached
/// MAC for the destination, else via the slirp gateway.
func socketSend(_ s: Int, dstIP: IPv4, dstPort: UInt16, src: UnsafeRawPointer, len: Int) -> Int {
    if !netReady { return netErrDown }
    if !socketValid(s) { return netErrInval }
    var mac = gNet.arp.lookup(dstIP) ?? gNet.arp.lookup(netGatewayIP)
    if mac == nil {
        _ = netResolve(netGatewayIP, timeoutMs: 2000)
        mac = gNet.arp.lookup(dstIP) ?? gNet.arp.lookup(netGatewayIP)
    }
    guard let dmac = mac else { return netErrUnreach }
    if !sockBound[s] {                       // implicit ephemeral bind on first send
        sockPort[s] = allocEphemeralPort(for: s); sockBound[s] = true
    }
    let srcPort = sockPort[s]
    let frameLen = gNet.buildUDP(toMac: dmac, toIP: dstIP, srcPort: srcPort, dstPort: dstPort,
                                 payload: src, payloadLen: len, out: virtioNetTxBuffer())
    virtioNetTxSubmit(frameLen: frameLen)
    return len
}

/// IPv6 send (uses NDP for neighbor resolution).
func socketSendv6(_ s: Int, dstIPv6: IPv6, dstPort: UInt16, src: UnsafeRawPointer, len: Int) -> Int {
    if !netReady { return netErrDown }
    if !socketValid(s) || sockFamily[s] != AF_INET6 { return netErrInval }
    // Resolve via NDP cache; if missing, send NS and wait a bit.
    var mac = gNet.ndp.lookup(dstIPv6)
    if mac == nil {
        // Send NS (solicited-node) and pump for a short time.
        let nsFrameLen = gNet.buildNS(target: dstIPv6, out: virtioNetTxBuffer())
        virtioNetTxSubmit(frameLen: nsFrameLen)
        let start = systemTicks
        let ticks = UInt64(200) // ~2s at 100 Hz
        enable_irq()
        while systemTicks - start < ticks {
            netPump()
            if let m = gNet.ndp.lookup(dstIPv6) { mac = m; break }
            wfi()
        }
    }
    guard let dmac = mac ?? gNet.ndp.lookup(dstIPv6) else { return netErrUnreach }
    if !sockBound[s] {
        sockPort[s] = allocEphemeralPort(for: s); sockBound[s] = true
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
    if !netReady { return netErrDown }
    if !socketValid(s) { return netErrInval }
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
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
            return n
        }
        if timeoutMs > 0 && systemTicks - start >= ticks { return netErrAgain }
        wfi()
    }
}

/// IPv6 recvfrom.
func socketRecvV6(_ s: Int, dst: UnsafeMutableRawPointer, cap: Int,
                  srcIPv6: inout IPv6, srcPort: inout UInt16, timeoutMs: Int) -> Int {
    if !netReady { return netErrDown }
    if !socketValid(s) || sockFamily[s] != AF_INET6 { return netErrInval }
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
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
            return n
        }
        if timeoutMs > 0 && systemTicks - start >= ticks { return netErrAgain }
        wfi()
    }
}

// ---- TCP (net-c2) ---------------------------------------------------------
func socketIsTCP(_ s: Int) -> Bool { socketValid(s) && sockProto[s] == sockProtoTCP }
func socketIsListener(_ s: Int) -> Bool { socketValid(s) && sockIsListener[s] }

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
            let c = socketCreateTCP(owner: sockOwner[l])
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
            let c = socketCreateTCP(owner: sockOwner[l])
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
    if !socketIsTCP(s) || !sockBound[s] { return netErrInval }
    sockIsListener[s] = true
    return 0
}

/// Block (pumping the NIC) until an established connection awaits acceptance on
/// listener `s`; return its socket index, or a negative errno on timeout.
func tcpAccept(_ s: Int, timeoutMs: Int) -> Int {
    if !netReady { return netErrDown }
    if !socketIsTCP(s) || !sockIsListener[s] { return netErrInval }
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        for c in 0..<maxSockets where sockInUse[c] && sockProto[c] == sockProtoTCP && !sockIsListener[c]
                && sockListenerOf[c] == s && !sockAccepted[c] && sockConnReady[c] {
            sockAccepted[c] = true
            return c
        }
        if timeoutMs > 0 && systemTicks - start >= ticks { return netErrAgain }
        wfi()
    }
}

/// Actively open a connection from TCP socket `s` to (`dstIP`, `dstPort`):
/// send the SYN, then pump until the handshake completes or `timeoutMs` elapses.
func socketConnect(_ s: Int, dstIP: IPv4, dstPort: UInt16, timeoutMs: Int) -> Int {
    if !netReady { return netErrDown }
    if !socketIsTCP(s) || sockIsListener[s] { return netErrInval }
    if tcpConns[s].state != .closed { return netErrInval }   // already open/opening

    // Route: resolve the destination MAC (direct, else via the slirp gateway).
    var mac = gNet.arp.lookup(dstIP) ?? gNet.arp.lookup(netGatewayIP)
    if mac == nil {
        _ = netResolve(netGatewayIP, timeoutMs: 2000)
        mac = gNet.arp.lookup(dstIP) ?? gNet.arp.lookup(netGatewayIP)
    }
    guard let dmac = mac else { return netErrUnreach }

    let localPort = sockBound[s] ? sockPort[s] : allocEphemeralPort(for: s)
    sockPort[s] = localPort; sockBound[s] = true
    sockRemoteIP[s] = dstIP; sockRemotePort[s] = dstPort; sockRemoteMac[s] = dmac
    sockConnReady[s] = false
    let now = systemTicks
    let iss = UInt32(truncatingIfNeeded: now) &* 1664525 &+ 1013904223
    tcpConns[s] = TCPConnection()
    tcpConns[s].activeOpen(localPort: localPort, remoteIP: dstIP, remotePort: dstPort, now: now, iss: iss)
    tcpDrain(s, now)                         // emit the SYN

    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        if sockConnReady[s] { return 0 }
        if tcpConns[s].state == .closed { return netErrUnreach }   // refused/reset
        if timeoutMs > 0 && systemTicks - start >= ticks { return netErrAgain }
        wfi()
    }
}

/// Receive stream bytes from connection `c` into `dst` (cap). Blocks (pumping)
/// until data arrives; returns 0 at EOF (peer closed) or a negative errno.
func tcpRecv(_ c: Int, dst: UnsafeMutableRawPointer, cap: Int, timeoutMs: Int) -> Int {
    if !socketIsTCP(c) { return netErrInval }
    let start = systemTicks
    let ticks = UInt64((timeoutMs + 9) / 10)
    enable_irq()
    while true {
        netPump()
        let n = tcpConns[c].read(dst, cap)
        if n > 0 { return n }
        let st = tcpConns[c].state
        if st == .closeWait || st == .closed || st == .lastAck || st == .closing || st == .timeWait {
            return 0   // peer closed and no buffered data left → EOF
        }
        if timeoutMs > 0 && systemTicks - start >= ticks { return netErrAgain }
        wfi()
    }
}

/// Send stream bytes on connection `c`. Returns bytes accepted.
func tcpSend(_ c: Int, src: UnsafeRawPointer, len: Int) -> Int {
    if !socketIsTCP(c) { return netErrInval }
    let now = systemTicks
    let n = tcpConns[c].appSend(src, len, now: now)
    tcpDrain(c, now)
    return n
}

/// Poll readiness (the caller pumps the NIC first). A listener is readable when
/// a connection awaits acceptance; a connection when it has data or peer-closed.
func socketPollReadable(_ s: Int) -> Bool {
    if !socketValid(s) { return false }
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
    if !socketValid(s) { return }
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
}
