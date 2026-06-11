// SPDX-License-Identifier: Apache-2.0
//
// llm_q8_engine_test.swift — host unit test for the Q8_0 quantized inference
// path in userland/lib/llama2.swift (I4).
//
// Compiled with the host Swift toolchain against the same pure source the EL0
// apps link, then run with no arguments. It loads the two quantized
// checkpoints produced by tools/quantize.swift (`make model`):
//   - models/stories260K-q8.bin + models/tok512.bin      (GS=4)
//   - models/stories15M-q8.bin  + models/tokenizer.bin   (GS=32, 32000-vocab)
// and asserts that greedy (temperature 0) generation reproduces, byte for
// byte, the reference llama2.c runq.c output for a fixed prompt. The goldens
// below were produced with upstream runq.c on these exact q8 files:
//   ./runq <model-q8.bin> -z <tokenizer> -t 0 -n 64 -i "Once upon a time"
//
// Mirrors tests/llm_engine_test.swift in style.

import Foundation

@main
struct LLMQ8EngineTest {
    static let prompt = "Once upon a time"
    static let steps = 64

    static let golden260K =
        "Once upon a time, there was a little girl named Lily. She loved to " +
        "play outside in the park. One day, she saw a big, red ball. She " +
        "wanted to play with it, but it was too high.\nLily"

    static let golden15M =
        "Once upon a time, there was a little girl named Lily. She loved to " +
        "play outside in the sunshine. One day, she saw a big, red ball in " +
        "the sky. It was the sun! She thought it was so pretty.\nLily wanted " +
        "to play with the ball, but it was"

    static var failed = false

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        failed = true
    }

    static func load(_ path: String) -> Data {
        guard let d = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("FAIL: cannot read \(path) — run `make model`\n".utf8))
            exit(1)
        }
        return d
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    static func testActivationQuantizationEdges() {
        check(llamaRoundedInt8Saturating(0.49) == 0, "rounding below half changed")
        check(llamaRoundedInt8Saturating(0.5) == 1, "rounding half away from zero changed")
        check(llamaRoundedInt8Saturating(-0.5) == -1, "negative half rounding changed")
        check(llamaRoundedInt8Saturating(127.49) == 127, "valid high int8 edge changed")
        check(llamaRoundedInt8Saturating(127.5) == 127, "positive overflow not saturated")
        check(llamaRoundedInt8Saturating(-128.5) == -128, "negative overflow not saturated")
        check(llamaRoundedInt8Saturating(Float.infinity) == 127, "positive infinity not saturated")
        check(llamaRoundedInt8Saturating(-Float.infinity) == -128, "negative infinity not saturated")
        check(llamaRoundedInt8Saturating(Float.nan) == 0, "NaN should quantize to zero")
        print("llm_q8_engine_test: activation quantization edge cases are saturating")
    }

    static func runCase(model modelPath: String, tokenizer tokPath: String,
                        golden: String, label: String,
                        dim: Int, gs: Int, vocab: Int) {
        let modelData = load(modelPath)
        let tokData = load(tokPath)
        let got: String = modelData.withUnsafeBytes { (mptr: UnsafeRawBufferPointer) in
            tokData.withUnsafeBytes { (tptr: UnsafeRawBufferPointer) in
                let base = mptr.baseAddress!
                guard QLlama2.isQuantized(base) else {
                    fail("\(label): not a v2 quantized checkpoint"); return ""
                }
                let model = QLlama2(modelBytes: base)
                if model.cfg.dim != dim || model.gs != gs || model.cfg.vocabSize != vocab {
                    fail("\(label): unexpected config dim=\(model.cfg.dim) gs=\(model.gs) vocab=\(model.cfg.vocabSize)")
                }
                let tok = LlamaTokenizer(tokenizerBytes: tptr.baseAddress!, vocabSize: model.cfg.vocabSize)
                var out: [UInt8] = []
                llamaGenerate(model, tok, prompt: prompt, steps: steps) { out.append(contentsOf: $0) }
                return String(decoding: out, as: UTF8.self)
            }
        }
        if got != golden {
            FileHandle.standardError.write(Data("--- \(label) got ----\n\(got)\n--- want ---\n\(golden)\n".utf8))
            let g = Array(got), w = Array(golden)
            var i = 0
            while i < g.count && i < w.count && g[i] == w[i] { i += 1 }
            fail("\(label): output diverged at index \(i) (got \(g.count) chars, want \(w.count))")
        } else {
            print("llm_q8_engine_test: \(label) matches runq.c reference (\(steps) steps)")
        }
    }

    static func main() {
        testActivationQuantizationEdges()
        runCase(model: "models/stories260K-q8.bin", tokenizer: "models/tok512.bin",
                golden: golden260K, label: "260K-q8", dim: 64, gs: 4, vocab: 512)
        runCase(model: "models/stories15M-q8.bin", tokenizer: "models/tokenizer.bin",
                golden: golden15M, label: "15M-q8", dim: 288, gs: 32, vocab: 32000)
        if failed {
            FileHandle.standardError.write(Data("llm_q8_engine_test: FAILURES\n".utf8))
            exit(1)
        }
        print("llm_q8_engine_test: PASS (int8 groupwise quantized path pinned to runq.c)")
    }
}
