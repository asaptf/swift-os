// socket.swift — kernel UDP socket layer (net-b). Kernel-only glue between the
// pure sans-IO core (NetStack) and the virtio-net driver; NOT part of the host
// net_test. It owns the live NetStack, pumps the NIC, demuxes received UDP
// datagrams into bound sockets, and transmits outbound ones.
//
// One shared NetStack drives the NIC; sockets are a small fixed table, each with
// a short ring of queued datagrams whose payloads live in a single PMM region
// allocated once at netInit (no per-socket alloc churn). recvfrom pumps the NIC
// until a datagram for the socket arrives or a timeout fires.

let netLocalIP: IPv4 = 0x0A00_020F     // 10.0.2.15 (slirp's default guest address)
let netGatewayIP: IPv4 = 0x0A00_0202   // 10.0.2.2  (slirp gateway)

private let maxSockets = 16
private let sockRingDepth = 4
private let sockDatagramCap = 1536
private let sockBufBytes = maxSockets * sockRingDepth * sockDatagramCap
private let sockBufPages = (sockBufBytes + 4095) / 4096

// Negative errno-ish returns shared with the syscall layer.
let netErrDown = -100      // ENETDOWN: no NIC
let netErrUnreach = -101   // EHOSTUNREACH: no route/MAC
let netErrMany = -24       // EMFILE
let netErrInval = -22      // EINVAL
let netErrInUse = -98      // EADDRINUSE
let netErrAgain = -11      // EAGAIN / timed out

var gNet = NetStack(mac: .zero, ip: netLocalIP)   // replaced in netInit with the real MAC
var netReady = false
private var gSockBufBase: UInt = 0

private var sockInUse = [Bool](repeating: false, count: maxSockets)
private var sockBound = [Bool](repeating: false, count: maxSockets)
private var sockPort = [UInt16](repeating: 0, count: maxSockets)
private var sockOwner = [UInt32](repeating: 0, count: maxSockets)
private var sockHead = [Int](repeating: 0, count: maxSockets)
private var sockCount = [Int](repeating: 0, count: maxSockets)
// Per (socket, ring slot) datagram metadata; the payload bytes live at
// gSockBufBase + (s*depth + slot) * sockDatagramCap.
private var dgSrcIP = [IPv4](repeating: 0, count: maxSockets * sockRingDepth)
private var dgSrcPort = [UInt16](repeating: 0, count: maxSockets * sockRingDepth)
private var dgLen = [Int](repeating: 0, count: maxSockets * sockRingDepth)

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
private var tcpConns = [TCPConnection](repeating: TCPConnection(), count: maxSockets)

@inline(__always) private func slotBuf(_ ri: Int) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(bitPattern: gSockBufBase + UInt(ri * sockDatagramCap))!
}
@inline(__always) private func socketValid(_ s: Int) -> Bool {
    s >= 0 && s < maxSockets && sockInUse[s]
}

/// Bring up the NIC once and create the shared NetStack + socket buffer pool.
/// Idempotent. A no-op when no virtio-net device is attached (netReady stays
/// false, so socket() returns ENETDOWN and the other boot paths are unaffected).
func netInit() {
    if netReady { return }
    if !virtioNetInit() {
        uartPuts("net: no virtio-net device attached\n")
        return
    }
    gNet = NetStack(mac: virtioNetMac(), ip: netLocalIP)
    let base = pmm_alloc_pages(sockBufPages)
    if base == 0 {
        uartPuts("net: socket buffer allocation failed\n")
        return
    }
    gSockBufBase = base
    netReady = true
}

/// Pump the NIC once: drain RX frames through the stack, delivering any UDP
/// datagrams to bound sockets (via socketDeliverUDP, called from virtioNetPoll).
func netPump() {
    if netReady { _ = virtioNetPoll(&gNet) }
}

/// Called by the driver for each received UDP datagram. `payload` points into
/// the RX DMA buffer; we copy it into the matching bound socket's ring.
func socketDeliverUDP(srcIP: IPv4, srcPort: UInt16, dstPort: UInt16,
                      payload: UnsafeRawPointer, len: Int) {
    if !netReady || len < 0 { return }
    for s in 0..<maxSockets where sockInUse[s] && sockBound[s] && sockPort[s] == dstPort {
        if sockCount[s] >= sockRingDepth { return }       // ring full: drop (UDP may)
        let n = len > sockDatagramCap ? sockDatagramCap : len
        let slot = (sockHead[s] + sockCount[s]) % sockRingDepth
        let ri = s * sockRingDepth + slot
        let dst = slotBuf(ri)
        var i = 0
        while i < n {
            dst.storeBytes(of: payload.load(fromByteOffset: i, as: UInt8.self),
                           toByteOffset: i, as: UInt8.self)
            i += 1
        }
        dgSrcIP[ri] = srcIP; dgSrcPort[ri] = srcPort; dgLen[ri] = n
        sockCount[s] += 1
        return
    }
}

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

func socketCreate(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoUDP) }
func socketCreateTCP(owner: UInt32) -> Int { socketAlloc(owner: owner, proto: sockProtoTCP) }

private func socketAlloc(owner: UInt32, proto: UInt8) -> Int {
    if !netReady { return netErrDown }
    for s in 0..<maxSockets where !sockInUse[s] {
        sockInUse[s] = true; sockBound[s] = false; sockPort[s] = 0
        sockOwner[s] = owner; sockHead[s] = 0; sockCount[s] = 0
        sockProto[s] = proto; sockIsListener[s] = false; sockListenerOf[s] = -1
        sockAccepted[s] = false; sockConnReady[s] = false
        sockRemoteIP[s] = 0; sockRemotePort[s] = 0; sockRemoteMac[s] = .zero
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
    let srcPort = sockBound[s] ? sockPort[s] : UInt16(40000 + s)
    let frameLen = gNet.buildUDP(toMac: dmac, toIP: dstIP, srcPort: srcPort, dstPort: dstPort,
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
            let srcp = slotBuf(ri)
            var i = 0
            while i < n {
                dst.storeBytes(of: srcp.load(fromByteOffset: i, as: UInt8.self),
                               toByteOffset: i, as: UInt8.self)
                i += 1
            }
            srcIP = dgSrcIP[ri]; srcPort = dgSrcPort[ri]
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
