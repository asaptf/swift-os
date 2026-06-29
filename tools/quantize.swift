// SPDX-License-Identifier: Apache-2.0
//
// quantize.swift — host-side Q8_0 model quantizer for swift-os (I4).
//
// Converts a legacy llama2.c fp32 checkpoint (.bin, the 28-byte 7-int header
// format) into the llama2.c "version 2" int8-quantized checkpoint that
// runq.c — and the swift-os engine's quantized path — consume:
//
//   header (256 bytes): magic "ak42" u32, version=2 i32, config 7×i32,
//                       shared_classifier u8, group_size i32, zero pad
//   fp32:  rms_att (L×dim), rms_ffn (L×dim), rms_final (dim)
//   then per quantized tensor, PER LAYER interleaved: int8 q[numel],
//        float32 s[numel/GS]  — order: q_tokens, wq, wk, wv, wo, w1, w2, w3,
//        and wcls only when the classifier is not shared.
//
// Quantization matches runq.c/export.py exactly, in 32-bit float arithmetic:
// per group of GS values, scale = max|v| / 127.0f, q = round(v / scale) with
// C round() semantics (half away from zero — Swift's default .rounded()).
// GS is chosen as the largest power of two ≤ 64 dividing BOTH dim and
// hidden_dim: runq.c's matmul walks rows in steps of GS, so GS must divide
// every matmul row length (dim and hidden_dim) or row tails would be dropped.
//
// Usage: quantize <in-fp32.bin> <out-q8.bin> [seqlen-override]
//
// The optional 3rd argument overrides the seqLen field written to the v2
// header (when > 0). The engine sizes its KV cache from that field, so a real
// model (e.g. TinyLlama, native ctx 2048) can be shipped with a smaller context
// to keep RAM modest in QEMU (LM4). The weights do not depend on seqLen (RoPE is
// recomputed at run time), so this is a pure cap on the served context length.

import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("quantize: \(msg)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
    die("usage: quantize <in-fp32.bin> <out-q8.bin> [seqlen-override]")
}
let inPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let seqLenOverride = CommandLine.arguments.count == 4 ? (Int(CommandLine.arguments[3]) ?? 0) : 0

// mmap the input rather than slurping it: a real fp32 checkpoint is multiple GB
// and a mapped read lets the OS page it instead of resident-loading the whole file.
guard let data = try? Data(contentsOf: URL(fileURLWithPath: inPath), options: .alwaysMapped) else {
    die("cannot read \(inPath)")
}

// ---- parse the legacy header -------------------------------------------------
func i32(_ off: Int) -> Int {
    Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: Int32.self) })
}
let dim = i32(0), hidden = i32(4), nLayers = i32(8), nHeads = i32(12)
let nKV = i32(16)
var vocab = i32(20)
let seqLenIn = i32(24)
let seqLen = seqLenOverride > 0 ? seqLenOverride : seqLenIn
let shared = vocab > 0
if vocab < 0 { vocab = -vocab }
let headSize = dim / nHeads
let kvDim = (dim * nKV) / nHeads

// GS: largest power of two ≤ 64 dividing both matmul row lengths.
var gs = 64
while gs > 1 && (dim % gs != 0 || hidden % gs != 0) { gs /= 2 }
if gs < 2 { die("degenerate group size for dim=\(dim) hidden=\(hidden)") }

let seqNote = seqLenOverride > 0 && seqLenOverride != seqLenIn ? " (overridden from \(seqLenIn))" : ""
print("quantize: dim=\(dim) hidden=\(hidden) layers=\(nLayers) heads=\(nHeads) kv=\(nKV) vocab=\(vocab) seq=\(seqLen)\(seqNote) shared=\(shared) GS=\(gs)")

// ---- map the legacy fp32 tensors ----------------------------------------------
// Legacy layout after the 28-byte header (run.c memory_map_weights order).
var off = 28
func take(_ n: Int) -> Int { let o = off; off += n * 4; return o }
let oTok = take(vocab * dim)
let oRmsAtt = take(nLayers * dim)
let oWq = take(nLayers * dim * dim)
let oWk = take(nLayers * dim * kvDim)
let oWv = take(nLayers * dim * kvDim)
let oWo = take(nLayers * dim * dim)
let oRmsFFN = take(nLayers * dim)
let oW1 = take(nLayers * dim * hidden)
let oW2 = take(nLayers * hidden * dim)
let oW3 = take(nLayers * dim * hidden)
let oRmsFinal = take(dim)
_ = take(seqLenIn * headSize / 2)   // legacy freq_cis_real (skip uses input layout)
_ = take(seqLenIn * headSize / 2)   // legacy freq_cis_imag (skip uses input layout)
let oWcls = off                    // present only when !shared
let needed = shared ? off : off + vocab * dim * 4
guard data.count >= needed else { die("file truncated: have \(data.count), need \(needed)") }

// ---- output buffer -------------------------------------------------------------
var out = Data(capacity: 256 + data.count / 3)

func putU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
func putI32(_ v: Int32) { putU32(UInt32(bitPattern: v.littleEndian)) }
func putF32(_ v: Float) { putU32(v.bitPattern.littleEndian) }

// header
putU32(0x616b3432)            // "ak42"
putI32(2)                     // version
putI32(Int32(dim)); putI32(Int32(hidden)); putI32(Int32(nLayers))
putI32(Int32(nHeads)); putI32(Int32(nKV)); putI32(Int32(vocab)); putI32(Int32(seqLen))
out.append(shared ? 1 : 0)    // shared_classifier u8
putI32(Int32(gs))             // group_size
while out.count < 256 { out.append(0) }

// fp32 norm blocks are copied verbatim (raw little-endian float bytes).
func copyF32(_ srcOff: Int, _ count: Int) {
    out.append(data.subdata(in: srcOff..<(srcOff + count * 4)))
}
copyF32(oRmsAtt, nLayers * dim)
copyF32(oRmsFFN, nLayers * dim)
copyF32(oRmsFinal, dim)

// Quantize `numel` floats at byte offset `srcOff` exactly like runq.c's
// quantize(): per group, scale = wmax/127.0f, q = round(v/scale), all Float32.
var maxQErr: Float = 0
func quantizeTensor(_ srcOff: Int, _ numel: Int) {
    precondition(numel % gs == 0, "tensor numel \(numel) not divisible by GS \(gs)")
    let groups = numel / gs
    var q = [Int8](repeating: 0, count: numel)
    var s = [Float](repeating: 0, count: groups)
    data.withUnsafeBytes { raw in
        for g in 0..<groups {
            var wmax: Float = 0
            for i in 0..<gs {
                let v = abs(raw.loadUnaligned(fromByteOffset: srcOff + (g * gs + i) * 4, as: Float.self))
                if v > wmax { wmax = v }
            }
            let scale: Float = wmax / 127.0
            s[g] = scale
            for i in 0..<gs {
                let v = raw.loadUnaligned(fromByteOffset: srcOff + (g * gs + i) * 4, as: Float.self)
                let qv: Float = scale == 0 ? 0 : (v / scale).rounded()  // C round(): half away from zero
                q[g * gs + i] = Int8(qv)
                let err = abs(qv * scale - v)
                if err > maxQErr { maxQErr = err }
            }
        }
    }
    q.withUnsafeBytes { out.append(contentsOf: $0) }
    for v in s { putF32(v) }
}

// Per-layer interleaving (init_quantized_tensors reads q then s per layer).
func quantizeLayered(_ baseOff: Int, _ perLayer: Int) {
    for l in 0..<nLayers { quantizeTensor(baseOff + l * perLayer * 4, perLayer) }
}

quantizeTensor(oTok, vocab * dim)         // q_tokens (single tensor)
quantizeLayered(oWq, dim * dim)
quantizeLayered(oWk, dim * kvDim)
quantizeLayered(oWv, dim * kvDim)
quantizeLayered(oWo, dim * dim)
quantizeLayered(oW1, dim * hidden)
quantizeLayered(oW2, hidden * dim)
quantizeLayered(oW3, dim * hidden)
if !shared { quantizeTensor(oWcls, dim * vocab) }

do {
    try out.write(to: URL(fileURLWithPath: outPath))
} catch {
    die("cannot write \(outPath): \(error)")
}
print("quantize: wrote \(out.count) bytes (\(data.count) fp32 -> q8, max abs err \(maxQErr))")
