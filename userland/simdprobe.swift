// SPDX-License-Identifier: Apache-2.0
// simdprobe.swift — LM1b diagnostic: isolate the int8 NEON codegen discrepancy.
//
// The Q8 inference path (QLlama2.qmatmul) produced output that diverges from the
// scalar/host reference when compiled with +neon and run under QEMU, while the
// fp32 path is fine. This probe pins down WHERE: in a single +neon-compiled
// binary it computes the same int8·int8 -> int32 dot two ways —
//   (a) a forced-scalar reference (`@_optimize(none)`, no auto-vectorization),
//   (b) the explicit SIMD16<Int8> -> SIMD16<Int32> form,
// over runtime-seeded data (no mmap / demand paging involved), and compares.
//
//   SCALAR == SIMD  -> the NEON int8 computation is correct on QEMU; the llmd
//                      divergence is elsewhere (mmap/demand-paging/other).
//   SCALAR != SIMD  -> the int8 NEON path itself is wrong here (Embedded-Swift
//                      codegen or QEMU-TCG NEON emulation). The printed operands
//                      that differ point at the failure mode (e.g. sign
//                      extension of negative Int8 lanes).
//
// Emits "SIMDPROBE: case <name> scalar=<x> simd=<y> <OK|MISMATCH>" per case and
// a final "SIMDPROBE: ALL OK" / "SIMDPROBE: MISMATCH FOUND" line.

private func putStatic(_ s: StaticString) {
    if s.hasPointerRepresentation {
        let p = s.utf8Start
        for i in 0..<s.utf8CodeUnitCount { swiftos_putc(p[i]) }
    }
}

private func putInt(_ value: Int32) {
    var v = Int(value)
    if v < 0 { swiftos_putc(0x2D); v = -v }   // "-"
    if v == 0 { swiftos_putc(0x30); return }
    var digits = [UInt8](repeating: 0, count: 12)
    var count = 0
    while v > 0 { digits[count] = UInt8(0x30 + (v % 10)); v /= 10; count += 1 }
    while count > 0 { count -= 1; swiftos_putc(digits[count]) }
}

// Forced-scalar ground truth: @_optimize(none) keeps LLVM from vectorizing it,
// so this is a true element-by-element Int32 accumulation regardless of +neon.
@_optimize(none)
private func dotScalar(_ a: UnsafePointer<Int8>, _ b: UnsafePointer<Int8>, _ n: Int) -> Int32 {
    var acc: Int32 = 0
    for k in 0..<n { acc &+= Int32(a[k]) &* Int32(b[k]) }
    return acc
}

// The explicit-SIMD form mirrors the (reverted) qmatmul vectorization.
private func dotSIMD(_ a: UnsafePointer<Int8>, _ b: UnsafePointer<Int8>, _ n: Int) -> Int32 {
    var acc = SIMD16<Int32>(repeating: 0)
    var k = 0
    while k + 16 <= n {
        let av: SIMD16<Int8> = UnsafeRawPointer(a + k).loadUnaligned(as: SIMD16<Int8>.self)
        let bv: SIMD16<Int8> = UnsafeRawPointer(b + k).loadUnaligned(as: SIMD16<Int8>.self)
        acc &+= SIMD16<Int32>(truncatingIfNeeded: av) &* SIMD16<Int32>(truncatingIfNeeded: bv)
        k += 16
    }
    var s = acc.wrappedSum()
    while k < n { s &+= Int32(a[k]) &* Int32(b[k]); k += 1 }
    return s
}

// Faithful copies of QLlama2.qmatmul: the float scaling beside the int dot is
// what pushes the register allocator to spill into x18 (the AArch64 platform
// register) in the real engine — the one structural difference from the simple
// dot cases above. Running this in a long loop accumulates timer preemptions /
// context switches, so if x18 (or any state) is not preserved across them, the
// SIMD result will eventually diverge from a precomputed scalar reference.
@_optimize(none)
private func qmatmulScalar(_ out: UnsafeMutablePointer<Float>, _ xq: UnsafePointer<Int8>, _ xs: UnsafePointer<Float>,
                           _ wq: UnsafePointer<Int8>, _ ws: UnsafePointer<Float>, _ n: Int, _ d: Int, _ gs: Int) {
    for i in 0..<d {
        var val: Float = 0
        let iN = i * n
        var j = 0
        while j + gs <= n {
            var ival: Int32 = 0
            for k in 0..<gs { ival &+= Int32(xq[j + k]) &* Int32(wq[iN + j + k]) }
            val += Float(ival) * ws[(iN + j) / gs] * xs[j / gs]
            j += gs
        }
        out[i] = val
    }
}

private func qmatmulSIMD(_ out: UnsafeMutablePointer<Float>, _ xq: UnsafePointer<Int8>, _ xs: UnsafePointer<Float>,
                         _ wq: UnsafePointer<Int8>, _ ws: UnsafePointer<Float>, _ n: Int, _ d: Int, _ gs: Int) {
    for i in 0..<d {
        var val: Float = 0
        let iN = i * n
        var j = 0
        while j + gs <= n {
            var acc = SIMD16<Int32>(repeating: 0)
            var k = 0
            while k + 16 <= gs {
                let av: SIMD16<Int8> = UnsafeRawPointer(xq + (j + k)).loadUnaligned(as: SIMD16<Int8>.self)
                let bv: SIMD16<Int8> = UnsafeRawPointer(wq + (iN + j + k)).loadUnaligned(as: SIMD16<Int8>.self)
                acc &+= SIMD16<Int32>(truncatingIfNeeded: av) &* SIMD16<Int32>(truncatingIfNeeded: bv)
                k += 16
            }
            var ival = acc.wrappedSum()
            while k < gs { ival &+= Int32(xq[j + k]) &* Int32(wq[iN + j + k]); k += 1 }
            val += Float(ival) * ws[(iN + j) / gs] * xs[j / gs]
            j += gs
        }
        out[i] = val
    }
}

private var mismatch = false

private func runCase(_ name: StaticString, _ a: UnsafePointer<Int8>, _ b: UnsafePointer<Int8>, _ n: Int) {
    let s = dotScalar(a, b, n)
    let v = dotSIMD(a, b, n)
    swiftos_puts("SIMDPROBE: case ")
    putStatic(name)
    swiftos_puts(" scalar=")
    putInt(s)
    swiftos_puts(" simd=")
    putInt(v)
    swiftos_putc(0x20)
    if s == v { swiftos_puts("OK") } else { swiftos_puts("MISMATCH"); mismatch = true }
    swiftos_putc(0x0A)
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argv; _ = envp
    let n = 64
    // Runtime seed (argc) defeats compile-time folding of the dot products.
    let seed = Int(argc)
    let a = UnsafeMutablePointer<Int8>.allocate(capacity: n)
    let b = UnsafeMutablePointer<Int8>.allocate(capacity: n)
    defer { a.deallocate(); b.deallocate() }

    // Case 1: all positive small values (sign extension is a no-op here).
    for k in 0..<n { a[k] = Int8((k + seed) % 100); b[k] = Int8((k * 3 + seed) % 100) }
    runCase("pos", a, b, n)

    // Case 2: mixed sign — the likely failure mode if signed widening is wrong.
    for k in 0..<n {
        a[k] = Int8(((k * 7 + seed * 3) % 251) - 125)
        b[k] = Int8(((k * 5 + seed) % 251) - 125)
    }
    runCase("mixed", a, b, n)

    // Case 3: all negative (every lane needs sign extension).
    for k in 0..<n { a[k] = Int8(-1 - (k % 100)); b[k] = Int8(-1 - ((k * 2) % 100)) }
    runCase("neg", a, b, n)

    // Case 4: extremes (-128 / 127) — max-magnitude products.
    for k in 0..<n { a[k] = (k % 2 == 0) ? -128 : 127; b[k] = (k % 3 == 0) ? 127 : -128 }
    runCase("extreme", a, b, n)

    // Case 5: the real qmatmul shape (forces x18 spill), looped long enough to
    // be preempted many times, compared against a precomputed scalar reference.
    let qn = 288, qd = 64, gs = 32     // n like stories15M dim; d kept modest
    let wq = UnsafeMutablePointer<Int8>.allocate(capacity: qd * qn)
    let ws = UnsafeMutablePointer<Float>.allocate(capacity: qd * qn / gs)
    let xq = UnsafeMutablePointer<Int8>.allocate(capacity: qn)
    let xs = UnsafeMutablePointer<Float>.allocate(capacity: qn / gs)
    let ref = UnsafeMutablePointer<Float>.allocate(capacity: qd)
    let got = UnsafeMutablePointer<Float>.allocate(capacity: qd)
    defer { wq.deallocate(); ws.deallocate(); xq.deallocate(); xs.deallocate(); ref.deallocate(); got.deallocate() }
    for i in 0..<(qd * qn) { wq[i] = Int8(((i * 13 + seed) % 251) - 125) }
    for i in 0..<(qd * qn / gs) { ws[i] = Float((i % 7) + 1) * 0.01 }
    for k in 0..<qn { xq[k] = Int8(((k * 9 + seed * 2) % 251) - 125) }
    for g in 0..<(qn / gs) { xs[g] = Float((g % 5) + 1) * 0.02 }

    qmatmulScalar(ref, xq, xs, wq, ws, qn, qd, gs)

    let iters = 4000
    var firstBad = -1
    for t in 0..<iters {
        qmatmulSIMD(got, xq, xs, wq, ws, qn, qd, gs)
        for i in 0..<qd where got[i] != ref[i] { firstBad = t; break }
        if firstBad >= 0 { break }
    }
    swiftos_puts("SIMDPROBE: case qmatmul iters=")
    putInt(Int32(iters))
    if firstBad < 0 {
        swiftos_puts(" all matched OK\n")
    } else {
        swiftos_puts(" diverged at iter="); putInt(Int32(firstBad)); swiftos_puts(" MISMATCH\n")
        mismatch = true
    }

    swiftos_puts(mismatch ? "SIMDPROBE: MISMATCH FOUND\n" : "SIMDPROBE: ALL OK\n")
    return 0
}
