// SPDX-License-Identifier: Apache-2.0
//
// acme.swift — the message layer of a native ACME (RFC 8555) client: parse the
// HTTP/1.1 responses and the small JSON objects an ACME server returns, and
// build the request bodies (protected JWS headers and payloads) the client
// sends. This is the pure, transport-free core (the TCP+TLS transport and the
// driving state machine live above it), so it is fully host-testable with
// canned Pebble/Let's-Encrypt responses — see tests/acme_test.swift.
//
// Embedded-compatible (heap byte arrays, no Foundation). JSON parsing is a
// small structural reader sufficient for ACME's machine-generated objects, not
// a general parser. JWS bodies are produced by composing these builders with
// userland/lib/jose.swift.

// MARK: - string-literal helper

private func a(_ s: StaticString) -> [UInt8] {
    var out = [UInt8]()
    s.withUTF8Buffer { bp in for b in bp { out.append(b) } }
    return out
}

private func eqASCIICaseless(_ x: [UInt8], _ y: [UInt8]) -> Bool {
    if x.count != y.count { return false }
    for i in 0..<x.count {
        var a = x[i], b = y[i]
        if a >= 0x41 && a <= 0x5A { a += 32 }
        if b >= 0x41 && b <= 0x5A { b += 32 }
        if a != b { return false }
    }
    return true
}

// MARK: - HTTP/1.1 response parsing

struct HTTPResponse {
    var status: Int
    var headers: [(name: [UInt8], value: [UInt8])]
    var body: [UInt8]
}

private func findSeq(_ hay: [UInt8], _ needle: [UInt8], _ from: Int) -> Int {
    if needle.isEmpty || needle.count > hay.count { return -1 }
    var i = from
    while i + needle.count <= hay.count {
        var j = 0
        while j < needle.count && hay[i + j] == needle[j] { j += 1 }
        if j == needle.count { return i }
        i += 1
    }
    return -1
}

/// Parse a complete HTTP/1.1 response buffer. The body is taken as Content-Length
/// bytes when that header is present, otherwise everything after the headers.
func parseHTTPResponse(_ data: [UInt8]) -> HTTPResponse? {
    let sep = findSeq(data, a("\r\n\r\n"), 0)
    if sep < 0 { return nil }
    let head = Array(data[0..<sep])

    // status line: "HTTP/1.1 NNN ..."
    let firstEOL = findSeq(head, a("\r\n"), 0)
    let statusLine = firstEOL < 0 ? head : Array(head[0..<firstEOL])
    var sp = 0
    while sp < statusLine.count && statusLine[sp] != 0x20 { sp += 1 }
    sp += 1
    var status = 0
    var k = sp
    while k < statusLine.count && statusLine[k] >= 0x30 && statusLine[k] <= 0x39 {
        status = status * 10 + Int(statusLine[k] - 0x30)
        k += 1
    }
    if status == 0 { return nil }

    // header lines
    var headers: [(name: [UInt8], value: [UInt8])] = []
    var lineStart = firstEOL < 0 ? head.count : firstEOL + 2
    while lineStart < head.count {
        let eol = findSeq(head, a("\r\n"), lineStart)
        let lineEnd = eol < 0 ? head.count : eol
        let line = Array(head[lineStart..<lineEnd])
        if let colon = line.firstIndex(of: 0x3A) {
            var name = Array(line[0..<colon])
            var vi = colon + 1
            while vi < line.count && (line[vi] == 0x20 || line[vi] == 0x09) { vi += 1 }
            let value = Array(line[vi...])
            // trim trailing spaces from name (rare)
            while let last = name.last, last == 0x20 { name.removeLast() }
            headers.append((name: name, value: value))
        }
        if eol < 0 { break }
        lineStart = eol + 2
    }

    var body = Array(data[(sep + 4)...])
    // honor Content-Length if present and shorter
    for h in headers where eqASCIICaseless(h.name, a("Content-Length")) {
        var n = 0
        for c in h.value where c >= 0x30 && c <= 0x39 { n = n * 10 + Int(c - 0x30) }
        if n <= body.count { body = Array(body[0..<n]) }
    }
    return HTTPResponse(status: status, headers: headers, body: body)
}

/// First header value matching `name` (case-insensitive), as a String.
func httpHeader(_ resp: HTTPResponse, _ name: StaticString) -> String? {
    let want = a(name)
    for h in resp.headers where eqASCIICaseless(h.name, want) {
        return String(decoding: h.value, as: UTF8.self)
    }
    return nil
}

// MARK: - minimal JSON reader (structural, for ACME objects)

private func jsWS(_ j: [UInt8], _ i: Int) -> Int {
    var k = i
    while k < j.count && (j[k] == 0x20 || j[k] == 0x09 || j[k] == 0x0A || j[k] == 0x0D) { k += 1 }
    return k
}

/// Index just past a JSON string that starts at `i` (j[i] == '"').
private func jsEndString(_ j: [UInt8], _ i: Int) -> Int {
    var k = i + 1
    while k < j.count {
        if j[k] == 0x5C { k += 2; continue }   // backslash escape
        if j[k] == 0x22 { return k + 1 }
        k += 1
    }
    return k
}

/// Index just past a {...} or [...] starting at `i`.
private func jsEndBracket(_ j: [UInt8], _ i: Int, _ open: UInt8, _ close: UInt8) -> Int {
    var depth = 0
    var k = i
    while k < j.count {
        let c = j[k]
        if c == 0x22 { k = jsEndString(j, k); continue }
        if c == open { depth += 1 }
        else if c == close { depth -= 1; if depth == 0 { return k + 1 } }
        k += 1
    }
    return k
}

/// Index just past the JSON value starting at `i`.
private func jsEndValue(_ j: [UInt8], _ i: Int) -> Int {
    if i >= j.count { return i }
    let c = j[i]
    if c == 0x22 { return jsEndString(j, i) }
    if c == 0x7B { return jsEndBracket(j, i, 0x7B, 0x7D) }
    if c == 0x5B { return jsEndBracket(j, i, 0x5B, 0x5D) }
    var k = i
    while k < j.count && j[k] != 0x2C && j[k] != 0x7D && j[k] != 0x5D
          && j[k] != 0x20 && j[k] != 0x09 && j[k] != 0x0A && j[k] != 0x0D { k += 1 }
    return k
}

/// Decode a JSON string token (j[i] == '"') into its bytes; handles the common
/// escapes (\" \\ \/ \n \t \r \b \f). \uXXXX is passed through as '?'.
private func jsString(_ j: [UInt8], _ i: Int) -> [UInt8] {
    var out = [UInt8]()
    var k = i + 1
    while k < j.count {
        let c = j[k]
        if c == 0x22 { break }
        if c == 0x5C && k + 1 < j.count {
            let e = j[k + 1]
            switch e {
            case 0x22, 0x5C, 0x2F: out.append(e)
            case 0x6E: out.append(0x0A)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x75: out.append(0x3F); k += 4   // \uXXXX -> '?'
            default: out.append(e)
            }
            k += 2
            continue
        }
        out.append(c)
        k += 1
    }
    return out
}

/// Raw value range [start,end) for `key` in the object beginning at `objStart`.
private func jsMember(_ j: [UInt8], _ objStart: Int, _ key: [UInt8]) -> (Int, Int)? {
    var i = jsWS(j, objStart)
    if i >= j.count || j[i] != 0x7B { return nil }
    i = jsWS(j, i + 1)
    if i < j.count && j[i] == 0x7D { return nil }
    while i < j.count {
        if j[i] != 0x22 { return nil }
        let name = jsString(j, i)
        i = jsWS(j, jsEndString(j, i))
        if i >= j.count || j[i] != 0x3A { return nil }
        i = jsWS(j, i + 1)
        let vStart = i
        let vEnd = jsEndValue(j, i)
        if name == key { return (vStart, vEnd) }
        i = jsWS(j, vEnd)
        if i < j.count && j[i] == 0x2C { i = jsWS(j, i + 1); continue }
        return nil
    }
    return nil
}

/// String value of a top-level object member, or nil.
private func jsMemberString(_ j: [UInt8], _ objStart: Int, _ key: StaticString) -> String? {
    guard let (s, _) = jsMember(j, objStart, a(key)), j[s] == 0x22 else { return nil }
    return String(decoding: jsString(j, s), as: UTF8.self)
}

/// Element value ranges of a JSON array starting at `arrStart` (j[arrStart]=='[').
private func jsArrayElements(_ j: [UInt8], _ arrStart: Int) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var i = jsWS(j, arrStart)
    if i >= j.count || j[i] != 0x5B { return out }
    i = jsWS(j, i + 1)
    if i < j.count && j[i] == 0x5D { return out }
    while i < j.count {
        let s = i
        let e = jsEndValue(j, i)
        out.append((s, e))
        i = jsWS(j, e)
        if i < j.count && j[i] == 0x2C { i = jsWS(j, i + 1); continue }
        break
    }
    return out
}

// MARK: - ACME object accessors

struct ACMEDirectory { var newNonce: String; var newAccount: String; var newOrder: String }

func parseDirectory(_ body: [UInt8]) -> ACMEDirectory? {
    guard let n = jsMemberString(body, 0, "newNonce"),
          let acc = jsMemberString(body, 0, "newAccount"),
          let ord = jsMemberString(body, 0, "newOrder") else { return nil }
    return ACMEDirectory(newNonce: n, newAccount: acc, newOrder: ord)
}

struct ACMEOrder {
    var status: String
    var finalize: String
    var certificate: String?
    var authorizations: [String]
}

func parseOrder(_ body: [UInt8]) -> ACMEOrder? {
    guard let status = jsMemberString(body, 0, "status"),
          let finalize = jsMemberString(body, 0, "finalize") else { return nil }
    var auths: [String] = []
    if let (s, _) = jsMember(body, 0, a("authorizations")) {
        for (es, _) in jsArrayElements(body, s) where body[es] == 0x22 {
            auths.append(String(decoding: jsString(body, es), as: UTF8.self))
        }
    }
    let cert = jsMemberString(body, 0, "certificate")
    return ACMEOrder(status: status, finalize: finalize, certificate: cert, authorizations: auths)
}

struct ACMEChallenge { var type: String; var url: String; var token: String; var status: String }

struct ACMEAuthorization { var status: String; var challenges: [ACMEChallenge] }

func parseAuthorization(_ body: [UInt8]) -> ACMEAuthorization? {
    guard let status = jsMemberString(body, 0, "status") else { return nil }
    var challenges: [ACMEChallenge] = []
    if let (s, _) = jsMember(body, 0, a("challenges")) {
        for (es, _) in jsArrayElements(body, s) where body[es] == 0x7B {
            let t = jsMemberString(body, es, "type") ?? ""
            let u = jsMemberString(body, es, "url") ?? ""
            let tok = jsMemberString(body, es, "token") ?? ""
            let st = jsMemberString(body, es, "status") ?? ""
            challenges.append(ACMEChallenge(type: t, url: u, token: tok, status: st))
        }
    }
    return ACMEAuthorization(status: status, challenges: challenges)
}

/// Compare a String to an ASCII literal by raw UTF-8 bytes. Avoids String's
/// Unicode-normalizing `==`, which pulls normalization tables absent from the
/// freestanding userland link.
func acmeEq(_ s: String, _ lit: StaticString) -> Bool {
    var lb = [UInt8]()
    lit.withUTF8Buffer { bp in for b in bp { lb.append(b) } }
    return Array(s.utf8) == lb
}

/// The http-01 challenge of an authorization, if any.
func httpChallenge(_ authz: ACMEAuthorization) -> ACMEChallenge? {
    for c in authz.challenges where acmeEq(c.type, "http-01") { return c }
    return nil
}

// MARK: - request builders (protected headers + payloads)

private func quoted(_ s: [UInt8]) -> [UInt8] {
    // ACME nonces/URLs/kids contain no JSON-special characters.
    var o: [UInt8] = [0x22]; o += s; o.append(0x22); return o
}

/// Protected header for a JWS keyed by the embedded JWK (newAccount and the
/// initial nonce-bearing requests): {"alg":"ES256","jwk":...,"nonce":..,"url":..}
func acmeProtectedJWK(nonce: String, url: String, pubX: [UInt8], pubY: [UInt8]) -> [UInt8] {
    var o = a("{\"alg\":\"ES256\",\"jwk\":")
    o += jwkES256JSON(pubX, pubY)
    o += a(",\"nonce\":")
    o += quoted(Array(nonce.utf8))
    o += a(",\"url\":")
    o += quoted(Array(url.utf8))
    o.append(0x7D)
    return o
}

/// Protected header for a JWS keyed by the account URL (every request after
/// newAccount): {"alg":"ES256","kid":..,"nonce":..,"url":..}
func acmeProtectedKID(nonce: String, url: String, kid: String) -> [UInt8] {
    var o = a("{\"alg\":\"ES256\",\"kid\":")
    o += quoted(Array(kid.utf8))
    o += a(",\"nonce\":")
    o += quoted(Array(nonce.utf8))
    o += a(",\"url\":")
    o += quoted(Array(url.utf8))
    o.append(0x7D)
    return o
}

func acmeNewAccountPayload() -> [UInt8] { a("{\"termsOfServiceAgreed\":true}") }

func acmeNewOrderPayload(dnsNames: [String]) -> [UInt8] {
    var o = a("{\"identifiers\":[")
    var first = true
    for d in dnsNames {
        if !first { o.append(0x2C) }
        first = false
        o += a("{\"type\":\"dns\",\"value\":")
        o += quoted(Array(d.utf8))
        o.append(0x7D)
    }
    o += a("]}")
    return o
}

func acmeFinalizePayload(csrDER: [UInt8]) -> [UInt8] {
    var o = a("{\"csr\":")
    o += quoted(base64urlEncode(csrDER))
    o.append(0x7D)
    return o
}

/// Payload to tell the server a challenge is ready: an empty JSON object.
func acmeChallengeReadyPayload() -> [UInt8] { a("{}") }

/// POST-as-GET uses an empty payload (signed protected header, no payload).
func acmePostAsGetPayload() -> [UInt8] { [] }
