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

func socketCreate(owner: UInt32) -> Int {
    if !netReady { return netErrDown }
    for s in 0..<maxSockets where !sockInUse[s] {
        sockInUse[s] = true; sockBound[s] = false; sockPort[s] = 0
        sockOwner[s] = owner; sockHead[s] = 0; sockCount[s] = 0
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

/// True if a bound socket has a queued datagram (for poll). The caller pumps
/// the NIC first (vfsPoll does when a socket fd is present).
func socketReadable(_ s: Int) -> Bool {
    socketValid(s) && sockCount[s] > 0
}

func socketClose(_ s: Int) {
    if !socketValid(s) { return }
    sockInUse[s] = false; sockBound[s] = false; sockPort[s] = 0
    sockHead[s] = 0; sockCount[s] = 0
}
