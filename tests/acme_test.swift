// SPDX-License-Identifier: Apache-2.0
//
// acme_test.swift — host unit test for userland/lib/acme.swift (A2a: the ACME
// message layer). Feeds canned Pebble-shaped HTTP/JSON responses and asserts
// the parsers extract the right fields, then composes the request builders into
// real flattened JWS (with the RFC 6979 §A.2.5 key) and verifies the signature
// and decoded contents. No network — the TCP+TLS transport is exercised
// separately against Pebble.

import Foundation

@main
struct ACMETest {
    static var failed = false
    static func check(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); failed = true }
    }
    static func hex(_ s: String) -> [UInt8] {
        let c = Array(s.utf8); var o = [UInt8](); var i = 0
        func n(_ b: UInt8) -> UInt8 {
            if b >= 0x30 && b <= 0x39 { return b - 0x30 }
            if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
            return b - 0x41 + 10
        }
        while i + 1 < c.count { o.append((n(c[i]) << 4) | n(c[i + 1])); i += 2 }
        return o
    }
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func str(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    static func sha(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { dp in out.withUnsafeMutableBytes { op in
            sha256(dp.baseAddress!, data.count, op.baseAddress!) } }
        return out
    }
    static func verifySig(_ px: [UInt8], _ py: [UInt8], _ h: [UInt8], _ r: [UInt8], _ s: [UInt8]) -> Bool {
        var ok = false
        px.withUnsafeBytes { xp in py.withUnsafeBytes { yp in h.withUnsafeBytes { hp in
        r.withUnsafeBytes { rp in s.withUnsafeBytes { sp in
            ok = p256Verify(xp.baseAddress!, yp.baseAddress!, hp.baseAddress!,
                            rp.baseAddress!, sp.baseAddress!) } } } } }
        return ok
    }
    static func field(_ json: String, _ name: String) -> String {
        guard let r = json.range(of: "\"\(name)\":\"") else { return "" }
        let rest = json[r.upperBound...]
        guard let e = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[rest.startIndex..<e])
    }
    /// Verify a flattened JWS against a public key: returns (protectedJSON, payloadJSON).
    static func checkJWS(_ jws: [UInt8], _ px: [UInt8], _ py: [UInt8], _ label: String) -> (String, String) {
        let s = str(jws)
        let p64 = field(s, "protected"), pl64 = field(s, "payload"), sig64 = field(s, "signature")
        let sig = base64urlDecode(bytes(sig64))!
        check(sig.count == 64, "\(label): sig 64 bytes")
        let r = Array(sig[0..<32]), ss = Array(sig[32..<64])
        let signingInput = bytes(p64 + "." + pl64)
        check(verifySig(px, py, sha(signingInput), r, ss), "\(label): JWS verifies")
        let prot = base64urlDecode(bytes(p64)).map { str($0) } ?? ""
        let pl = base64urlDecode(bytes(pl64)).map { str($0) } ?? ""
        return (prot, pl)
    }

    static func main() {
        let pubX = hex("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6")
        let pubY = hex("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299")
        let priv = hex("C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721")

        // ---- 1. HTTP/1.1 response parsing ---------------------------------
        let dirBody = "{\"keyChange\":\"https://localhost:14000/rollover-account-key\",\"newAccount\":\"https://localhost:14000/sign-me-up\",\"newNonce\":\"https://localhost:14000/nonce-plz\",\"newOrder\":\"https://localhost:14000/order-plz\",\"revokeCert\":\"https://localhost:14000/revoke-cert\"}"
        let raw = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nReplay-Nonce: NONCE_ABC123\r\nLocation: https://localhost:14000/my-account/1\r\nContent-Length: \(Array(dirBody.utf8).count)\r\n\r\n\(dirBody)"
        let resp = parseHTTPResponse(bytes(raw))!
        check(resp.status == 201, "HTTP status 201 (got \(resp.status))")
        check(httpHeader(resp, "Replay-Nonce") == "NONCE_ABC123", "Replay-Nonce header")
        check(httpHeader(resp, "location") == "https://localhost:14000/my-account/1", "Location header (case-insensitive)")
        check(httpHeader(resp, "Content-Type") == "application/json", "Content-Type header")
        check(str(resp.body) == dirBody, "body matches")

        // ---- 2. directory --------------------------------------------------
        let dir = parseDirectory(resp.body)!
        check(dir.newNonce == "https://localhost:14000/nonce-plz", "dir newNonce")
        check(dir.newAccount == "https://localhost:14000/sign-me-up", "dir newAccount")
        check(dir.newOrder == "https://localhost:14000/order-plz", "dir newOrder")

        // ---- 3. order (pending, then valid) -------------------------------
        let orderPending = bytes("{\"status\":\"pending\",\"expires\":\"2026-06-18T00:00:00Z\",\"identifiers\":[{\"type\":\"dns\",\"value\":\"example.com\"}],\"authorizations\":[\"https://localhost:14000/authZ/aaa\",\"https://localhost:14000/authZ/bbb\"],\"finalize\":\"https://localhost:14000/finalize/123\"}")
        let op = parseOrder(orderPending)!
        check(op.status == "pending", "order status pending")
        check(op.finalize == "https://localhost:14000/finalize/123", "order finalize")
        check(op.certificate == nil, "order pending has no certificate")
        check(op.authorizations.count == 2, "order 2 authorizations")
        check(op.authorizations[1] == "https://localhost:14000/authZ/bbb", "order authz[1]")

        let orderValid = bytes("{\"status\":\"valid\",\"finalize\":\"https://localhost:14000/finalize/123\",\"certificate\":\"https://localhost:14000/certZ/xyz\",\"authorizations\":[\"https://localhost:14000/authZ/aaa\"]}")
        let ov = parseOrder(orderValid)!
        check(ov.status == "valid", "order valid status")
        check(ov.certificate == "https://localhost:14000/certZ/xyz", "order certificate url")

        // ---- 4. authorization + http-01 challenge -------------------------
        let authz = bytes("{\"status\":\"pending\",\"identifier\":{\"type\":\"dns\",\"value\":\"example.com\"},\"challenges\":[{\"type\":\"dns-01\",\"url\":\"https://localhost:14000/chalZ/dns\",\"token\":\"DNSTOK\",\"status\":\"pending\"},{\"type\":\"http-01\",\"url\":\"https://localhost:14000/chalZ/http\",\"token\":\"HTTPTOKEN123\",\"status\":\"pending\"}]}")
        let az = parseAuthorization(authz)!
        check(az.status == "pending", "authz status")
        check(az.challenges.count == 2, "authz 2 challenges")
        let hc = httpChallenge(az)!
        check(hc.url == "https://localhost:14000/chalZ/http", "http-01 url")
        check(hc.token == "HTTPTOKEN123", "http-01 token")

        // ---- 5. request builders → real JWS -------------------------------
        // newAccount: protected header carries the JWK.
        let protJWK = acmeProtectedJWK(nonce: "NONCE_ABC123", url: dir.newAccount, pubX: pubX, pubY: pubY)
        let jwsAcc = jwsFlattenedES256(protectedJSON: protJWK, payloadJSON: acmeNewAccountPayload(), priv32: priv)!
        let (protAcc, plAcc) = checkJWS(jwsAcc, pubX, pubY, "newAccount")
        check(protAcc.contains("\"jwk\":") && protAcc.contains("\"alg\":\"ES256\""), "newAccount protected has jwk+alg")
        check(protAcc.contains("\"nonce\":\"NONCE_ABC123\""), "newAccount nonce")
        check(plAcc == "{\"termsOfServiceAgreed\":true}", "newAccount payload (got \(plAcc))")

        // newOrder: protected header keyed by account URL (kid).
        let kid = "https://localhost:14000/my-account/1"
        let protKID = acmeProtectedKID(nonce: "NONCE_XYZ", url: dir.newOrder, kid: kid)
        let jwsOrd = jwsFlattenedES256(protectedJSON: protKID,
                                       payloadJSON: acmeNewOrderPayload(dnsNames: ["example.com", "www.example.com"]),
                                       priv32: priv)!
        let (protOrd, plOrd) = checkJWS(jwsOrd, pubX, pubY, "newOrder")
        check(protOrd.contains("\"kid\":\"\(kid)\"") && !protOrd.contains("\"jwk\""), "newOrder uses kid not jwk")
        check(plOrd == "{\"identifiers\":[{\"type\":\"dns\",\"value\":\"example.com\"},{\"type\":\"dns\",\"value\":\"www.example.com\"}]}", "newOrder payload (got \(plOrd))")

        // finalize: payload carries base64url(CSR DER).
        let csr = acmeCSR(dnsNames: [bytes("example.com")], pubX: pubX, pubY: pubY, priv32: priv)!
        let finPayload = acmeFinalizePayload(csrDER: csr)
        let csrField = field(str(finPayload), "csr")
        check(base64urlDecode(bytes(csrField))! == csr, "finalize payload carries the CSR DER")

        // POST-as-GET is an empty payload.
        check(acmePostAsGetPayload().isEmpty, "POST-as-GET payload is empty")
        let jwsGet = jwsFlattenedES256(protectedJSON: protKID, payloadJSON: acmePostAsGetPayload(), priv32: priv)!
        let (_, plGet) = checkJWS(jwsGet, pubX, pubY, "post-as-get")
        check(plGet == "", "POST-as-GET signed payload is empty string")

        if failed {
            FileHandle.standardError.write(Data("acme_test: FAILED\n".utf8))
            exit(1)
        }
        print("acme_test: all vectors OK")
    }
}
