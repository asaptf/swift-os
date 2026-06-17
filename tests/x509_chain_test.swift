// SPDX-License-Identifier: Apache-2.0
//
// x509_chain_test.swift — host unit test for the V2a chain/host/date validation
// in userland/lib/x509_verify.swift: epoch→YYYYMMDDHHMMSS conversion, SAN
// hostname matching (incl. wildcard), and x509VerifyChain anchoring a leaf to a
// trusted root with validity-window and trust-anchor checks.

import Foundation

@main
struct X509ChainTest {
    static var failed = false
    static func check(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); failed = true }
    }
    static func b64d(_ s: String) -> [UInt8] {
        func v(_ c: UInt8) -> Int {
            if c >= 65 && c <= 90 { return Int(c - 65) }
            if c >= 97 && c <= 122 { return Int(c - 97 + 26) }
            if c >= 48 && c <= 57 { return Int(c - 48 + 52) }
            if c == 43 { return 62 }; if c == 47 { return 63 }; return -1
        }
        var acc = 0, bits = 0, out = [UInt8]()
        for c in s.utf8 { if c == 61 { break }; let d = v(c); if d < 0 { continue }
            acc = (acc << 6) | d; bits += 6
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> bits) & 0xff)) } }
        return out
    }

    static let EC_LEAF = "MIIBrDCCAVOgAwIBAgIUOEQrJemUPH9qhLcmZHKYlSiZc7QwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPU3dpZnRPUyBUZXN0IENBMCAXDTI2MDYxNzEzMTk0OFoYDzIxMjYwNTI0MTMxOTQ4WjAXMRUwEwYDVQQDDAxzaXRlLmV4YW1wbGUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQNuCe3Un409foKM3WDzIPH8atQ56WxrwYTipFdLN547s/y7CZITkwX2xJ6yiYu7iDNMxUAPO/WGZ5w9Od9nttTo3gwdjAJBgNVHRMEAjAAMCkGA1UdEQQiMCCCDHNpdGUuZXhhbXBsZYIQd3d3LnNpdGUuZXhhbXBsZTAdBgNVHQ4EFgQUurdCi4PloX/LPfOSyTSZlgwlVl0wHwYDVR0jBBgwFoAUstY09DjYBaguWFbrJWtz6Y6XTPIwCgYIKoZIzj0EAwIDRwAwRAIgI720Exch3spkkPPvD0Nv7qpyo49vU/Q1VN2ih0+BEEkCIH7eXbOiYkuKUIou44ey7/aejgvoFUPll3bwSfKk6K51"
    static let EC_CA = "MIIBjDCCATGgAwIBAgIUS9nX08rUJxLEEq3ZUSmErvoBTrUwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPU3dpZnRPUyBUZXN0IENBMCAXDTI2MDYxNzEzMTk0OFoYDzIxMjYwNTI0MTMxOTQ4WjAaMRgwFgYDVQQDDA9Td2lmdE9TIFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARSzWLEZqdSJdrPzOzQp4Yzb1RqIWPsz6VT6c5Fg3CB+mNAvMuFis0OXHyqH4NhFuX+rbkfl0nRODtZJOCVAwwXo1MwUTAdBgNVHQ4EFgQUstY09DjYBaguWFbrJWtz6Y6XTPIwHwYDVR0jBBgwFoAUstY09DjYBaguWFbrJWtz6Y6XTPIwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAqvEpOjUNmTXRZygu9IbMeUEiE1whTqRdko4JgWiPdB0CIQCaLFJFCcolHDuMcPiGJCFD8+Q0dP4f1g3WJeW/St9cjw=="
    static let RSA_CA = "MIIDHzCCAgegAwIBAgIUX0WkDYzPQG0OXJjsPUTbej9FLLIwDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTU3dpZnRPUyBSU0EgVGVzdCBDQTAgFw0yNjA2MTcxNDI3NTZaGA8yMTI2MDUyNDE0Mjc1NlowHjEcMBoGA1UEAwwTU3dpZnRPUyBSU0EgVGVzdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ9IC7vUgkyW4g8qSh8IjuzvpAhu95dxnILtCRbh7hixBeICSQeT0xFC+BaHcNKceSpJ7ULPrYOYe7DEXw0PXJ5/LyFVph4jBrVP866neUgNE5EdFQRqglzCbSxKm6eMJcdtkX/DFippnE5/Zi0GKW7UEV1OJMObfpFgnUwCbQgH7N5iDj/Nk9S/UhZDmp07GNY9TvwUkzy+aYEdT4Fai2AJPMTMwfieXl4DJqn+J+vHI4KRFQPp/xVGgHsCCZa092z/slmq6xjrIHlN+37Y8jRjov/gwEvfEYltQ152iskbSWpUDV9eKDq71McIjNxAXhEezWp2+VRDXN1wiwgdMBsCAwEAAaNTMFEwHQYDVR0OBBYEFAzMUhWHyLl3HFRKpd6loKXVMolYMB8GA1UdIwQYMBaAFAzMUhWHyLl3HFRKpd6loKXVMolYMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAHLkdnUXrisGzxsZJTJAKNMgtYK0xyGWpZUwxmCdJSpa+O1Lb2EureKK7+yCYfPifpPOX8bUfDEu/mftYFulkQpzsfN05AtjTRUcntjFR7I4T5hx5aaPogHISEfZG2cU/sbSgPB8wHcGpDhdv4n4sOYA30vBAKmgdGKszrJzzoKfAbollGL2G2NqvfTLlOTKAvbAEyDCzcWppifq2tK7gfYgfjwnSVc5VqZc8KvwuJID6wSeVEpuRYD3INMBZu8Je6CF01+og5cSLdzMZf+m/M1I6f+EcQaAVh+b3Ae2GI9hotoDyvnVD6GZdg208oDvCKgza9iSk9NjQpb/z6osph0="
    static let RSA_LEAF = "MIIDKTCCAhGgAwIBAgIUC3atKwc12+yMLoMNdoI+i+og8yswDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTU3dpZnRPUyBSU0EgVGVzdCBDQTAgFw0yNjA2MTcxNDI3NTZaGA8yMTI2MDUyNDE0Mjc1NlowFjEUMBIGA1UEAwwLcnNhLmV4YW1wbGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCtfdlxxKP+FctLYmX6wYH2s2FPt26v2UbrullJLZ4AqrfwSpUUR5qsZT6mSqBjg/SwGKS1H9RnIor/MQ3W8snHm28nlOJ4kVYAjBVuktrjnjhrt+DlGxkKBnQ/rUPoWo7lGSRiSSWebFzYLNDiqzgb6VNJFQ+Advx0k3jNx6l31aUSSZ+QLHhEIKX8ixHU+U5/i3m51zbtH3j6A2wWZ0toHpcvgg6kpx3oZjm65tbS6fvg0Ducxwe95dsiKiFVUhMfq9lTrTnXe62YOxQ1zJuB8fHz97aIYSC+R+RO0lJMe4j2ru4PSyso/BaC8SLWL5dKFnPUyELFrY/hOW4GmpK1AgMBAAGjZTBjMAkGA1UdEwQCMAAwFgYDVR0RBA8wDYILcnNhLmV4YW1wbGUwHQYDVR0OBBYEFDsixXpzjaC5mhDuHVUPFGQx8ZI0MB8GA1UdIwQYMBaAFAzMUhWHyLl3HFRKpd6loKXVMolYMA0GCSqGSIb3DQEBCwUAA4IBAQABwxEA4udTetNIp7orAIe654z/qR+Yf+HNARf5YsGsNCBOvnd0cSLy2+ARusYLlfEB4Bz4HDezlT/OsWqu1ru040i9cngynxVjkBRe+njuYUqQ90Q5ioPVO3v2/LySLaxJZ6YWF03+KL76pfpZfCPv7wMnsxgfZE9jThcPsZgMXTm8lUbcTlcMuDU9mBKEqjxkPmZyWDTXopYyBpvgGnFkCSrXz56lwd3yTLSTXO/C63cezrZZT8OqqkQb/92puaVHsDy2lQIpJoXykFamn/C7QS4ZGtbuYc3l1WIO+qCyuSh/6Tas9HEuqC8yV0++QMyr4tZavSHvzPJTvewq+n82"

    static func main() {
        // ---- 1. epoch conversion ----
        check(unixToYYYYMMDDHHMMSS(1700000000) == 20231114221320, "epoch 1700000000 (got \(unixToYYYYMMDDHHMMSS(1700000000)))")
        check(unixToYYYYMMDDHHMMSS(0) == 19700101000000, "epoch 0")

        // ---- 2. hostname / SAN matching ----
        check(hostnameMatchesSAN("site.example", ["site.example", "www.site.example"]), "exact SAN match")
        check(hostnameMatchesSAN("WWW.SITE.EXAMPLE", ["www.site.example"]), "case-insensitive match")
        check(!hostnameMatchesSAN("evil.example", ["site.example"]), "non-matching host rejected")
        check(hostnameMatchesSAN("a.example.com", ["*.example.com"]), "wildcard matches one label")
        check(!hostnameMatchesSAN("a.b.example.com", ["*.example.com"]), "wildcard does not match two labels")
        check(!hostnameMatchesSAN("example.com", ["*.example.com"]), "wildcard does not match apex")

        // ---- 3. chain validation (now within the 2026→2126 fixture window) ----
        let now: UInt64 = 20300101000000
        guard let ecLeaf = parseX509(b64d(EC_LEAF)), let ecCa = parseX509(b64d(EC_CA)),
              let rsaLeaf = parseX509(b64d(RSA_LEAF)), let rsaCa = parseX509(b64d(RSA_CA)) else {
            FileHandle.standardError.write(Data("FAIL: fixture parse\n".utf8)); exit(1)
        }

        check(x509VerifyChain(leaf: ecLeaf, intermediates: [], roots: [ecCa], hostname: "site.example", now: now),
              "ECDSA leaf chains to trusted CA")
        check(x509VerifyChain(leaf: rsaLeaf, intermediates: [], roots: [rsaCa], hostname: "rsa.example", now: now),
              "RSA leaf chains to trusted CA")

        check(!x509VerifyChain(leaf: ecLeaf, intermediates: [], roots: [ecCa], hostname: "evil.example", now: now),
              "wrong hostname rejected")
        check(!x509VerifyChain(leaf: ecLeaf, intermediates: [], roots: [], hostname: "site.example", now: now),
              "empty trust store rejected")
        check(!x509VerifyChain(leaf: ecLeaf, intermediates: [], roots: [rsaCa], hostname: "site.example", now: now),
              "untrusted CA rejected")
        check(!x509VerifyChain(leaf: ecLeaf, intermediates: [], roots: [ecCa], hostname: "site.example", now: 21300101000000),
              "expired (now after notAfter) rejected")
        check(!x509VerifyChain(leaf: ecLeaf, intermediates: [], roots: [ecCa], hostname: "site.example", now: 20200101000000),
              "not-yet-valid (now before notBefore) rejected")

        // ---- IP-SAN: a self-signed CA:TRUE cert with IP:10.0.2.2 + DNS:site.example ----
        let ipsanB64 = "MIIBpjCCAUygAwIBAgIUdEXFkHfRMNu3lv7ux0lu016OzB0wCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNaXBzYW4uZXhhbXBsZTAgFw0yNjA2MTcxNTUzNTBaGA8yMTI2MDUyNDE1NTM1MFowGDEWMBQGA1UEAwwNaXBzYW4uZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABK4gJtEE8NI22QNGfrctc2ytPNKQa4k+bBJM8+/mW0a9CuIqzVXINL395wpqTd2hmiY4NNpCpaOY/Ii4Cvj+p1qjcjBwMB0GA1UdDgQWBBTH0RL9TnlYbtHaRn2V2yMARAvFIDAfBgNVHSMEGDAWgBTH0RL9TnlYbtHaRn2V2yMARAvFIDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdEQQWMBSCDHNpdGUuZXhhbXBsZYcECgACAjAKBggqhkjOPQQDAgNIADBFAiAFaqYgJCGmehj6qNVUzWlIYxOGi2xwoImqkWSyJ0mBDgIhALCDurmgBhePXoMYU46tBhVbS94KDrgPOUE1kP8fQm8q"
        guard let ipc = parseX509(b64d(ipsanB64)) else {
            FileHandle.standardError.write(Data("FAIL: ip-san parse\n".utf8)); exit(1)
        }
        check(x509VerifyChain(leaf: ipc, intermediates: [], roots: [ipc], hostname: "10.0.2.2", now: now),
              "IP host matches iPAddress SAN")
        check(x509VerifyChain(leaf: ipc, intermediates: [], roots: [ipc], hostname: "site.example", now: now),
              "DNS host matches dNSName SAN on the same cert")
        check(!x509VerifyChain(leaf: ipc, intermediates: [], roots: [ipc], hostname: "10.0.2.3", now: now),
              "wrong IP rejected")

        if failed {
            FileHandle.standardError.write(Data("x509_chain_test: FAILED\n".utf8)); exit(1)
        }
        print("x509_chain_test: all cases OK")
    }
}
