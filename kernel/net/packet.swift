// SPDX-License-Identifier: Apache-2.0
// packet.swift — byte-level helpers shared by the sans-IO network core.
//
// Pure Swift: no MMIO, no heap allocation on the per-packet path, no syscalls.
// These files compile both into the kernel (Embedded Swift) and into a host
// unit test (tests/net_test.swift), exactly like kernel/arch/aarch64/fdt.swift.
// The driver (kernel/drivers/virtio_net.swift) is the only kernel-only file and
// is NOT part of the host test; it pumps real frame bytes through this core.
//
// All multi-byte protocol fields are big-endian (network byte order). We read
// and write them byte-by-byte so nothing depends on host alignment or
// endianness — important because the kernel builds with +strict-align and the
// frame bytes live in DMA buffers at arbitrary offsets.

/// An IPv4 address held in host order (e.g. 10.0.2.2 == 0x0A000202). Converted
/// to/from big-endian only at the wire boundary by `be32`/`be32set`.
typealias IPv4 = UInt32

/// A 48-bit Ethernet MAC address.
struct MAC: Equatable {
    var a: UInt8, b: UInt8, c: UInt8, d: UInt8, e: UInt8, f: UInt8
    init(_ a: UInt8 = 0, _ b: UInt8 = 0, _ c: UInt8 = 0,
         _ d: UInt8 = 0, _ e: UInt8 = 0, _ f: UInt8 = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }
    static let broadcast = MAC(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
    static let zero = MAC()
}

@inline(__always) func b8(_ p: UnsafeRawPointer, _ off: Int) -> UInt8 {
    p.load(fromByteOffset: off, as: UInt8.self)
}
@inline(__always) func b8set(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt8) {
    p.storeBytes(of: v, toByteOffset: off, as: UInt8.self)
}
@inline(__always) func be16(_ p: UnsafeRawPointer, _ off: Int) -> UInt16 {
    (UInt16(b8(p, off)) << 8) | UInt16(b8(p, off + 1))
}
@inline(__always) func be16set(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt16) {
    b8set(p, off, UInt8(v >> 8)); b8set(p, off + 1, UInt8(v & 0xFF))
}
@inline(__always) func be32(_ p: UnsafeRawPointer, _ off: Int) -> UInt32 {
    (UInt32(b8(p, off)) << 24) | (UInt32(b8(p, off + 1)) << 16) |
    (UInt32(b8(p, off + 2)) << 8) | UInt32(b8(p, off + 3))
}
@inline(__always) func be32set(_ p: UnsafeMutableRawPointer, _ off: Int, _ v: UInt32) {
    b8set(p, off, UInt8((v >> 24) & 0xFF)); b8set(p, off + 1, UInt8((v >> 16) & 0xFF))
    b8set(p, off + 2, UInt8((v >> 8) & 0xFF)); b8set(p, off + 3, UInt8(v & 0xFF))
}

@inline(__always) func macGet(_ p: UnsafeRawPointer, _ off: Int) -> MAC {
    MAC(b8(p, off), b8(p, off + 1), b8(p, off + 2),
        b8(p, off + 3), b8(p, off + 4), b8(p, off + 5))
}
@inline(__always) func macSet(_ p: UnsafeMutableRawPointer, _ off: Int, _ m: MAC) {
    b8set(p, off, m.a); b8set(p, off + 1, m.b); b8set(p, off + 2, m.c)
    b8set(p, off + 3, m.d); b8set(p, off + 4, m.e); b8set(p, off + 5, m.f)
}

// The internet checksum (RFC 1071) is a ones-complement sum of 16-bit words.
// These three helpers let a checksum span several regions — UDP needs the IPv4
// pseudo-header plus the UDP header and payload — by accumulating into a 32-bit
// running sum and folding once at the end. `inetChecksum` is the single-region
// case used by the IPv4 header and ICMP.

/// Add the big-endian 16-bit words of `[p, p+len)` to a running sum.
func sumBytes(_ acc: UInt32, _ p: UnsafeRawPointer, _ len: Int) -> UInt32 {
    var sum = acc
    var i = 0
    while i + 1 < len {
        sum &+= (UInt32(b8(p, i)) << 8) | UInt32(b8(p, i + 1))
        i += 2
    }
    if i < len { sum &+= UInt32(b8(p, i)) << 8 }  // odd trailing byte
    return sum
}

/// Add one 16-bit word to a running sum (for pseudo-header fields).
@inline(__always) func sumWord(_ acc: UInt32, _ v: UInt16) -> UInt32 { acc &+ UInt32(v) }

/// Fold the carries and complement to produce the final checksum field.
func foldChecksum(_ acc: UInt32) -> UInt16 {
    var sum = acc
    while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
    return UInt16(~sum & 0xFFFF)
}

/// The RFC 1071 internet checksum over `[p, p+len)`. Used for both the IPv4
/// header and the ICMP message. A buffer whose checksum field already holds the
/// correct value sums to 0, which is how we validate received packets.
func inetChecksum(_ p: UnsafeRawPointer, _ len: Int) -> UInt16 {
    foldChecksum(sumBytes(0, p, len))
}
