// SPDX-License-Identifier: Apache-2.0
// Random.swift — seeded deterministic PRNG, Foundation-free.
//
// Raft's only source of nondeterminism is the randomized election timeout, which
// breaks symmetric split votes. SC1 draws it from a seeded SplitMix64 so a
// (seed, scenario) pair is fully reproducible — no wall clock, no system RNG. Per
// CLAUDE.md/SC1, the per-node stream is varied by node index so two nodes do not
// march in lockstep.

/// SplitMix64 — a tiny, well-distributed PRNG with a 64-bit state. Deterministic
/// and allocation-free; identical output on every platform.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniformly distributed Int in the inclusive range. `range` must be
    /// non-empty and span fewer than 2^63 values (always true for tick counts).
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}
