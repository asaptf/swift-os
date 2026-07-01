// SPDX-License-Identifier: Apache-2.0
//
// ggufdump.swift — host tool that parses a GGUF file with the shared reader
// (userland/lib/gguf.swift) and prints the header, the llama hyperparameters,
// the tokenizer summary, and the tensor table (name / shape / ggml type). Used
// by the LM5a acceptance test to prove the reader understands a real
// TinyLlama Q4_K_M GGUF without pulling in any GGUF-specific host library.
//
// Usage: ggufdump <model.gguf>

import Foundation

func die(_ m: String) -> Never {
    FileHandle.standardError.write(Data("ggufdump: \(m)\n".utf8)); exit(1)
}

func typeName(_ t: UInt32) -> String {
    switch GGMLType(rawValue: t) {
    case .f32: return "F32"; case .f16: return "F16"
    case .q4_0: return "Q4_0"; case .q4_1: return "Q4_1"
    case .q5_0: return "Q5_0"; case .q5_1: return "Q5_1"
    case .q8_0: return "Q8_0"; case .q8_1: return "Q8_1"
    case .q2_K: return "Q2_K"; case .q3_K: return "Q3_K"; case .q4_K: return "Q4_K"
    case .q5_K: return "Q5_K"; case .q6_K: return "Q6_K"; case .q8_K: return "Q8_K"
    case .none: return "type\(t)"
    }
}

@main
struct GGUFDump {
static func main() {
guard CommandLine.arguments.count == 2 else { die("usage: ggufdump <model.gguf>") }
guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]),
                           options: .alwaysMapped) else {
    die("cannot read \(CommandLine.arguments[1])")
}
data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    let base = raw.baseAddress!
    guard GGUFFile.isGGUF(base) else { die("not a GGUF file") }
    let g = GGUFFile(base: base, count: raw.count)
    guard g.ok else { die("GGUF parse failed") }

    print("gguf: version \(g.version), \(g.tensorCount) tensors, dataStart \(g.dataStart)")

    let arch = g.withMetaString("general.architecture") { p, n in
        String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
    } ?? "?"
    print("arch: \(arch)")
    func geti(_ k: StaticString) -> Int { g.metaInt(k) ?? -1 }
    print("dim=\(geti("llama.embedding_length")) hidden=\(geti("llama.feed_forward_length")) "
        + "layers=\(geti("llama.block_count")) heads=\(geti("llama.attention.head_count")) "
        + "kv=\(geti("llama.attention.head_count_kv")) ctx=\(geti("llama.context_length"))")
    if let eps = g.metaF32("llama.attention.layer_norm_rms_epsilon") { print("rms_eps=\(eps)") }
    if let theta = g.metaF32("llama.rope.freq_base") { print("rope_freq_base=\(theta)") }

    // Tokenizer summary.
    let tokModel = g.withMetaString("tokenizer.ggml.model") { p, n in
        String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
    } ?? "?"
    var tokN = 0
    _ = g.stringArray("tokenizer.ggml.tokens") { i, _, _ in tokN = i + 1 }
    print("tokenizer: model=\(tokModel) tokens=\(tokN) bos=\(geti("tokenizer.ggml.bos_token_id")) "
        + "eos=\(geti("tokenizer.ggml.eos_token_id"))")

    // Tensor table + a type histogram.
    var hist: [UInt32: Int] = [:]
    print("tensors:")
    for t in g.tensors {
        hist[t.type, default: 0] += 1
        let name = String(decoding: UnsafeRawBufferPointer(start: base + t.nameOff, count: t.nameLen),
                          as: UTF8.self)
        // Print the first few + all non-block-0 layer reps would be noisy; print
        // layer 0 + the top-level tensors to keep it readable.
        if name.hasPrefix("blk.0.") || !name.hasPrefix("blk.") {
            var shape = ""
            for d in 0..<t.nDims {
                let v = [t.dims.0, t.dims.1, t.dims.2, t.dims.3][d]
                shape += (d == 0 ? "" : "x") + "\(v)"
            }
            print("  \(name)  [\(shape)]  \(typeName(t.type))")
        }
    }
    var histStr = "type histogram:"
    for (t, c) in hist.sorted(by: { $0.key < $1.key }) { histStr += " \(typeName(t))=\(c)" }
    print(histStr)
}
}
}
