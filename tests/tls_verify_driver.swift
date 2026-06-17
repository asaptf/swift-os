// SPDX-License-Identifier: Apache-2.0
//
// tls_verify_driver.swift — host driver that exercises the V2b certificate
// verification in userland/lib/tls13.swift against a real openssl TLS 1.3
// server. It is the same sans-IO engine the guest runs, driven here over a
// POSIX socket so the verify path can be tested without QEMU.
//
// Usage: tls_verify_driver <host> <port> <ca-der-path> <now-YYYYMMDDHHMMSS>
//   Connects to 127.0.0.1:<port>, enables verification trusting the CA DER,
//   expects <host> in the leaf SAN, and prints VERIFY-OK / VERIFY-FAIL.
//   Exit 0 iff the authenticated handshake completed.

import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
struct TLSVerifyDriver {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 5,
              let port = UInt16(args[2]),
              let now = UInt64(args[4]) else {
            FileHandle.standardError.write(Data("usage: tls_verify_driver <host> <port> <ca-der> <now>\n".utf8))
            exit(2)
        }
        let host = args[1]
        guard let caData = FileManager.default.contents(atPath: args[3]) else {
            FileHandle.standardError.write(Data("cannot read CA DER\n".utf8)); exit(2)
        }
        let caDER = [UInt8](caData)

        let fd = socket(AF_INET, sockStreamType, 0)
        if fd < 0 { print("VERIFY-FAIL connect"); exit(1) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let crc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if crc != 0 { print("VERIFY-FAIL connect"); exit(1) }

        let client = TLS13Client()
        client.enableVerification(rootsDER: [caDER], hostname: host, now: now)

        var sk = [UInt8](repeating: 0, count: 32)
        var ch = [UInt8](repeating: 0, count: 32)
        sk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 32) }
        ch.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 32) }
        sk.withUnsafeBytes { skp in ch.withUnsafeBytes { chp in
            client.startHandshake(randomSK: skp.baseAddress!, randomCH: chp.baseAddress!) } }

        let cap = tlsMaxRecord
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        defer { buf.deallocate() }

        func flushOut() -> Bool {
            while client.pendingOut > 0 {
                let n = client.takeTLS(buf, cap)
                if n <= 0 { return true }
                var off = 0
                while off < n {
                    let w = write(fd, buf.advanced(by: off), n - off)
                    if w <= 0 { return false }
                    off += w
                }
            }
            return true
        }

        _ = flushOut()
        var done = false, failed = false
        switch client.advance() {
        case .handshakeComplete: done = true
        case .failed: failed = true
        case .needMoreData: break
        }
        while !done && !failed {
            let r = read(fd, buf, cap)
            if r <= 0 { failed = true; break }
            client.feedTLS(buf, r)
            switch client.advance() {
            case .handshakeComplete: done = true
            case .failed: failed = true
            case .needMoreData: break
            }
            if !flushOut() { failed = true; break }
        }
        close(fd)

        if done {
            print("VERIFY-OK")
            exit(0)
        }
        print("VERIFY-FAIL err=\(client.lastError)")
        exit(1)
    }
}

#if canImport(Glibc)
private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamType = SOCK_STREAM
#endif
