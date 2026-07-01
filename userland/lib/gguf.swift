// SPDX-License-Identifier: Apache-2.0
//
// gguf.swift — minimal GGUF container reader for the swift-os inference engine
// (LM5). GGUF is llama.cpp's on-disk model format: a header, a table of typed
// key/value metadata (hyperparameters, tokenizer), a table of tensor infos
// (name, shape, ggml quant type, data offset), then an aligned tensor-data blob.
//
// This reader is deliberately just enough to load a llama-architecture model
// (e.g. TinyLlama) quantized as Q4_K_M: it walks every KV pair (it must, to
// reach the tensor table), records where each key's value lives, and exposes
// typed getters + the tensor table. It does not copy tensor data — tensors are
// referenced by (offset, ggml type) into the caller-owned, kept-alive buffer,
// exactly like the v2 Q8 path, so the weights stay memory-mapped and the Q4_K /
// Q6_K blocks are dequantized on the fly during matmul (userland/lib/llama2.swift).
//
// Pure and Foundation-free so it compiles into EL0 llmd and host tools alike.
// All integers are little-endian per the GGUF spec.

// ---- k-quant super-block sizes (QK_K = 256 weights per super-block) ----------
public let ggmlQKK = 256
public let ggmlQ4KBlockBytes = 144   // d(f16) + dmin(f16) + scales[12] + qs[128]
public let ggmlQ6KBlockBytes = 210   // ql[128] + qh[64] + scales[16] + d(f16)

/// IEEE half → float. Handles zero/subnormal/inf/nan; k-quant scales are normal
/// halves in practice, but the full path keeps the reader correct for any GGUF.
@inline(__always)
public func ggufF16ToF32(_ h: UInt16) -> Float {
    let h32 = UInt32(h)
    let sign = (h32 & 0x8000) << 16
    let exp = (h32 >> 10) & 0x1F
    let mant = h32 & 0x3FF
    var bits: UInt32
    if exp == 0 {
        if mant == 0 { bits = sign }
        else {
            // Subnormal half = mant × 2^-24. Shift the leading 1 up to bit 10;
            // e shifts means the leading bit was at position 10-e, so the
            // normalized f32 exponent field is (10-e) + 103 = 113 - e.
            var e: Int32 = 0
            var m = mant
            while (m & 0x400) == 0 { e += 1; m <<= 1 }
            m &= 0x3FF
            let fe = UInt32(bitPattern: (113 - e))
            bits = sign | (fe << 23) | (m << 13)
        }
    } else if exp == 0x1F {
        bits = sign | 0x7F80_0000 | (mant << 13)
    } else {
        bits = sign | ((exp + (127 - 15)) << 23) | (mant << 13)
    }
    return Float(bitPattern: bits)
}

// Q4_K 6-bit scale/min unpack (ggml get_scale_min_k4), `s` = the 12 packed bytes.
@inline(__always)
private func q4kScaleMin(_ j: Int, _ s: UnsafePointer<UInt8>) -> (UInt8, UInt8) {
    if j < 4 {
        return (s[j] & 63, s[j + 4] & 63)
    } else {
        let d = (s[j + 4] & 0xF) | ((s[j - 4] >> 6) << 4)
        let m = (s[j + 4] >> 4)  | ((s[j    ] >> 6) << 4)
        return (d, m)
    }
}

/// Dequantize one Q4_K super-block (144 bytes) to 256 floats. Matches ggml's
/// dequantize_row_q4_K exactly: per super-block scales `d`/`dmin` (f16), eight
/// sub-blocks of 32 with a 6-bit scale + 6-bit min, 4-bit weights.
public func ggufDequantQ4K(_ blk: UnsafeRawPointer, _ out: UnsafeMutablePointer<Float>) {
    let d = ggufF16ToF32(blk.loadUnaligned(fromByteOffset: 0, as: UInt16.self))
    let dmin = ggufF16ToF32(blk.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
    let s = (blk + 4).assumingMemoryBound(to: UInt8.self)     // scales[12]
    let q = (blk + 16).assumingMemoryBound(to: UInt8.self)    // qs[128]
    var y = 0, qi = 0, isc = 0, j = 0
    while j < ggmlQKK {
        let (sc1, m1) = q4kScaleMin(isc, s)
        let (sc2, m2) = q4kScaleMin(isc + 1, s)
        let d1 = d * Float(sc1), min1 = dmin * Float(m1)
        let d2 = d * Float(sc2), min2 = dmin * Float(m2)
        var l = 0
        while l < 32 { out[y] = d1 * Float(q[qi + l] & 0xF) - min1; y += 1; l += 1 }
        l = 0
        while l < 32 { out[y] = d2 * Float(q[qi + l] >> 4) - min2; y += 1; l += 1 }
        qi += 32; isc += 2; j += 64
    }
}

/// Dequantize one Q6_K super-block (210 bytes) to 256 floats. Matches ggml's
/// dequantize_row_q6_K exactly: 4-bit low (`ql`) + 2-bit high (`qh`) → signed
/// 6-bit weights centered at −32, scaled by an 8-bit sub-block scale × f16 `d`.
public func ggufDequantQ6K(_ blk: UnsafeRawPointer, _ out: UnsafeMutablePointer<Float>) {
    let ql = blk.assumingMemoryBound(to: UInt8.self)            // 128
    let qh = (blk + 128).assumingMemoryBound(to: UInt8.self)    // 64
    let sc = (blk + 192).assumingMemoryBound(to: Int8.self)     // 16
    let d = ggufF16ToF32(blk.loadUnaligned(fromByteOffset: 208, as: UInt16.self))
    var y = 0, qlo = 0, qho = 0, sco = 0, half = 0
    while half < 2 {
        var l = 0
        while l < 32 {
            let iscl = l / 16
            let v1 = (ql[qlo + l]      & 0xF) | (((qh[qho + l] >> 0) & 3) << 4)
            let v2 = (ql[qlo + l + 32] & 0xF) | (((qh[qho + l] >> 2) & 3) << 4)
            let v3 = (ql[qlo + l]      >> 4)  | (((qh[qho + l] >> 4) & 3) << 4)
            let v4 = (ql[qlo + l + 32] >> 4)  | (((qh[qho + l] >> 6) & 3) << 4)
            out[y + l]      = d * Float(sc[sco + iscl + 0]) * Float(Int32(v1) - 32)
            out[y + l + 32] = d * Float(sc[sco + iscl + 2]) * Float(Int32(v2) - 32)
            out[y + l + 64] = d * Float(sc[sco + iscl + 4]) * Float(Int32(v3) - 32)
            out[y + l + 96] = d * Float(sc[sco + iscl + 6]) * Float(Int32(v4) - 32)
            l += 1
        }
        y += 128; qlo += 64; qho += 32; sco += 8; half += 1
    }
}

// ggml tensor quantization types we recognize (subset; Q4_K_M uses F32/Q4_K/Q6_K).
public enum GGMLType: UInt32 {
    case f32   = 0
    case f16   = 1
    case q4_0  = 2
    case q4_1  = 3
    case q5_0  = 6
    case q5_1  = 7
    case q8_0  = 8
    case q8_1  = 9
    case q2_K  = 10
    case q3_K  = 11
    case q4_K  = 12
    case q5_K  = 13
    case q6_K  = 14
    case q8_K  = 15
}

// GGUF metadata value type tags.
private let gtUInt8: UInt32 = 0, gtInt8: UInt32 = 1
private let gtUInt16: UInt32 = 2, gtInt16: UInt32 = 3
private let gtUInt32: UInt32 = 4, gtInt32: UInt32 = 5
private let gtFloat32: UInt32 = 6, gtBool: UInt32 = 7
private let gtString: UInt32 = 8, gtArray: UInt32 = 9
private let gtUInt64: UInt32 = 10, gtInt64: UInt32 = 11, gtFloat64: UInt32 = 12

public struct GGUFTensor {
    public var nameOff: Int      // byte offset of the name bytes in the base buffer
    public var nameLen: Int
    public var nDims: Int
    public var dims: (Int, Int, Int, Int)
    public var type: UInt32      // ggml type
    public var dataOffset: UInt64  // relative to the (aligned) tensor-data start
}

private struct GGUFKV {
    var keyOff: Int
    var keyLen: Int
    var valueType: UInt32
    var valueOff: Int   // byte offset where the value payload begins
}

public final class GGUFFile {
    public let base: UnsafeRawPointer
    public let count: Int
    public private(set) var version: UInt32 = 0
    public private(set) var tensorCount: Int = 0
    public private(set) var dataStart: Int = 0    // byte offset of the tensor-data blob
    public private(set) var tensors: [GGUFTensor] = []
    public private(set) var ok = false
    private var kvs: [GGUFKV] = []

    // ---- little-endian primitive reads (bounds-checked) ----------------------
    @inline(__always) private func u8(_ o: Int) -> UInt8 {
        base.loadUnaligned(fromByteOffset: o, as: UInt8.self)
    }
    @inline(__always) private func u32(_ o: Int) -> UInt32 {
        base.loadUnaligned(fromByteOffset: o, as: UInt32.self)
    }
    @inline(__always) private func u64(_ o: Int) -> UInt64 {
        base.loadUnaligned(fromByteOffset: o, as: UInt64.self)
    }

    public static func isGGUF(_ base: UnsafeRawPointer) -> Bool {
        // "GGUF" little-endian = 0x46 0x47 0x55 0x46 -> 0x46554747.
        return base.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x4655_4747
    }

    /// Size in bytes of a metadata value of `type` starting at `o` (for ARRAY,
    /// includes the elem-type + count header). Returns -1 on malformed input.
    private func valueSize(_ type: UInt32, _ o: Int) -> Int {
        switch type {
        case gtUInt8, gtInt8, gtBool: return 1
        case gtUInt16, gtInt16: return 2
        case gtUInt32, gtInt32, gtFloat32: return 4
        case gtUInt64, gtInt64, gtFloat64: return 8
        case gtString:
            if o + 8 > count { return -1 }
            return 8 + Int(u64(o))
        case gtArray:
            if o + 12 > count { return -1 }
            let elemType = u32(o)
            let n = Int(u64(o + 4))
            var p = o + 12
            if elemType == gtString || elemType == gtArray {
                // Variable-size elements: walk each.
                for _ in 0..<n {
                    let s = valueSize(elemType, p)
                    if s < 0 { return -1 }
                    p += s
                }
                return p - o
            }
            let es = fixedSize(elemType)
            if es < 0 { return -1 }
            return 12 + n * es
        default: return -1
        }
    }

    private func fixedSize(_ type: UInt32) -> Int {
        switch type {
        case gtUInt8, gtInt8, gtBool: return 1
        case gtUInt16, gtInt16: return 2
        case gtUInt32, gtInt32, gtFloat32: return 4
        case gtUInt64, gtInt64, gtFloat64: return 8
        default: return -1
        }
    }

    public init(base: UnsafeRawPointer, count: Int) {
        self.base = base
        self.count = count
        if count < 24 || !GGUFFile.isGGUF(base) { return }
        version = u32(4)
        if version < 2 || version > 3 { return }
        tensorCount = Int(u64(8))
        let kvCount = Int(u64(16))
        var o = 24

        // ---- metadata KV table ----
        kvs.reserveCapacity(kvCount)
        for _ in 0..<kvCount {
            if o + 8 > count { return }
            let keyLen = Int(u64(o)); o += 8
            let keyOff = o
            o += keyLen
            if o + 4 > count { return }
            let vtype = u32(o); o += 4
            let vsize = valueSize(vtype, o)
            if vsize < 0 || o + vsize > count { return }
            kvs.append(GGUFKV(keyOff: keyOff, keyLen: keyLen, valueType: vtype, valueOff: o))
            o += vsize
        }

        // ---- tensor info table ----
        tensors.reserveCapacity(tensorCount)
        for _ in 0..<tensorCount {
            if o + 8 > count { return }
            let nameLen = Int(u64(o)); o += 8
            let nameOff = o
            o += nameLen
            if o + 4 > count { return }
            let nDims = Int(u32(o)); o += 4
            if nDims < 1 || nDims > 4 || o + nDims * 8 + 12 > count { return }
            var dims = (1, 1, 1, 1)
            for d in 0..<nDims {
                let v = Int(u64(o)); o += 8
                switch d { case 0: dims.0 = v; case 1: dims.1 = v; case 2: dims.2 = v; default: dims.3 = v }
            }
            let gtype = u32(o); o += 4
            let doff = u64(o); o += 8
            tensors.append(GGUFTensor(nameOff: nameOff, nameLen: nameLen, nDims: nDims,
                                      dims: dims, type: gtype, dataOffset: doff))
        }

        // ---- align to the tensor-data blob ----
        let alignment = metaU64("general.alignment") ?? 32
        let a = alignment == 0 ? 32 : Int(alignment)
        dataStart = (o + a - 1) / a * a
        if dataStart > count { return }
        ok = true
    }

    // ---- key lookup + typed getters -----------------------------------------
    private func keyMatches(_ kv: GGUFKV, _ s: StaticString) -> Bool {
        if kv.keyLen != s.utf8CodeUnitCount { return false }
        let sp = s.utf8Start
        var i = 0
        while i < kv.keyLen { if u8(kv.keyOff + i) != sp[i] { return false }; i += 1 }
        return true
    }

    private func find(_ key: StaticString) -> GGUFKV? {
        for kv in kvs where keyMatches(kv, key) { return kv }
        return nil
    }

    /// Read any unsigned integer metadata value as UInt64 (accepts u8..u64).
    public func metaU64(_ key: StaticString) -> UInt64? {
        guard let kv = find(key) else { return nil }
        switch kv.valueType {
        case gtUInt8, gtInt8, gtBool: return UInt64(u8(kv.valueOff))
        case gtUInt16, gtInt16: return UInt64(base.loadUnaligned(fromByteOffset: kv.valueOff, as: UInt16.self))
        case gtUInt32, gtInt32: return UInt64(u32(kv.valueOff))
        case gtUInt64, gtInt64: return u64(kv.valueOff)
        default: return nil
        }
    }

    public func metaInt(_ key: StaticString) -> Int? {
        if let v = metaU64(key) { return Int(bitPattern: UInt(truncatingIfNeeded: v)) }
        return nil
    }

    public func metaF32(_ key: StaticString) -> Float? {
        guard let kv = find(key), kv.valueType == gtFloat32 else { return nil }
        return Float(bitPattern: u32(kv.valueOff))
    }

    /// Run `body` with the raw bytes of a STRING metadata value.
    public func withMetaString<R>(_ key: StaticString, _ body: (UnsafeRawPointer, Int) -> R) -> R? {
        guard let kv = find(key), kv.valueType == gtString else { return nil }
        let len = Int(u64(kv.valueOff))
        return body(base + kv.valueOff + 8, len)
    }

    /// For a STRING-array metadata value (e.g. tokenizer.ggml.tokens): its element
    /// count, and a callback per element with (index, bytes, len).
    public func stringArray(_ key: StaticString, _ body: (Int, UnsafeRawPointer, Int) -> Void) -> Int {
        guard let kv = find(key), kv.valueType == gtArray else { return -1 }
        let elemType = u32(kv.valueOff)
        if elemType != gtString { return -1 }
        let n = Int(u64(kv.valueOff + 4))
        var p = kv.valueOff + 12
        for i in 0..<n {
            let len = Int(u64(p))
            body(i, base + p + 8, len)
            p += 8 + len
        }
        return n
    }

    /// For a FLOAT32-array metadata value (e.g. tokenizer.ggml.scores): count +
    /// per-element callback (index, value).
    public func float32Array(_ key: StaticString, _ body: (Int, Float) -> Void) -> Int {
        guard let kv = find(key), kv.valueType == gtArray else { return -1 }
        let elemType = u32(kv.valueOff)
        if elemType != gtFloat32 { return -1 }
        let n = Int(u64(kv.valueOff + 4))
        var p = kv.valueOff + 12
        for i in 0..<n { body(i, Float(bitPattern: u32(p))); p += 4 }
        return n
    }

    /// Find a tensor by exact name. Linear scan (few hundred tensors).
    public func tensor(_ name: StaticString) -> GGUFTensor? {
        let sp = name.utf8Start
        let sl = name.utf8CodeUnitCount
        for t in tensors {
            if t.nameLen != sl { continue }
            var i = 0
            var eq = true
            while i < sl { if u8(t.nameOff + i) != sp[i] { eq = false; break }; i += 1 }
            if eq { return t }
        }
        return nil
    }

    /// Find a tensor by a runtime name (layer tensors like "blk.3.attn_q.weight").
    public func tensor(name: String) -> GGUFTensor? {
        let bytes = Array(name.utf8)
        for t in tensors {
            if t.nameLen != bytes.count { continue }
            var i = 0, eq = true
            while i < bytes.count { if u8(t.nameOff + i) != bytes[i] { eq = false; break }; i += 1 }
            if eq { return t }
        }
        return nil
    }

    /// Absolute pointer to a tensor's data in the buffer.
    public func tensorData(_ t: GGUFTensor) -> UnsafeRawPointer {
        return base + dataStart + Int(t.dataOffset)
    }
}
