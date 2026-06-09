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

    @inline(__always)
    static func rsqrtf(_ x: Float) -> Float { return 1.0 / x.squareRoot() }
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
            var val: Float = 0
            let row = wt + i * n
            for j in 0..<n { val += row[j] * xin[j] }
            xout[i] = val
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
                    score /= Float(headSize).squareRoot()
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
func llamaGenerate(_ model: Llama2, _ tok: LlamaTokenizer, prompt: String,
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
