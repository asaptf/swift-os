// SPDX-License-Identifier: Apache-2.0
// NetProbe.swift — the on-device ProbeProber over the SC2 network stack.
//
// This is the real prober compiled into the `slet` ELF (it references the swift_user
// socket bridge, so it is NOT linked into the host test, exactly as the host
// `FakeCellSupervisor`/`FakeProber` are test-only). It implements the two SC5 probe
// kinds against a Cell's reachable IPv4 address:
//   • tcp  — a successful `connect` to address:port is health; a refused/failed connect
//            is a failure.
//   • http — connect, send a minimal `GET <path> HTTP/1.0` request, read the status line,
//            and treat a 2xx/3xx code as health (anything else, or no parseable status,
//            is a failure).
// The per-attempt timeout is enforced with `swiftos_poll` on the socket before reading;
// a poll that returns 0 (no data within `timeoutSeconds`) is reported as `.timeout`,
// which the runner counts as a failure. Active connect remains blocking in the current
// bridge (only passive v6 and active v4 connect are exposed), so a connect that hangs is
// bounded by the kernel's own connect timeout — tightening that to the probe timeout is
// the small follow-on noted here and in FORMAT.md.
//
// Like the C6 adapter, this path is only exercised on-device once real Cells exist (C6);
// until then the SC5 QEMU end-to-end gate is DEFERRED and the host acceptance tests drive
// the `FakeProber`. The probe state machine (ProbeRunner) above this seam is unchanged by
// that work. Foundation-free.

final class NetProbe: ProbeProber {
    init() {}

    func probe(_ spec: ProbeSpec, address: String) -> ProbeOutcome {
        guard let ip = NetProbe.parseIPv4(address) else { return .failure }
        switch spec.kind {
        case .tcp:  return tcpProbe(ip: ip, port: spec.port, timeout: spec.timeoutSeconds)
        case .http: return httpProbe(ip: ip, port: spec.port, path: spec.httpPath,
                                     host: address, timeout: spec.timeoutSeconds)
        case .none, .exec:
            // Inert here — the runner never calls a prober for an inactive probe.
            return .failure
        }
    }

    // MARK: - tcp

    private func tcpProbe(ip: UInt32, port: UInt16, timeout: UInt32) -> ProbeOutcome {
        let fd = swiftos_socket_stream()
        if fd < 0 { return .failure }
        defer { _ = swiftos_close(fd) }
        return swiftos_connect(fd, ip, port) == 0 ? .success : .failure
    }

    // MARK: - http (GET; 2xx/3xx ⇒ success)

    private func httpProbe(ip: UInt32, port: UInt16, path: String, host: String, timeout: UInt32) -> ProbeOutcome {
        let fd = swiftos_socket_stream()
        if fd < 0 { return .failure }
        defer { _ = swiftos_close(fd) }
        if swiftos_connect(fd, ip, port) != 0 { return .failure }

        let reqPath = path.isEmpty ? "/" : path
        let req = "GET \(reqPath) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let reqBytes = Array(req.utf8)
        let wrote = reqBytes.withUnsafeBytes { p in
            p.baseAddress.map { swiftos_write(Int32(fd), $0, UInt(p.count)) } ?? -1
        }
        if wrote < 0 { return .failure }

        // Bound the read by the probe timeout via poll (POLLIN = 0x001).
        var pfd = [UInt8](repeating: 0, count: 8)
        let f = Int32(fd)
        pfd[0] = UInt8(truncatingIfNeeded: f); pfd[1] = UInt8(truncatingIfNeeded: f >> 8)
        pfd[2] = UInt8(truncatingIfNeeded: f >> 16); pfd[3] = UInt8(truncatingIfNeeded: f >> 24)
        pfd[4] = 0x01; pfd[5] = 0x00   // events = POLLIN
        let timeoutMs = Int(timeout == 0 ? 1000 : timeout) * 1000
        let ready = pfd.withUnsafeMutableBytes { swiftos_poll($0.baseAddress, 1, timeoutMs) }
        if ready == 0 { return .timeout }
        if ready < 0 { return .failure }

        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBytes { p in
            p.baseAddress.map { swiftos_read(Int32(fd), $0, UInt(p.count)) } ?? -1
        }
        if n <= 0 { return .failure }
        return NetProbe.statusIs2xx3xx(buf, count: Int(n)) ? .success : .failure
    }

    // MARK: - Parsing helpers

    /// Parse the status code out of an "HTTP/1.x SSS ..." status line; success iff 200–399.
    static func statusIs2xx3xx(_ buf: [UInt8], count: Int) -> Bool {
        // Find the first space (after "HTTP/1.x"), then read three digits.
        var i = 0
        while i < count && buf[i] != 0x20 { i += 1 }   // skip to first space
        i += 1
        guard i + 2 < count else { return false }
        var code = 0
        var k = 0
        while k < 3, i < count, buf[i] >= 0x30, buf[i] <= 0x39 {
            code = code * 10 + Int(buf[i] - 0x30); i += 1; k += 1
        }
        return code >= 200 && code < 400
    }

    /// Parse a dotted-quad IPv4 (e.g. "10.0.2.15") into a host-order UInt32 (the form
    /// `swiftos_connect` expects). Returns nil if it is not a plain IPv4 literal.
    static func parseIPv4(_ s: String) -> UInt32? {
        let b = Array(s.utf8)
        var octets: [UInt32] = []
        var cur: Int = -1
        for c in b {
            if c >= 0x30 && c <= 0x39 {
                cur = (cur < 0 ? 0 : cur) * 10 + Int(c - 0x30)
                if cur > 255 { return nil }
            } else if c == 0x2E {            // '.'
                if cur < 0 { return nil }
                octets.append(UInt32(cur)); cur = -1
            } else {
                return nil                   // not a bare IPv4 literal (host:port is SC7's job)
            }
        }
        if cur < 0 { return nil }
        octets.append(UInt32(cur))
        guard octets.count == 4 else { return nil }
        return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    }
}
