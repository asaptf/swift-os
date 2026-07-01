// SPDX-License-Identifier: Apache-2.0
//
// llama2.swift — a portable, I/O-free Llama-2 inference engine in (Embedded-
// compatible) Swift. A faithful reimplementation of Andrej Karpathy's
// llama2.c forward pass + SentencePiece-style BPE tokenizer, kept free of
// Foundation, libm, and all I/O so the identical source compiles on the host
// (for TDD against the reference) and as an EL0 Embedded Swift program on
// swift-os (the /bin/llm app, milestone I1+).
//
// Design notes that matter for correctness:
//   - All arithmetic is Float (32-bit), accumulated in Float, to match run.c
//     bit-for-bit class behaviour. Using Double here would diverge the argmax.
//   - We have no libm in EL0, so expf/sinf/cosf are implemented below. powf is
//     only needed for the constant base 10000 in RoPE, so we fold it into exp
//     via exp(x * ln(10000)).
//   - Greedy (argmax) decoding only: deterministic, robust to the ~1e-6
//     polynomial error in our transcendentals. Sampling is future work.
//
// This is the I0 core: callers provide the model + tokenizer bytes (read by
// whatever I/O the platform has) and consume generated pieces via a closure.

// MARK: - Freestanding scalar math (no libm)

enum Mathf {
    static let pi: Float = 3.14159265358979323846
    static let ln2: Float = 0.69314718055994530942
    static let log2e: Float = 1.44269504088896340736
    // ln(10000), used to compute powf(10000, x) = exp(x * ln10000) for RoPE.
    static let ln10000: Float = 9.21034037197618273607

    /// 2^k for integer k by directly composing the IEEE-754 exponent field.
    @inline(__always)
    static func exp2i(_ k: Int) -> Float {
        if k < -126 { return 0 }
        if k > 127 { return Float.infinity }
        return Float(bitPattern: UInt32(127 + k) << 23)
    }

    /// e^x. Range-reduce x = k*ln2 + r with |r| <= ln2/2, then a degree-5
    /// Taylor series on the small remainder. ~2e-6 relative error.
    static func expf(_ x: Float) -> Float {
        if x != x { return x }          // NaN
        if x > 88.0 { return Float.infinity }
        if x < -88.0 { return 0 }
        let kf = (x * log2e).rounded()
        let k = Int(kf)
        let r = x - kf * ln2
        let r2 = r * r
        let p: Float = 1.0 + r + r2 * 0.5
            + r2 * r * (1.0 / 6.0)
            + r2 * r2 * (1.0 / 24.0)
            + r2 * r2 * r * (1.0 / 120.0)
        return p * exp2i(k)
    }

    // sin/cos on the reduced interval [-pi/4, pi/4] (Taylor, error ~1e-8).
    @inline(__always)
    static func sinPoly(_ r: Float) -> Float {
        let r2 = r * r
        return r * (1.0 - r2 * (1.0 / 6.0) + r2 * r2 * (1.0 / 120.0)
            - r2 * r2 * r2 * (1.0 / 5040.0))
    }
    @inline(__always)
    static func cosPoly(_ r: Float) -> Float {
        let r2 = r * r
        return 1.0 - r2 * 0.5 + r2 * r2 * (1.0 / 24.0)
            - r2 * r2 * r2 * (1.0 / 720.0)
            + r2 * r2 * r2 * r2 * (1.0 / 40320.0)
    }

    /// sin(x): reduce to the nearest multiple of pi/2, evaluate by quadrant.
    static func sinf(_ x: Float) -> Float {
        let twoOverPi: Float = 0.63661977236758134308
        let q = (x * twoOverPi).rounded()
        let r = x - q * (pi * 0.5)
        let n = ((Int(q) % 4) + 4) % 4
        switch n {
        case 0: return sinPoly(r)
        case 1: return cosPoly(r)
        case 2: return -sinPoly(r)
        default: return -cosPoly(r)
        }
    }
    static func cosf(_ x: Float) -> Float { return sinf(x + pi * 0.5) }

    /// sqrt via a bit-trick seed + Heron iterations. Pure scalar Swift so it
    /// links freestanding (the toolchain lowers Float.squareRoot() to a libm
    /// `sqrtf` call, which EL0 has no libc for) and gives identical results on
    /// host and Embedded. Four iterations reach ~Float precision.
    @inline(__always)
    static func sqrtf(_ x: Float) -> Float {
        if x <= 0 { return 0 }
        let seed = UInt32(0x1fbd1df5) &+ (x.bitPattern >> 1)
        var y = Float(bitPattern: seed)
        y = 0.5 * (y + x / y)
        y = 0.5 * (y + x / y)
        y = 0.5 * (y + x / y)
        y = 0.5 * (y + x / y)
        return y
    }

    @inline(__always)
    static func rsqrtf(_ x: Float) -> Float { return 1.0 / sqrtf(x) }
}

// MARK: - NEON-vectorized hot-path dot products (LM1)
//
// The matmul inner products dominate the forward pass. These helpers express
// them with Swift `SIMD` types, which the aarch64 backend lowers to NEON
// (fmul/fadd .4s for fp32, smull/saddw for int8) when the translation unit is
// built with `+neon` (see USER_SWIFT_FLAGS_NEON). The same source still compiles
// on the host (native NEON), because `SIMD` is part of the Embedded-Swift-
// compatible stdlib subset.
//
// Numerics: the int8 group dot accumulates in Int32 with wrapping ops, so it is
// bit-for-bit identical to the sequential scalar sum (integer add is associative
// under two's-complement wraparound) — proven in QEMU by /bin/simdprobe across
// positive/mixed/negative/extreme lanes and a preemption-heavy 4000-iter qmatmul
// loop. The fp32 dot uses a 4-lane accumulator + horizontal sum, reassociating
// the float additions — a sub-ULP change the host engine tests pin to llama2.c.
//
// LM1b note: the int8 path here is safe under +neon, but the activation
// quantizer (QLlama2.quantizeBuf) is NOT — its +neon codegen diverges in QEMU,
// so it carries an `@_optimize(none)`. See that function and docs/NOTES.md (LM1).

/// int8·int8 -> int32 over `gs` elements (one quant group). `gs` is a multiple
/// of the group size (32/64) in real checkpoints; a scalar tail covers any
/// remainder so the helper is total for arbitrary lengths.
@inline(__always)
func llamaQDotGroup(_ x: UnsafePointer<Int8>, _ w: UnsafePointer<Int8>, _ gs: Int) -> Int32 {
    var acc = SIMD16<Int32>(repeating: 0)
    var k = 0
    while k + 16 <= gs {
        let xa: SIMD16<Int8> = UnsafeRawPointer(x + k).loadUnaligned(as: SIMD16<Int8>.self)
        let wa: SIMD16<Int8> = UnsafeRawPointer(w + k).loadUnaligned(as: SIMD16<Int8>.self)
        acc &+= SIMD16<Int32>(truncatingIfNeeded: xa) &* SIMD16<Int32>(truncatingIfNeeded: wa)
        k += 16
    }
    var s = acc.wrappedSum()
    while k < gs { s &+= Int32(x[k]) &* Int32(w[k]); k += 1 }
    return s
}

/// float·float -> float over `n` elements (4-lane SIMD + scalar tail).
@inline(__always)
func llamaFDot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ n: Int) -> Float {
    var acc = SIMD4<Float>(repeating: 0)
    var j = 0
    while j + 4 <= n {
        let va = UnsafeRawPointer(a + j).loadUnaligned(as: SIMD4<Float>.self)
        let vb = UnsafeRawPointer(b + j).loadUnaligned(as: SIMD4<Float>.self)
        acc += va * vb
        j += 4
    }
    var s = acc.sum()
    while j < n { s += a[j] * b[j]; j += 1 }
    return s
}

// MARK: - Model configuration + weights

struct LlamaConfig {
    var dim: Int
    var hiddenDim: Int
    var nLayers: Int
    var nHeads: Int
    var nKVHeads: Int
    var vocabSize: Int
    var seqLen: Int

    var headSize: Int { dim / nHeads }
    var kvDim: Int { (dim * nKVHeads) / nHeads }
    var kvMul: Int { nHeads / nKVHeads }
}

// Weight tensors are slices of the (caller-owned, kept-alive) model buffer.
struct LlamaWeights {
    var tokenEmbed: UnsafePointer<Float>   // (vocab, dim)
    var rmsAtt: UnsafePointer<Float>       // (layer, dim)
    var wq: UnsafePointer<Float>           // (layer, dim, n_heads*head_size)
    var wk: UnsafePointer<Float>           // (layer, dim, n_kv_heads*head_size)
    var wv: UnsafePointer<Float>
    var wo: UnsafePointer<Float>
    var rmsFFN: UnsafePointer<Float>       // (layer, dim)
    var w1: UnsafePointer<Float>           // (layer, hidden, dim)
    var w2: UnsafePointer<Float>           // (layer, dim, hidden)
    var w3: UnsafePointer<Float>
    var rmsFinal: UnsafePointer<Float>     // (dim,)
    var wcls: UnsafePointer<Float>         // (vocab, dim) — shared or separate
}

// MARK: - The transformer

final class Llama2 {
    let cfg: LlamaConfig
    let w: LlamaWeights

    // Activation "wave" buffers (allocated once, like run.c's RunState).
    private let x: UnsafeMutablePointer<Float>
    private let xb: UnsafeMutablePointer<Float>
    private let xb2: UnsafeMutablePointer<Float>
    private let hb: UnsafeMutablePointer<Float>
    private let hb2: UnsafeMutablePointer<Float>
    private let q: UnsafeMutablePointer<Float>
    private let att: UnsafeMutablePointer<Float>
    private let logits: UnsafeMutablePointer<Float>
    private let keyCache: UnsafeMutablePointer<Float>
    private let valueCache: UnsafeMutablePointer<Float>

    /// Parse the llama2.c checkpoint header + map the weights. `base` must
    /// remain valid (and unfreed) for the lifetime of this object.
    init(modelBytes base: UnsafeRawPointer) {
        // 7 little-endian int32 config fields.
        func i32(_ off: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: off, as: Int32.self)) }
        let dim = i32(0), hidden = i32(4), nLayers = i32(8), nHeads = i32(12)
        let nKV = i32(16)
        var vocab = i32(20)
        let seqLen = i32(24)
        // Negative vocab signals unshared classifier weights (run.c convention).
        let shared = vocab > 0
        if vocab < 0 { vocab = -vocab }
        let c = LlamaConfig(dim: dim, hiddenDim: hidden, nLayers: nLayers,
                            nHeads: nHeads, nKVHeads: nKV, vocabSize: vocab,
                            seqLen: seqLen)
        self.cfg = c

        // Weights begin right after the 28-byte header (4-byte aligned).
        var p = (base + 28).assumingMemoryBound(to: Float.self)
        let headSize = c.headSize
        func take(_ n: Int) -> UnsafePointer<Float> {
            let r = UnsafePointer<Float>(p); p += n; return r
        }
        let tokenEmbed = take(c.vocabSize * c.dim)
        let rmsAtt = take(c.nLayers * c.dim)
        let wq = take(c.nLayers * c.dim * (c.nHeads * headSize))
        let wk = take(c.nLayers * c.dim * (c.nKVHeads * headSize))
        let wv = take(c.nLayers * c.dim * (c.nKVHeads * headSize))
        let wo = take(c.nLayers * (c.nHeads * headSize) * c.dim)
        let rmsFFN = take(c.nLayers * c.dim)
        let w1 = take(c.nLayers * c.dim * c.hiddenDim)
        let w2 = take(c.nLayers * c.hiddenDim * c.dim)
        let w3 = take(c.nLayers * c.dim * c.hiddenDim)
        let rmsFinal = take(c.dim)
        _ = take(c.seqLen * headSize / 2)   // skip legacy freq_cis_real
        _ = take(c.seqLen * headSize / 2)   // skip legacy freq_cis_imag
        let wcls = shared ? tokenEmbed : UnsafePointer<Float>(p)
        self.w = LlamaWeights(tokenEmbed: tokenEmbed, rmsAtt: rmsAtt, wq: wq,
                              wk: wk, wv: wv, wo: wo, rmsFFN: rmsFFN, w1: w1,
                              w2: w2, w3: w3, rmsFinal: rmsFinal, wcls: wcls)

        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let m = UnsafeMutablePointer<Float>.allocate(capacity: n)
            m.initialize(repeating: 0, count: n)
            return m
        }
        self.x = alloc(c.dim)
        self.xb = alloc(c.dim)
        self.xb2 = alloc(c.dim)
        self.hb = alloc(c.hiddenDim)
        self.hb2 = alloc(c.hiddenDim)
        self.q = alloc(c.dim)
        self.att = alloc(c.nHeads * c.seqLen)
        self.logits = alloc(c.vocabSize)
        self.keyCache = alloc(c.nLayers * c.seqLen * c.kvDim)
        self.valueCache = alloc(c.nLayers * c.seqLen * c.kvDim)
    }

    deinit {
        x.deallocate(); xb.deallocate(); xb2.deallocate(); hb.deallocate()
        hb2.deallocate(); q.deallocate(); att.deallocate(); logits.deallocate()
        keyCache.deallocate(); valueCache.deallocate()
    }

    // MARK: net blocks

    private func rmsnorm(_ o: UnsafeMutablePointer<Float>, _ xin: UnsafePointer<Float>,
                         _ weight: UnsafePointer<Float>, _ size: Int) {
        var ss: Float = 0
        for j in 0..<size { ss += xin[j] * xin[j] }
        ss /= Float(size)
        ss += 1e-5
        ss = Mathf.rsqrtf(ss)
        for j in 0..<size { o[j] = weight[j] * (ss * xin[j]) }
    }

    private func softmax(_ a: UnsafeMutablePointer<Float>, _ size: Int) {
        var maxVal = a[0]
        for i in 1..<size where a[i] > maxVal { maxVal = a[i] }
        var sum: Float = 0
        for i in 0..<size { a[i] = Mathf.expf(a[i] - maxVal); sum += a[i] }
        for i in 0..<size { a[i] /= sum }
    }

    // xout(d) = W(d,n) @ x(n)
    private func matmul(_ xout: UnsafeMutablePointer<Float>, _ xin: UnsafePointer<Float>,
                        _ wt: UnsafePointer<Float>, _ n: Int, _ d: Int) {
        for i in 0..<d {
            xout[i] = llamaFDot(wt + i * n, xin, n)   // LM1: NEON-vectorized
        }
    }

    /// One decode step. Returns the logits pointer (vocabSize values).
    func forward(token: Int, pos: Int) -> UnsafePointer<Float> {
        let dim = cfg.dim, kvDim = cfg.kvDim, kvMul = cfg.kvMul
        let hidden = cfg.hiddenDim, headSize = cfg.headSize

        // token embedding -> x
        (w.tokenEmbed + token * dim).withMemoryRebound(to: Float.self, capacity: dim) { src in
            x.update(from: src, count: dim)
        }

        for l in 0..<cfg.nLayers {
            rmsnorm(xb, x, w.rmsAtt + l * dim, dim)

            let loff = l * cfg.seqLen * kvDim
            let k = keyCache + loff + pos * kvDim
            let v = valueCache + loff + pos * kvDim

            matmul(q, xb, w.wq + l * dim * dim, dim, dim)
            matmul(k, xb, w.wk + l * dim * kvDim, dim, kvDim)
            matmul(v, xb, w.wv + l * dim * kvDim, dim, kvDim)

            // RoPE: rotate (q,k) pairwise per head.
            var i = 0
            while i < dim {
                let headDim = i % headSize
                let freq = 1.0 / Mathf.expf((Float(headDim) / Float(headSize)) * Mathf.ln10000)
                let val = Float(pos) * freq
                let fcr = Mathf.cosf(val)
                let fci = Mathf.sinf(val)
                let rotn = i < kvDim ? 2 : 1
                for vSel in 0..<rotn {
                    let vec = vSel == 0 ? q : k
                    let v0 = vec[i], v1 = vec[i + 1]
                    vec[i] = v0 * fcr - v1 * fci
                    vec[i + 1] = v0 * fci + v1 * fcr
                }
                i += 2
            }

            // multi-head attention
            for h in 0..<cfg.nHeads {
                let qh = q + h * headSize
                let attH = att + h * cfg.seqLen
                for t in 0...pos {
                    let kt = keyCache + loff + t * kvDim + (h / kvMul) * headSize
                    var score: Float = 0
                    for d in 0..<headSize { score += qh[d] * kt[d] }
                    score /= Mathf.sqrtf(Float(headSize))
                    attH[t] = score
                }
                softmax(attH, pos + 1)
                let xbH = xb + h * headSize
                for d in 0..<headSize { xbH[d] = 0 }
                for t in 0...pos {
                    let vt = valueCache + loff + t * kvDim + (h / kvMul) * headSize
                    let a = attH[t]
                    for d in 0..<headSize { xbH[d] += a * vt[d] }
                }
            }

            matmul(xb2, xb, w.wo + l * dim * dim, dim, dim)
            for d in 0..<dim { x[d] += xb2[d] }

            // FFN: w2(silu(w1(x)) * w3(x))
            rmsnorm(xb, x, w.rmsFFN + l * dim, dim)
            matmul(hb, xb, w.w1 + l * dim * hidden, dim, hidden)
            matmul(hb2, xb, w.w3 + l * dim * hidden, dim, hidden)
            for d in 0..<hidden {
                var val = hb[d]
                val *= 1.0 / (1.0 + Mathf.expf(-val))   // SiLU
                val *= hb2[d]
                hb[d] = val
            }
            matmul(xb, hb, w.w2 + l * dim * hidden, hidden, dim)
            for d in 0..<dim { x[d] += xb[d] }
        }

        rmsnorm(x, x, w.rmsFinal, dim)
        matmul(logits, x, w.wcls, dim, cfg.vocabSize)
        return UnsafePointer(logits)
    }

    static func argmax(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
        var mi = 0, mp = p[0]
        for i in 1..<n where p[i] > mp { mi = i; mp = p[i] }
        return mi
    }
}

// MARK: - Model protocol (fp32 and int8 engines share the generation loop)

protocol LlamaModel: AnyObject {
    var cfg: LlamaConfig { get }
    func forward(token: Int, pos: Int) -> UnsafePointer<Float>
}

extension Llama2: LlamaModel {}

// MARK: - Q8_0 quantized transformer (llama2.c "version 2" checkpoints, I4)
//
// A faithful reimplementation of runq.c: groupwise int8 weights with float32
// scales (group size GS from the header), activations quantized per matmul,
// int32 accumulation per group scaled by s_w * s_x. The norm (rmsnorm) weights
// stay fp32. The token embedding row is dequantized on the fly per token —
// element-for-element the same values runq.c gets from its predequantized
// table, without spending vocab*dim*4 bytes of RAM on a copy.

@inline(__always)
func llamaRoundedInt8Saturating(_ x: Float) -> Int8 {
    let r = x.rounded()
    if r != r { return 0 }       // NaN: keep the request alive, contribute zero.
    if r > 127.0 { return 127 }
    if r < -128.0 { return -128 }
    return Int8(r)
}

final class QLlama2: LlamaModel {
    let cfg: LlamaConfig
    let gs: Int

    // Weight views into the (caller-owned, kept-alive) model buffer.
    private struct QT {  // one quantized tensor: int8 values + per-group scales
        var q: UnsafePointer<Int8>
        var s: UnsafePointer<Float>
    }
    private let rmsAtt: UnsafePointer<Float>
    private let rmsFFN: UnsafePointer<Float>
    private let rmsFinal: UnsafePointer<Float>
    private let qTok: QT
    private let wq: UnsafeMutablePointer<QT>   // one per layer
    private let wk: UnsafeMutablePointer<QT>
    private let wv: UnsafeMutablePointer<QT>
    private let wo: UnsafeMutablePointer<QT>
    private let w1: UnsafeMutablePointer<QT>
    private let w2: UnsafeMutablePointer<QT>
    private let w3: UnsafeMutablePointer<QT>
    private let wcls: QT

    // Activation buffers (fp32) + quantized activation staging (q + scales).
    private let x: UnsafeMutablePointer<Float>
    private let xb: UnsafeMutablePointer<Float>
    private let xb2: UnsafeMutablePointer<Float>
    private let hb: UnsafeMutablePointer<Float>
    private let hb2: UnsafeMutablePointer<Float>
    private let q: UnsafeMutablePointer<Float>
    private let att: UnsafeMutablePointer<Float>
    private let logits: UnsafeMutablePointer<Float>
    private let keyCache: UnsafeMutablePointer<Float>
    private let valueCache: UnsafeMutablePointer<Float>
    private let xqQ: UnsafeMutablePointer<Int8>
    private let xqS: UnsafeMutablePointer<Float>
    private let hqQ: UnsafeMutablePointer<Int8>
    private let hqS: UnsafeMutablePointer<Float>

    /// True when `base` starts a v2 quantized checkpoint ("ak42" magic).
    static func isQuantized(_ base: UnsafeRawPointer) -> Bool {
        return base.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x616b_3432
    }

    /// Parse a v2 checkpoint header + map the weights. `base` must stay valid
    /// (and unfreed) for the lifetime of this object.
    init(modelBytes base: UnsafeRawPointer) {
        func i32(_ off: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: off, as: Int32.self)) }
        // magic u32 @0, version i32 @4 (checked via isQuantized by the caller),
        // config @8..35, shared u8 @36, group_size i32 @37 (unaligned).
        let dim = i32(8), hidden = i32(12), nLayers = i32(16), nHeads = i32(20)
        let nKV = i32(24), vocab = i32(28), seqLen = i32(32)
        let shared = base.loadUnaligned(fromByteOffset: 36, as: UInt8.self) != 0
        let groupSize = Int(base.loadUnaligned(fromByteOffset: 37, as: Int32.self))
        let c = LlamaConfig(dim: dim, hiddenDim: hidden, nLayers: nLayers,
                            nHeads: nHeads, nKVHeads: nKV, vocabSize: vocab,
                            seqLen: seqLen)
        self.cfg = c
        self.gs = groupSize

        // fp32 norm blocks follow the 256-byte header.
        var off = 256
        func takeF(_ n: Int) -> UnsafePointer<Float> {
            let p = (base + off).assumingMemoryBound(to: Float.self)
            off += n * 4
            return p
        }
        self.rmsAtt = takeF(c.nLayers * c.dim)
        self.rmsFFN = takeF(c.nLayers * c.dim)
        self.rmsFinal = takeF(c.dim)

        // Quantized tensors: per tensor, int8 q[numel] then float s[numel/GS];
        // layered weights repeat that per layer (runq.c init_quantized_tensors).
        func takeQ(_ numel: Int) -> QT {
            let qp = (base + off).assumingMemoryBound(to: Int8.self)
            off += numel
            let sp = (base + off).assumingMemoryBound(to: Float.self)
            off += (numel / groupSize) * 4
            return QT(q: qp, s: sp)
        }
        func takeLayered(_ perLayer: Int) -> UnsafeMutablePointer<QT> {
            let arr = UnsafeMutablePointer<QT>.allocate(capacity: c.nLayers)
            for l in 0..<c.nLayers { (arr + l).initialize(to: takeQ(perLayer)) }
            return arr
        }
        let headSize = c.headSize
        self.qTok = takeQ(c.vocabSize * c.dim)
        self.wq = takeLayered(c.dim * (c.nHeads * headSize))
        self.wk = takeLayered(c.dim * (c.nKVHeads * headSize))
        self.wv = takeLayered(c.dim * (c.nKVHeads * headSize))
        self.wo = takeLayered((c.nHeads * headSize) * c.dim)
        self.w1 = takeLayered(c.dim * c.hiddenDim)
        self.w2 = takeLayered(c.hiddenDim * c.dim)
        self.w3 = takeLayered(c.dim * c.hiddenDim)
        self.wcls = shared ? qTok : takeQ(c.dim * c.vocabSize)

        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let m = UnsafeMutablePointer<Float>.allocate(capacity: n)
            m.initialize(repeating: 0, count: n)
            return m
        }
        self.x = alloc(c.dim)
        self.xb = alloc(c.dim)
        self.xb2 = alloc(c.dim)
        self.hb = alloc(c.hiddenDim)
        self.hb2 = alloc(c.hiddenDim)
        self.q = alloc(c.dim)
        self.att = alloc(c.nHeads * c.seqLen)
        self.logits = alloc(c.vocabSize)
        self.keyCache = alloc(c.nLayers * c.seqLen * c.kvDim)
        self.valueCache = alloc(c.nLayers * c.seqLen * c.kvDim)
        self.xqQ = UnsafeMutablePointer<Int8>.allocate(capacity: c.dim)
        self.xqQ.initialize(repeating: 0, count: c.dim)
        self.xqS = alloc(c.dim / groupSize)
        self.hqQ = UnsafeMutablePointer<Int8>.allocate(capacity: c.hiddenDim)
        self.hqQ.initialize(repeating: 0, count: c.hiddenDim)
        self.hqS = alloc(c.hiddenDim / groupSize)
    }

    deinit {
        wq.deallocate(); wk.deallocate(); wv.deallocate(); wo.deallocate()
        w1.deallocate(); w2.deallocate(); w3.deallocate()
        x.deallocate(); xb.deallocate(); xb2.deallocate(); hb.deallocate()
        hb2.deallocate(); q.deallocate(); att.deallocate(); logits.deallocate()
        keyCache.deallocate(); valueCache.deallocate()
        xqQ.deallocate(); xqS.deallocate(); hqQ.deallocate(); hqS.deallocate()
    }

    // MARK: quantized net blocks (mirror runq.c)

    /// Quantize `n` activations into (qOut, sOut), runq.c quantize(): per group,
    /// scale = max|v| / 127.0f, q = round(v/scale) — half away from zero, all
    /// float32. An all-zero group gets q=0, s=0 (its contribution is zero either
    /// way, since the group's scale multiplies the whole partial sum).
    // LM1b: this function's +neon-optimized codegen produces wrong activation
    // quantization in QEMU (bisected from the /bin/llmd Q8 serving divergence:
    // exempting exactly this function — abs-max reduction + round/saturate per
    // group — makes the served story match the runq.c reference again, while the
    // NEON `qmatmul`/`matmul` dot products stay correct). Pinned to scalar codegen
    // here; it is O(n) per matmul (vs qmatmul's O(d·n)), so the cost is marginal.
    // Root-causing the exact miscompiled op (likely the `.rounded()`/saturate or
    // the max reduction) and dropping this pin is follow-up work. See docs/NOTES.md.
    @_optimize(none)
    private func quantizeBuf(_ qOut: UnsafeMutablePointer<Int8>, _ sOut: UnsafeMutablePointer<Float>,
                             _ xin: UnsafePointer<Float>, _ n: Int) {
        let groups = n / gs
        for g in 0..<groups {
            let xg = xin + g * gs
            var wmax: Float = 0
            for i in 0..<gs {
                let v = xg[i] < 0 ? -xg[i] : xg[i]
                if v > wmax { wmax = v }
            }
            let scale = wmax / 127.0
            sOut[g] = scale
            let qg = qOut + g * gs
            if scale == 0 {
                for i in 0..<gs { qg[i] = 0 }
            } else {
                for i in 0..<gs { qg[i] = llamaRoundedInt8Saturating(xg[i] / scale) }
            }
        }
    }

    /// xout(d) = W(d,n) @ x(n) over quantized operands: int32 accumulation per
    /// group of GS, scaled by the weight-group and activation-group scales.
    private func qmatmul(_ xout: UnsafeMutablePointer<Float>,
                         _ xq: UnsafePointer<Int8>, _ xs: UnsafePointer<Float>,
                         _ w: QT, _ n: Int, _ d: Int) {
        for i in 0..<d {
            var val: Float = 0
            let iN = i * n
            var j = 0
            while j + gs <= n {
                // LM1: NEON-vectorized int32 group dot (bit-identical to scalar,
                // proven in QEMU by /bin/simdprobe).
                let ival = llamaQDotGroup(xq + j, w.q + (iN + j), gs)
                val += Float(ival) * w.s[(iN + j) / gs] * xs[j / gs]
                j += gs
            }
            xout[i] = val
        }
    }

    private func rmsnorm(_ o: UnsafeMutablePointer<Float>, _ xin: UnsafePointer<Float>,
                         _ weight: UnsafePointer<Float>, _ size: Int) {
        var ss: Float = 0
        for j in 0..<size { ss += xin[j] * xin[j] }
        ss /= Float(size)
        ss += 1e-5
        ss = Mathf.rsqrtf(ss)
        for j in 0..<size { o[j] = weight[j] * (ss * xin[j]) }
    }

    private func softmax(_ a: UnsafeMutablePointer<Float>, _ size: Int) {
        var maxVal = a[0]
        for i in 1..<size where a[i] > maxVal { maxVal = a[i] }
        var sum: Float = 0
        for i in 0..<size { a[i] = Mathf.expf(a[i] - maxVal); sum += a[i] }
        for i in 0..<size { a[i] /= sum }
    }

    /// One decode step (runq.c forward). Returns the logits (vocabSize values).
    func forward(token: Int, pos: Int) -> UnsafePointer<Float> {
        let dim = cfg.dim, kvDim = cfg.kvDim, kvMul = cfg.kvMul
        let hidden = cfg.hiddenDim, headSize = cfg.headSize

        // Token embedding, dequantized on the fly (== runq.c's predequantized
        // table values: same per-element q * s, no accumulation).
        let tBase = token * dim
        for i in 0..<dim {
            x[i] = Float(qTok.q[tBase + i]) * qTok.s[(tBase + i) / gs]
        }

        for l in 0..<cfg.nLayers {
            rmsnorm(xb, x, rmsAtt + l * dim, dim)

            let loff = l * cfg.seqLen * kvDim
            let k = keyCache + loff + pos * kvDim
            let v = valueCache + loff + pos * kvDim

            quantizeBuf(xqQ, xqS, xb, dim)
            qmatmul(q, xqQ, xqS, wq[l], dim, dim)
            qmatmul(k, xqQ, xqS, wk[l], dim, kvDim)
            qmatmul(v, xqQ, xqS, wv[l], dim, kvDim)

            // RoPE: rotate (q,k) pairwise per head.
            var i = 0
            while i < dim {
                let headDim = i % headSize
                let freq = 1.0 / Mathf.expf((Float(headDim) / Float(headSize)) * Mathf.ln10000)
                let val = Float(pos) * freq
                let fcr = Mathf.cosf(val)
                let fci = Mathf.sinf(val)
                let rotn = i < kvDim ? 2 : 1
                for vSel in 0..<rotn {
                    let vec = vSel == 0 ? q : k
                    let v0 = vec[i], v1 = vec[i + 1]
                    vec[i] = v0 * fcr - v1 * fci
                    vec[i + 1] = v0 * fci + v1 * fcr
                }
                i += 2
            }

            for h in 0..<cfg.nHeads {
                let qh = q + h * headSize
                let attH = att + h * cfg.seqLen
                for t in 0...pos {
                    let kt = keyCache + loff + t * kvDim + (h / kvMul) * headSize
                    var score: Float = 0
                    for d in 0..<headSize { score += qh[d] * kt[d] }
                    score /= Mathf.sqrtf(Float(headSize))
                    attH[t] = score
                }
                softmax(attH, pos + 1)
                let xbH = xb + h * headSize
                for d in 0..<headSize { xbH[d] = 0 }
                for t in 0...pos {
                    let vt = valueCache + loff + t * kvDim + (h / kvMul) * headSize
                    let a = attH[t]
                    for d in 0..<headSize { xbH[d] += a * vt[d] }
                }
            }

            quantizeBuf(xqQ, xqS, xb, dim)
            qmatmul(xb2, xqQ, xqS, wo[l], dim, dim)
            for d in 0..<dim { x[d] += xb2[d] }

            rmsnorm(xb, x, rmsFFN + l * dim, dim)
            quantizeBuf(xqQ, xqS, xb, dim)
            qmatmul(hb, xqQ, xqS, w1[l], dim, hidden)
            qmatmul(hb2, xqQ, xqS, w3[l], dim, hidden)
            for d in 0..<hidden {
                var val = hb[d]
                val *= 1.0 / (1.0 + Mathf.expf(-val))   // SiLU
                val *= hb2[d]
                hb[d] = val
            }
            quantizeBuf(hqQ, hqS, hb, hidden)
            qmatmul(xb, hqQ, hqS, w2[l], hidden, dim)
            for d in 0..<dim { x[d] += xb[d] }
        }

        rmsnorm(x, x, rmsFinal, dim)
        quantizeBuf(xqQ, xqS, x, dim)
        qmatmul(logits, xqQ, xqS, wcls, dim, cfg.vocabSize)
        return UnsafePointer(logits)
    }
}

// MARK: - GGUF Q4_K/Q6_K engine (LM5)
//
// Reads a llama-architecture GGUF (e.g. TinyLlama Q4_K_M) and runs the same
// forward pass as QLlama2, but the weights stay compressed in RAM (~0.6 GB for
// 1.1B, half of Q8) and each matmul dequantizes a k-quant super-block at a time
// into a small fp32 scratch, then dots it with the fp32 activation (llamaFDot,
// SIMD). Norms are fp32 in GGUF (read directly); token embedding and classifier
// are k-quant rows dequantized per lookup. Activations are never quantized (no
// quantizeBuf). The dequant helpers (gguf.swift) are elementwise with no
// reduction — unlike quantizeBuf they are left optimized (≈14× faster than the
// @_optimize(none) fallback); LM5c/LM5d verify their output stays correct on the
// host and under +neon in QEMU.

final class GGUFLlama: LlamaModel {
    let cfg: LlamaConfig
    private let rmsEps: Float

    private struct GW { var data: UnsafeRawPointer; var type: GGMLType }
    private let gguf: GGUFFile     // kept alive: weights are views into its buffer
    private let tokEmbd: GW
    private let wq: [GW], wk: [GW], wv: [GW], wo: [GW]
    private let w1: [GW], w2: [GW], w3: [GW]
    private let attnNorm: [UnsafePointer<Float>]
    private let ffnNorm: [UnsafePointer<Float>]
    private let outNorm: UnsafePointer<Float>
    private let wcls: GW

    // Activation buffers (fp32) — no quantized staging, unlike QLlama2.
    private let x, xb, xb2, hb, hb2, q, att, logits: UnsafeMutablePointer<Float>
    private let keyCache, valueCache: UnsafeMutablePointer<Float>
    private let dqTmp: UnsafeMutablePointer<Float>   // 256-float dequant scratch

    static func isGGUF(_ base: UnsafeRawPointer) -> Bool { GGUFFile.isGGUF(base) }

    /// Build from a GGUF buffer (`base`/`count` must stay valid for the lifetime).
    /// Returns nil if it is not a parseable llama GGUF. `maxSeqLen` caps the KV
    /// cache context (LM5 ships 512, like LM4, to keep RAM modest).
    init?(ggufBytes base: UnsafeRawPointer, count: Int, maxSeqLen: Int = 512) {
        let g = GGUFFile(base: base, count: count)
        guard g.ok else { return nil }
        self.gguf = g
        guard let dim = g.metaInt("llama.embedding_length"),
              let hidden = g.metaInt("llama.feed_forward_length"),
              let nLayers = g.metaInt("llama.block_count"),
              let nHeads = g.metaInt("llama.attention.head_count"),
              let teInfo = g.tensor("token_embd.weight") else {
            return nil
        }
        let vocab = teInfo.dims.1          // token_embd is [embedding_length, vocab]
        let nKV = g.metaInt("llama.attention.head_count_kv") ?? nHeads
        let ctx = g.metaInt("llama.context_length") ?? maxSeqLen
        let seqLen = ctx < maxSeqLen ? ctx : maxSeqLen
        self.rmsEps = g.metaF32("llama.attention.layer_norm_rms_epsilon") ?? 1e-5
        let c = LlamaConfig(dim: dim, hiddenDim: hidden, nLayers: nLayers,
                            nHeads: nHeads, nKVHeads: nKV, vocabSize: vocab, seqLen: seqLen)
        self.cfg = c

        func w(_ name: String) -> GW? {
            guard let t = g.tensor(name: name), let ty = GGMLType(rawValue: t.type) else { return nil }
            return GW(data: g.tensorData(t), type: ty)
        }
        func norm(_ name: String) -> UnsafePointer<Float>? {
            guard let t = g.tensor(name: name) else { return nil }
            return g.tensorData(t).assumingMemoryBound(to: Float.self)
        }
        guard let te = w("token_embd.weight"),
              let on = norm("output_norm.weight") else { return nil }
        // Some GGUFs tie the classifier to the embeddings (no output.weight).
        let cls = w("output.weight") ?? te
        self.tokEmbd = te; self.outNorm = on; self.wcls = cls

        var aq = [GW](), ak = [GW](), av = [GW](), ao = [GW]()
        var f1 = [GW](), f2 = [GW](), f3 = [GW]()
        var an = [UnsafePointer<Float>](), fn = [UnsafePointer<Float>]()
        for l in 0..<nLayers {
            guard let q = w("blk.\(l).attn_q.weight"), let k = w("blk.\(l).attn_k.weight"),
                  let v = w("blk.\(l).attn_v.weight"), let o = w("blk.\(l).attn_output.weight"),
                  let g1 = w("blk.\(l).ffn_gate.weight"), let g2 = w("blk.\(l).ffn_down.weight"),
                  let g3 = w("blk.\(l).ffn_up.weight"),
                  let na = norm("blk.\(l).attn_norm.weight"), let nf = norm("blk.\(l).ffn_norm.weight")
            else { return nil }
            aq.append(q); ak.append(k); av.append(v); ao.append(o)
            f1.append(g1); f2.append(g2); f3.append(g3); an.append(na); fn.append(nf)
        }
        self.wq = aq; self.wk = ak; self.wv = av; self.wo = ao
        self.w1 = f1; self.w2 = f2; self.w3 = f3; self.attnNorm = an; self.ffnNorm = fn

        func alloc(_ n: Int) -> UnsafeMutablePointer<Float> {
            let m = UnsafeMutablePointer<Float>.allocate(capacity: n); m.initialize(repeating: 0, count: n); return m
        }
        self.x = alloc(dim); self.xb = alloc(dim); self.xb2 = alloc(dim)
        self.hb = alloc(hidden); self.hb2 = alloc(hidden); self.q = alloc(dim)
        self.att = alloc(nHeads * seqLen); self.logits = alloc(vocab)
        self.keyCache = alloc(nLayers * seqLen * c.kvDim)
        self.valueCache = alloc(nLayers * seqLen * c.kvDim)
        self.dqTmp = alloc(ggmlQKK)
    }

    deinit {
        x.deallocate(); xb.deallocate(); xb2.deallocate(); hb.deallocate(); hb2.deallocate()
        q.deallocate(); att.deallocate(); logits.deallocate()
        keyCache.deallocate(); valueCache.deallocate(); dqTmp.deallocate()
    }

    /// Dequantize super-block `b` of the k-quant `w` row that starts at `rowBlockBase`
    /// (a byte pointer) into dqTmp[0..<256].
    @inline(__always)
    private func dequantBlock(_ blk: UnsafeRawPointer, _ type: GGMLType) {
        if type == .q6_K { ggufDequantQ6K(blk, dqTmp) } else { ggufDequantQ4K(blk, dqTmp) }
    }

    /// out[o] = sum_j W[o,j] * x[j], for o in 0..<nOut. Each row of length nIn
    /// (a multiple of 256) is nIn/256 k-quant super-blocks; dequant one block,
    /// dot with the matching x slice, accumulate.
    private func kqMatmul(_ out: UnsafeMutablePointer<Float>, _ xin: UnsafePointer<Float>,
                          _ w: GW, _ nIn: Int, _ nOut: Int) {
        let nb = nIn / ggmlQKK
        let blkBytes = w.type == .q6_K ? ggmlQ6KBlockBytes : ggmlQ4KBlockBytes
        let rowBytes = nb * blkBytes
        for o in 0..<nOut {
            let rowBase = w.data + o * rowBytes
            var acc: Float = 0
            for b in 0..<nb {
                dequantBlock(rowBase + b * blkBytes, w.type)
                acc += llamaFDot(dqTmp, xin + b * ggmlQKK, ggmlQKK)
            }
            out[o] = acc
        }
    }

    /// Dequantize row `row` (length `nIn`) of a k-quant tensor into `out`.
    private func dequantRow(_ out: UnsafeMutablePointer<Float>, _ w: GW, _ row: Int, _ nIn: Int) {
        let nb = nIn / ggmlQKK
        let blkBytes = w.type == .q6_K ? ggmlQ6KBlockBytes : ggmlQ4KBlockBytes
        let rowBase = w.data + row * nb * blkBytes
        for b in 0..<nb {
            dequantBlock(rowBase + b * blkBytes, w.type)
            for i in 0..<ggmlQKK { out[b * ggmlQKK + i] = dqTmp[i] }
        }
    }

    private func rmsnorm(_ o: UnsafeMutablePointer<Float>, _ xin: UnsafePointer<Float>,
                         _ weight: UnsafePointer<Float>, _ size: Int) {
        var ss: Float = 0
        for j in 0..<size { ss += xin[j] * xin[j] }
        ss /= Float(size); ss += rmsEps; ss = Mathf.rsqrtf(ss)
        for j in 0..<size { o[j] = weight[j] * (ss * xin[j]) }
    }

    private func softmax(_ a: UnsafeMutablePointer<Float>, _ size: Int) {
        var maxVal = a[0]
        for i in 1..<size where a[i] > maxVal { maxVal = a[i] }
        var sum: Float = 0
        for i in 0..<size { a[i] = Mathf.expf(a[i] - maxVal); sum += a[i] }
        for i in 0..<size { a[i] /= sum }
    }

    func forward(token: Int, pos: Int) -> UnsafePointer<Float> {
        let dim = cfg.dim, kvDim = cfg.kvDim, kvMul = cfg.kvMul
        let hidden = cfg.hiddenDim, headSize = cfg.headSize

        dequantRow(x, tokEmbd, token, dim)   // token embedding

        for l in 0..<cfg.nLayers {
            rmsnorm(xb, x, attnNorm[l], dim)

            let loff = l * cfg.seqLen * kvDim
            let k = keyCache + loff + pos * kvDim
            let v = valueCache + loff + pos * kvDim

            kqMatmul(q, xb, wq[l], dim, dim)
            kqMatmul(k, xb, wk[l], dim, kvDim)
            kqMatmul(v, xb, wv[l], dim, kvDim)

            var i = 0
            while i < dim {
                let headDim = i % headSize
                let freq = 1.0 / Mathf.expf((Float(headDim) / Float(headSize)) * Mathf.ln10000)
                let val = Float(pos) * freq
                let fcr = Mathf.cosf(val), fci = Mathf.sinf(val)
                let rotn = i < kvDim ? 2 : 1
                for vSel in 0..<rotn {
                    let vec = vSel == 0 ? q : k
                    let v0 = vec[i], v1 = vec[i + 1]
                    vec[i] = v0 * fcr - v1 * fci
                    vec[i + 1] = v0 * fci + v1 * fcr
                }
                i += 2
            }

            for h in 0..<cfg.nHeads {
                let qh = q + h * headSize
                let attH = att + h * cfg.seqLen
                for t in 0...pos {
                    let kt = keyCache + loff + t * kvDim + (h / kvMul) * headSize
                    var score: Float = 0
                    for d in 0..<headSize { score += qh[d] * kt[d] }
                    score /= Mathf.sqrtf(Float(headSize))
                    attH[t] = score
                }
                softmax(attH, pos + 1)
                let xbH = xb + h * headSize
                for d in 0..<headSize { xbH[d] = 0 }
                for t in 0...pos {
                    let vt = valueCache + loff + t * kvDim + (h / kvMul) * headSize
                    let a = attH[t]
                    for d in 0..<headSize { xbH[d] += a * vt[d] }
                }
            }

            kqMatmul(xb2, xb, wo[l], dim, dim)
            for d in 0..<dim { x[d] += xb2[d] }

            rmsnorm(xb, x, ffnNorm[l], dim)
            kqMatmul(hb, xb, w1[l], dim, hidden)
            kqMatmul(hb2, xb, w3[l], dim, hidden)
            for d in 0..<hidden {
                var val = hb[d]
                val *= 1.0 / (1.0 + Mathf.expf(-val))   // SiLU
                val *= hb2[d]
                hb[d] = val
            }
            kqMatmul(xb, hb, w2[l], hidden, dim)
            for d in 0..<dim { x[d] += xb[d] }
        }

        rmsnorm(x, x, outNorm, dim)
        kqMatmul(logits, x, wcls, dim, cfg.vocabSize)
        return UnsafePointer(logits)
    }
}

// MARK: - BPE tokenizer (SentencePiece-style, byte fallback)

final class LlamaTokenizer {
    let vocabSize: Int
    private var vocab: [String]
    private var scores: [Float]
    private var lookup: [String: Int] = [:]   // piece -> id (str_lookup)
    let bosId = 1
    let eosId = 2

    /// Parse the llama2.c tokenizer.bin: int32 max_token_length, then per
    /// vocab entry: float32 score, int32 len, len bytes.
    init(tokenizerBytes base: UnsafeRawPointer, vocabSize: Int) {
        self.vocabSize = vocabSize
        self.vocab = [String](repeating: "", count: vocabSize)
        self.scores = [Float](repeating: 0, count: vocabSize)
        var off = 4   // skip max_token_length
        for i in 0..<vocabSize {
            let score = base.loadUnaligned(fromByteOffset: off, as: Float.self); off += 4
            let len = Int(base.loadUnaligned(fromByteOffset: off, as: Int32.self)); off += 4
            var bytes = [UInt8](repeating: 0, count: len)
            for b in 0..<len { bytes[b] = (base + off + b).load(as: UInt8.self) }
            off += len
            scores[i] = score
            let s = String(decoding: bytes, as: UTF8.self)
            vocab[i] = s
            // First mapping wins, mirroring a stable str_lookup over the vocab.
            if lookup[s] == nil { lookup[s] = i }
        }
    }

    /// Encode text to token ids. Mirrors run.c encode() with add_dummy_prefix
    /// and byte-fallback, then greedy score-ordered pair merging.
    func encode(_ text: String, bos: Bool, eos: Bool) -> [Int] {
        var tokens: [Int] = []
        if bos { tokens.append(bosId) }
        // add_dummy_prefix: prepend a space token for non-empty input.
        if !text.isEmpty, let sp = lookup[" "] { tokens.append(sp) }

        // Per-codepoint: look the piece up; else byte-fallback (+3 offset).
        for scalar in text.unicodeScalars {
            let piece = String(scalar)
            if let id = lookup[piece] {
                tokens.append(id)
            } else {
                for b in Array(piece.utf8) { tokens.append(Int(b) + 3) }
            }
        }

        // Merge the best-scoring adjacent pair until none remain.
        while true {
            var bestScore: Float = -1e10
            var bestId = -1
            var bestIdx = -1
            var i = 0
            while i < tokens.count - 1 {
                let merged = vocab[tokens[i]] + vocab[tokens[i + 1]]
                if let id = lookup[merged], scores[id] > bestScore {
                    bestScore = scores[id]; bestId = id; bestIdx = i
                }
                i += 1
            }
            if bestIdx == -1 { break }
            tokens[bestIdx] = bestId
            tokens.remove(at: bestIdx + 1)
        }

        if eos { tokens.append(eosId) }
        return tokens
    }

    /// Decode one token to its printable bytes, given the previous token (for
    /// the post-BOS leading-space strip and raw-byte "<0xXX>" handling).
    func decode(prevToken: Int, token: Int) -> [UInt8] {
        var piece = vocab[token]
        if prevToken == bosId, piece.first == " " { piece.removeFirst() }
        // Raw byte token of the form "<0xAB>".
        if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">") {
            let hex = piece.dropFirst(3).dropLast()
            if let byte = UInt8(hex, radix: 16) {
                // safe_printf: only emit printable / whitespace single bytes.
                if isPrintableOrSpace(byte) { return [byte] }
                return []
            }
        }
        return Array(piece.utf8)
    }

    private func isPrintableOrSpace(_ b: UInt8) -> Bool {
        if b == 0x20 || (b >= 0x09 && b <= 0x0D) { return true }   // space + \t\n\v\f\r
        return b >= 0x20 && b < 0x7F                                // printable ASCII
    }
}

// MARK: - Greedy generation (deterministic)

/// Generate up to `steps` positions with greedy decoding, invoking `emit` with
/// each decoded piece's bytes (the prompt's forced tokens are emitted too, as
/// run.c does). Returns the number of positions advanced.
@discardableResult
func llamaGenerate<M: LlamaModel>(_ model: M, _ tok: LlamaTokenizer, prompt: String,
                                  steps: Int, emit: ([UInt8]) -> Void) -> Int {
    let promptTokens = tok.encode(prompt, bos: true, eos: false)
    if promptTokens.isEmpty { return 0 }
    var token = promptTokens[0]
    var pos = 0
    while pos < steps {
        let logits = model.forward(token: token, pos: pos)
        let next: Int
        if pos < promptTokens.count - 1 {
            next = promptTokens[pos + 1]
        } else {
            next = Llama2.argmax(logits, model.cfg.vocabSize)
        }
        pos += 1
        if next == tok.bosId { break }   // BOS delimits sequences
        emit(tok.decode(prevToken: token, token: next))
        token = next
    }
    return pos
}
