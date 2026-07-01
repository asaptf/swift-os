// SPDX-License-Identifier: Apache-2.0
//
// gguf_engine.swift — the GGUF Q4_K/Q6_K inference engine (LM5), split from
// llama2.swift so that GGUF-free consumers (/bin/llm, the Q8/fp32 host tests)
// still compile llama2.swift alone. Compiled together (WMO) with llama2.swift
// (LlamaModel/LlamaConfig/llamaFDot/Mathf) and gguf.swift (reader + dequant).

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

