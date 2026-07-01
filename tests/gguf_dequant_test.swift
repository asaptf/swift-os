// SPDX-License-Identifier: Apache-2.0
//
// gguf_dequant_test.swift — LM5b host known-answer test for the Q4_K / Q6_K
// super-block dequantizers in userland/lib/gguf.swift. It reads the real
// TinyLlama Q4_K_M GGUF (`make tinyllama-gguf`), dequantizes the first
// super-block of a Q4_K tensor (blk.0.ffn_gate.weight) and a Q6_K tensor
// (blk.0.attn_v.weight), and asserts the first values match goldens produced
// independently by the official `gguf` Python package's dequantize(). That
// cross-checks our from-scratch ggml-format decode against the reference.

import Foundation

@main
struct GGUFDequantTest {
    // First 12 dequantized floats, from `gguf.quants.dequantize` (Python).
    static let goldenQ4K: [Float] = [
        0.00012397766, 0.0098664761, 0.0098664761, 0.014737725, -0.0096185207, 0.024480224,
        0.00012397766, 0.014737725, 0.029351473, 0.014737725, 0.00012397766, 0.00012397766,
    ]
    static let goldenQ6K: [Float] = [
        0.028381348, 0.0059127808, 0.0, -0.0059127808, 0.0070953369, -0.0082778931,
        0.0070953369, -0.01537323, 0.036659241, -0.0011825562, 0.010643005, -0.014190674,
    ]

    static func die(_ m: String) -> Never {
        FileHandle.standardError.write(Data("gguf_dequant_test: \(m)\n".utf8)); exit(1)
    }

    static func main() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "models/tinyllama-q4km.gguf"),
                                   options: .alwaysMapped) else {
            die("cannot read models/tinyllama-q4km.gguf — run `make tinyllama-gguf`")
        }
        var failed = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            let g = GGUFFile(base: base, count: raw.count)
            guard g.ok else { die("GGUF parse failed") }

            func checkTensor(_ name: StaticString, _ type: GGMLType, _ golden: [Float],
                             _ dequant: (UnsafeRawPointer, UnsafeMutablePointer<Float>) -> Void) {
                guard let t = g.tensor(name) else { failed = true
                    FileHandle.standardError.write(Data("FAIL: tensor not found\n".utf8)); return }
                if t.type != type.rawValue { failed = true
                    FileHandle.standardError.write(Data("FAIL: unexpected ggml type \(t.type)\n".utf8)); return }
                var out = [Float](repeating: 0, count: ggmlQKK)
                out.withUnsafeMutableBufferPointer { ob in
                    dequant(g.tensorData(t), ob.baseAddress!)
                }
                // All finite.
                for v in out where !v.isFinite { failed = true
                    FileHandle.standardError.write(Data("FAIL: non-finite dequant value\n".utf8)); break }
                // First 12 match the reference within a tight epsilon.
                for i in 0..<golden.count {
                    if abs(out[i] - golden[i]) > 1e-6 {
                        failed = true
                        FileHandle.standardError.write(Data(
                            "FAIL: [\(i)] got \(out[i]) want \(golden[i])\n".utf8))
                    }
                }
            }

            checkTensor("blk.0.ffn_gate.weight", .q4_K, goldenQ4K, ggufDequantQ4K)
            checkTensor("blk.0.attn_v.weight",   .q6_K, goldenQ6K, ggufDequantQ6K)
        }
        if failed { die("FAILURES") }
        print("gguf_dequant_test: PASS (Q4_K + Q6_K dequant match the gguf reference)")
    }
}
