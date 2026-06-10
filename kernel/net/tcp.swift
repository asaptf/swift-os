// SPDX-License-Identifier: Apache-2.0
// tcp.swift — sans-IO TCP connection state machine (net-c1).
//
// Pure protocol logic: a `TCPConnection` value consumes parsed inbound segment
// fields (+ payload + a monotonic `now` tick) and emits outbound segment
// *descriptors* into a small fixed queue the caller drains; it performs no I/O
// and holds no kernel state. net-c2 wires it to sockets and the driver (turning
// each descriptor into bytes via tcpWriteHeader + ipWriteHeader + ethWriteHeader
// and transmitting); tests/net_test.swift drives it with crafted segments.
//
// Scope (minimal but real): passive + active open, in-order data with cumulative
// ACK, a send buffer with single-timer RTO retransmit, a fixed window, the full
// close handshake, and RST. Out of scope (net-c2+): out-of-order reassembly
// (we drop + re-ACK), delayed ACK, Nagle, congestion control, SACK, timestamps.

let tcpMinHeaderLen = 20
let ipProtoTCP: UInt8 = 6

let tcpFlagFIN: UInt8 = 0x01
let tcpFlagSYN: UInt8 = 0x02
let tcpFlagRST: UInt8 = 0x04
let tcpFlagPSH: UInt8 = 0x08
let tcpFlagACK: UInt8 = 0x10

// --- segment bytes (parse/build), mirroring udp.swift ----------------------
@inline(__always) func tcpSrcPort(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 0) }
@inline(__always) func tcpDstPort(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 2) }
@inline(__always) func tcpSeq(_ p: UnsafeRawPointer) -> UInt32 { be32(p, 4) }
@inline(__always) func tcpAck(_ p: UnsafeRawPointer) -> UInt32 { be32(p, 8) }
@inline(__always) func tcpDataOffset(_ p: UnsafeRawPointer) -> Int { Int(b8(p, 12) >> 4) * 4 }
@inline(__always) func tcpFlags(_ p: UnsafeRawPointer) -> UInt8 { b8(p, 13) }
@inline(__always) func tcpWindow(_ p: UnsafeRawPointer) -> UInt16 { be16(p, 14) }

/// TCP checksum over the IPv4 pseudo-header + the `segLen` bytes at `seg`
/// (whose checksum field must be zero). Same folding as udpChecksum.
func tcpChecksum(src: IPv4, dst: IPv4, seg: UnsafeRawPointer, segLen: Int) -> UInt16 {
    var acc: UInt32 = 0
    acc = sumWord(acc, UInt16(src >> 16)); acc = sumWord(acc, UInt16(src & 0xFFFF))
    acc = sumWord(acc, UInt16(dst >> 16)); acc = sumWord(acc, UInt16(dst & 0xFFFF))
    acc = sumWord(acc, UInt16(ipProtoTCP))
    acc = sumWord(acc, UInt16(segLen))
    acc = sumBytes(acc, seg, segLen)
    return foldChecksum(acc)
}

func tcpChecksumValid(src: IPv4, dst: IPv4, seg: UnsafeRawPointer, segLen: Int) -> Bool {
    var acc: UInt32 = 0
    acc = sumWord(acc, UInt16(src >> 16)); acc = sumWord(acc, UInt16(src & 0xFFFF))
    acc = sumWord(acc, UInt16(dst >> 16)); acc = sumWord(acc, UInt16(dst & 0xFFFF))
    acc = sumWord(acc, UInt16(ipProtoTCP))
    acc = sumWord(acc, UInt16(segLen))
    acc = sumBytes(acc, seg, segLen)
    return foldChecksum(acc) == 0
}

/// Write a 20-byte TCP header (no options) + payload checksum at `p`. The caller
/// places `payloadLen` bytes after the header; `src`/`dst` feed the pseudo-header.
func tcpWriteHeader(_ p: UnsafeMutableRawPointer, srcPort: UInt16, dstPort: UInt16,
                    seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16,
                    src: IPv4, dst: IPv4, payloadLen: Int) {
    be16set(p, 0, srcPort)
    be16set(p, 2, dstPort)
    be32set(p, 4, seq)
    be32set(p, 8, ack)
    b8set(p, 12, 5 << 4)        // data offset 5 words (20 bytes), no options
    b8set(p, 13, flags)
    be16set(p, 14, window)
    be16set(p, 16, 0)           // checksum zeroed before computing
    be16set(p, 18, 0)           // urgent pointer
    be16set(p, 16, tcpChecksum(src: src, dst: dst, seg: p, segLen: tcpMinHeaderLen + payloadLen))
}

// --- ephemeral local-port allocator (net-rob) ------------------------------
// Pure rotating allocator over the IANA dynamic range. The socket layer keeps
// the live cursor and supplies an `inUse` predicate over its bind table; kept
// here (sans-IO) so the host net_test can unit-check it without the kernel-only
// socket.swift.
let ephemeralPortLow: UInt16 = 49152
let ephemeralPortHigh: UInt16 = 65535

/// Pick the next free local port in [low, high], skipping any port for which
/// `inUse` is true. Advances `cursor` (wrapping within the range) so successive
/// calls rotate and rarely re-issue a just-used port.
func nextEphemeralPort(cursor: inout UInt16, inUse: (UInt16) -> Bool) -> UInt16 {
    let span = Int(ephemeralPortHigh - ephemeralPortLow) + 1
    var tries = 0
    while tries < span {
        let candidate = cursor
        cursor = candidate == ephemeralPortHigh ? ephemeralPortLow : candidate + 1
        if !inUse(candidate) { return candidate }
        tries += 1
    }
    return cursor   // every port busy (impossible with the socket table << span)
}

// --- sequence-number arithmetic (wraparound-safe, RFC 1982) ----------------
@inline(__always) func seqLT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
@inline(__always) func seqLEQ(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }
@inline(__always) func seqGT(_ a: UInt32, _ b: UInt32) -> Bool { seqLT(b, a) }
@inline(__always) func seqGEQ(_ a: UInt32, _ b: UInt32) -> Bool { seqLEQ(b, a) }

// --- connection ------------------------------------------------------------
enum TCPState {
    case closed, listen, synSent, synRcvd, established
    case finWait1, finWait2, closing, timeWait, closeWait, lastAck
}

/// What processing one event produced (OR-accumulated by the caller).
struct TCPEvent {
    var established = false
    var dataAvailable = false
    var peerClosed = false
    var closed = false
    var reset = false
}

/// A segment the engine wants transmitted. `payloadOff` is relative to snd.una
/// (an index into the live send buffer); payloadLen 0 means a pure control/ACK.
struct TCPSegmentOut {
    var flags: UInt8 = 0
    var seq: UInt32 = 0
    var ack: UInt32 = 0
    var window: UInt16 = 0
    var payloadOff = 0
    var payloadLen = 0
}

private let tcpSndCap = 2048
private let tcpRcvCap = 2048
private let tcpSegMax = 1024          // max payload bytes per emitted segment
private let tcpOutCap = 8
private let tcpRtoTicks: UInt64 = 100 // ~1s at 100 Hz
private let tcpTimeWaitTicks: UInt64 = 50
private let tcpMaxRetries = 6
private let tcpISS: UInt32 = 0x1000   // fixed for net-c1 determinism (net-c2 seeds from RTC)

struct TCPConnection {
    private(set) var state: TCPState = .closed
    var localPort: UInt16 = 0
    var remotePort: UInt16 = 0
    var remoteIP: IPv4 = 0

    // Send sequence space. Buffered data covers [sndUna, sndUna + sndCount);
    // sndNxt is the next seq to transmit; a queued FIN sits at sndUna+sndCount.
    private var sndUna: UInt32 = 0
    private var sndNxt: UInt32 = 0
    private var sndWnd: UInt16 = 0xFFFF
    private var iss: UInt32 = 0
    private var openISS: UInt32 = tcpISS   // ISS to use on open (net-c2 seeds from the RTC)
    private var finQueued = false
    private var finSeq: UInt32 = 0
    private var finAckedNow = false

    // Receive sequence space.
    private var rcvNxt: UInt32 = 0
    private var irs: UInt32 = 0

    private var sndBuf = [UInt8](repeating: 0, count: tcpSndCap)
    private var sndCount = 0
    private var rcvBuf = [UInt8](repeating: 0, count: tcpRcvCap)
    private var rcvCount = 0

    private var rtoActive = false
    private var rtoDeadline: UInt64 = 0
    private var retries = 0
    private var timeWaitDeadline: UInt64 = 0

    private var out = [TCPSegmentOut](repeating: TCPSegmentOut(), count: tcpOutCap)
    private(set) var outCount = 0

    mutating func reset() {
        state = .closed
        localPort = 0
        remotePort = 0
        remoteIP = 0
        sndUna = 0
        sndNxt = 0
        sndWnd = 0xFFFF
        iss = 0
        openISS = tcpISS
        finQueued = false
        finSeq = 0
        finAckedNow = false
        rcvNxt = 0
        irs = 0
        sndCount = 0
        rcvCount = 0
        rtoActive = false
        rtoDeadline = 0
        retries = 0
        timeWaitDeadline = 0
        outCount = 0
    }

    // ---- output queue accessors (drained by the caller) ----
    func outSegment(_ i: Int) -> TCPSegmentOut { out[i] }
    func availableBytes() -> Int { rcvCount }
    func segmentPayloadByte(_ seg: TCPSegmentOut, _ i: Int) -> UInt8 { sndBuf[seg.payloadOff + i] }
    /// Copy a segment's payload out of the (private) send buffer into `dst`.
    func copySegmentPayload(_ seg: TCPSegmentOut, to dst: UnsafeMutableRawPointer) {
        var i = 0
        while i < seg.payloadLen {
            dst.storeBytes(of: sndBuf[seg.payloadOff + i], toByteOffset: i, as: UInt8.self)
            i += 1
        }
    }
    mutating func clearOut() { outCount = 0 }

    private mutating func emit(flags: UInt8, seq: UInt32, payloadOff: Int = 0, payloadLen: Int = 0) {
        if outCount >= tcpOutCap { return }
        out[outCount] = TCPSegmentOut(flags: flags, seq: seq, ack: rcvNxt,
                                      window: UInt16(rcvSpace()), payloadOff: payloadOff,
                                      payloadLen: payloadLen)
        outCount += 1
    }

    private func rcvSpace() -> Int { tcpRcvCap - rcvCount }
    private mutating func armRTO(_ now: UInt64) { rtoActive = true; rtoDeadline = now &+ tcpRtoTicks; retries = 0 }

    // ---- opens ----
    mutating func passiveOpen(localPort: UInt16, iss: UInt32 = tcpISS) {
        self.localPort = localPort
        self.openISS = iss
        state = .listen
    }

    mutating func activeOpen(localPort: UInt16, remoteIP: IPv4, remotePort: UInt16,
                             now: UInt64, iss issArg: UInt32 = tcpISS) {
        self.localPort = localPort
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        iss = issArg; sndUna = iss; sndNxt = iss &+ 1
        state = .synSent
        emit(flags: tcpFlagSYN, seq: iss)
        armRTO(now)
    }

    // ---- application I/O ----
    /// Queue `len` bytes to send and emit as much as the window allows. Returns
    /// the number of bytes accepted into the send buffer.
    mutating func appSend(_ src: UnsafeRawPointer, _ len: Int, now: UInt64) -> Int {
        guard state == .established || state == .closeWait else { return 0 }
        let space = tcpSndCap - sndCount
        let n = len > space ? space : len
        var i = 0
        while i < n { sndBuf[sndCount + i] = src.load(fromByteOffset: i, as: UInt8.self); i += 1 }
        sndCount += n
        pumpSend(now: now)
        return n
    }

    /// Begin closing: send a FIN once buffered data is flushed.
    mutating func appClose(now: UInt64) {
        switch state {
        case .established:
            queueFIN(now: now); state = .finWait1
        case .closeWait:
            queueFIN(now: now); state = .lastAck
        default:
            break
        }
    }

    /// Copy delivered in-order bytes to `dst` (capacity `cap`). Returns the count.
    mutating func read(_ dst: UnsafeMutableRawPointer, _ cap: Int) -> Int {
        let n = rcvCount > cap ? cap : rcvCount
        var i = 0
        while i < n { dst.storeBytes(of: rcvBuf[i], toByteOffset: i, as: UInt8.self); i += 1 }
        // Shift the remainder to the front.
        var j = n
        while j < rcvCount { rcvBuf[j - n] = rcvBuf[j]; j += 1 }
        rcvCount -= n
        return n
    }

    mutating func advertiseReadWindow() {
        switch state {
        case .established, .finWait1, .finWait2, .closeWait:
            emit(flags: tcpFlagACK, seq: sndNxt)
        default:
            break
        }
    }

    private mutating func queueFIN(now: UInt64) {
        if finQueued { return }
        finQueued = true
        finSeq = sndUna &+ UInt32(sndCount)
        // Flush any unsent data first, then the FIN.
        pumpSend(now: now)
        if seqGEQ(sndNxt, finSeq) {            // all data sent; send the FIN now
            emit(flags: tcpFlagFIN | tcpFlagACK, seq: finSeq)
            sndNxt = finSeq &+ 1
            if !rtoActive { armRTO(now) }
        }
    }

    /// Transmit unsent buffered data within the window.
    private mutating func pumpSend(now: UInt64) {
        let dataEnd = sndUna &+ UInt32(sndCount)            // first seq past buffered data
        let limit = sndUna &+ UInt32(sndWnd)                // peer's advertised window edge
        while seqLT(sndNxt, dataEnd) {
            if !seqLT(sndNxt, limit) { break }              // window full
            let off = Int(sndNxt &- sndUna)
            var chunk = sndCount - off
            if chunk > tcpSegMax { chunk = tcpSegMax }
            let windowRoom = Int(limit &- sndNxt)
            if chunk > windowRoom { chunk = windowRoom }
            if chunk <= 0 { break }
            emit(flags: tcpFlagPSH | tcpFlagACK, seq: sndNxt, payloadOff: off, payloadLen: chunk)
            sndNxt = sndNxt &+ UInt32(chunk)
            if !rtoActive { armRTO(now) }
        }
    }

    // ---- RTO ----
    mutating func tick(now: UInt64) {
        if state == .timeWait && now >= timeWaitDeadline {
            state = .closed
            return
        }
        if !rtoActive || now < rtoDeadline { return }
        retries += 1
        if retries > tcpMaxRetries {
            emit(flags: tcpFlagRST, seq: sndNxt)
            state = .closed
            rtoActive = false
            return
        }
        rtoDeadline = now &+ tcpRtoTicks
        // Retransmit the oldest unacknowledged item.
        if state == .synRcvd {
            emit(flags: tcpFlagSYN | tcpFlagACK, seq: iss)
        } else if sndCount > 0 {
            var chunk = sndCount
            if chunk > tcpSegMax { chunk = tcpSegMax }
            emit(flags: tcpFlagPSH | tcpFlagACK, seq: sndUna, payloadOff: 0, payloadLen: chunk)
        } else if finQueued && seqLT(sndUna, finSeq &+ 1) {
            emit(flags: tcpFlagFIN | tcpFlagACK, seq: finSeq)
        }
    }

    // ---- the core: process one inbound segment ----
    mutating func onSegment(flags: UInt8, seq: UInt32, ack: UInt32, window: UInt16,
                            payload: UnsafeRawPointer?, payloadLen: Int, now: UInt64) -> TCPEvent {
        var ev = TCPEvent()
        finAckedNow = false
        let isSYN = (flags & tcpFlagSYN) != 0
        let isACK = (flags & tcpFlagACK) != 0
        let isFIN = (flags & tcpFlagFIN) != 0
        let isRST = (flags & tcpFlagRST) != 0

        if state == .closed { return ev }

        // A RST tears the connection down from ANY non-LISTEN state (SYN_SENT,
        // SYN_RCVD, ESTABLISHED, the FIN_WAIT/CLOSING/CLOSE_WAIT/LAST_ACK close
        // states, even TIME_WAIT): stop all timers, flag both reset and closed,
        // and drop any queued output so the caller emits nothing in reply.
        if isRST {
            if state != .listen {
                state = .closed
                rtoActive = false
                outCount = 0
                ev.reset = true
                ev.closed = true
            }
            return ev
        }

        if state == .listen {
            if isSYN && !isACK {
                irs = seq; rcvNxt = seq &+ 1
                iss = openISS; sndUna = iss; sndNxt = iss &+ 1
                state = .synRcvd
                emit(flags: tcpFlagSYN | tcpFlagACK, seq: iss)
                armRTO(now)
            }
            return ev
        }

        if state == .synSent {
            if isSYN && isACK && ack == sndNxt {
                irs = seq; rcvNxt = seq &+ 1
                sndUna = ack; rtoActive = false
                state = .established
                emit(flags: tcpFlagACK, seq: sndNxt)
                ev.established = true
            }
            return ev
        }

        // Passive-open completion: the ACK of our SYN (which consumed one
        // sequence number) moves us to ESTABLISHED. Fall through so a piggybacked
        // payload/FIN on the same segment is still processed.
        if state == .synRcvd {
            guard isACK && seqGEQ(ack, iss &+ 1) else { return ev }
            sndUna = iss &+ 1
            state = .established
            rtoActive = false
            ev.established = true
        }

        // States with an established sequence space.
        if isACK { processAck(ack: ack, now: now, ev: &ev) }
        sndWnd = window

        // Accept in-order payload (states where the peer may still send data).
        if payloadLen > 0 && (state == .established || state == .finWait1 || state == .finWait2) {
            if seq == rcvNxt && rcvSpace() > 0, let payload {
                let n = payloadLen > rcvSpace() ? rcvSpace() : payloadLen
                var i = 0
                while i < n { rcvBuf[rcvCount + i] = payload.load(fromByteOffset: i, as: UInt8.self); i += 1 }
                rcvCount += n
                rcvNxt = rcvNxt &+ UInt32(n)
                ev.dataAvailable = true
            }
            emit(flags: tcpFlagACK, seq: sndNxt)   // ACK (cumulative; re-ACK on old/out-of-order)
        }

        // Peer FIN: consumes the sequence number after its data.
        if isFIN {
            let finAt = seq &+ UInt32(payloadLen)
            if seqLEQ(finAt, rcvNxt) {            // we have everything up to the FIN
                rcvNxt = finAt &+ 1
                ev.peerClosed = true
                emit(flags: tcpFlagACK, seq: sndNxt)
                switch state {
                case .established: state = .closeWait
                case .finWait1:    state = finAckedNow ? .timeWait : .closing
                case .finWait2:    state = .timeWait
                default: break
                }
                if state == .timeWait { timeWaitDeadline = now &+ tcpTimeWaitTicks }
            }
        }

        if state == .closed { ev.closed = true }
        return ev
    }

    /// Advance snd.una on a valid ACK, freeing acked send bytes and driving the
    /// FIN/close state transitions.
    private mutating func processAck(ack: UInt32, now: UInt64, ev: inout TCPEvent) {
        let sndMax = sndUna &+ UInt32(sndCount) &+ (finQueued ? 1 : 0)
        guard seqGT(ack, sndUna) && seqLEQ(ack, sndMax) else { return }

        let delta = Int(ack &- sndUna)
        let dataAcked = delta > sndCount ? sndCount : delta
        if dataAcked > 0 {
            var j = dataAcked
            while j < sndCount { sndBuf[j - dataAcked] = sndBuf[j]; j += 1 }
            sndCount -= dataAcked
        }
        if finQueued && seqGEQ(ack, finSeq &+ 1) { finAckedNow = true }
        sndUna = ack

        // Stop or restart the retransmit timer.
        if seqGEQ(sndUna, sndNxt) && sndCount == 0 && !(finQueued && !finAckedNow) {
            rtoActive = false
        } else {
            armRTO(now)
        }

        switch state {
        case .finWait1: if finAckedNow { state = .finWait2 }
        case .closing:  if finAckedNow { state = .timeWait; timeWaitDeadline = now &+ tcpTimeWaitTicks }
        case .lastAck:  if finAckedNow { state = .closed; rtoActive = false; ev.closed = true }
        default: break
        }
    }
}
