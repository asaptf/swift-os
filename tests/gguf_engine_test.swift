// SPDX-License-Identifier: Apache-2.0
//
// gguf_engine_test.swift — LM5c host oracle for the GGUF Q4_K/Q6_K engine
// (GGUFLlama in userland/lib/llama2.swift). Loads the real TinyLlama-1.1B-Chat
// Q4_K_M GGUF (`make tinyllama-gguf`) + the Llama-2 tokenizer, runs greedy
// generation, and asserts the config matches TinyLlama and the output is
// coherent. Q4_K_M is a lossier quant than the Q8 path, so this checks meaning
// (the right factual answer) rather than a byte-exact match to the Q8 engine.

import Foundation

@main
struct GGUFEngineTest {
    static func die(_ m: String) -> Never {
        FileHandle.standardError.write(Data("gguf_engine_test: \(m)\n".utf8)); exit(1)
    }
    static func load(_ p: String) -> Data {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p), options: .alwaysMapped) else {
            die("cannot read \(p)")
        }
        return d
    }

    static let cases: [(prompt: String, needle: String, steps: Int)] = [
        ("The capital of France is", "Paris", 16),
        ("The opposite of hot is", "cold", 12),
    ]

    static func main() {
        let md = load("models/tinyllama-q4km.gguf")
        let td = load("models/tinyllama-tokenizer.bin")
        var failed = false
        md.withUnsafeBytes { (mptr: UnsafeRawBufferPointer) in
            td.withUnsafeBytes { (tptr: UnsafeRawBufferPointer) in
                guard let model = GGUFLlama(ggufBytes: mptr.baseAddress!, count: mptr.count) else {
                    die("GGUFLlama init failed")
                }
                let c = model.cfg
                FileHandle.standardError.write(Data("config dim=\(c.dim) layers=\(c.nLayers) heads=\(c.nHeads) kv=\(c.nKVHeads) vocab=\(c.vocabSize) seq=\(c.seqLen)\n".utf8))
                if c.dim != 2048 || c.nLayers != 22 || c.nHeads != 32 || c.nKVHeads != 4 || c.vocabSize != 32000 {
                    failed = true
                    FileHandle.standardError.write(Data("FAIL: unexpected config\n".utf8))
                }
                let tok = LlamaTokenizer(tokenizerBytes: tptr.baseAddress!, vocabSize: c.vocabSize)
                for (prompt, needle, steps) in cases {
                    var out: [UInt8] = []
                    _ = llamaGenerate(model, tok, prompt: prompt, steps: steps) { out.append(contentsOf: $0) }
                    let got = String(decoding: out, as: UTF8.self)
                    if got.contains(needle) {
                        print("gguf_engine_test: \"\(prompt)\" -> coherent (contains \"\(needle)\")")
                    } else {
                        failed = true
                        FileHandle.standardError.write(Data("FAIL: \"\(prompt)\" -> \(got)\n(expected to contain \"\(needle)\")\n".utf8))
                    }
                }
            }
        }
        if failed { die("FAILURES") }
        print("gguf_engine_test: PASS (TinyLlama Q4_K_M GGUF serves coherent text)")
    }
}
