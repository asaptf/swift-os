// SPDX-License-Identifier: Apache-2.0
// sysrng.swift — kernel CSPRNG with a hardware-independent jitter-entropy seed.
//
// SYS_RANDOM (#80) prefers virtio-rng when the hypervisor exposes it (QEMU
// `-device virtio-rng`). Hetzner Cloud ARM VMs do NOT expose a virtio-rng
// device, and the Neoverse-N1 core has no FEAT_RNG (RNDR) instruction — so
// without a fallback getentropy() fails and OpenSSL's DRBG refuses to
// instantiate ("entropy source strength too weak"), taking nginx/TLS down while
// leaving sshd on weak image-seeded randomness.
//
// This module gathers entropy from generic-timer (CNTPCT_EL0) execution-timing
// jitter — the same source class as Linux's jitterentropy-rng; on a KVM guest
// the dominant noise is VM-exit / host-scheduling latency variance — whitens it
// with SHA-256 into a 256-bit pool, and runs a ChaCha20 DRBG that rekeys after
// every request for backtracking resistance, reseeding fresh jitter periodically.

private var rngReady = false
private var drbgKey = [UInt8](repeating: 0, count: 32)
private var drbgNonce = [UInt8](repeating: 0, count: 12)
private var drbgCounter: UInt32 = 0
private var entPool = [UInt8](repeating: 0, count: 32)
private var jitterBuf = [UInt64](repeating: 0, count: 256)   // 2 KiB sample buffer
private var scratchBlk = [UInt8](repeating: 0, count: 64)    // one ChaCha20 block
private var bytesSinceReseed = 0
private let RESEED_BYTES = 1 << 16   // re-mix fresh jitter every 64 KiB served

// Cache-walk scratch page makes the timed work data-dependent so its latency
// varies with cache / pipeline / VM-exit noise. Best-effort: jitter still works
// (with less variance) from the bare CNTPCT loop if the allocation fails.
private var walkPage: UInt = 0
private var walkAccum: UInt64 = 0x9e3779b97f4a7c15   // anti-DCE sink + walk index

// Collect `count` raw CNTPCT deltas. The low bits carry micro-architectural and
// hypervisor-scheduling timing noise; SHA-256 downstream condenses them.
private func collectJitter(_ out: UnsafeMutablePointer<UInt64>, _ count: Int) {
    var i = 0
    while i < count {
        let t0 = read_cntpct_el0()
        let folds = 32 + Int(walkAccum & 0x3F)
        var k = 0
        if walkPage != 0 {
            let p = UnsafeMutableRawPointer(bitPattern: walkPage)!
            while k < folds {
                let off = Int(walkAccum & 0xFF8)   // 0..4088, 8-byte aligned
                let v = p.load(fromByteOffset: off, as: UInt64.self)
                walkAccum = (walkAccum ^ v) &* 0x100000001b3 &+ UInt64(k)
                p.storeBytes(of: walkAccum, toByteOffset: off, as: UInt64.self)
                k += 1
            }
        } else {
            var a = walkAccum
            while k < folds {
                a = a &* 6364136223846793005 &+ 1442695040888963407
                k += 1
            }
            walkAccum = a
        }
        let t1 = read_cntpct_el0()
        out[i] = t1 &- t0
        i += 1
    }
}

// Absorb fresh jitter + architectural/boot-variance inputs into the pool. The
// existing pool is folded back in first, so a reseed only ever ADDS entropy.
private func reseedPool(_ blocks: Int) {
    var s = Sha256Stream()
    entPool.withUnsafeBytes { s.update($0.baseAddress!, $0.count) }
    var b = 0
    while b < blocks {
        jitterBuf.withUnsafeMutableBytes { jraw in
            let jp = jraw.baseAddress!.assumingMemoryBound(to: UInt64.self)
            collectJitter(jp, 256)
            s.update(jraw.baseAddress!, jraw.count)   // 2048 bytes of deltas
        }
        var ids = (read_cntpct_el0(), read_cntfrq_el0(), read_mpidr_el1(), walkAccum)
        withUnsafeBytes(of: &ids) { s.update($0.baseAddress!, $0.count) }
        // Uninitialized scratch-page RAM contributes boot-to-boot variance.
        if walkPage != 0 {
            s.update(UnsafeRawPointer(bitPattern: walkPage)!, 512)
        }
        b += 1
    }
    entPool.withUnsafeMutableBytes { s.final($0.baseAddress!) }
}

// Derive the DRBG key (SHA256(pool‖0x01)) and nonce (SHA256(pool‖0x02)[0..<12])
// so leaking a keystream-derived key never exposes the pool itself.
private func deriveKeyNonce() {
    var dg = [UInt8](repeating: 0, count: 32)

    var s1 = Sha256Stream()
    entPool.withUnsafeBytes { s1.update($0.baseAddress!, $0.count) }
    var tag1: UInt8 = 0x01
    withUnsafeBytes(of: &tag1) { s1.update($0.baseAddress!, 1) }
    dg.withUnsafeMutableBytes { s1.final($0.baseAddress!) }
    var i = 0
    while i < 32 { drbgKey[i] = dg[i]; i += 1 }

    var s2 = Sha256Stream()
    entPool.withUnsafeBytes { s2.update($0.baseAddress!, $0.count) }
    var tag2: UInt8 = 0x02
    withUnsafeBytes(of: &tag2) { s2.update($0.baseAddress!, 1) }
    dg.withUnsafeMutableBytes { s2.final($0.baseAddress!) }
    i = 0
    while i < 12 { drbgNonce[i] = dg[i]; i += 1 }

    drbgCounter = 0
}

// Backtracking resistance: replace the key with one fresh keystream block so a
// future state compromise cannot reproduce already-served output.
private func rekeyForward() {
    scratchBlk.withUnsafeMutableBytes { braw in
        drbgKey.withUnsafeBytes { kraw in
            drbgNonce.withUnsafeBytes { nraw in
                chacha20Block(key: kraw.baseAddress!, counter: drbgCounter,
                              nonce: nraw.baseAddress!, out: braw.baseAddress!)
            }
        }
    }
    var i = 0
    scratchBlk.withUnsafeBytes { braw in
        while i < 32 {
            drbgKey[i] = braw.load(fromByteOffset: i, as: UInt8.self)
            i += 1
        }
    }
    drbgCounter = 0
}

/// Initialise the jitter-seeded DRBG. Cheap (a few ms of timing loops); safe to
/// call once heap + generic timer are up. Idempotent.
func sysRngInit() {
    if rngReady { return }
    if walkPage == 0 {
        let pg = pmm_alloc_page()
        if pg != 0 { walkPage = pg }   // leave its RAM as-is — extra boot noise
    }
    reseedPool(8)
    deriveKeyNonce()
    bytesSinceReseed = 0
    rngReady = true
}

/// True once the DRBG is seeded and able to serve SYS_RANDOM.
func sysRngHealthy() -> Bool { rngReady }

/// Fill `count` bytes at `dst` from the ChaCha20 DRBG. Returns `count`, or a
/// negative errno on bad arguments. Always succeeds once seeded — this is the
/// SYS_RANDOM fallback when no virtio-rng device exists.
func sysRngFill(_ dst: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int {
    if count == 0 { return 0 }
    if count < 0 { return Errno.invalid.code }   // EINVAL
    if !rngReady { sysRngInit() }
    if !rngReady { return Errno.io.code }    // EIO (allocation/seed failure — should not happen)

    // Per-call freshness: stir a live timing sample into the nonce so two calls
    // never reuse keystream, even before the next periodic reseed.
    let t = read_cntpct_el0() ^ (walkAccum << 17)
    var j = 0
    while j < 8 {
        drbgNonce[j] = drbgNonce[j] ^ UInt8((t >> (UInt64(j) * 8)) & 0xFF)
        j += 1
    }

    var produced = 0
    while produced < count {
        scratchBlk.withUnsafeMutableBytes { braw in
            drbgKey.withUnsafeBytes { kraw in
                drbgNonce.withUnsafeBytes { nraw in
                    chacha20Block(key: kraw.baseAddress!, counter: drbgCounter,
                                  nonce: nraw.baseAddress!, out: braw.baseAddress!)
                }
            }
        }
        drbgCounter &+= 1
        let n = min(64, count - produced)
        scratchBlk.withUnsafeBytes { braw in
            var i = 0
            while i < n {
                dst[produced + i] = braw.load(fromByteOffset: i, as: UInt8.self)
                i += 1
            }
        }
        produced += n
    }

    rekeyForward()

    bytesSinceReseed += count
    if bytesSinceReseed >= RESEED_BYTES {
        reseedPool(2)
        deriveKeyNonce()
        bytesSinceReseed = 0
    }
    return count
}
