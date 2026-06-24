// SPDX-License-Identifier: Apache-2.0
// NetProxyTransport.swift — the on-device ProxyTransport over the SC2 TCP stack.
//
// This is the real L4 transport compiled into the `slet` ELF (it references the swift_user
// socket bridge, so it is NOT linked into the host test — exactly as NetProbe is the on-device
// prober and FakeProber the test one). It implements the ProxyTransport seam over the swift-os
// TCP primitives verified present in the stack: swiftos_socket_stream / bind / listen / accept
// (passive) and swiftos_connect (active v4 open) + swiftos_read/write + swiftos_poll.
//
// Two honest limitations of the current bridge, documented here and in FORMAT.md:
//   • No shutdown(2) is exposed, so `shutdownWrite` cannot half-close a live socket. The splice
//     therefore relays full-duplex and tears the connection down with close() once both
//     directions hit EOF; a backend that waits for the client's FIN before replying is the
//     follow-on for when shutdown is exposed. Request/response (and most L4) workloads are
//     unaffected.
//   • Active open is blocking (only passive v6 and active v4 connect are exposed), so a dial to
//     an unreachable endpoint is bounded by the kernel connect timeout, not an explicit per-dial
//     deadline — the same constraint NetProbe records. accept() is made non-blocking with a
//     zero-timeout poll so the proxy's event loop never wedges on an idle listener.
//
// The pure forwarding/LB logic above this seam (NodeProxy/Balancer) is unchanged by all of that.
// Foundation-free.

final class NetProxyConn: ProxyConn {
    private var fd: Int32
    private var closed = false
    init(fd: Int32) { self.fd = fd }

    func read(into buf: inout [UInt8], max: Int) -> Int {
        if closed { return -1 }
        let cap = Swift.min(max, buf.count)
        let n = buf.withUnsafeMutableBytes { p -> Int in
            guard let base = p.baseAddress else { return -1 }
            return Int(swiftos_read(fd, base, UInt(cap)))
        }
        return n   // >0 data, 0 EOF, <0 error/would-block
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int {
        if closed || bytes.isEmpty { return 0 }
        let n = bytes.withUnsafeBytes { p -> Int in
            guard let base = p.baseAddress else { return -1 }
            return Int(swiftos_write(fd, base, UInt(p.count)))
        }
        return n
    }

    /// No shutdown(2) in the bridge ⇒ a half-close is unavailable; this is a no-op and the
    /// connection is fully torn down by `close()` once both directions EOF. See header.
    func shutdownWrite() {}

    func close() {
        if closed { return }
        closed = true
        _ = swiftos_close(fd)
    }
}

final class NetProxyListener: ProxyListener {
    private var fd: Int32
    private var closed = false
    init(fd: Int32) { self.fd = fd }

    func accept() -> ProxyConn? {
        if closed { return nil }
        // Non-blocking: poll the listener with a zero timeout; only accept when readable so the
        // proxy's loop never blocks on an idle service.
        var pfd = [UInt8](repeating: 0, count: 8)
        pfd[0] = UInt8(truncatingIfNeeded: fd); pfd[1] = UInt8(truncatingIfNeeded: fd >> 8)
        pfd[2] = UInt8(truncatingIfNeeded: fd >> 16); pfd[3] = UInt8(truncatingIfNeeded: fd >> 24)
        pfd[4] = 0x01; pfd[5] = 0x00   // events = POLLIN
        let ready = pfd.withUnsafeMutableBytes { swiftos_poll($0.baseAddress, 1, 0) }
        if ready <= 0 { return nil }
        let c = swiftos_accept(fd)
        if c < 0 { return nil }
        return NetProxyConn(fd: c)
    }

    func close() {
        if closed { return }
        closed = true
        _ = swiftos_close(fd)
    }
}

final class NetProxyTransport: ProxyTransport {
    init() {}

    func listen(port: UInt16) -> ProxyListener? {
        let fd = swiftos_socket_stream()
        if fd < 0 { return nil }
        if swiftos_bind(fd, port) != 0 { _ = swiftos_close(fd); return nil }
        if swiftos_listen(fd, 16) != 0 { _ = swiftos_close(fd); return nil }
        return NetProxyListener(fd: fd)
    }

    func dial(host: String, port: UInt16) -> ProxyConn? {
        guard let ip = NetProbe.parseIPv4(host) else { return nil }
        let fd = swiftos_socket_stream()
        if fd < 0 { return nil }
        if swiftos_connect(fd, ip, port) != 0 { _ = swiftos_close(fd); return nil }
        return NetProxyConn(fd: fd)
    }
}
