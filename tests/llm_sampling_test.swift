// SPDX-License-Identifier: Apache-2.0
//
// llm_sampling_test.swift — LM6a host oracle for the sampler + chat template
// (llama2.swift). Uses the TinyLlama Q8 bundle (`make tinyllama`) and asserts:
//   1. temperature 0 sampling reproduces greedy argmax exactly;
//   2. a fixed seed is reproducible (same output twice) and two different seeds
//      diverge (sampling is actually random, not stuck on argmax);
//   3. the chat template wraps a user turn as <|user|>…</s><|assistant|> with the
//      real EOS token and yields a coherent sampled reply (low temperature keeps
//      a factual question on-answer).

import Foundation

@main
struct LLMSamplingTest {
    static func die(_ m: String) -> Never {
        FileHandle.standardError.write(Data("llm_sampling_test: \(m)\n".utf8)); exit(1)
    }
    static func load(_ p: String) -> Data {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p), options: .alwaysMapped) else {
            die("cannot read \(p) — run `make tinyllama`")
        }
        return d
    }

    static func main() {
        let md = load("models/tinyllama-q8.bin")
        let tdd = load("models/tinyllama-tokenizer.bin")
        var failed = false
        func check(_ c: Bool, _ m: String) { if !c { failed = true; FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)) } }

        md.withUnsafeBytes { (mptr: UnsafeRawBufferPointer) in
            tdd.withUnsafeBytes { (tptr: UnsafeRawBufferPointer) in
                let model = QLlama2(modelBytes: mptr.baseAddress!)
                let tok = LlamaTokenizer(tokenizerBytes: tptr.baseAddress!, vocabSize: model.cfg.vocabSize)

                func gen(prompt: String, steps: Int, _ s: inout LlamaSampler, stopOnEos: Bool = false) -> String {
                    let pt = tok.encode(prompt, bos: true, eos: false)
                    var out: [UInt8] = []
                    _ = llamaGenerateSampled(model, tok, promptTokens: pt, steps: steps,
                                             sampler: &s, stopOnEos: stopOnEos) { out.append(contentsOf: $0) }
                    return String(decoding: out, as: UTF8.self)
                }

                // 1. temperature 0 == greedy.
                let greedyPrompt = "The capital of France is"
                var s0 = LlamaSampler(temperature: 0)
                let sampled0 = gen(prompt: greedyPrompt, steps: 24, &s0)
                var gout: [UInt8] = []
                llamaGenerate(model, tok, prompt: greedyPrompt, steps: 24) { gout.append(contentsOf: $0) }
                let greedy = String(decoding: gout, as: UTF8.self)
                check(sampled0 == greedy, "temperature-0 sampling != greedy\n  samp: \(sampled0)\n  grdy: \(greedy)")
                if sampled0 == greedy { print("llm_sampling_test: temperature 0 == greedy (\(greedy.count) chars)") }

                // 2. fixed seed reproducible; different seeds diverge.
                var a1 = LlamaSampler(temperature: 0.9, topK: 40, topP: 0.95, seed: 42)
                var a2 = LlamaSampler(temperature: 0.9, topK: 40, topP: 0.95, seed: 42)
                var b = LlamaSampler(temperature: 0.9, topK: 40, topP: 0.95, seed: 1337)
                let r1 = gen(prompt: "Once upon a time", steps: 32, &a1)
                let r2 = gen(prompt: "Once upon a time", steps: 32, &a2)
                let rb = gen(prompt: "Once upon a time", steps: 32, &b)
                check(r1 == r2, "same seed not reproducible")
                check(r1 != rb, "different seeds did not diverge (sampler stuck on argmax?)")
                if r1 == r2 && r1 != rb { print("llm_sampling_test: seed 42 reproducible; seed 1337 diverges") }

                // 3. chat template + low-temp sampling stays on-answer.
                let chatTokens = llamaChatTokens(tok, userMessage: "What is the capital of France?")
                var cs = LlamaSampler(temperature: 0.3, topK: 40, topP: 0.9, seed: 7)
                var cout: [UInt8] = []
                _ = llamaGenerateSampled(model, tok, promptTokens: chatTokens, steps: chatTokens.count + 20,
                                         sampler: &cs, stopOnEos: true) { cout.append(contentsOf: $0) }
                let chat = String(decoding: cout, as: UTF8.self)
                FileHandle.standardError.write(Data("chat reply: \(chat)\n".utf8))
                check(chat.contains("Paris"), "chat reply did not mention Paris")
                if chat.contains("Paris") { print("llm_sampling_test: chat template -> on-answer reply (Paris)") }
            }
        }
        if failed { die("FAILURES") }
        print("llm_sampling_test: PASS (sampler + chat template)")
    }
}
