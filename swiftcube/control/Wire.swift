// SPDX-License-Identifier: Apache-2.0
// Wire.swift — length-prefixed framing for the control channel (SC2).
//
// The control RPCs and the watch stream run as discrete messages over the mTLS
// byte stream. Each message is one frame: a 4-byte little-endian length followed
// by that many payload bytes. Framing is decoupled from the payload meaning
// (Rpc.swift) and from the transport (the mTLS engine) so all three are tested in
// isolation. A FrameBuffer accumulates raw stream bytes (records may split or
// coalesce frames arbitrarily) and yields complete payloads in order.
//
// This is the network form of SC0's watch: the in-process watcher fully described
// by {range, fromRevision} becomes a Watch frame, and each delivered Event becomes
// one length-prefixed event frame with its modRevision — resumable by replaying
// modRevision > R, exactly as SC0. Foundation-free, little-endian throughout.

/// Cap on a single frame to bound buffer growth from a hostile/garbled peer.
let maxFrameLen = 1 << 20    // 1 MiB

enum FrameError: Error, Equatable {
    case oversize       // declared length exceeds maxFrameLen
}

/// Wrap a payload in a length-prefixed frame.
func encodeFrame(_ payload: Bytes) -> Bytes {
    var w = ByteWriter()
    w.u32(UInt32(payload.count))
    w.raw(payload)
    return w.bytes
}

/// Accumulates inbound stream bytes and pops complete frame payloads. The stream
/// may deliver partial frames, multiple frames per chunk, or split a length
/// prefix across chunks — all handled.
struct FrameBuffer {
    private var buf: Bytes = []

    /// Append freshly received stream bytes.
    mutating func feed(_ bytes: ArraySlice<UInt8>) { buf.append(contentsOf: bytes) }
    mutating func feed(_ bytes: Bytes) { buf.append(contentsOf: bytes) }

    /// Pop the next complete frame payload, or nil if one has not fully arrived.
    /// Throws `.oversize` if a peer declares a length beyond `maxFrameLen`.
    mutating func next() throws(FrameError) -> Bytes? {
        if buf.count < 4 { return nil }
        let len = Int(UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24)
        if len > maxFrameLen { throw FrameError.oversize }
        if buf.count < 4 + len { return nil }
        let payload = Array(buf[4 ..< 4 + len])
        buf.removeFirst(4 + len)
        return payload
    }

    var pendingBytes: Int { buf.count }
}
