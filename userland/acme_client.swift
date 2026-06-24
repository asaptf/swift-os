// SPDX-License-Identifier: Apache-2.0
// acme_client.swift — native Swift `/bin/acme`: an ACME (RFC 8555) client that
// obtains an HTTPS certificate end-to-end over the in-tree TLS 1.3 stack.
//
// Usage: acme <ip> <port> <dir-path> <domain> <webroot> <cert-out>
//   ip/port/dir-path  the ACME directory (e.g. 10.0.2.2 14010 /directory)
//   domain            the dNSName to request (http-01)
//   webroot           served directory; the http-01 token file is written under
//                     <webroot>/.well-known/acme-challenge/<token>
//   cert-out          path to write the issued PEM chain
//
// It generates a fresh ECDSA P-256 account key and certificate key, then drives
// directory → newNonce → newAccount → newOrder → authz → http-01 → finalize →
// certificate, one TLS connection per request. The message layer (parsing,
// JWS, CSR) is userland/lib/{acme,jose,asn1}.swift; the transport mirrors
// /bin/tlsget over userland/lib/tls13.swift.
//
// ⚠️ Like tlsget, the TLS client does NOT verify the server certificate — fine
//    for the mock/Pebble test harness, but real Let's Encrypt use needs X.509
//    verification (a separate track; see the tls13.swift header).

private let oRdOnly: Int32 = 0
private let oWrOnly: Int32 = 1
private let oCreat: Int32 = 0x40
private let oTrunc: Int32 = 0x80

// Optional TLS server-certificate verification (set from --ca). When enabled,
// every HTTPS connection authenticates the server against these roots.
private var gVerifyEnabled = false
private var gVerifyRoots: [[UInt8]] = []
private var gVerifyNow: UInt64 = 0

// MARK: - small output helpers

private func a(_ s: StaticString) -> [UInt8] {
    var out = [UInt8](); s.withUTF8Buffer { bp in for b in bp { out.append(b) } }; return out
}
private func emit(_ b: [UInt8]) { b.withUnsafeBytes { _ = swiftos_write(1, $0.baseAddress!, UInt($0.count)) } }
private func emitLine(_ s: StaticString) { var b = a(s); b.append(0x0A); emit(b) }
private func emitKV(_ s: StaticString, _ v: [UInt8]) { var b = a(s); b += v; b.append(0x0A); emit(b) }

private func cstr(_ p: UnsafeMutablePointer<CChar>?) -> [UInt8] {
    guard let p = p else { return [] }
    var out = [UInt8](); var i = 0
    while p[i] != 0 { out.append(UInt8(bitPattern: p[i])); i += 1 }
    return out
}

// MARK: - entropy (mirrors tlsget)

private func fillRandom(_ buf: UnsafeMutableRawPointer, _ n: Int) {
    var off = 0
    while off < n {
        let r = swiftos_random(buf + off, UInt(n - off))
        if r <= 0 { break }
        off += Int(r)
    }
    if off == n { return }
    var probe: UInt64 = 0
    var x = UInt64(swiftos_time())
        ^ (UInt64(bitPattern: Int64(swiftos_getpid())) &* 0x9E37_79B9_7F4A_7C15)
        ^ withUnsafeMutablePointer(to: &probe) { UInt64(UInt(bitPattern: $0)) }
        ^ UInt64(off)
    if x == 0 { x = 0x9E37_79B9_7F4A_7C15 }
    var i = off
    while i < n {
        x = x &* 6364136223846793005 &+ 1442695040888963407
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        buf.storeBytes(of: UInt8((z >> 24) & 0xFF), toByteOffset: i, as: UInt8.self)
        i += 1
    }
}

/// A fresh P-256 keypair (private scalar in [1,n-1]) and its public X/Y.
private func genKey() -> (priv: [UInt8], x: [UInt8], y: [UInt8])? {
    for _ in 0..<16 {
        var priv = [UInt8](repeating: 0, count: 32)
        priv.withUnsafeMutableBytes { fillRandom($0.baseAddress!, 32) }
        var x = [UInt8](repeating: 0, count: 32)
        var y = [UInt8](repeating: 0, count: 32)
        var ok = false
        priv.withUnsafeBytes { pp in x.withUnsafeMutableBytes { xp in y.withUnsafeMutableBytes { yp in
            ok = p256DerivePublic(pp.baseAddress!, xp.baseAddress!, yp.baseAddress!) } } }
        if ok { return (priv, x, y) }
    }
    return nil
}

// MARK: - URL parsing

private func parseIPv4Bytes(_ b: ArraySlice<UInt8>) -> UInt32? {
    var octets = [UInt32](repeating: 0, count: 4)
    var idx = 0, cur: UInt32 = 0, digits = 0
    for ch in b {
        if ch >= 0x30 && ch <= 0x39 { cur = cur * 10 + UInt32(ch - 0x30); if cur > 255 { return nil }; digits += 1 }
        else if ch == 0x2E { if digits == 0 || idx > 3 { return nil }; octets[idx] = cur; idx += 1; cur = 0; digits = 0 }
        else { return nil }
    }
    if digits == 0 || idx != 3 { return nil }
    octets[3] = cur
    return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
}

private struct Target { var host: [UInt8]; var ip: UInt32; var port: UInt16; var path: [UInt8] }

/// Parse "https://HOST[:PORT]/path" (or http://) into a connectable target.
private func parseURL(_ url: String) -> Target? {
    let bytes = Array(url.utf8)
    var i = 0
    // skip scheme
    if let s = findSubseq(bytes, a("://"), 0) { i = s + 3 }
    // authority up to '/'
    var authEnd = i
    while authEnd < bytes.count && bytes[authEnd] != 0x2F { authEnd += 1 }
    let authority = Array(bytes[i..<authEnd])
    let path = authEnd < bytes.count ? Array(bytes[authEnd...]) : a("/")
    // split host:port
    var host = authority
    var port: UInt16 = 443
    if let c = authority.lastIndex(of: 0x3A) {
        host = Array(authority[0..<c])
        var v: UInt = 0
        for d in authority[(c + 1)...] where d >= 0x30 && d <= 0x39 { v = v * 10 + UInt(d - 0x30) }
        if v > 0 && v <= 65535 { port = UInt16(v) }
    }
    var ip: UInt32 = 0
    if let parsed = parseIPv4Bytes(host[0...]) {
        ip = parsed
    } else {
        host.append(0)
        ip = host.withUnsafeBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: host.count) {
                swiftos_resolve($0, 0x0A00_0203, 53)
            }
        }
        host.removeLast()
        if ip == 0 { return nil }
    }
    return Target(host: host, ip: ip, port: port, path: path)
}

private func findSubseq(_ hay: [UInt8], _ needle: [UInt8], _ from: Int) -> Int? {
    if needle.isEmpty || needle.count > hay.count { return nil }
    var i = from
    while i + needle.count <= hay.count {
        var j = 0
        while j < needle.count && hay[i + j] == needle[j] { j += 1 }
        if j == needle.count { return i }
        i += 1
    }
    return nil
}

// MARK: - HTTPS transport (one connection per request, mirrors tlsget)

/// Perform one HTTPS request to `t` and return the raw HTTP response bytes.
private func httpsExchange(_ t: Target, _ request: [UInt8]) -> [UInt8]? {
    let fd = swiftos_socket_stream()
    if fd < 0 { return nil }
    if swiftos_connect(fd, t.ip, t.port) != 0 { _ = swiftos_close(fd); return nil }
    let client = TLS13Client()
    if gVerifyEnabled {
        client.enableVerification(rootsDER: gVerifyRoots,
                                  hostname: String(decoding: t.host, as: UTF8.self),
                                  now: gVerifyNow)
    }
    var sk = [UInt8](repeating: 0, count: 32)
    var ch = [UInt8](repeating: 0, count: 32)
    sk.withUnsafeMutableBytes { fillRandom($0.baseAddress!, 32) }
    ch.withUnsafeMutableBytes { fillRandom($0.baseAddress!, 32) }
    sk.withUnsafeBytes { skp in ch.withUnsafeBytes { chp in
        client.startHandshake(randomSK: skp.baseAddress!, randomCH: chp.baseAddress!) } }

    func flushOut() -> Bool {
        while client.pendingOut > 0 {
            let ok = withUnsafeTemporaryAllocation(byteCount: tlsMaxRecord, alignment: 16) { raw -> Bool in
                let n = client.takeTLS(raw.baseAddress!, raw.count)
                if n <= 0 { return true }
                var off = 0
                while off < n {
                    let w = swiftos_write(fd, raw.baseAddress!.advanced(by: off), UInt(n - off))
                    if w <= 0 { return false }
                    off += Int(w)
                }
                return true
            }
            if !ok { return false }
        }
        return true
    }

    let rxCap = tlsMaxRecord
    let buf = UnsafeMutableRawPointer.allocate(byteCount: rxCap, alignment: 16)
    defer { buf.deallocate() }

    if !flushOut() { _ = swiftos_close(fd); return nil }
    var done = false, failed = false
    switch client.advance() {
    case .handshakeComplete: done = true
    case .failed: failed = true
    case .needMoreData: break
    }
    while !done && !failed {
        let r = swiftos_read(fd, buf, UInt(rxCap))
        if r <= 0 { failed = true; break }
        client.feedTLS(buf, Int(r))
        switch client.advance() {
        case .handshakeComplete: done = true
        case .failed: failed = true
        case .needMoreData: break
        }
        if !flushOut() { failed = true; break }
    }
    if failed || !done { _ = swiftos_close(fd); return nil }
    if !flushOut() { _ = swiftos_close(fd); return nil }

    request.withUnsafeBytes { client.sendAppData($0.baseAddress!, $0.count) }
    if !flushOut() { _ = swiftos_close(fd); return nil }

    var resp = [UInt8]()
    while resp.count < 262144 {
        let r = swiftos_read(fd, buf, UInt(rxCap))
        if r <= 0 { break }
        client.feedTLS(buf, Int(r))
        _ = client.advance()
        while client.pendingAppData > 0 {
            let n = client.receiveAppData(buf, rxCap)
            if n <= 0 { break }
            let bp = UnsafeRawBufferPointer(start: buf, count: n)
            for byte in bp { resp.append(byte) }
        }
        if client.lastError != 0 { break }
    }
    _ = swiftos_close(fd)
    return resp.isEmpty ? nil : resp
}

private func buildHTTP(method: [UInt8], host: [UInt8], port: UInt16,
                       path: [UInt8], body: [UInt8], post: Bool) -> [UInt8] {
    var req = method
    req.append(0x20)
    req += path
    req += a(" HTTP/1.1\r\nHost: ")
    req += host
    req.append(0x3A)
    req += decimal(UInt(port))
    req += a("\r\n")
    if post {
        req += a("Content-Type: application/jose+json\r\nContent-Length: ")
        req += decimal(UInt(body.count))
        req += a("\r\n")
    }
    req += a("Connection: close\r\n\r\n")
    req += body
    return req
}

private func decimal(_ v: UInt) -> [UInt8] {
    if v == 0 { return [0x30] }
    var out = [UInt8](); var x = v
    while x > 0 { out.insert(UInt8(0x30 + (x % 10)), at: 0); x /= 10 }
    return out
}

// MARK: - request convenience (parses URL, builds, exchanges, parses response)

private func doRequest(method: [UInt8], url: String, body: [UInt8], post: Bool) -> HTTPResponse? {
    guard let t = parseURL(url) else { return nil }
    let req = buildHTTP(method: method, host: t.host, port: t.port, path: t.path, body: body, post: post)
    guard let raw = httpsExchange(t, req) else { return nil }
    return parseHTTPResponse(raw)
}

private func signedPOST(url: String, protectedHdr: [UInt8], payload: [UInt8], priv: [UInt8]) -> HTTPResponse? {
    guard let jws = jwsFlattenedES256(protectedJSON: protectedHdr, payloadJSON: payload, priv32: priv) else { return nil }
    return doRequest(method: a("POST"), url: url, body: jws, post: true)
}

private func writeFile(_ path: [UInt8], _ data: [UInt8]) -> Bool {
    var p = path; p.append(0)
    let fd = p.withUnsafeBufferPointer { bp in
        bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) {
            swiftos_open($0, oWrOnly | oCreat | oTrunc)
        }
    }
    if fd < 0 { return false }
    var ok = true
    data.withUnsafeBytes {
        if swiftos_write(fd, $0.baseAddress!, UInt($0.count)) != Int(data.count) { ok = false }
    }
    _ = swiftos_fsync(fd)   // durability: the cert must survive reboot on /data
    _ = swiftos_close(fd)
    return ok
}

private func mkdirC(_ path: [UInt8]) {
    var p = path; p.append(0)
    _ = p.withUnsafeBufferPointer { bp in
        bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { swiftos_mkdir($0) }
    }
}

private func withCPath<T>(_ path: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
    var p = path; p.append(0)
    return p.withUnsafeBufferPointer { bp in
        bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { body($0) }
    }
}

private func fileExists(_ path: [UInt8]) -> Bool {
    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    return withCPath(path) { swiftos_stat($0, &mode, &uid, &gid, &nlink, &size, &mtime) } == 0
}

/// Read up to `cap` bytes of a file, or nil if it cannot be opened.
private func readFile(_ path: [UInt8], _ cap: Int) -> [UInt8]? {
    let fd = withCPath(path) { swiftos_open($0, oRdOnly) }
    if fd < 0 { return nil }
    var out = [UInt8]()
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    defer { buf.deallocate() }
    while out.count < cap {
        let r = swiftos_read(fd, buf, 4096)
        if r <= 0 { break }
        let bp = UnsafeRawBufferPointer(start: buf, count: Int(r))
        for b in bp { out.append(b) }
    }
    _ = swiftos_close(fd)
    return out
}

/// Load the account key from <statedir>/account.key, or generate and persist a
/// fresh one. Returns the key and whether it was newly generated.
private func loadOrCreateAccountKey(_ statedir: [UInt8]) -> (key: (priv: [UInt8], x: [UInt8], y: [UInt8]), fresh: Bool)? {
    mkdirC(statedir)
    var keyPath = statedir; keyPath += a("/account.key")
    if let raw = readFile(keyPath, 32), raw.count == 32 {
        var x = [UInt8](repeating: 0, count: 32)
        var y = [UInt8](repeating: 0, count: 32)
        var ok = false
        raw.withUnsafeBytes { pp in x.withUnsafeMutableBytes { xp in y.withUnsafeMutableBytes { yp in
            ok = p256DerivePublic(pp.baseAddress!, xp.baseAddress!, yp.baseAddress!) } } }
        if ok { return ((raw, x, y), false) }
    }
    guard let k = genKey() else { return nil }
    if !writeFile(keyPath, k.priv) { return nil }
    return (k, true)
}

// MARK: - main

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    if argc < 7 {
        emitLine("acme: usage: acme <ip> <port> <dir-path> <domain> <webroot> <statedir> [--force] [--ca <file>] [--insecure]")
        return 2
    }
    let ipStr = String(decoding: cstr(argv?[1]), as: UTF8.self)
    let portStr = String(decoding: cstr(argv?[2]), as: UTF8.self)
    let dirPath = String(decoding: cstr(argv?[3]), as: UTF8.self)
    let domain = String(decoding: cstr(argv?[4]), as: UTF8.self)
    let webroot = cstr(argv?[5])
    let statedir = cstr(argv?[6])
    var force = false
    var caPath: [UInt8]? = nil
    var insecure = false
    var ai = 7
    while ai < Int(argc) {
        let arg = cstr(argv?[ai])
        if arg == a("--force") { force = true; ai += 1 }
        else if arg == a("--ca") && ai + 1 < Int(argc) { caPath = cstr(argv?[ai + 1]); ai += 2 }
        else if arg == a("--insecure") { insecure = true; ai += 1 }
        else { ai += 1 }
    }

    // TLS server-certificate verification is ON by default, anchored at the system
    // trust store (/etc/ssl/cert.pem); --ca overrides the roots and --insecure
    // disables it (bring-up / mock servers only).
    if !insecure {
        let caBytes = caPath ?? a("/etc/ssl/cert.pem")
        guard let pem = readFile(caBytes, 1 << 18) else {
            emitLine("acme: FAIL read ca"); return 1
        }
        let roots = pemReadCertificates(pem)
        if roots.isEmpty { emitLine("acme: FAIL no certs in ca"); return 1 }
        gVerifyRoots = roots
        gVerifyNow = unixToYYYYMMDDHHMMSS(UInt64(swiftos_time()))
        gVerifyEnabled = true
        emitLine("acme: verification enabled")
    } else {
        emitLine("acme: WARNING insecure — TLS certificate NOT verified")
    }

    // Persistent state layout under <statedir>: account.key, <domain>/{cert,key}.pem
    var certDir = statedir; certDir.append(0x2F); certDir += Array(domain.utf8)
    var certPath = certDir; certPath += a("/cert.pem")
    var keyPath = certDir; keyPath += a("/key.pem")

    // Idempotency / renewal guard: an existing cert is kept unless --force.
    if !force && fileExists(certPath) {
        emitLine("acme: certificate already present")
        return 0
    }

    guard let accPair = loadOrCreateAccountKey(statedir) else { emitLine("acme: FAIL account key"); return 1 }
    let acc = accPair.key
    emitLine(accPair.fresh ? "acme: account key generated" : "acme: account key loaded")
    guard let cert = genKey() else { emitLine("acme: FAIL keygen"); return 1 }

    // 1. directory
    var durl = a("https://")
    durl += Array(ipStr.utf8); durl.append(0x3A); durl += Array(portStr.utf8); durl += Array(dirPath.utf8)
    let dirURL = String(decoding: durl, as: UTF8.self)
    guard let dr = doRequest(method: a("GET"), url: dirURL, body: [], post: false),
          let dir = parseDirectory(dr.body) else { emitLine("acme: FAIL directory"); return 1 }
    emitLine("acme: directory ok")

    // 2. nonce
    guard let nr = doRequest(method: a("HEAD"), url: dir.newNonce, body: [], post: false),
          var nonce = httpHeader(nr, "Replay-Nonce") else { emitLine("acme: FAIL nonce"); return 1 }
    emitLine("acme: nonce ok")

    // 3. newAccount (jwk-keyed)
    let protAcc = acmeProtectedJWK(nonce: nonce, url: dir.newAccount, pubX: acc.x, pubY: acc.y)
    guard let ar = signedPOST(url: dir.newAccount, protectedHdr: protAcc, payload: acmeNewAccountPayload(), priv: acc.priv),
          let kid = httpHeader(ar, "Location") else { emitLine("acme: FAIL newAccount"); return 1 }
    if let n = httpHeader(ar, "Replay-Nonce") { nonce = n }
    emitLine("acme: account registered")

    // 4. newOrder (kid-keyed)
    let protOrd = acmeProtectedKID(nonce: nonce, url: dir.newOrder, kid: kid)
    guard let or = signedPOST(url: dir.newOrder, protectedHdr: protOrd, payload: acmeNewOrderPayload(dnsNames: [domain]), priv: acc.priv),
          let order = parseOrder(or.body),
          let orderURL = httpHeader(or, "Location") else { emitLine("acme: FAIL newOrder"); return 1 }
    if let n = httpHeader(or, "Replay-Nonce") { nonce = n }
    emitLine("acme: order created")

    // 5. authorizations + http-01
    for authzURL in order.authorizations {
        let protAz = acmeProtectedKID(nonce: nonce, url: authzURL, kid: kid)
        guard let azr = signedPOST(url: authzURL, protectedHdr: protAz, payload: acmePostAsGetPayload(), priv: acc.priv),
              let authz = parseAuthorization(azr.body),
              let chal = httpChallenge(authz) else { emitLine("acme: FAIL authz"); return 1 }
        if let n = httpHeader(azr, "Replay-Nonce") { nonce = n }

        let keyAuth = acmeKeyAuthorization(Array(chal.token.utf8), acc.x, acc.y)
        // write <webroot>/.well-known/acme-challenge/<token>
        mkdirC(webroot)
        var d1 = webroot; d1 += a("/.well-known"); mkdirC(d1)
        var d2 = d1; d2 += a("/acme-challenge"); mkdirC(d2)
        var f = d2; f.append(0x2F); f += Array(chal.token.utf8)
        if !writeFile(f, keyAuth) { emitLine("acme: FAIL write challenge"); return 1 }
        emitLine("acme: wrote challenge file")

        // tell server the challenge is ready
        let protCh = acmeProtectedKID(nonce: nonce, url: chal.url, kid: kid)
        guard let cr = signedPOST(url: chal.url, protectedHdr: protCh, payload: acmeChallengeReadyPayload(), priv: acc.priv)
            else { emitLine("acme: FAIL challenge"); return 1 }
        if let n = httpHeader(cr, "Replay-Nonce") { nonce = n }

        // poll the authorization until valid
        var valid = false
        for _ in 0..<20 {
            let protPoll = acmeProtectedKID(nonce: nonce, url: authzURL, kid: kid)
            guard let pr = signedPOST(url: authzURL, protectedHdr: protPoll, payload: acmePostAsGetPayload(), priv: acc.priv),
                  let pa = parseAuthorization(pr.body) else { break }
            if let n = httpHeader(pr, "Replay-Nonce") { nonce = n }
            if acmeEq(pa.status, "valid") { valid = true; break }
            if acmeEq(pa.status, "invalid") { break }
            swiftos_nanosleep(0, 200_000_000)
        }
        if !valid { emitLine("acme: FAIL authz not valid"); return 1 }
        emitLine("acme: authorization valid")
    }

    // 6. finalize
    guard let csr = acmeCSR(dnsNames: [Array(domain.utf8)], pubX: cert.x, pubY: cert.y, priv32: cert.priv)
        else { emitLine("acme: FAIL csr"); return 1 }
    let protFin = acmeProtectedKID(nonce: nonce, url: order.finalize, kid: kid)
    guard let fr = signedPOST(url: order.finalize, protectedHdr: protFin, payload: acmeFinalizePayload(csrDER: csr), priv: acc.priv),
          var fo = parseOrder(fr.body) else { emitLine("acme: FAIL finalize"); return 1 }
    if let n = httpHeader(fr, "Replay-Nonce") { nonce = n }
    emitLine("acme: finalized")

    // 7. poll order until a certificate is ready
    var certURL = fo.certificate
    var tries = 0
    while certURL == nil && tries < 20 {
        tries += 1
        swiftos_nanosleep(0, 200_000_000)
        let protPoll = acmeProtectedKID(nonce: nonce, url: orderURL, kid: kid)
        guard let pr = signedPOST(url: orderURL, protectedHdr: protPoll, payload: acmePostAsGetPayload(), priv: acc.priv),
              let po = parseOrder(pr.body) else { break }
        if let n = httpHeader(pr, "Replay-Nonce") { nonce = n }
        fo = po
        certURL = po.certificate
    }
    guard let cu = certURL else { emitLine("acme: FAIL no certificate url"); return 1 }

    // 8. download the certificate
    let protCert = acmeProtectedKID(nonce: nonce, url: cu, kid: kid)
    guard let cr = signedPOST(url: cu, protectedHdr: protCert, payload: acmePostAsGetPayload(), priv: acc.priv)
        else { emitLine("acme: FAIL cert download"); return 1 }

    // Persist the chain and a PEM EC key (nginx ssl_certificate / _key form).
    mkdirC(certDir)
    if !writeFile(certPath, cr.body) { emitLine("acme: FAIL write cert"); return 1 }
    let keyPEM = ecPrivateKeyPEM(priv32: cert.priv, pubX: cert.x, pubY: cert.y)
    if !writeFile(keyPath, keyPEM) { emitLine("acme: FAIL write key"); return 1 }
    emitKV("acme: certificate obtained bytes=", decimal(UInt(cr.body.count)))
    return 0
}
