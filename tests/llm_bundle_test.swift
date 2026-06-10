// SPDX-License-Identifier: Apache-2.0
//
// llm_bundle_test.swift — host unit test for userland/lib/modelbundle.swift
// (I5): manifest TOML-subset parsing, payload integrity verification, and the
// newest-first generation policy. Compiled with the host Swift toolchain
// against the same pure sources /bin/llmd links (modelbundle.swift +
// kernel/crypto/sha256.swift). Mirrors tests/llm_engine_test.swift in style.

import Foundation

@main
struct LLMBundleTest {
    static var failed = false

    static func check(_ cond: Bool, _ msg: String) {
        if !cond {
            FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
            failed = true
        }
    }

    static func parse(_ s: String) -> ModelManifest? {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBytes { modelManifestParse($0) }
    }

    static func hexOf(_ payload: [UInt8]) -> String {
        var hex = [UInt8](repeating: 0, count: 64)
        payload.withUnsafeBytes { raw in
            hex.withUnsafeMutableBytes { out in
                sha256Hex(raw.baseAddress!, payload.count, out.baseAddress!)
            }
        }
        return String(decoding: hex, as: UTF8.self)
    }

    static func manifest(_ modelPayload: [UInt8], _ tokPayload: [UInt8],
                         gen: Int = 1, modelSize: Int? = nil) -> String {
        return """
        # comment line
        name = "demo"
        generation = \(gen)
        format = "llama2c"

        [file.model]
        path = "model.bin"
        sha256 = "\(hexOf(modelPayload))"
        size = \(modelSize ?? modelPayload.count)

        [file.tokenizer]
        path = "tokenizer.bin"
        sha256 = "\(hexOf(tokPayload))"
        size = \(tokPayload.count)
        """
    }

    static func main() {
        let model: [UInt8] = Array("fake model weights payload".utf8)
        let tok: [UInt8] = Array("fake tokenizer payload".utf8)

        // 1. A good manifest parses with all fields.
        guard let m = parse(manifest(model, tok, gen: 3)) else {
            check(false, "good manifest did not parse"); report()
        }
        check(m.name == "demo" && m.generation == 3 && m.format == "llama2c",
              "top-level fields wrong: \(m.name)/\(m.generation)/\(m.format)")
        check(m.model.path == "model.bin" && m.model.size == model.count,
              "model entry wrong")
        check(m.tokenizer.path == "tokenizer.bin" && m.tokenizer.size == tok.count,
              "tokenizer entry wrong")

        // 2. Verification passes on intact payloads.
        model.withUnsafeBytes { raw in
            check(modelBundleVerify(m.model, raw.baseAddress!, raw.count),
                  "verify rejected an intact payload")
        }
        // Uppercase hex in the manifest must also verify (case-insensitive).
        var upper = m.model
        upper.sha256 = upper.sha256.uppercased()
        model.withUnsafeBytes { raw in
            check(modelBundleVerify(upper, raw.baseAddress!, raw.count),
                  "verify rejected uppercase hex")
        }

        // 3. A flipped byte fails the hash check.
        var corrupt = model
        corrupt[0] ^= 0xFF
        corrupt.withUnsafeBytes { raw in
            check(!modelBundleVerify(m.model, raw.baseAddress!, raw.count),
                  "verify accepted a corrupted payload")
        }

        // 4. A size mismatch fails fast (the cheap pre-hash check).
        guard let mShort = parse(manifest(model, tok, modelSize: model.count + 7)) else {
            check(false, "size-mismatch manifest did not parse"); report()
        }
        model.withUnsafeBytes { raw in
            check(!modelBundleVerify(mShort.model, raw.baseAddress!, raw.count),
                  "verify accepted a size mismatch")
        }

        // 5. Malformed manifests are rejected.
        check(parse("name = \"x\"\ngeneration = 1\n") == nil,
              "manifest missing [file.*] tables parsed")
        check(parse("name = \"unterminated\n") == nil, "unterminated string parsed")
        check(parse("[file.model\npath = \"m\"\n") == nil, "unterminated table parsed")
        // Unknown tables/keys are tolerated (forward compatibility).
        let extra = manifest(model, tok) + "\n[signature]\nalgo = \"none\"\nfuture = 1\n"
        check(parse(extra) != nil, "unknown [signature] table broke the parse")

        // 6. Newest-first generation policy.
        let order = modelGenerationsNewestFirst([1, 7, 3, 2])
        check(order == [7, 3, 2, 1], "generation order wrong: \(order)")
        check(modelGenerationsNewestFirst([]) == [], "empty generations mishandled")

        // 7. I7 signature plumbing: the [signature] table parses into
        // signatureHex, the signed range stops at the table header line, and
        // the hex decoder round-trips / rejects malformed input.
        let sigHex = String(repeating: "ab", count: 64)
        let body = manifest(model, tok) + "\n"
        let signed = body + "[signature]\nalgo = \"ed25519\"\nsig = \"\(sigHex)\"\n"
        if let sm = parse(signed) {
            check(sm.signatureHex == sigHex, "signatureHex not parsed")
        } else {
            check(false, "signed manifest did not parse")
        }
        let signedBytes = Array(signed.utf8)
        let range = signedBytes.withUnsafeBytes { modelManifestSignedRange($0) }
        check(range == body.utf8.count, "signed range wrong: \(range) != \(body.utf8.count)")
        let unsignedBytes = Array(body.utf8)
        let fullRange = unsignedBytes.withUnsafeBytes { modelManifestSignedRange($0) }
        check(fullRange == unsignedBytes.count, "unsigned range should cover the whole file")
        check(modelSignatureDecode(sigHex) == [UInt8](repeating: 0xab, count: 64),
              "hex decode wrong")
        check(modelSignatureDecode("zz" + String(sigHex.dropFirst(2))) == nil,
              "non-hex accepted")
        check(modelSignatureDecode("abcd") == nil, "short hex accepted")

        // 8. I8 streaming SHA-256 must agree with the one-shot for sizes that
        // exercise the tail buffer (empty, sub-block, block-spanning, and a
        // multi-chunk update pattern like the kernel's 4 KiB verify loop).
        for size in [0, 1, 55, 56, 64, 65, 4096, 4097, 13000] {
            var data = [UInt8](repeating: 0, count: size)
            for i in 0..<size { data[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
            var oneShot = [UInt8](repeating: 0, count: 32)
            data.withUnsafeBytes { raw in
                oneShot.withUnsafeMutableBytes { out in
                    sha256(raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                           size, out.baseAddress!)
                }
            }
            var stream = Sha256Stream()
            var off = 0
            while off < size {                       // 4 KiB chunks, like the kernel
                let chunk = min(4096, size - off)
                data.withUnsafeBytes { raw in
                    stream.update(raw.baseAddress! + off, chunk)
                }
                off += chunk
            }
            var streamed = [UInt8](repeating: 0, count: 32)
            streamed.withUnsafeMutableBytes { stream.final($0.baseAddress!) }
            check(oneShot == streamed, "streaming sha256 diverged at size \(size)")
        }

        report()
    }

    static func report() -> Never {
        if failed {
            FileHandle.standardError.write(Data("llm_bundle_test: FAILURES\n".utf8))
            exit(1)
        }
        print("llm_bundle_test: PASS (manifest parse + sha256 verify + generation policy)")
        exit(0)
    }
}
