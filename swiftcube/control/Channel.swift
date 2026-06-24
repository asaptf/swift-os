// SPDX-License-Identifier: Apache-2.0
// Channel.swift — a framed message channel over the mTLS engine (SC2).
//
// TLSChannel turns the sans-IO MutualTLS engine + Wire framing into a simple
// "write a message, read a message" channel, with the actual byte movement left
// to the caller (feedWire/takeWire) so the same channel works over a host
// loopback pipe and over an on-device TCP socket. Inbound TLS application data is
// reassembled into discrete frames; outbound frames are length-prefixed and
// TLS-sealed. Foundation-free.

final class TLSChannel {
    let tls: MutualTLS
    private var inFrames = FrameBuffer()
    private(set) var failed = false
    private var frameError = false

    init(_ tls: MutualTLS) { self.tls = tls }

    var peerIdentity: String? { tls.peerIdentity }
    var handshakeComplete: Bool { tls.handshakeComplete }
    var lastError: Int { tls.lastError }

    /// Kick off the handshake (client emits ClientHello; server waits).
    func start() { tls.start() }

    /// Feed raw bytes received from the wire; advance the engine; reassemble any
    /// decrypted application frames.
    func feedWire(_ bytes: [UInt8]) {
        if bytes.isEmpty { return }
        tls.feedTLS(bytes)
        if tls.advance() == .failed { failed = true; return }
        let app = tls.receiveAppData()
        if !app.isEmpty { inFrames.feed(app) }
    }

    /// Drain encrypted bytes queued for the wire.
    func takeWire() -> [UInt8] { tls.takeTLS() }

    var pendingWire: Int { tls.pendingOut }

    /// Queue one framed message (sealed under the current TLS keys).
    func writeFrame(_ payload: [UInt8]) {
        if !handshakeComplete { return }
        tls.sendAppData(encodeFrame(payload))
    }

    /// Pop the next fully-received frame payload, or nil if none is ready.
    func nextFrame() -> [UInt8]? {
        do { return try inFrames.next() } catch { frameError = true; failed = true; return nil }
    }
}

/// Move bytes between two in-process channels until neither has anything queued
/// (the host loopback transport). Bounded to avoid an accidental infinite loop.
func loopbackPump(_ a: TLSChannel, _ b: TLSChannel, rounds: Int = 200) {
    for _ in 0..<rounds {
        var moved = false
        let x = a.takeWire(); if !x.isEmpty { b.feedWire(x); moved = true }
        let y = b.takeWire(); if !y.isEmpty { a.feedWire(y); moved = true }
        if !moved { return }
    }
}
