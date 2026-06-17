// SPDX-License-Identifier: Apache-2.0
//
// x509_verify_test.swift — host unit test for userland/lib/x509_verify.swift
// (V1 dispatcher). Verifies real openssl CA→leaf signatures both ways: an
// ECDSA-P256 chain (p256 path) and an RSA-2048 chain (rsa path), and rejects a
// tampered TBS and a mismatched issuer key.

import Foundation

@main
struct X509VerifyTest {
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

    // ECDSA P-256 fixtures (same as tests/x509_test.swift).
    static let EC_LEAF = "MIIBrDCCAVOgAwIBAgIUOEQrJemUPH9qhLcmZHKYlSiZc7QwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPU3dpZnRPUyBUZXN0IENBMCAXDTI2MDYxNzEzMTk0OFoYDzIxMjYwNTI0MTMxOTQ4WjAXMRUwEwYDVQQDDAxzaXRlLmV4YW1wbGUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQNuCe3Un409foKM3WDzIPH8atQ56WxrwYTipFdLN547s/y7CZITkwX2xJ6yiYu7iDNMxUAPO/WGZ5w9Od9nttTo3gwdjAJBgNVHRMEAjAAMCkGA1UdEQQiMCCCDHNpdGUuZXhhbXBsZYIQd3d3LnNpdGUuZXhhbXBsZTAdBgNVHQ4EFgQUurdCi4PloX/LPfOSyTSZlgwlVl0wHwYDVR0jBBgwFoAUstY09DjYBaguWFbrJWtz6Y6XTPIwCgYIKoZIzj0EAwIDRwAwRAIgI720Exch3spkkPPvD0Nv7qpyo49vU/Q1VN2ih0+BEEkCIH7eXbOiYkuKUIou44ey7/aejgvoFUPll3bwSfKk6K51"
    static let EC_CA = "MIIBjDCCATGgAwIBAgIUS9nX08rUJxLEEq3ZUSmErvoBTrUwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPU3dpZnRPUyBUZXN0IENBMCAXDTI2MDYxNzEzMTk0OFoYDzIxMjYwNTI0MTMxOTQ4WjAaMRgwFgYDVQQDDA9Td2lmdE9TIFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARSzWLEZqdSJdrPzOzQp4Yzb1RqIWPsz6VT6c5Fg3CB+mNAvMuFis0OXHyqH4NhFuX+rbkfl0nRODtZJOCVAwwXo1MwUTAdBgNVHQ4EFgQUstY09DjYBaguWFbrJWtz6Y6XTPIwHwYDVR0jBBgwFoAUstY09DjYBaguWFbrJWtz6Y6XTPIwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAqvEpOjUNmTXRZygu9IbMeUEiE1whTqRdko4JgWiPdB0CIQCaLFJFCcolHDuMcPiGJCFD8+Q0dP4f1g3WJeW/St9cjw=="

    // RSA-2048 fixtures (sha256WithRSAEncryption chain).
    static let RSA_CA = "MIIDHzCCAgegAwIBAgIUX0WkDYzPQG0OXJjsPUTbej9FLLIwDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTU3dpZnRPUyBSU0EgVGVzdCBDQTAgFw0yNjA2MTcxNDI3NTZaGA8yMTI2MDUyNDE0Mjc1NlowHjEcMBoGA1UEAwwTU3dpZnRPUyBSU0EgVGVzdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ9IC7vUgkyW4g8qSh8IjuzvpAhu95dxnILtCRbh7hixBeICSQeT0xFC+BaHcNKceSpJ7ULPrYOYe7DEXw0PXJ5/LyFVph4jBrVP866neUgNE5EdFQRqglzCbSxKm6eMJcdtkX/DFippnE5/Zi0GKW7UEV1OJMObfpFgnUwCbQgH7N5iDj/Nk9S/UhZDmp07GNY9TvwUkzy+aYEdT4Fai2AJPMTMwfieXl4DJqn+J+vHI4KRFQPp/xVGgHsCCZa092z/slmq6xjrIHlN+37Y8jRjov/gwEvfEYltQ152iskbSWpUDV9eKDq71McIjNxAXhEezWp2+VRDXN1wiwgdMBsCAwEAAaNTMFEwHQYDVR0OBBYEFAzMUhWHyLl3HFRKpd6loKXVMolYMB8GA1UdIwQYMBaAFAzMUhWHyLl3HFRKpd6loKXVMolYMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAHLkdnUXrisGzxsZJTJAKNMgtYK0xyGWpZUwxmCdJSpa+O1Lb2EureKK7+yCYfPifpPOX8bUfDEu/mftYFulkQpzsfN05AtjTRUcntjFR7I4T5hx5aaPogHISEfZG2cU/sbSgPB8wHcGpDhdv4n4sOYA30vBAKmgdGKszrJzzoKfAbollGL2G2NqvfTLlOTKAvbAEyDCzcWppifq2tK7gfYgfjwnSVc5VqZc8KvwuJID6wSeVEpuRYD3INMBZu8Je6CF01+og5cSLdzMZf+m/M1I6f+EcQaAVh+b3Ae2GI9hotoDyvnVD6GZdg208oDvCKgza9iSk9NjQpb/z6osph0="
    static let RSA_LEAF = "MIIDKTCCAhGgAwIBAgIUC3atKwc12+yMLoMNdoI+i+og8yswDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTU3dpZnRPUyBSU0EgVGVzdCBDQTAgFw0yNjA2MTcxNDI3NTZaGA8yMTI2MDUyNDE0Mjc1NlowFjEUMBIGA1UEAwwLcnNhLmV4YW1wbGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCtfdlxxKP+FctLYmX6wYH2s2FPt26v2UbrullJLZ4AqrfwSpUUR5qsZT6mSqBjg/SwGKS1H9RnIor/MQ3W8snHm28nlOJ4kVYAjBVuktrjnjhrt+DlGxkKBnQ/rUPoWo7lGSRiSSWebFzYLNDiqzgb6VNJFQ+Advx0k3jNx6l31aUSSZ+QLHhEIKX8ixHU+U5/i3m51zbtH3j6A2wWZ0toHpcvgg6kpx3oZjm65tbS6fvg0Ducxwe95dsiKiFVUhMfq9lTrTnXe62YOxQ1zJuB8fHz97aIYSC+R+RO0lJMe4j2ru4PSyso/BaC8SLWL5dKFnPUyELFrY/hOW4GmpK1AgMBAAGjZTBjMAkGA1UdEwQCMAAwFgYDVR0RBA8wDYILcnNhLmV4YW1wbGUwHQYDVR0OBBYEFDsixXpzjaC5mhDuHVUPFGQx8ZI0MB8GA1UdIwQYMBaAFAzMUhWHyLl3HFRKpd6loKXVMolYMA0GCSqGSIb3DQEBCwUAA4IBAQABwxEA4udTetNIp7orAIe654z/qR+Yf+HNARf5YsGsNCBOvnd0cSLy2+ARusYLlfEB4Bz4HDezlT/OsWqu1ru040i9cngynxVjkBRe+njuYUqQ90Q5ioPVO3v2/LySLaxJZ6YWF03+KL76pfpZfCPv7wMnsxgfZE9jThcPsZgMXTm8lUbcTlcMuDU9mBKEqjxkPmZyWDTXopYyBpvgGnFkCSrXz56lwd3yTLSTXO/C63cezrZZT8OqqkQb/92puaVHsDy2lQIpJoXykFamn/C7QS4ZGtbuYc3l1WIO+qCyuSh/6Tas9HEuqC8yV0++QMyr4tZavSHvzPJTvewq+n82"

    static func main() {
        guard let ecLeaf = parseX509(b64d(EC_LEAF)), let ecCa = parseX509(b64d(EC_CA)),
              let rsaLeaf = parseX509(b64d(RSA_LEAF)), let rsaCa = parseX509(b64d(RSA_CA)) else {
            FileHandle.standardError.write(Data("FAIL: a fixture did not parse\n".utf8)); exit(1)
        }

        check(x509VerifyChainLink(child: ecLeaf, issuer: ecCa), "ECDSA leaf verifies against its CA")
        check(x509VerifyChainLink(child: rsaLeaf, issuer: rsaCa), "RSA leaf verifies against its CA")

        var tampered = ecLeaf; tampered.tbs[20] ^= 0x01
        check(!x509VerifyChainLink(child: tampered, issuer: ecCa), "tampered ECDSA TBS rejected")

        check(!x509VerifyChainLink(child: ecLeaf, issuer: rsaCa), "ECDSA leaf rejected against wrong (RSA) issuer key")
        check(!x509VerifyChainLink(child: rsaLeaf, issuer: ecCa), "RSA leaf rejected against wrong (EC) issuer key")

        if failed {
            FileHandle.standardError.write(Data("x509_verify_test: FAILED\n".utf8)); exit(1)
        }
        print("x509_verify_test: all chains OK")
    }
}
