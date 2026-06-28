// SPDX-License-Identifier: Apache-2.0
// datafs.swift — a minimal on-disk read/write filesystem for the persistent
// /data tier (D1). Unlike the read-only packed base (served via extents) and the
// RAM tmpfs (lost on reboot), datafs lives on a writable virtio-blk disk and
// survives reboot.
//
// V0 (multi-volume): datafs is no longer a singleton. Its former global state
// (geometry + scratch buffers + bound device) now lives in a `DfsVolume` record,
// and the whole API is indexed by a volume slot `vol`. Slot 0 is the legacy
// persistent /data disk (bound to virtioBlkDataDeviceIndex()); later slots bind
// additional writable disks / Hetzner Volumes. Behaviour is unchanged: today the
// VFS only mounts volume 0.
//
// Design (deliberately small, "modern minimalism"):
//   - 4 KiB blocks (8 x 512-byte sectors). Block 0 is the superblock, but only
//     its first sector is written, so the D0 boot counter (sector 2 of the data
//     disk) is preserved.
//   - A fixed inode table (DFS_INODE_COUNT inodes x 128 bytes). Each inode stores
//     its type, parent inode, inline name, size, mode, mtime, and a single index
//     block. Directories have no data blocks: a directory's children are exactly
//     the inodes whose `parent` is that directory — so lookup/readdir is a scan of
//     the (small) inode table. Inode 0 is the root directory.
//   - One index block per file holds up to DFS_PTRS_PER_INDEX (1024) data-block
//     numbers, so a file is capped at ~4 MiB for now (single indirect; a later
//     milestone can add double indirect for larger files).
//   - A block bitmap (kept in memory, written through on change) tracks free
//     data blocks so rewrites/truncation reclaim space (SQLite churns pages).
//
// All disk I/O goes through virtioBlkVolume{ReadRange,WriteRange,Flush} on the
// volume's bound device, which do per-sector read-modify-write, so sub-block
// writes are safe. Native little-endian stores/loads are used directly: the data
// we read back is only ever written by us, on the same aarch64 (LE) target.

private let DFS_BS = 4096
private let DFS_INODE_SIZE = 128
private let DFS_INODE_COUNT = 256
private let DFS_NAME_MAX = 100              // 128 - DI_NAME header bytes
private let DFS_PTRS_PER_INDEX = DFS_BS / 4 // 1024 data-block pointers per file
private let DFS_VERSION: UInt32 = 2          // V2a: superblock carries UUID + label
private let DFS_LABEL_MAX = 31               // label bytes (a short mount-point name)

// Superblock field byte offsets (within sector 0). The 8-byte magic at offset 0
// is also what the virtio-blk scan keys on to identify the data disk.
private let SB_VERSION = 8
private let SB_BLOCKSIZE = 12
private let SB_TOTALBLOCKS = 16
private let SB_INODECOUNT = 20
private let SB_INODEBLOCK = 24
private let SB_INODEBLOCKS = 28
private let SB_BITMAPBLOCK = 32
private let SB_BITMAPBLOCKS = 36
private let SB_DATASTART = 40
// V2a: stable volume identity. UUID is generated once at format; the label is
// provisioned offline (stamped into sector 0 before first boot) and PRESERVED
// across format, so the kernel mounts the volume by its label, not by scan order.
private let SB_UUID = 44        // 16 bytes: 128-bit volume UUID
private let SB_LABELLEN = 60    // u8: label length (0..DFS_LABEL_MAX)
private let SB_LABEL = 61       // up to DFS_LABEL_MAX label bytes (NUL-padded), ends at 91

// Inode on-disk record (128 bytes) field offsets.
private let DI_TYPE = 0      // u8: 0 free, 1 file, 2 dir
private let DI_NAMELEN = 1   // u8
private let DI_PARENT = 2    // u16 inode index
private let DI_SIZE = 4      // u32 byte length
private let DI_MODE = 8      // u32 permission bits
private let DI_INDEX = 12    // u32 index-block number (0 = none)
private let DI_MTIME = 16    // u64 Unix seconds
private let DI_NAME = 24     // inline name bytes

private let DFS_T_FREE: UInt8 = 0
private let DFS_T_FILE: UInt8 = 1
private let DFS_T_DIR: UInt8 = 2

// One mounted datafs instance. Geometry is loaded from the superblock at mount;
// the scratch buffers are allocated once from the kernel heap and reused (the
// VFS path is serialized under vfsLock). `device` is the virtio-blk device this
// volume binds to.
private struct DfsVolume {
    var mounted = false
    var device = -1          // bound virtio-blk device index (-1 = unbound)
    var totalBlocks = 0
    var inodeBlock = 0
    var inodeBlocks = 0
    var bitmapBlock = 0
    var bitmapBlocks = 0
    var dataStart = 0
    var bitmapPtr: UInt = 0  // in-memory copy of the block bitmap
    var zeroPtr: UInt = 0    // a zeroed block, for zero-fills / zeroing
    var idxPtr: UInt = 0     // one file index block
    var inoPtr: UInt = 0     // one 128-byte inode record
    // V2a identity (cached from the superblock at mount).
    var uuidLo: UInt64 = 0   // low 64 bits of the 128-bit volume UUID
    var uuidHi: UInt64 = 0   // high 64 bits
    var labelLen = 0         // 0 = unlabeled
    var labelPtr: UInt = 0   // heap buffer holding up to DFS_LABEL_MAX label bytes
}

private let DFS_MAX_VOLUMES = 4
private var dfsVolumes = [DfsVolume](repeating: DfsVolume(), count: DFS_MAX_VOLUMES)

private func dfsValidVol(_ vol: Int) -> Bool { vol >= 0 && vol < DFS_MAX_VOLUMES }

// --- little-endian field access on a raw buffer -----------------------------
private func dfsU8(_ p: UInt, _ off: Int) -> UInt8 {
    UnsafeRawPointer(bitPattern: p)!.load(fromByteOffset: off, as: UInt8.self)
}
private func dfsSetU8(_ p: UInt, _ off: Int, _ v: UInt8) {
    UnsafeMutableRawPointer(bitPattern: p)!.storeBytes(of: v, toByteOffset: off, as: UInt8.self)
}
private func dfsU16(_ p: UInt, _ off: Int) -> UInt16 {
    UnsafeRawPointer(bitPattern: p)!.load(fromByteOffset: off, as: UInt16.self)
}
private func dfsSetU16(_ p: UInt, _ off: Int, _ v: UInt16) {
    UnsafeMutableRawPointer(bitPattern: p)!.storeBytes(of: v, toByteOffset: off, as: UInt16.self)
}
private func dfsU32(_ p: UInt, _ off: Int) -> UInt32 {
    UnsafeRawPointer(bitPattern: p)!.load(fromByteOffset: off, as: UInt32.self)
}
private func dfsSetU32(_ p: UInt, _ off: Int, _ v: UInt32) {
    UnsafeMutableRawPointer(bitPattern: p)!.storeBytes(of: v, toByteOffset: off, as: UInt32.self)
}
private func dfsU64(_ p: UInt, _ off: Int) -> UInt64 {
    UnsafeRawPointer(bitPattern: p)!.load(fromByteOffset: off, as: UInt64.self)
}
private func dfsSetU64(_ p: UInt, _ off: Int, _ v: UInt64) {
    UnsafeMutableRawPointer(bitPattern: p)!.storeBytes(of: v, toByteOffset: off, as: UInt64.self)
}

// --- raw disk byte I/O (on the volume's bound device) ------------------------
private func dfsReadAt(_ vol: Int, _ off: UInt64, _ buf: UInt, _ len: Int) -> Bool {
    virtioBlkVolumeReadRange(dfsVolumes[vol].device, off,
                             UnsafeMutableRawPointer(bitPattern: buf), UInt32(len)) == 0
}
private func dfsWriteAt(_ vol: Int, _ off: UInt64, _ buf: UInt, _ len: Int) -> Bool {
    virtioBlkVolumeWriteRange(dfsVolumes[vol].device, off,
                              UnsafeRawPointer(bitPattern: buf), UInt32(len)) == 0
}
private func dfsBlockOff(_ b: Int) -> UInt64 { UInt64(b) * UInt64(DFS_BS) }

private func dfsZeroBuf(_ p: UInt, _ len: Int) {
    let m = UnsafeMutableRawPointer(bitPattern: p)!
    var i = 0
    while i < len { m.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self); i += 1 }
}
// Zero a whole data block on disk (used right after allocation).
private func dfsZeroBlock(_ vol: Int, _ b: Int) {
    _ = dfsWriteAt(vol, dfsBlockOff(b), dfsVolumes[vol].zeroPtr, DFS_BS)
}

// --- block bitmap ------------------------------------------------------------
private func dfsBitGet(_ vol: Int, _ blk: Int) -> Bool {
    let p = UnsafePointer<UInt8>(bitPattern: dfsVolumes[vol].bitmapPtr)!
    return (p[blk >> 3] & (UInt8(1) << UInt8(blk & 7))) != 0
}
private func dfsBitSet(_ vol: Int, _ blk: Int, _ v: Bool) {
    let p = UnsafeMutablePointer<UInt8>(bitPattern: dfsVolumes[vol].bitmapPtr)!
    let mask = UInt8(1) << UInt8(blk & 7)
    if v { p[blk >> 3] |= mask } else { p[blk >> 3] &= ~mask }
}
private func dfsBitmapFlush(_ vol: Int) {
    _ = dfsWriteAt(vol, dfsBlockOff(dfsVolumes[vol].bitmapBlock),
                   dfsVolumes[vol].bitmapPtr, dfsVolumes[vol].bitmapBlocks * DFS_BS)
}
// Allocate a free data block, zero it, write the bitmap through. -1 if full.
private func dfsAllocBlock(_ vol: Int) -> Int {
    var b = dfsVolumes[vol].dataStart
    while b < dfsVolumes[vol].totalBlocks {
        if !dfsBitGet(vol, b) {
            dfsBitSet(vol, b, true)
            dfsBitmapFlush(vol)
            dfsZeroBlock(vol, b)
            return b
        }
        b += 1
    }
    return -1
}
private func dfsFreeBlock(_ vol: Int, _ b: Int) {
    if b >= dfsVolumes[vol].dataStart && b < dfsVolumes[vol].totalBlocks {
        dfsBitSet(vol, b, false)
        dfsBitmapFlush(vol)
    }
}

// --- inode records -----------------------------------------------------------
private func dfsInodeOff(_ vol: Int, _ ino: Int) -> UInt64 {
    UInt64(dfsVolumes[vol].inodeBlock) * UInt64(DFS_BS) + UInt64(ino) * UInt64(DFS_INODE_SIZE)
}
// Load inode `ino` into the volume's inoPtr. Returns false on I/O error / bad index.
private func dfsLoadInode(_ vol: Int, _ ino: Int) -> Bool {
    if ino < 0 || ino >= DFS_INODE_COUNT { return false }
    return dfsReadAt(vol, dfsInodeOff(vol, ino), dfsVolumes[vol].inoPtr, DFS_INODE_SIZE)
}
private func dfsStoreInode(_ vol: Int, _ ino: Int) -> Bool {
    if ino < 0 || ino >= DFS_INODE_COUNT { return false }
    return dfsWriteAt(vol, dfsInodeOff(vol, ino), dfsVolumes[vol].inoPtr, DFS_INODE_SIZE)
}

// --- mount / format ----------------------------------------------------------
private func dfsAllocScratch(_ vol: Int) -> Bool {
    if dfsVolumes[vol].zeroPtr == 0 {
        guard let z = swiftos_kernel_alloc(UInt(DFS_BS), 16) else { return false }
        dfsVolumes[vol].zeroPtr = UInt(bitPattern: z); dfsZeroBuf(dfsVolumes[vol].zeroPtr, DFS_BS)
    }
    if dfsVolumes[vol].idxPtr == 0 {
        guard let x = swiftos_kernel_alloc(UInt(DFS_BS), 16) else { return false }
        dfsVolumes[vol].idxPtr = UInt(bitPattern: x)
    }
    if dfsVolumes[vol].inoPtr == 0 {
        guard let n = swiftos_kernel_alloc(UInt(DFS_INODE_SIZE), 16) else { return false }
        dfsVolumes[vol].inoPtr = UInt(bitPattern: n)
    }
    if dfsVolumes[vol].labelPtr == 0 {
        guard let l = swiftos_kernel_alloc(UInt(DFS_LABEL_MAX), 1) else { return false }
        dfsVolumes[vol].labelPtr = UInt(bitPattern: l)
    }
    return true
}

// V2a: a label byte must be a printable, path-safe character so the label can
// name a /mnt mount point. Anything else means the label region is unstamped or
// corrupt — treat the volume as unlabeled.
private func dfsLabelByteOK(_ c: UInt8) -> Bool {
    if c == UInt8(ascii: "/") { return false }
    return c >= 0x21 && c <= 0x7e
}

// V2b guardrail: true iff sector-0 carries the "SWDATAFS" magic. The format path
// only runs when this holds, so datafs NEVER auto-formats a disk that is not
// explicitly marked as ours — a non-blank, non-SWDATAFS disk is left untouched.
private func dfsHasMagic(_ buf: UInt) -> Bool {
    let magic: StaticString = "SWDATAFS"
    var ok = true
    magic.withUTF8Buffer { m in for i in 0..<8 { if dfsU8(buf, i) != m[i] { ok = false } } }
    return ok
}

// V3: true iff sector 0 (the 512-byte superblock region) is entirely zero — a
// genuinely blank disk, safe to format under FORMAT_IF_BLANK. A non-zero sector 0
// without our magic is an unknown disk and is never auto-wiped.
private func dfsSectorBlank(_ buf: UInt) -> Bool {
    var i = 0
    while i < 512 { if dfsU8(buf, i) != 0 { return false }; i += 1 }
    return true
}

// Capture the (pre-stamped or formatted) label from a sector-0 buffer into the
// volume's label cache. Invalid/empty -> labelLen 0 (unlabeled).
private func dfsCaptureLabel(_ vol: Int, _ buf: UInt) {
    var ll = Int(dfsU8(buf, SB_LABELLEN))
    if ll > DFS_LABEL_MAX { ll = 0 }
    let lp = dfsVolumes[vol].labelPtr
    var i = 0
    while i < ll {
        let c = dfsU8(buf, SB_LABEL + i)
        if !dfsLabelByteOK(c) { ll = 0; break }
        if lp != 0 { dfsSetU8(lp, i, c) }
        i += 1
    }
    dfsVolumes[vol].labelLen = ll
}

// V2a: generate the 128-bit volume UUID once, at format time. The RNG is the
// primary source, but it may not yet be producing entropy this early in boot
// (e.g. no virtio-rng device + an unseeded jitter DRBG), so we fold in the wall
// clock and a per-volume salt — a volume UUID needs uniqueness + stability, not
// cryptographic secrecy, so this guarantees a non-zero, unique-enough value in
// every boot configuration.
private func dfsGenUuid(_ vol: Int) {
    var b = [UInt8](repeating: 0, count: 16)
    b.withUnsafeMutableBufferPointer { p in _ = virtioRngRead(p.baseAddress!, 16) }
    var lo: UInt64 = 0, hi: UInt64 = 0
    for i in 0..<8 { lo |= UInt64(b[i]) << (8 * UInt64(i)) }
    for i in 0..<8 { hi |= UInt64(b[8 + i]) << (8 * UInt64(i)) }
    let t = rtcNow()
    lo ^= t &* 0x9e3779b97f4a7c15
    hi ^= (t &+ UInt64(vol) &+ 0xa5a5_a5a5) &* 0xc2b2ae3d27d4eb4f
    if lo == 0 && hi == 0 { lo = 1 }
    dfsVolumes[vol].uuidLo = lo
    dfsVolumes[vol].uuidHi = hi
}

// Write the superblock header (only sector 0, so the D0 boot counter survives).
private func dfsFormat(_ vol: Int, _ totalBlocks: Int) -> Bool {
    let inodeBlocks = (DFS_INODE_COUNT * DFS_INODE_SIZE + DFS_BS - 1) / DFS_BS
    let inodeBlock = 1
    let bitmapBlock = inodeBlock + inodeBlocks
    let bitsPerBlock = DFS_BS * 8
    let bitmapBlocks = (totalBlocks + bitsPerBlock - 1) / bitsPerBlock
    let dataStart = bitmapBlock + bitmapBlocks
    if dataStart >= totalBlocks { return false }

    dfsVolumes[vol].totalBlocks = totalBlocks
    dfsVolumes[vol].inodeBlock = inodeBlock
    dfsVolumes[vol].inodeBlocks = inodeBlocks
    dfsVolumes[vol].bitmapBlock = bitmapBlock
    dfsVolumes[vol].bitmapBlocks = bitmapBlocks
    dfsVolumes[vol].dataStart = dataStart

    // Superblock header in sector 0 (magic at 0 is already stamped on disk).
    let sb = dfsVolumes[vol].zeroPtr  // reuse the zero block as scratch (re-zeroed after)
    dfsZeroBuf(sb, 512)
    let magic: StaticString = "SWDATAFS"
    magic.withUTF8Buffer { m in for i in 0..<8 { dfsSetU8(sb, i, m[i]) } }
    dfsSetU32(sb, SB_VERSION, DFS_VERSION)
    dfsSetU32(sb, SB_BLOCKSIZE, UInt32(DFS_BS))
    dfsSetU32(sb, SB_TOTALBLOCKS, UInt32(totalBlocks))
    dfsSetU32(sb, SB_INODECOUNT, UInt32(DFS_INODE_COUNT))
    dfsSetU32(sb, SB_INODEBLOCK, UInt32(inodeBlock))
    dfsSetU32(sb, SB_INODEBLOCKS, UInt32(inodeBlocks))
    dfsSetU32(sb, SB_BITMAPBLOCK, UInt32(bitmapBlock))
    dfsSetU32(sb, SB_BITMAPBLOCKS, UInt32(bitmapBlocks))
    dfsSetU32(sb, SB_DATASTART, UInt32(dataStart))
    // V2a: stamp the volume identity. The UUID was generated by the caller; the
    // label was captured from the pre-stamped sector 0 (preserved across format).
    dfsSetU64(sb, SB_UUID, dfsVolumes[vol].uuidLo)
    dfsSetU64(sb, SB_UUID + 8, dfsVolumes[vol].uuidHi)
    let ll = dfsVolumes[vol].labelLen
    dfsSetU8(sb, SB_LABELLEN, UInt8(ll))
    let lp = dfsVolumes[vol].labelPtr
    if lp != 0 { var i = 0; while i < ll { dfsSetU8(sb, SB_LABEL + i, dfsU8(lp, i)); i += 1 } }
    let okSb = dfsWriteAt(vol, 0, sb, 512)
    dfsZeroBuf(dfsVolumes[vol].zeroPtr, DFS_BS) // restore the all-zero scratch
    if !okSb { return false }

    // Zero the inode table (type 0 = free) and the bitmap region.
    var b = inodeBlock
    while b < bitmapBlock {
        if !dfsWriteAt(vol, dfsBlockOff(b), dfsVolumes[vol].zeroPtr, DFS_BS) { return false }
        b += 1
    }
    // Bitmap: clear all, then mark metadata blocks [0, dataStart) used.
    guard dfsVolumes[vol].bitmapPtr != 0 else { return false }
    dfsZeroBuf(dfsVolumes[vol].bitmapPtr, bitmapBlocks * DFS_BS)
    var i = 0
    while i < dataStart { dfsBitSet(vol, i, true); i += 1 }
    dfsBitmapFlush(vol)

    // Root directory = inode 0.
    dfsZeroBuf(dfsVolumes[vol].inoPtr, DFS_INODE_SIZE)
    dfsSetU8(dfsVolumes[vol].inoPtr, DI_TYPE, DFS_T_DIR)
    dfsSetU16(dfsVolumes[vol].inoPtr, DI_PARENT, 0)
    dfsSetU32(dfsVolumes[vol].inoPtr, DI_MODE, 0o755)
    dfsSetU64(dfsVolumes[vol].inoPtr, DI_MTIME, rtcNow())
    return dfsStoreInode(vol, 0)
}

// Mount volume `vol`'s datafs on `device`, formatting it on first boot. Returns
// false if the device is absent, too small, or I/O fails. Slot 0 binds the
// legacy /data disk (device = virtioBlkDataDeviceIndex()). V2c: when `usePinned`
// is set and the disk is being formatted (first boot), the root volume's UUID is
// stamped to `pinnedLo`/`pinnedHi` (the kernel-cmdline anchor) instead of being
// generated, so future boots match the root by that UUID.
func datafsMount(_ vol: Int, _ device: Int,
                 pinnedLo: UInt64 = 0, pinnedHi: UInt64 = 0, usePinned: Bool = false,
                 formatBlank: Bool = false) -> Bool {
    if !dfsValidVol(vol) || device < 0 { return false }
    if dfsVolumes[vol].mounted { return true }
    dfsVolumes[vol].device = device
    if !dfsAllocScratch(vol) { return false }

    let sectors = virtioBlkVolumeCapacitySectors(device)
    let totalBlocks = Int(sectors / UInt64(DFS_BS / 512))
    if totalBlocks < 16 { return false }
    let z = dfsVolumes[vol].zeroPtr

    // Read the superblock (sector 0) and decide format-vs-mount.
    if !dfsReadAt(vol, 0, z, 512) { dfsZeroBuf(z, DFS_BS); return false }
    // V2a: capture the volume label from sector 0 now, before the format path
    // zeroes the buffer — an offline-provisioned label is preserved across format.
    dfsCaptureLabel(vol, z)
    let version = dfsU32(z, SB_VERSION)
    if version != DFS_VERSION {
        // V2b guardrail: only (re)format a disk explicitly marked as ours. A disk
        // without the SWDATAFS magic — an unknown, possibly-data-bearing disk — is
        // never auto-formatted; refuse the mount instead of wiping it.
        //   V3 FORMAT_IF_BLANK relaxes this for a *genuinely blank* disk (sector 0
        //   all zero — e.g. a freshly attached cloud volume), which we may stamp
        //   and format. A non-zero sector 0 without our magic stays an unknown disk
        //   and is still refused, never wiped.
        if !dfsHasMagic(z) && !(formatBlank && dfsSectorBlank(z)) { dfsZeroBuf(z, DFS_BS); return false }
        // First boot (or an older format): take the cmdline-pinned UUID for the
        // root (V2c), else generate a fresh one; dfsFormat then stamps UUID + the
        // captured label into the new superblock.
        if usePinned { dfsVolumes[vol].uuidLo = pinnedLo; dfsVolumes[vol].uuidHi = pinnedHi }
        else { dfsGenUuid(vol) }
        // Allocate the bitmap before format (format fills it).
        if dfsVolumes[vol].bitmapPtr == 0 {
            let bitsPerBlock = DFS_BS * 8
            let bmBlocks = (totalBlocks + bitsPerBlock - 1) / bitsPerBlock
            guard let bm = swiftos_kernel_alloc(UInt(bmBlocks * DFS_BS), 16) else { dfsZeroBuf(z, DFS_BS); return false }
            dfsVolumes[vol].bitmapPtr = UInt(bitPattern: bm)
        }
        dfsZeroBuf(z, DFS_BS)
        if !dfsFormat(vol, totalBlocks) { return false }
        _ = virtioBlkVolumeFlush(device)
    } else {
        // Already V2-formatted: load the persisted UUID (label already captured).
        dfsVolumes[vol].uuidLo = dfsU64(z, SB_UUID)
        dfsVolumes[vol].uuidHi = dfsU64(z, SB_UUID + 8)
        dfsVolumes[vol].totalBlocks = Int(dfsU32(z, SB_TOTALBLOCKS))
        dfsVolumes[vol].inodeBlock = Int(dfsU32(z, SB_INODEBLOCK))
        dfsVolumes[vol].inodeBlocks = Int(dfsU32(z, SB_INODEBLOCKS))
        dfsVolumes[vol].bitmapBlock = Int(dfsU32(z, SB_BITMAPBLOCK))
        dfsVolumes[vol].bitmapBlocks = Int(dfsU32(z, SB_BITMAPBLOCKS))
        dfsVolumes[vol].dataStart = Int(dfsU32(z, SB_DATASTART))
        dfsZeroBuf(z, DFS_BS)
        if dfsVolumes[vol].bitmapPtr == 0 {
            guard let bm = swiftos_kernel_alloc(UInt(dfsVolumes[vol].bitmapBlocks * DFS_BS), 16) else { return false }
            dfsVolumes[vol].bitmapPtr = UInt(bitPattern: bm)
        }
        if !dfsReadAt(vol, dfsBlockOff(dfsVolumes[vol].bitmapBlock),
                      dfsVolumes[vol].bitmapPtr, dfsVolumes[vol].bitmapBlocks * DFS_BS) { return false }
    }
    dfsVolumes[vol].mounted = true
    return true
}

// --- V2a volume identity (used by the VFS mount-point naming) ---------------
// Label length (0 = unlabeled), and a copy of the label bytes into `dst`.
func datafsVolumeLabelLen(_ vol: Int) -> Int { dfsValidVol(vol) ? dfsVolumes[vol].labelLen : 0 }
func datafsVolumeLabelCopy(_ vol: Int, _ dst: UnsafeMutablePointer<UInt8>, _ max: Int) -> Int {
    if !dfsValidVol(vol) { return 0 }
    var n = dfsVolumes[vol].labelLen
    if n > max { n = max }
    let lp = dfsVolumes[vol].labelPtr
    if lp == 0 { return 0 }
    var i = 0
    while i < n { dst[i] = dfsU8(lp, i); i += 1 }
    return n
}
// The two halves of the 128-bit volume UUID (stable across reboot once formatted).
func datafsVolumeUuidLo(_ vol: Int) -> UInt64 { dfsValidVol(vol) ? dfsVolumes[vol].uuidLo : 0 }
func datafsVolumeUuidHi(_ vol: Int) -> UInt64 { dfsValidVol(vol) ? dfsVolumes[vol].uuidHi : 0 }

// V2a: read a device's datafs label WITHOUT mounting it (sector-0 peek), so the
// VFS can pick the root /data disk (the unlabeled one) and route labeled disks to
// /mnt/<label> independent of scan order. Returns the label length (0 = unlabeled,
// not a datafs, or corrupt), copying the bytes into `dst`. Works on a freshly
// provisioned disk (label stamped offline) and on an already-formatted one.
func datafsPeekLabel(_ device: Int, _ dst: UnsafeMutablePointer<UInt8>, _ max: Int) -> Int {
    if device < 0 { return 0 }
    var got = 0
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { buf in
        guard let base = buf.baseAddress else { return }
        if virtioBlkVolumeReadRange(device, 0, base, 512) != 0 { return }
        let p = UInt(bitPattern: base)
        let magic: StaticString = "SWDATAFS"
        var ok = true
        magic.withUTF8Buffer { m in for i in 0..<8 { if dfsU8(p, i) != m[i] { ok = false } } }
        if !ok { return }
        var ll = Int(dfsU8(p, SB_LABELLEN))
        if ll > DFS_LABEL_MAX || ll > max { return }
        var i = 0
        while i < ll {
            let c = dfsU8(p, SB_LABEL + i)
            if !dfsLabelByteOK(c) { ll = 0; break }
            dst[i] = c
            i += 1
        }
        got = ll
    }
    return got
}

// V2c: read a device's datafs UUID without mounting. Returns (lo, hi, formatted);
// `formatted` is true only for an already-v2-formatted disk — a blank/SWDATAFS-
// stamped but unformatted disk returns false so the caller can format it as the
// pinned root.
func datafsPeekUuid(_ device: Int) -> (lo: UInt64, hi: UInt64, formatted: Bool) {
    if device < 0 { return (0, 0, false) }
    var rlo: UInt64 = 0, rhi: UInt64 = 0, fmt = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { buf in
        guard let base = buf.baseAddress else { return }
        if virtioBlkVolumeReadRange(device, 0, base, 512) != 0 { return }
        let p = UInt(bitPattern: base)
        if !dfsHasMagic(p) || dfsU32(p, SB_VERSION) != DFS_VERSION { return }
        rlo = dfsU64(p, SB_UUID)
        rhi = dfsU64(p, SB_UUID + 8)
        fmt = true
    }
    return (rlo, rhi, fmt)
}

// --- inode introspection (used by the VFS mirror) ---------------------------
func datafsInodeCount() -> Int { DFS_INODE_COUNT }
func datafsRootInode() -> Int { 0 }
func datafsInodeUsed(_ vol: Int, _ ino: Int) -> Bool {
    if !dfsLoadInode(vol, ino) { return false }
    return dfsU8(dfsVolumes[vol].inoPtr, DI_TYPE) != DFS_T_FREE
}
func datafsInodeIsDir(_ vol: Int, _ ino: Int) -> Bool {
    if !dfsLoadInode(vol, ino) { return false }
    return dfsU8(dfsVolumes[vol].inoPtr, DI_TYPE) == DFS_T_DIR
}
func datafsInodeParent(_ vol: Int, _ ino: Int) -> Int {
    if !dfsLoadInode(vol, ino) { return -1 }
    return Int(dfsU16(dfsVolumes[vol].inoPtr, DI_PARENT))
}
func datafsInodeSize(_ vol: Int, _ ino: Int) -> Int {
    if !dfsLoadInode(vol, ino) { return 0 }
    return Int(dfsU32(dfsVolumes[vol].inoPtr, DI_SIZE))
}
func datafsInodeMode(_ vol: Int, _ ino: Int) -> UInt32 {
    if !dfsLoadInode(vol, ino) { return 0 }
    return dfsU32(dfsVolumes[vol].inoPtr, DI_MODE)
}
func datafsInodeMtime(_ vol: Int, _ ino: Int) -> UInt64 {
    if !dfsLoadInode(vol, ino) { return 0 }
    return dfsU64(dfsVolumes[vol].inoPtr, DI_MTIME)
}
func datafsInodeNameLen(_ vol: Int, _ ino: Int) -> Int {
    if !dfsLoadInode(vol, ino) { return 0 }
    return Int(dfsU8(dfsVolumes[vol].inoPtr, DI_NAMELEN))
}
// Copy the inode's inline name into `dst` (up to max). Returns the name length.
func datafsInodeNameCopy(_ vol: Int, _ ino: Int, _ dst: UnsafeMutablePointer<UInt8>, _ max: Int) -> Int {
    if !dfsLoadInode(vol, ino) { return 0 }
    var n = Int(dfsU8(dfsVolumes[vol].inoPtr, DI_NAMELEN))
    if n > max { n = max }
    var i = 0
    while i < n { dst[i] = dfsU8(dfsVolumes[vol].inoPtr, DI_NAME + i); i += 1 }
    return n
}

// --- create / remove / rename -----------------------------------------------
// Create a child inode under `parent`. Returns the new inode number, or -1.
func datafsCreate(_ vol: Int, _ parent: Int, _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int,
                  isDir: Bool, mode: UInt32) -> Int {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted || nameLen <= 0 || nameLen > DFS_NAME_MAX { return -1 }
    let ino0 = dfsVolumes[vol].inoPtr
    // Find a free inode (skip 0 = root).
    var ino = 1
    var free = -1
    while ino < DFS_INODE_COUNT {
        if dfsLoadInode(vol, ino) && dfsU8(ino0, DI_TYPE) == DFS_T_FREE { free = ino; break }
        ino += 1
    }
    if free < 0 { return -1 }
    dfsZeroBuf(ino0, DFS_INODE_SIZE)
    dfsSetU8(ino0, DI_TYPE, isDir ? DFS_T_DIR : DFS_T_FILE)
    dfsSetU8(ino0, DI_NAMELEN, UInt8(nameLen))
    dfsSetU16(ino0, DI_PARENT, UInt16(parent))
    dfsSetU32(ino0, DI_MODE, mode)
    dfsSetU64(ino0, DI_MTIME, rtcNow())
    var i = 0
    while i < nameLen { dfsSetU8(ino0, DI_NAME + i, namePtr[i]); i += 1 }
    if !dfsStoreInode(vol, free) { return -1 }
    return free
}

// Free a file/dir inode and any data it owns. The caller guarantees a directory
// is empty. Returns false on a bad/free inode.
func datafsRemove(_ vol: Int, _ ino: Int) -> Bool {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted || ino <= 0 { return false }
    if !dfsLoadInode(vol, ino) { return false }
    if dfsU8(dfsVolumes[vol].inoPtr, DI_TYPE) == DFS_T_FREE { return false }
    let index = Int(dfsU32(dfsVolumes[vol].inoPtr, DI_INDEX))
    if index != 0 {
        if dfsReadAt(vol, dfsBlockOff(index), dfsVolumes[vol].idxPtr, DFS_BS) {
            var k = 0
            while k < DFS_PTRS_PER_INDEX {
                let dblk = Int(dfsU32(dfsVolumes[vol].idxPtr, k * 4))
                if dblk != 0 { dfsFreeBlock(vol, dblk) }
                k += 1
            }
        }
        dfsFreeBlock(vol, index)
    }
    // Mark the inode free (reload to be safe; idxPtr work above didn't touch it).
    if !dfsLoadInode(vol, ino) { return false }
    dfsSetU8(dfsVolumes[vol].inoPtr, DI_TYPE, DFS_T_FREE)
    return dfsStoreInode(vol, ino)
}

// Update an inode's parent and name (rename within datafs).
func datafsSetParentName(_ vol: Int, _ ino: Int, _ newParent: Int,
                         _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int) -> Bool {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted || ino < 0 || nameLen <= 0 || nameLen > DFS_NAME_MAX { return false }
    if !dfsLoadInode(vol, ino) { return false }
    let ino0 = dfsVolumes[vol].inoPtr
    dfsSetU16(ino0, DI_PARENT, UInt16(newParent))
    dfsSetU8(ino0, DI_NAMELEN, UInt8(nameLen))
    var i = 0
    while i < nameLen { dfsSetU8(ino0, DI_NAME + i, namePtr[i]); i += 1 }
    // Clear any stale tail of the old (possibly longer) name.
    while i < DFS_NAME_MAX { dfsSetU8(ino0, DI_NAME + i, 0); i += 1 }
    return dfsStoreInode(vol, ino)
}

// --- file read / write / truncate -------------------------------------------
// Ensure the file inode has an index block; returns its block number, or -1.
private func dfsEnsureIndex(_ vol: Int, _ ino: Int) -> Int {
    var index = Int(dfsU32(dfsVolumes[vol].inoPtr, DI_INDEX))
    if index == 0 {
        index = dfsAllocBlock(vol)
        if index < 0 { return -1 }
        dfsSetU32(dfsVolumes[vol].inoPtr, DI_INDEX, UInt32(index))
        if !dfsStoreInode(vol, ino) { dfsFreeBlock(vol, index); return -1 }
    }
    return index
}

func datafsRead(_ vol: Int, _ ino: Int, _ off: Int, _ dst: UnsafeMutableRawPointer, _ len: Int) -> Int {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted || off < 0 || len <= 0 { return 0 }
    if !dfsLoadInode(vol, ino) { return -1 }
    if dfsU8(dfsVolumes[vol].inoPtr, DI_TYPE) != DFS_T_FILE { return -1 }
    let size = Int(dfsU32(dfsVolumes[vol].inoPtr, DI_SIZE))
    if off >= size { return 0 }
    let index = Int(dfsU32(dfsVolumes[vol].inoPtr, DI_INDEX))
    var want = len
    if off + want > size { want = size - off }
    let out = dst.assumingMemoryBound(to: UInt8.self)
    var done = 0
    while done < want {
        let pos = off + done
        let fb = pos / DFS_BS
        let within = pos % DFS_BS
        var chunk = DFS_BS - within
        if chunk > want - done { chunk = want - done }
        var dblk = 0
        if index != 0 && fb < DFS_PTRS_PER_INDEX {
            if !dfsReadAt(vol, dfsBlockOff(index), dfsVolumes[vol].idxPtr, DFS_BS) { return done > 0 ? done : -1 }
            dblk = Int(dfsU32(dfsVolumes[vol].idxPtr, fb * 4))
        }
        if dblk == 0 {
            var i = 0
            while i < chunk { out[done + i] = 0; i += 1 } // hole reads as zeros
        } else {
            if !dfsReadAt(vol, dfsBlockOff(dblk) + UInt64(within),
                          UInt(bitPattern: out + done), chunk) {
                return done > 0 ? done : -1
            }
        }
        done += chunk
    }
    return done
}

func datafsWrite(_ vol: Int, _ ino: Int, _ off: Int, _ src: UnsafeRawPointer, _ len: Int) -> Int {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted || off < 0 || len <= 0 { return 0 }
    if !dfsLoadInode(vol, ino) { return -1 }
    if dfsU8(dfsVolumes[vol].inoPtr, DI_TYPE) != DFS_T_FILE { return -1 }
    if off + len > DFS_PTRS_PER_INDEX * DFS_BS { return -1 } // file size cap
    let index = dfsEnsureIndex(vol, ino)
    if index < 0 { return -1 }
    let inBytes = src.assumingMemoryBound(to: UInt8.self)
    var done = 0
    while done < len {
        let pos = off + done
        let fb = pos / DFS_BS
        let within = pos % DFS_BS
        var chunk = DFS_BS - within
        if chunk > len - done { chunk = len - done }
        if !dfsReadAt(vol, dfsBlockOff(index), dfsVolumes[vol].idxPtr, DFS_BS) { break }
        var dblk = Int(dfsU32(dfsVolumes[vol].idxPtr, fb * 4))
        if dblk == 0 {
            dblk = dfsAllocBlock(vol)
            if dblk < 0 { break }
            dfsSetU32(dfsVolumes[vol].idxPtr, fb * 4, UInt32(dblk))
            if !dfsWriteAt(vol, dfsBlockOff(index), dfsVolumes[vol].idxPtr, DFS_BS) { dfsFreeBlock(vol, dblk); break }
        }
        if !dfsWriteAt(vol, dfsBlockOff(dblk) + UInt64(within),
                       UInt(bitPattern: inBytes + done), chunk) { break }
        done += chunk
    }
    if done > 0 {
        // Grow the recorded size and refresh mtime.
        if !dfsLoadInode(vol, ino) { return done }
        let size = Int(dfsU32(dfsVolumes[vol].inoPtr, DI_SIZE))
        if off + done > size { dfsSetU32(dfsVolumes[vol].inoPtr, DI_SIZE, UInt32(off + done)) }
        dfsSetU64(dfsVolumes[vol].inoPtr, DI_MTIME, rtcNow())
        _ = dfsStoreInode(vol, ino)
    }
    return done
}

func datafsTruncate(_ vol: Int, _ ino: Int, _ newLen: Int) -> Bool {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted || newLen < 0 || newLen > DFS_PTRS_PER_INDEX * DFS_BS { return false }
    if !dfsLoadInode(vol, ino) { return false }
    if dfsU8(dfsVolumes[vol].inoPtr, DI_TYPE) != DFS_T_FILE { return false }
    let old = Int(dfsU32(dfsVolumes[vol].inoPtr, DI_SIZE))
    let index = Int(dfsU32(dfsVolumes[vol].inoPtr, DI_INDEX))
    if newLen < old && index != 0 {
        if dfsReadAt(vol, dfsBlockOff(index), dfsVolumes[vol].idxPtr, DFS_BS) {
            // Zero the partial tail of the boundary block so a regrow reads zeros.
            let within = newLen % DFS_BS
            if within != 0 {
                let fb = newLen / DFS_BS
                let dblk = Int(dfsU32(dfsVolumes[vol].idxPtr, fb * 4))
                if dblk != 0 {
                    _ = dfsWriteAt(vol, dfsBlockOff(dblk) + UInt64(within), dfsVolumes[vol].zeroPtr, DFS_BS - within)
                }
            }
            // Free whole blocks beyond newLen.
            var fb = (newLen + DFS_BS - 1) / DFS_BS
            while fb < DFS_PTRS_PER_INDEX {
                let dblk = Int(dfsU32(dfsVolumes[vol].idxPtr, fb * 4))
                if dblk != 0 { dfsFreeBlock(vol, dblk); dfsSetU32(dfsVolumes[vol].idxPtr, fb * 4, 0) }
                fb += 1
            }
            _ = dfsWriteAt(vol, dfsBlockOff(index), dfsVolumes[vol].idxPtr, DFS_BS)
        }
    }
    if !dfsLoadInode(vol, ino) { return false }
    dfsSetU32(dfsVolumes[vol].inoPtr, DI_SIZE, UInt32(newLen))
    dfsSetU64(dfsVolumes[vol].inoPtr, DI_MTIME, rtcNow())
    return dfsStoreInode(vol, ino)
}

// Flush volume `vol`'s data disk write cache to stable media (D2 fsync builds on
// this). Returns the underlying virtio-blk flush result (0 on success).
func datafsFlush(_ vol: Int) -> Int32 {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted { return -1 }
    return virtioBlkVolumeFlush(dfsVolumes[vol].device)
}

// Flush every mounted datafs volume to stable media (D2 sync()).
func datafsSyncAll() {
    var vol = 0
    while vol < DFS_MAX_VOLUMES {
        if dfsVolumes[vol].mounted { _ = virtioBlkVolumeFlush(dfsVolumes[vol].device) }
        vol += 1
    }
}

// V3: release a runtime-mounted datafs volume slot so the slot — and its disk —
// can be remounted later. Flush first for durability, then clear the binding. The
// fixed scratch buffers (zero/idx/inode/label) are kept for reuse; the block
// bitmap is dropped (its size tracks the disk, so a later mount of a different
// disk into this slot reallocates a correctly sized one).
func datafsUnmount(_ vol: Int) -> Bool {
    if !dfsValidVol(vol) || !dfsVolumes[vol].mounted { return false }
    _ = virtioBlkVolumeFlush(dfsVolumes[vol].device)
    dfsVolumes[vol].mounted = false
    dfsVolumes[vol].device = -1
    dfsVolumes[vol].bitmapPtr = 0   // size tracks the disk; reallocate on remount
    dfsVolumes[vol].totalBlocks = 0
    dfsVolumes[vol].uuidLo = 0
    dfsVolumes[vol].uuidHi = 0
    dfsVolumes[vol].labelLen = 0
    return true
}

// V3: the first unmounted (free) datafs slot, or -1 if all slots are in use. The
// VFS picks a free slot for a runtime mount.
func datafsFindFreeVolume() -> Int {
    var vol = 0
    while vol < DFS_MAX_VOLUMES {
        if !dfsVolumes[vol].mounted { return vol }
        vol += 1
    }
    return -1
}

// V3: the slot a given virtio-blk device is currently mounted on, or -1 if none.
// Lets the VFS skip an already-mounted disk when resolving a mount selector.
func datafsDeviceMountedSlot(_ device: Int) -> Int {
    if device < 0 { return -1 }
    var vol = 0
    while vol < DFS_MAX_VOLUMES {
        if dfsVolumes[vol].mounted && dfsVolumes[vol].device == device { return vol }
        vol += 1
    }
    return -1
}
