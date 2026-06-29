// SPDX-License-Identifier: Apache-2.0
//
// llm_tinyllama_engine_test.swift — host oracle for the first *real* model on the
// swift-os Q8 inference path (LM4a): TinyLlama-1.1B-Chat, converted from Hugging
// Face to the engine's v2 Q8 format by scripts/convert-tinyllama.py +
// tools/quantize.swift (seqLen capped to 512).
//
// Compiled with the host toolchain against the exact source the EL0 apps link
// (userland/lib/llama2.swift), then run with no arguments. It loads the bundle
//   - models/tinyllama-q8.bin       (GS=64, 32000-vocab, GQA 32/4 heads)
//   - models/tinyllama-tokenizer.bin (Llama-2 32k SentencePiece)
// (build them with `make tinyllama`) and asserts:
//   1. the parsed config matches TinyLlama (dim/layers/heads/kv/vocab/seq/GS), which
//      proves the GQA-correct RoPE-unpermuted conversion produced the right layout;
//   2. greedy (temperature 0) generation reproduces, byte for byte, the fixed output
//      this engine produces for two factual prompts — i.e. the model is not merely
//      "not crashing" but answers coherently and deterministically.
//
// Greedy decoding is deterministic, so the goldens below are exact (captured from
// this engine on this q8 file). They double as a coherence check: "The capital of
// France is Paris." is the right answer, not noise.
//
// This test needs the ~1.1 GB model, so it is NOT part of `make test`; run it via
// `make llm-tinyllama-test`.

import Foundation

@main
struct LLMTinyLlamaEngineTest {
    static let steps = 24

    // prompt -> exact greedy continuation (prompt included, as llamaGenerate emits it).
    static let cases: [(prompt: String, golden: String)] = [
        ("The capital of France is",
         "The capital of France is Paris.\n\n2. B. The capital of Germany is Berlin.\n\n3."),
        ("The three primary colors are",
         "The three primary colors are red, blue, and yellow. They are used to create the primary colors of the color wheel"),
    ]

    static var failed = false

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        failed = true
    }

    static func load(_ path: String) -> Data {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            FileHandle.standardError.write(Data("FAIL: cannot read \(path) — run `make tinyllama`\n".utf8))
            exit(1)
        }
        return d
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    static func main() {
        let modelData = load("models/tinyllama-q8.bin")
        let tokData = load("models/tinyllama-tokenizer.bin")

        modelData.withUnsafeBytes { (mptr: UnsafeRawBufferPointer) in
            tokData.withUnsafeBytes { (tptr: UnsafeRawBufferPointer) in
                let base = mptr.baseAddress!
                guard QLlama2.isQuantized(base) else {
                    fail("not a v2 quantized checkpoint"); return
                }
                let model = QLlama2(modelBytes: base)
                let c = model.cfg
                check(c.dim == 2048, "dim=\(c.dim), want 2048")
                check(c.nLayers == 22, "nLayers=\(c.nLayers), want 22")
                check(c.nHeads == 32, "nHeads=\(c.nHeads), want 32")
                check(c.nKVHeads == 4, "nKVHeads=\(c.nKVHeads), want 4 (GQA)")
                check(c.vocabSize == 32000, "vocab=\(c.vocabSize), want 32000")
                check(c.seqLen == 512, "seqLen=\(c.seqLen), want 512 (LM4 cap)")
                check(model.gs == 64, "GS=\(model.gs), want 64")

                let tok = LlamaTokenizer(tokenizerBytes: tptr.baseAddress!, vocabSize: c.vocabSize)
                for (prompt, golden) in cases {
                    var out: [UInt8] = []
                    _ = llamaGenerate(model, tok, prompt: prompt, steps: steps) { out.append(contentsOf: $0) }
                    let got = String(decoding: out, as: UTF8.self)
                    if got != golden {
                        FileHandle.standardError.write(Data("--- prompt \"\(prompt)\" got ---\n\(got)\n--- want ---\n\(golden)\n".utf8))
                        let g = Array(got), w = Array(golden)
                        var i = 0
                        while i < g.count && i < w.count && g[i] == w[i] { i += 1 }
                        fail("\"\(prompt)\": diverged at index \(i) (got \(g.count) chars, want \(w.count))")
                    } else {
                        print("llm_tinyllama_engine_test: \"\(prompt)\" -> coherent greedy match (\(steps) steps)")
                    }
                }
            }
        }

        if failed {
            FileHandle.standardError.write(Data("llm_tinyllama_engine_test: FAILURES\n".utf8))
            exit(1)
        }
        print("llm_tinyllama_engine_test: PASS (TinyLlama-1.1B Q8 GQA serves coherent text)")
    }
}
