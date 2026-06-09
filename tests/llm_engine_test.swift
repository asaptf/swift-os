// SPDX-License-Identifier: Apache-2.0
//
// llm_engine_test.swift — host unit test for userland/lib/llama2.swift (I0).
//
// Compiled with the host Swift toolchain against the same pure source the
// /bin/llm ELF will link (llama2.swift), then run with no arguments. It loads
// the tiny TinyStories test checkpoint (stories260K) + tokenizer (tok512) and
// asserts that greedy (temperature 0) generation reproduces, byte-for-byte, the
// reference llama2.c output for a fixed prompt. This pins both the BPE
// tokenizer and the transformer forward pass to the reference implementation.
//
// Prerequisite: run `scripts/fetch-model.sh` (or `make model`) once to fetch
// models/stories260K.bin + models/tok512.bin. The reference golden below was
// produced with the upstream run.c:
//   ./run stories260K.bin -z tok512.bin -t 0 -n 64 -i "Once upon a time"
//
// Mirrors tests/tls_handshake_test.swift in style.

import Foundation

@main
struct LLMEngineTest {
    static let modelPath = "models/stories260K.bin"
    static let tokPath = "models/tok512.bin"
    static let prompt = "Once upon a time"
    static let steps = 64

    // Reference output (the concatenated decoded pieces; run.c's trailing '\n'
    // is its own, not a generated token, so it is excluded here).
    static let golden =
        "Once upon a time, there was a little girl named Lily. She loved to " +
        "play outside in the park. One day, she saw a big, red ball. She " +
        "wanted to play with it, but it was too high.\nLily"

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    static func load(_ path: String) -> Data {
        guard let d = FileManager.default.contents(atPath: path) else {
            fail("cannot read \(path) — run `make model` to fetch the test checkpoint")
        }
        return d
    }

    static func main() {
        let modelData = load(modelPath)
        let tokData = load(tokPath)

        let got: String = modelData.withUnsafeBytes { (mptr: UnsafeRawBufferPointer) in
            tokData.withUnsafeBytes { (tptr: UnsafeRawBufferPointer) in
                let model = Llama2(modelBytes: mptr.baseAddress!)
                // Sanity-check the parsed header against the known stories260K shape.
                let c = model.cfg
                if c.dim != 64 || c.nLayers != 5 || c.nHeads != 8
                    || c.nKVHeads != 4 || c.vocabSize != 512 || c.seqLen != 512 {
                    fail("unexpected config dim=\(c.dim) layers=\(c.nLayers) "
                        + "heads=\(c.nHeads) kv=\(c.nKVHeads) vocab=\(c.vocabSize) seq=\(c.seqLen)")
                }
                let tok = LlamaTokenizer(tokenizerBytes: tptr.baseAddress!, vocabSize: c.vocabSize)
                var out: [UInt8] = []
                llamaGenerate(model, tok, prompt: prompt, steps: steps) { out.append(contentsOf: $0) }
                return String(decoding: out, as: UTF8.self)
            }
        }

        if got != golden {
            FileHandle.standardError.write(Data("--- got ----\n\(got)\n--- want ---\n\(golden)\n".utf8))
            // Point at the first diverging character to make debugging quick.
            let g = Array(got), w = Array(golden)
            var i = 0
            while i < g.count && i < w.count && g[i] == w[i] { i += 1 }
            fail("output diverged at index \(i) (got \(g.count) chars, want \(w.count))")
        }

        print("llm_engine_test: PASS (stories260K greedy generation matches llama2.c reference, \(steps) steps)")
    }
}
