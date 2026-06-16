// SPDX-License-Identifier: Apache-2.0
// datafs.swift — a minimal on-disk read/write filesystem for the persistent
// /data tier (D1). Unlike the read-only packed base (served via extents) and the
// RAM tmpfs (lost on reboot), datafs lives on the writable virtio-blk "data"
// disk (D0) and survives reboot.
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
// All disk I/O goes through virtioBlkData{ReadRange,WriteRange,Flush}, which do
// per-sector read-modify-write, so sub-block writes are safe. Native little-endian
// stores/loads are used directly: the data we read back is only ever written by
// us, on the same aarch64 (LE) target.

private let DFS_BS = 4096
private let DFS_INODE_SIZE = 128
private let DFS_INODE_COUNT = 256
private let DFS_NAME_MAX = 100              // 128 - DI_NAME header bytes
private let DFS_PTRS_PER_INDEX = DFS_BS / 4 // 1024 data-block pointers per file
private let DFS_VERSION: UInt32 = 1

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

private var dfsMounted = false
private var dfsTotalBlocks = 0
private var dfsInodeBlock = 0
private var dfsInodeBlocks = 0
private var dfsBitmapBlock = 0
private var dfsBitmapBlocks = 0
private var dfsDataStart = 0

// Scratch buffers, allocated once at mount and reused (single-threaded VFS path).
private var dfsBitmapPtr: UInt = 0   // in-memory copy of the block bitmap
private var dfsZeroPtr: UInt = 0     // a zeroed block, for zero-fills / zeroing
private var dfsIdxPtr: UInt = 0      // one file index block
private var dfsInoPtr: UInt = 0      // one 128-byte inode record

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

// --- raw disk byte I/O -------------------------------------------------------
private func dfsReadAt(_ off: UInt64, _ buf: UInt, _ len: Int) -> Bool {
    virtioBlkDataReadRange(off, UnsafeMutableRawPointer(bitPattern: buf), UInt32(len)) == 0
}
private func dfsWriteAt(_ off: UInt64, _ buf: UInt, _ len: Int) -> Bool {
    virtioBlkDataWriteRange(off, UnsafeRawPointer(bitPattern: buf), UInt32(len)) == 0
}
private func dfsBlockOff(_ b: Int) -> UInt64 { UInt64(b) * UInt64(DFS_BS) }

private func dfsZeroBuf(_ p: UInt, _ len: Int) {
    let m = UnsafeMutableRawPointer(bitPattern: p)!
    var i = 0
    while i < len { m.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self); i += 1 }
}
// Zero a whole data block on disk (used right after allocation).
private func dfsZeroBlock(_ b: Int) {
    _ = dfsWriteAt(dfsBlockOff(b), dfsZeroPtr, DFS_BS)
}

// --- block bitmap ------------------------------------------------------------
private func dfsBitGet(_ blk: Int) -> Bool {
    let p = UnsafePointer<UInt8>(bitPattern: dfsBitmapPtr)!
    return (p[blk >> 3] & (UInt8(1) << UInt8(blk & 7))) != 0
}
private func dfsBitSet(_ blk: Int, _ v: Bool) {
    let p = UnsafeMutablePointer<UInt8>(bitPattern: dfsBitmapPtr)!
    let mask = UInt8(1) << UInt8(blk & 7)
    if v { p[blk >> 3] |= mask } else { p[blk >> 3] &= ~mask }
}
private func dfsBitmapFlush() {
    _ = dfsWriteAt(dfsBlockOff(dfsBitmapBlock), dfsBitmapPtr, dfsBitmapBlocks * DFS_BS)
}
// Allocate a free data block, zero it, write the bitmap through. -1 if full.
private func dfsAllocBlock() -> Int {
    var b = dfsDataStart
    while b < dfsTotalBlocks {
        if !dfsBitGet(b) {
            dfsBitSet(b, true)
            dfsBitmapFlush()
            dfsZeroBlock(b)
            return b
        }
        b += 1
    }
    return -1
}
private func dfsFreeBlock(_ b: Int) {
    if b >= dfsDataStart && b < dfsTotalBlocks {
        dfsBitSet(b, false)
        dfsBitmapFlush()
    }
}

// --- inode records -----------------------------------------------------------
private func dfsInodeOff(_ ino: Int) -> UInt64 {
    UInt64(dfsInodeBlock) * UInt64(DFS_BS) + UInt64(ino) * UInt64(DFS_INODE_SIZE)
}
// Load inode `ino` into dfsInoPtr. Returns false on I/O error / bad index.
private func dfsLoadInode(_ ino: Int) -> Bool {
    if ino < 0 || ino >= DFS_INODE_COUNT { return false }
    return dfsReadAt(dfsInodeOff(ino), dfsInoPtr, DFS_INODE_SIZE)
}
private func dfsStoreInode(_ ino: Int) -> Bool {
    if ino < 0 || ino >= DFS_INODE_COUNT { return false }
    return dfsWriteAt(dfsInodeOff(ino), dfsInoPtr, DFS_INODE_SIZE)
}

// --- mount / format ----------------------------------------------------------
private func dfsAllocScratch() -> Bool {
    if dfsZeroPtr == 0 {
        guard let z = swiftos_kernel_alloc(UInt(DFS_BS), 16) else { return false }
        dfsZeroPtr = UInt(bitPattern: z); dfsZeroBuf(dfsZeroPtr, DFS_BS)
    }
    if dfsIdxPtr == 0 {
        guard let x = swiftos_kernel_alloc(UInt(DFS_BS), 16) else { return false }
        dfsIdxPtr = UInt(bitPattern: x)
    }
    if dfsInoPtr == 0 {
        guard let n = swiftos_kernel_alloc(UInt(DFS_INODE_SIZE), 16) else { return false }
        dfsInoPtr = UInt(bitPattern: n)
    }
    return true
}

// Write the superblock header (only sector 0, so the D0 boot counter survives).
private func dfsFormat(_ totalBlocks: Int) -> Bool {
    let inodeBlocks = (DFS_INODE_COUNT * DFS_INODE_SIZE + DFS_BS - 1) / DFS_BS
    let inodeBlock = 1
    let bitmapBlock = inodeBlock + inodeBlocks
    let bitsPerBlock = DFS_BS * 8
    let bitmapBlocks = (totalBlocks + bitsPerBlock - 1) / bitsPerBlock
    let dataStart = bitmapBlock + bitmapBlocks
    if dataStart >= totalBlocks { return false }

    dfsTotalBlocks = totalBlocks
    dfsInodeBlock = inodeBlock
    dfsInodeBlocks = inodeBlocks
    dfsBitmapBlock = bitmapBlock
    dfsBitmapBlocks = bitmapBlocks
    dfsDataStart = dataStart

    // Superblock header in sector 0 (magic at 0 is already stamped on disk).
    let sb = dfsZeroPtr  // reuse the zero block as a scratch (we re-zero after)
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
    let okSb = dfsWriteAt(0, sb, 512)
    dfsZeroBuf(dfsZeroPtr, DFS_BS) // restore the all-zero scratch
    if !okSb { return false }

    // Zero the inode table (type 0 = free) and the bitmap region.
    var b = inodeBlock
    while b < bitmapBlock { if !dfsWriteAt(dfsBlockOff(b), dfsZeroPtr, DFS_BS) { return false }; b += 1 }
    // Bitmap: clear all, then mark metadata blocks [0, dataStart) used.
    guard dfsBitmapPtr != 0 else { return false }
    dfsZeroBuf(dfsBitmapPtr, bitmapBlocks * DFS_BS)
    var i = 0
    while i < dataStart { dfsBitSet(i, true); i += 1 }
    dfsBitmapFlush()

    // Root directory = inode 0.
    dfsZeroBuf(dfsInoPtr, DFS_INODE_SIZE)
    dfsSetU8(dfsInoPtr, DI_TYPE, DFS_T_DIR)
    dfsSetU16(dfsInoPtr, DI_PARENT, 0)
    dfsSetU32(dfsInoPtr, DI_MODE, 0o755)
    dfsSetU64(dfsInoPtr, DI_MTIME, rtcNow())
    return dfsStoreInode(0)
}

// Mount the data disk's datafs, formatting it on first boot. Returns false if no
// data disk is attached or I/O fails.
func datafsMount() -> Bool {
    if dfsMounted { return true }
    if !virtioBlkDataAvailable() { return false }
    if !dfsAllocScratch() { return false }

    let sectors = virtioBlkDataCapacitySectors()
    let totalBlocks = Int(sectors / UInt64(DFS_BS / 512))
    if totalBlocks < 16 { return false }

    // Read the superblock (sector 0) and decide format-vs-mount.
    if !dfsReadAt(0, dfsZeroPtr, 512) { dfsZeroBuf(dfsZeroPtr, DFS_BS); return false }
    let version = dfsU32(dfsZeroPtr, SB_VERSION)
    if version != DFS_VERSION {
        // Allocate the bitmap before format (format fills it).
        if dfsBitmapPtr == 0 {
            let bitsPerBlock = DFS_BS * 8
            let bmBlocks = (totalBlocks + bitsPerBlock - 1) / bitsPerBlock
            guard let bm = swiftos_kernel_alloc(UInt(bmBlocks * DFS_BS), 16) else { dfsZeroBuf(dfsZeroPtr, DFS_BS); return false }
            dfsBitmapPtr = UInt(bitPattern: bm)
        }
        dfsZeroBuf(dfsZeroPtr, DFS_BS)
        if !dfsFormat(totalBlocks) { return false }
        _ = virtioBlkDataFlush()
    } else {
        dfsTotalBlocks = Int(dfsU32(dfsZeroPtr, SB_TOTALBLOCKS))
        dfsInodeBlock = Int(dfsU32(dfsZeroPtr, SB_INODEBLOCK))
        dfsInodeBlocks = Int(dfsU32(dfsZeroPtr, SB_INODEBLOCKS))
        dfsBitmapBlock = Int(dfsU32(dfsZeroPtr, SB_BITMAPBLOCK))
        dfsBitmapBlocks = Int(dfsU32(dfsZeroPtr, SB_BITMAPBLOCKS))
        dfsDataStart = Int(dfsU32(dfsZeroPtr, SB_DATASTART))
        dfsZeroBuf(dfsZeroPtr, DFS_BS)
        if dfsBitmapPtr == 0 {
            guard let bm = swiftos_kernel_alloc(UInt(dfsBitmapBlocks * DFS_BS), 16) else { return false }
            dfsBitmapPtr = UInt(bitPattern: bm)
        }
        if !dfsReadAt(dfsBlockOff(dfsBitmapBlock), dfsBitmapPtr, dfsBitmapBlocks * DFS_BS) { return false }
    }
    dfsMounted = true
    return true
}

// --- inode introspection (used by the VFS mirror) ---------------------------
func datafsInodeCount() -> Int { DFS_INODE_COUNT }
func datafsRootInode() -> Int { 0 }
func datafsInodeUsed(_ ino: Int) -> Bool {
    if !dfsLoadInode(ino) { return false }
    return dfsU8(dfsInoPtr, DI_TYPE) != DFS_T_FREE
}
func datafsInodeIsDir(_ ino: Int) -> Bool {
    if !dfsLoadInode(ino) { return false }
    return dfsU8(dfsInoPtr, DI_TYPE) == DFS_T_DIR
}
func datafsInodeParent(_ ino: Int) -> Int {
    if !dfsLoadInode(ino) { return -1 }
    return Int(dfsU16(dfsInoPtr, DI_PARENT))
}
func datafsInodeSize(_ ino: Int) -> Int {
    if !dfsLoadInode(ino) { return 0 }
    return Int(dfsU32(dfsInoPtr, DI_SIZE))
}
func datafsInodeMode(_ ino: Int) -> UInt32 {
    if !dfsLoadInode(ino) { return 0 }
    return dfsU32(dfsInoPtr, DI_MODE)
}
func datafsInodeMtime(_ ino: Int) -> UInt64 {
    if !dfsLoadInode(ino) { return 0 }
    return dfsU64(dfsInoPtr, DI_MTIME)
}
func datafsInodeNameLen(_ ino: Int) -> Int {
    if !dfsLoadInode(ino) { return 0 }
    return Int(dfsU8(dfsInoPtr, DI_NAMELEN))
}
// Copy the inode's inline name into `dst` (up to max). Returns the name length.
func datafsInodeNameCopy(_ ino: Int, _ dst: UnsafeMutablePointer<UInt8>, _ max: Int) -> Int {
    if !dfsLoadInode(ino) { return 0 }
    var n = Int(dfsU8(dfsInoPtr, DI_NAMELEN))
    if n > max { n = max }
    var i = 0
    while i < n { dst[i] = dfsU8(dfsInoPtr, DI_NAME + i); i += 1 }
    return n
}

// --- name matching helper ----------------------------------------------------
private func dfsNameMatches(_ namePtr: UnsafePointer<UInt8>, _ nameLen: Int) -> Bool {
    if Int(dfsU8(dfsInoPtr, DI_NAMELEN)) != nameLen { return false }
    var i = 0
    while i < nameLen { if dfsU8(dfsInoPtr, DI_NAME + i) != namePtr[i] { return false }; i += 1 }
    return true
}

// --- create / remove / rename -----------------------------------------------
// Create a child inode under `parent`. Returns the new inode number, or -1.
func datafsCreate(_ parent: Int, _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int,
                  isDir: Bool, mode: UInt32) -> Int {
    if !dfsMounted || nameLen <= 0 || nameLen > DFS_NAME_MAX { return -1 }
    // Find a free inode (skip 0 = root).
    var ino = 1
    var free = -1
    while ino < DFS_INODE_COUNT {
        if dfsLoadInode(ino) && dfsU8(dfsInoPtr, DI_TYPE) == DFS_T_FREE { free = ino; break }
        ino += 1
    }
    if free < 0 { return -1 }
    dfsZeroBuf(dfsInoPtr, DFS_INODE_SIZE)
    dfsSetU8(dfsInoPtr, DI_TYPE, isDir ? DFS_T_DIR : DFS_T_FILE)
    dfsSetU8(dfsInoPtr, DI_NAMELEN, UInt8(nameLen))
    dfsSetU16(dfsInoPtr, DI_PARENT, UInt16(parent))
    dfsSetU32(dfsInoPtr, DI_MODE, mode)
    dfsSetU64(dfsInoPtr, DI_MTIME, rtcNow())
    var i = 0
    while i < nameLen { dfsSetU8(dfsInoPtr, DI_NAME + i, namePtr[i]); i += 1 }
    if !dfsStoreInode(free) { return -1 }
    return free
}

// Free a file/dir inode and any data it owns. The caller guarantees a directory
// is empty. Returns false on a bad/free inode.
func datafsRemove(_ ino: Int) -> Bool {
    if !dfsMounted || ino <= 0 { return false }
    if !dfsLoadInode(ino) { return false }
    if dfsU8(dfsInoPtr, DI_TYPE) == DFS_T_FREE { return false }
    let index = Int(dfsU32(dfsInoPtr, DI_INDEX))
    if index != 0 {
        if dfsReadAt(dfsBlockOff(index), dfsIdxPtr, DFS_BS) {
            var k = 0
            while k < DFS_PTRS_PER_INDEX {
                let dblk = Int(dfsU32(dfsIdxPtr, k * 4))
                if dblk != 0 { dfsFreeBlock(dblk) }
                k += 1
            }
        }
        dfsFreeBlock(index)
    }
    // Mark the inode free (reload to be safe; dfsIdxPtr work above didn't touch it).
    if !dfsLoadInode(ino) { return false }
    dfsSetU8(dfsInoPtr, DI_TYPE, DFS_T_FREE)
    return dfsStoreInode(ino)
}

// Update an inode's parent and name (rename within datafs).
func datafsSetParentName(_ ino: Int, _ newParent: Int,
                         _ namePtr: UnsafePointer<UInt8>, _ nameLen: Int) -> Bool {
    if !dfsMounted || ino < 0 || nameLen <= 0 || nameLen > DFS_NAME_MAX { return false }
    if !dfsLoadInode(ino) { return false }
    dfsSetU16(dfsInoPtr, DI_PARENT, UInt16(newParent))
    dfsSetU8(dfsInoPtr, DI_NAMELEN, UInt8(nameLen))
    var i = 0
    while i < nameLen { dfsSetU8(dfsInoPtr, DI_NAME + i, namePtr[i]); i += 1 }
    // Clear any stale tail of the old (possibly longer) name.
    while i < DFS_NAME_MAX { dfsSetU8(dfsInoPtr, DI_NAME + i, 0); i += 1 }
    return dfsStoreInode(ino)
}

// --- file read / write / truncate -------------------------------------------
// Ensure the file inode has an index block; returns its block number, or -1.
private func dfsEnsureIndex(_ ino: Int) -> Int {
    var index = Int(dfsU32(dfsInoPtr, DI_INDEX))
    if index == 0 {
        index = dfsAllocBlock()
        if index < 0 { return -1 }
        dfsSetU32(dfsInoPtr, DI_INDEX, UInt32(index))
        if !dfsStoreInode(ino) { dfsFreeBlock(index); return -1 }
    }
    return index
}

func datafsRead(_ ino: Int, _ off: Int, _ dst: UnsafeMutableRawPointer, _ len: Int) -> Int {
    if !dfsMounted || off < 0 || len <= 0 { return 0 }
    if !dfsLoadInode(ino) { return -1 }
    if dfsU8(dfsInoPtr, DI_TYPE) != DFS_T_FILE { return -1 }
    let size = Int(dfsU32(dfsInoPtr, DI_SIZE))
    if off >= size { return 0 }
    let index = Int(dfsU32(dfsInoPtr, DI_INDEX))
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
            if !dfsReadAt(dfsBlockOff(index), dfsIdxPtr, DFS_BS) { return done > 0 ? done : -1 }
            dblk = Int(dfsU32(dfsIdxPtr, fb * 4))
        }
        if dblk == 0 {
            var i = 0
            while i < chunk { out[done + i] = 0; i += 1 } // hole reads as zeros
        } else {
            if !dfsReadAt(dfsBlockOff(dblk) + UInt64(within),
                          UInt(bitPattern: out + done), chunk) {
                return done > 0 ? done : -1
            }
        }
        done += chunk
    }
    return done
}

func datafsWrite(_ ino: Int, _ off: Int, _ src: UnsafeRawPointer, _ len: Int) -> Int {
    if !dfsMounted || off < 0 || len <= 0 { return 0 }
    if !dfsLoadInode(ino) { return -1 }
    if dfsU8(dfsInoPtr, DI_TYPE) != DFS_T_FILE { return -1 }
    if off + len > DFS_PTRS_PER_INDEX * DFS_BS { return -1 } // file size cap
    let index = dfsEnsureIndex(ino)
    if index < 0 { return -1 }
    let inBytes = src.assumingMemoryBound(to: UInt8.self)
    var done = 0
    while done < len {
        let pos = off + done
        let fb = pos / DFS_BS
        let within = pos % DFS_BS
        var chunk = DFS_BS - within
        if chunk > len - done { chunk = len - done }
        if !dfsReadAt(dfsBlockOff(index), dfsIdxPtr, DFS_BS) { break }
        var dblk = Int(dfsU32(dfsIdxPtr, fb * 4))
        if dblk == 0 {
            dblk = dfsAllocBlock()
            if dblk < 0 { break }
            dfsSetU32(dfsIdxPtr, fb * 4, UInt32(dblk))
            if !dfsWriteAt(dfsBlockOff(index), dfsIdxPtr, DFS_BS) { dfsFreeBlock(dblk); break }
        }
        if !dfsWriteAt(dfsBlockOff(dblk) + UInt64(within),
                       UInt(bitPattern: inBytes + done), chunk) { break }
        done += chunk
    }
    if done > 0 {
        // Grow the recorded size and refresh mtime.
        if !dfsLoadInode(ino) { return done }
        let size = Int(dfsU32(dfsInoPtr, DI_SIZE))
        if off + done > size { dfsSetU32(dfsInoPtr, DI_SIZE, UInt32(off + done)) }
        dfsSetU64(dfsInoPtr, DI_MTIME, rtcNow())
        _ = dfsStoreInode(ino)
    }
    return done
}

func datafsTruncate(_ ino: Int, _ newLen: Int) -> Bool {
    if !dfsMounted || newLen < 0 || newLen > DFS_PTRS_PER_INDEX * DFS_BS { return false }
    if !dfsLoadInode(ino) { return false }
    if dfsU8(dfsInoPtr, DI_TYPE) != DFS_T_FILE { return false }
    let old = Int(dfsU32(dfsInoPtr, DI_SIZE))
    let index = Int(dfsU32(dfsInoPtr, DI_INDEX))
    if newLen < old && index != 0 {
        if dfsReadAt(dfsBlockOff(index), dfsIdxPtr, DFS_BS) {
            // Zero the partial tail of the boundary block so a regrow reads zeros.
            let within = newLen % DFS_BS
            if within != 0 {
                let fb = newLen / DFS_BS
                let dblk = Int(dfsU32(dfsIdxPtr, fb * 4))
                if dblk != 0 {
                    _ = dfsWriteAt(dfsBlockOff(dblk) + UInt64(within), dfsZeroPtr, DFS_BS - within)
                }
            }
            // Free whole blocks beyond newLen.
            var fb = (newLen + DFS_BS - 1) / DFS_BS
            while fb < DFS_PTRS_PER_INDEX {
                let dblk = Int(dfsU32(dfsIdxPtr, fb * 4))
                if dblk != 0 { dfsFreeBlock(dblk); dfsSetU32(dfsIdxPtr, fb * 4, 0) }
                fb += 1
            }
            _ = dfsWriteAt(dfsBlockOff(index), dfsIdxPtr, DFS_BS)
        }
    }
    if !dfsLoadInode(ino) { return false }
    dfsSetU32(dfsInoPtr, DI_SIZE, UInt32(newLen))
    dfsSetU64(dfsInoPtr, DI_MTIME, rtcNow())
    return dfsStoreInode(ino)
}

// Flush the data disk's write cache to stable media (D2 builds fsync on this).
func datafsFlush() -> Int32 { virtioBlkDataFlush() }
