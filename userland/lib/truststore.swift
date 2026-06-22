// SPDX-License-Identifier: Apache-2.0
// truststore.swift — load the system TLS trust store (CA root certificates) for
// verifying HTTPS clients.
//
// The default store is /etc/ssl/cert.pem, shipped read-only in the signed base
// image (currently the ISRG / Let's Encrypt roots — the trust anchors for our
// ACME-issued certificates and for HTTPS to the LE API). A client reads it once
// and hands the DER roots to TLS13Client.enableVerification(rootsDER:). Install
// the `ca-certificates` package for a full Mozilla bundle (general-purpose HTTPS
// to arbitrary hosts).

let systemTrustStorePath: StaticString = "/etc/ssl/cert.pem"

// Read a PEM CA file (by NUL-terminated path) and return each certificate as a
// DER blob. Returns [] if the file is missing/empty or has no certificates.
func loadTrustRootsFile(_ path: UnsafePointer<CChar>) -> [[UInt8]] {
    let fd = swiftos_open(path, 0)   // O_RDONLY
    if fd < 0 { return [] }
    defer { _ = swiftos_close(fd) }
    var data = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = chunk.withUnsafeMutableBytes { swiftos_read(fd, $0.baseAddress, UInt($0.count)) }
        if n <= 0 { break }
        var i = 0
        while i < Int(n) { data.append(chunk[i]); i += 1 }
        if data.count > 4 * 1024 * 1024 { break }   // sanity bound for a CA bundle
    }
    return pemReadCertificates(data)
}

// Load the default system trust store (/etc/ssl/cert.pem).
func loadSystemTrustRoots() -> [[UInt8]] {
    var p: [CChar] = []
    let n = systemTrustStorePath.utf8CodeUnitCount
    var i = 0
    while i < n { p.append(CChar(bitPattern: systemTrustStorePath.utf8Start[i])); i += 1 }
    p.append(0)
    return p.withUnsafeBufferPointer { loadTrustRootsFile($0.baseAddress!) }
}
