// SPDX-License-Identifier: Apache-2.0
// ProxyTransport.swift — the I/O seam under the userspace L4 node-proxy (SC7).
//
// The node-proxy is a userspace L4 forwarder: it listens on each service's node-local proxy
// port, accepts a TCP connection, picks a ready endpoint, dials it, and splices bytes both
// ways. Everything ABOVE the raw sockets — target management, round-robin load balancing,
// dial-failover, fast-fail, drain — is Foundation-free pure logic in NodeProxy.swift, tested
// deterministically over an in-memory transport. The raw sockets are this seam, with two
// bindings (the same split as SC5's FakeProber/NetProbe and SC6's FakeApplier/NginxApplier):
//
//   • a FAKE transport (host tests): in-memory full-duplex connections + fake backend servers,
//     so bytes actually flow end-to-end and LB distribution/drain/failover are observable with
//     no kernel and no real sockets.
//   • a REAL transport (on-device): swiftos_socket_stream/listen/accept/connect/read/write/poll,
//     compiled only into the `slet` ELF (NetProxyTransport.swift) — never linked into the host
//     test, exactly like NetProbe.
//
// A connection is byte-oriented and half-closable: `read` returns >0 bytes, 0 at EOF, or <0
// when no progress is possible right now (the splice treats <0 as "idle this direction").
// `shutdownWrite` half-closes the write side (forwards the peer's EOF); `close` tears down.

/// One L4 connection (an accepted client conn, or a dialed backend conn).
protocol ProxyConn: AnyObject {
    /// Read up to `max` bytes into `buf`. Returns the count (>0), 0 at EOF, or <0 if no data is
    /// available yet (non-fatal; the splice loop simply makes no progress on this side).
    func read(into buf: inout [UInt8], max: Int) -> Int
    /// Write all of `bytes`. Returns the count written, or <0 on error.
    @discardableResult func write(_ bytes: [UInt8]) -> Int
    /// Half-close the write side (the peer sees EOF); the read side stays open to drain.
    func shutdownWrite()
    /// Fully tear down the connection.
    func close()
}

/// Opens listeners and dials backends. The node-proxy holds one of these.
protocol ProxyTransport: AnyObject {
    /// Bind + listen on a node-local `port`; nil if the bind fails. The returned listener yields
    /// accepted client connections.
    func listen(port: UInt16) -> ProxyListener?
    /// Active-open a connection to a backend endpoint; nil if the connect fails (the proxy then
    /// tries the next ready endpoint — see NodeProxy dial-failover).
    func dial(host: String, port: UInt16) -> ProxyConn?
}

/// A bound listener for one service's proxy port.
protocol ProxyListener: AnyObject {
    /// The next pending inbound connection, or nil if none is waiting right now (non-blocking).
    func accept() -> ProxyConn?
    /// Stop listening (the service was removed).
    func close()
}
