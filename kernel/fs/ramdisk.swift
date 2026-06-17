// SPDX-License-Identifier: Apache-2.0
// ramdisk.swift — RAM-backed read-only base image (H3).
//
// On the Hetzner ARM VM the boot disk is virtio-scsi over PCIe, which the kernel
// does not drive. Rather than write a virtio-scsi driver just to mount the
// read-only base FS, the UEFI loader reads the packed base image (base.img,
// "SWOSBASE") from the ESP — via the firmware's Simple File System, transport-
// agnostic — into a reserved RAM region and hands the kernel its base + size in
// x4/x5. The VFS then serves the read-only base from RAM instead of issuing
// virtio-blk reads; /tmp is RAM anyway, so this fits the FS design. The
// virtio-blk path stays for the QEMU `-kernel` test profile (no ramdisk).
//
// The loader places the image below 2 GiB so it falls inside the 1 GiB of RAM
// the early MMU map covers as normal memory (vm_early.c, l1_table[1]).

var ramdiskBase: UInt = 0
var ramdiskSize: UInt = 0

@inline(__always)
func ramdiskAvailable() -> Bool { ramdiskBase != 0 && ramdiskSize != 0 }

/// Record the loader's ramdisk handoff (x4 = base, x5 = size). Ignored if either
/// is zero (the QEMU `-kernel` path passes 0/0 and keeps the virtio-blk base).
func ramdiskInit(base: UInt, size: UInt) {
    if base == 0 || size == 0 { return }
    ramdiskBase = base
    ramdiskSize = size
    uartPuts("H3 ramdisk: base ")
    uartPutHex(base)
    uartPuts(" size ")
    uartPutHex(size)
    uartPuts("\n")
}

/// Read `len` bytes at `byteOff` of the RAM base image into `buf`. Mirrors the
/// virtio-blk read contract the VFS expects: returns **0 on success** (the whole
/// request was satisfied from the image), or a negative errno on a bad/short
/// request. Bounds are overflow-safe.
func ramdiskReadRange(_ byteOff: UInt64, _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    guard let dst = buf, ramdiskBase != 0 else { return -1 }
    if len == 0 { return 0 }
    let end = byteOff &+ UInt64(len)
    if byteOff > UInt64(ramdiskSize) || end > UInt64(ramdiskSize) || end < byteOff {
        return -5 // EIO: request falls outside the RAM image
    }
    let off = UInt(byteOff)
    let n = UInt(len)

    let src = UnsafeRawPointer(bitPattern: ramdiskBase + off)!
    // Word-at-a-time copy with a byte tail (the image is normal cacheable RAM).
    var i: UInt = 0
    while i + 8 <= n {
        dst.storeBytes(of: src.load(fromByteOffset: Int(i), as: UInt64.self),
                       toByteOffset: Int(i), as: UInt64.self)
        i += 8
    }
    while i < n {
        dst.storeBytes(of: src.load(fromByteOffset: Int(i), as: UInt8.self),
                       toByteOffset: Int(i), as: UInt8.self)
        i += 1
    }
    return 0
}
