// SPDX-License-Identifier: Apache-2.0
// store.swift - narrow read-only package-store activation reader (P3).

private let pkgStoreMagic0: UInt8 = 0x53 // S
private let pkgStoreHeaderSize = 512
private let pkgStoreRecordHeaderSize = 128
private let pkgStoreSectorSize = 512
private let pkgStoreMaxRecords = 128
private let pkgStoreMaxPayloads = 32
private let pkgStoreMaxActivations = 32
private let pkgStoreActivationHeaderSize = 16
private let pkgStoreActivationEntrySize = 80
private let pkgStoreInstallChunkSize = 4096
private let swpkgHeaderSize = 128

private let pkgRecordKindPayload: UInt32 = 1
private let pkgRecordKindActivation: UInt32 = 2
private let pkgRecordKindActivePointer: UInt32 = 3
private let pkgRecordMagicString: StaticString = "SWPSREC1"
private let pkgActivationMagicString: StaticString = "SWPACT01"

private struct PackageStorePayload {
    var inUse = false
    var active = false
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var h0: UInt64 = 0
    var h1: UInt64 = 0
    var h2: UInt64 = 0
    var h3: UInt64 = 0
}

private struct PackageStoreActivation {
    var inUse = false
    var generation: UInt64 = 0
    var offset: UInt64 = 0
    var size: UInt64 = 0
}

private var pkgPayloads = [PackageStorePayload](repeating: PackageStorePayload(), count: pkgStoreMaxPayloads)
private var pkgActivations = [PackageStoreActivation](repeating: PackageStoreActivation(), count: pkgStoreMaxActivations)
private var pkgActivePayloadIndex = [Int](repeating: -1, count: pkgStoreMaxPayloads)
private var pkgActivePayloadCountValue = 0
private var pkgActiveGeneration: UInt64 = 0
private var pkgMaxGeneration: UInt64 = 0
private var pkgNextRecordOffset: UInt64 = UInt64(pkgStoreHeaderSize)
private var pkgStoreLockWord: UInt64 = 0
private var pkgStoreLockAcquireCount: UInt64 = 0
private var pkgStoreLockContentionCount: UInt64 = 0
private var pkgStoreMutationInProgress = false

@inline(__always)
private func pkgStoreLock() -> UInt64 {
    let daif = irq_save()
    var contended = false
    while true {
        var expected: UInt64 = 0
        let acquired = withUnsafeMutablePointer(to: &pkgStoreLockWord) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if acquired {
            if contended {
                withUnsafeMutablePointer(to: &pkgStoreLockContentionCount) { count in
                    _ = smpAtomicFetchAdd(count, 1)
                }
            }
            withUnsafeMutablePointer(to: &pkgStoreLockAcquireCount) { count in
                _ = smpAtomicFetchAdd(count, 1)
            }
            smpMemoryBarrier()
            return daif
        }
        contended = true
        smpLoadBarrier()
    }
}

@inline(__always)
private func pkgStoreUnlock(_ daif: UInt64) {
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &pkgStoreLockWord) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

@inline(__always)
private func pkgStoreAtomicLoad(_ word: inout UInt64) -> UInt64 {
    withUnsafeMutablePointer(to: &word) { ptr in
        smpAtomicLoad(ptr)
    }
}

private func pkgLe32(_ p: UnsafePointer<UInt8>, _ off: Int) -> UInt32 {
    UInt32(p[off]) | (UInt32(p[off + 1]) << 8) |
    (UInt32(p[off + 2]) << 16) | (UInt32(p[off + 3]) << 24)
}

private func pkgLe64(_ p: UnsafePointer<UInt8>, _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    var i = 7
    while i >= 0 {
        v = (v << 8) | UInt64(p[off + i])
        i -= 1
    }
    return v
}

private func pkgPutLe32(_ p: UnsafeMutablePointer<UInt8>, _ off: Int, _ v: UInt32) {
    p[off] = UInt8(v & 0xFF)
    p[off + 1] = UInt8((v >> 8) & 0xFF)
    p[off + 2] = UInt8((v >> 16) & 0xFF)
    p[off + 3] = UInt8((v >> 24) & 0xFF)
}

private func pkgPutLe64(_ p: UnsafeMutablePointer<UInt8>, _ off: Int, _ v: UInt64) {
    var i = 0
    while i < 8 {
        p[off + i] = UInt8((v >> UInt64(i * 8)) & 0xFF)
        i += 1
    }
}

private func pkgBytesEqual(_ p: UnsafePointer<UInt8>, _ off: Int, _ magic: StaticString) -> Bool {
    var ok = true
    magic.withUTF8Buffer { m in
        if m.count > 8 { ok = false; return }
        var i = 0
        while i < m.count {
            if p[off + i] != m[i] { ok = false }
            i += 1
        }
    }
    return ok
}

private func pkgBytesEqualRaw(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
    var i = 0
    while i < count {
        if a[i] != b[i] { return false }
        i += 1
    }
    return true
}

private func pkgAlignUp(_ n: UInt64, _ align: UInt64) -> UInt64 {
    (n + align - 1) & ~(align - 1)
}

private func pkgClear() {
    var i = 0
    while i < pkgStoreMaxPayloads {
        pkgPayloads[i] = PackageStorePayload()
        pkgActivePayloadIndex[i] = -1
        i += 1
    }
    i = 0
    while i < pkgStoreMaxActivations {
        pkgActivations[i] = PackageStoreActivation()
        i += 1
    }
    pkgActivePayloadCountValue = 0
    pkgActiveGeneration = 0
    pkgMaxGeneration = 0
    pkgNextRecordOffset = UInt64(pkgStoreHeaderSize)
}

private func pkgStoreBeginMutation() -> Bool {
    let daif = pkgStoreLock()
    defer { pkgStoreUnlock(daif) }
    if pkgStoreMutationInProgress { return false }
    pkgStoreMutationInProgress = true
    return true
}

private func pkgStoreEndMutation() {
    let daif = pkgStoreLock()
    pkgStoreMutationInProgress = false
    pkgStoreUnlock(daif)
}

private func pkgStoreNextGeneration() -> UInt64 {
    let daif = pkgStoreLock()
    defer { pkgStoreUnlock(daif) }
    return pkgMaxGeneration + 1
}

private func pkgReserveRecord(dataSize: UInt64) -> (rc: Int, recordOffset: UInt64, dataOffset: UInt64, next: UInt64) {
    let daif = pkgStoreLock()
    defer { pkgStoreUnlock(daif) }
    if !virtioBlkPackageStoreAvailable() { return (-2, 0, 0, 0) }
    let recordOffset = pkgNextRecordOffset
    let dataOffset = recordOffset + UInt64(pkgStoreRecordHeaderSize)
    let (end, overflow) = dataOffset.addingReportingOverflow(dataSize)
    if overflow { return (-28, 0, 0, 0) }
    let cap = virtioBlkPackageStoreCapacityBytes()
    if end > cap { return (-28, 0, 0, 0) }
    let next = pkgAlignUp(end, UInt64(pkgStoreSectorSize))
    if next < end || next > cap {
        return (-28, 0, 0, 0)
    }
    return (0, recordOffset, dataOffset, next)
}

private func pkgCommitRecordNext(_ next: UInt64) {
    let daif = pkgStoreLock()
    if next > pkgNextRecordOffset { pkgNextRecordOffset = next }
    pkgStoreUnlock(daif)
}

private func pkgRecordHashParts(_ p: UnsafePointer<UInt8>, _ off: Int) -> (UInt64, UInt64, UInt64, UInt64) {
    (pkgLe64(p, off), pkgLe64(p, off + 8), pkgLe64(p, off + 16), pkgLe64(p, off + 24))
}

private func pkgAddPayload(_ dataOffset: UInt64, _ dataSize: UInt64,
                           _ h0: UInt64, _ h1: UInt64, _ h2: UInt64, _ h3: UInt64) {
    var i = 0
    while i < pkgStoreMaxPayloads {
        if !pkgPayloads[i].inUse {
            pkgPayloads[i].inUse = true
            pkgPayloads[i].offset = dataOffset
            pkgPayloads[i].size = dataSize
            pkgPayloads[i].h0 = h0
            pkgPayloads[i].h1 = h1
            pkgPayloads[i].h2 = h2
            pkgPayloads[i].h3 = h3
            return
        }
        i += 1
    }
}

private func pkgAddActivation(_ generation: UInt64, _ dataOffset: UInt64, _ dataSize: UInt64) {
    if generation > pkgMaxGeneration { pkgMaxGeneration = generation }
    var i = 0
    while i < pkgStoreMaxActivations {
        if !pkgActivations[i].inUse {
            pkgActivations[i].inUse = true
            pkgActivations[i].generation = generation
            pkgActivations[i].offset = dataOffset
            pkgActivations[i].size = dataSize
            return
        }
        i += 1
    }
}

private func pkgCopyCString(_ va: UInt, _ maxLen: Int,
                            _ dst: UnsafeMutablePointer<UInt8>, _ cap: Int) -> Int {
    guard maxLen > 0, cap > 0, let src = userCString(va, maxLen: maxLen) else { return -22 }
    var n = 0
    while n < cap && src[n] != 0 {
        dst[n] = src[n]
        n += 1
    }
    if n == 0 || n >= cap { return -22 }
    return n
}

private func pkgCopyPadded(_ dst: UnsafeMutablePointer<UInt8>, _ off: Int, _ cap: Int,
                           _ src: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    if len <= 0 || len > cap { return false }
    var i = 0
    while i < cap {
        dst[off + i] = i < len ? src[i] : 0
        i += 1
    }
    return true
}

private func pkgCopyStaticPadded(_ dst: UnsafeMutablePointer<UInt8>, _ off: Int, _ cap: Int,
                                 _ src: StaticString) -> Bool {
    var ok = true
    src.withUTF8Buffer { bp in
        ok = pkgCopyPadded(dst, off, cap, bp.baseAddress!, bp.count)
    }
    return ok
}

private func pkgHashFileRange(fd: Int, offset: UInt64, size: UInt64,
                              out: UnsafeMutablePointer<UInt8>) -> Int {
    guard let raw = swiftos_kernel_alloc(UInt(pkgStoreInstallChunkSize), 16) else { return -12 }
    var sha = SHA256Stream()
    var done: UInt64 = 0
    while done < size {
        var chunk = UInt64(pkgStoreInstallChunkSize)
        if chunk > size - done { chunk = size - done }
        let got = vfsKernelReadFile(fd: fd, offset: Int(offset + done), buffer: raw, count: Int(chunk))
        if got != Int(chunk) { return -22 }
        sha.update(UnsafeRawPointer(raw), Int(chunk))
        done += chunk
    }
    sha.finalize(UnsafeMutableRawPointer(out))
    return 0
}

private func pkgWriteZeroPadding(from start: UInt64, to end: UInt64) -> Int {
    if end <= start { return 0 }
    let zeros = [UInt8](repeating: 0, count: pkgStoreSectorSize)
    var off = start
    while off < end {
        var chunk = UInt64(pkgStoreSectorSize)
        if chunk > end - off { chunk = end - off }
        let rc = zeros.withUnsafeBytes { raw in
            virtioBlkWritePackageStoreRange(off, raw.baseAddress, UInt32(chunk))
        }
        if rc != 0 { return Int(rc) }
        off += chunk
    }
    return 0
}

private func pkgWriteFileRangeToStore(fd: Int, fileOffset: UInt64, storeOffset: UInt64,
                                      size: UInt64) -> Int {
    guard let raw = swiftos_kernel_alloc(UInt(pkgStoreInstallChunkSize), 16) else { return -12 }
    var done: UInt64 = 0
    while done < size {
        var chunk = UInt64(pkgStoreInstallChunkSize)
        if chunk > size - done { chunk = size - done }
        let got = vfsKernelReadFile(fd: fd, offset: Int(fileOffset + done), buffer: raw, count: Int(chunk))
        if got != Int(chunk) { return -22 }
        let rc = virtioBlkWritePackageStoreRange(storeOffset + done, UnsafeRawPointer(raw), UInt32(chunk))
        if rc != 0 { return Int(rc) }
        done += chunk
    }
    return 0
}

private func pkgAppendRecord(kind: UInt32, generation: UInt64,
                             dataPtr: UnsafeRawPointer?, dataSize: UInt64,
                             dataHash: UnsafePointer<UInt8>,
                             name: UnsafePointer<UInt8>, nameLen: Int,
                             version: UnsafePointer<UInt8>, versionLen: Int) -> (rc: Int, dataOffset: UInt64) {
    let reserved = pkgReserveRecord(dataSize: dataSize)
    if reserved.rc != 0 { return (reserved.rc, 0) }

    var header = [UInt8](repeating: 0, count: pkgStoreRecordHeaderSize)
    let ok = header.withUnsafeMutableBufferPointer { bp -> Bool in
        let h = bp.baseAddress!
        pkgRecordMagicString.withUTF8Buffer { m in
            var i = 0
            while i < 8 { h[i] = m[i]; i += 1 }
        }
        pkgPutLe32(h, 8, 1)
        pkgPutLe32(h, 12, UInt32(pkgStoreRecordHeaderSize))
        pkgPutLe32(h, 16, kind)
        pkgPutLe32(h, 20, 0)
        pkgPutLe64(h, 24, generation)
        pkgPutLe64(h, 32, reserved.dataOffset)
        pkgPutLe64(h, 40, dataSize)
        var i = 0
        while i < 32 { h[48 + i] = dataHash[i]; i += 1 }
        return pkgCopyPadded(h, 80, 32, name, nameLen) &&
               pkgCopyPadded(h, 112, 16, version, versionLen)
    }
    if !ok { return (-22, 0) }
    let hrc = header.withUnsafeBytes { raw in
        virtioBlkWritePackageStoreRange(reserved.recordOffset, raw.baseAddress, UInt32(pkgStoreRecordHeaderSize))
    }
    if hrc != 0 { return (Int(hrc), 0) }
    if dataSize > 0 {
        guard let data = dataPtr else { return (-22, 0) }
        let drc = virtioBlkWritePackageStoreRange(reserved.dataOffset, data, UInt32(dataSize))
        if drc != 0 { return (Int(drc), 0) }
    }
    let prc = pkgWriteZeroPadding(from: reserved.dataOffset + dataSize, to: reserved.next)
    if prc != 0 { return (prc, 0) }
    pkgCommitRecordNext(reserved.next)
    return (0, reserved.dataOffset)
}

private func pkgAppendFilePayload(fd: Int, fileOffset: UInt64, size: UInt64,
                                  hash: UnsafePointer<UInt8>,
                                  name: UnsafePointer<UInt8>, nameLen: Int,
                                  version: UnsafePointer<UInt8>, versionLen: Int) -> (rc: Int, dataOffset: UInt64) {
    let reserved = pkgReserveRecord(dataSize: size)
    if reserved.rc != 0 { return (reserved.rc, 0) }

    var header = [UInt8](repeating: 0, count: pkgStoreRecordHeaderSize)
    let ok = header.withUnsafeMutableBufferPointer { bp -> Bool in
        let h = bp.baseAddress!
        pkgRecordMagicString.withUTF8Buffer { m in
            var i = 0
            while i < 8 { h[i] = m[i]; i += 1 }
        }
        pkgPutLe32(h, 8, 1)
        pkgPutLe32(h, 12, UInt32(pkgStoreRecordHeaderSize))
        pkgPutLe32(h, 16, pkgRecordKindPayload)
        pkgPutLe32(h, 20, 0)
        pkgPutLe64(h, 24, 0)
        pkgPutLe64(h, 32, reserved.dataOffset)
        pkgPutLe64(h, 40, size)
        var i = 0
        while i < 32 { h[48 + i] = hash[i]; i += 1 }
        return pkgCopyPadded(h, 80, 32, name, nameLen) &&
               pkgCopyPadded(h, 112, 16, version, versionLen)
    }
    if !ok { return (-22, 0) }
    let hrc = header.withUnsafeBytes { raw in
        virtioBlkWritePackageStoreRange(reserved.recordOffset, raw.baseAddress, UInt32(pkgStoreRecordHeaderSize))
    }
    if hrc != 0 { return (Int(hrc), 0) }
    let drc = pkgWriteFileRangeToStore(fd: fd, fileOffset: fileOffset, storeOffset: reserved.dataOffset, size: size)
    if drc != 0 { return (drc, 0) }
    let prc = pkgWriteZeroPadding(from: reserved.dataOffset + size, to: reserved.next)
    if prc != 0 { return (prc, 0) }
    pkgCommitRecordNext(reserved.next)
    return (0, reserved.dataOffset)
}

private func pkgFindPayload(_ h0: UInt64, _ h1: UInt64, _ h2: UInt64, _ h3: UInt64) -> Int {
    var i = 0
    while i < pkgStoreMaxPayloads {
        let p = pkgPayloads[i]
        if p.inUse && p.h0 == h0 && p.h1 == h1 && p.h2 == h2 && p.h3 == h3 {
            return i
        }
        i += 1
    }
    return -1
}

private func pkgFindActivation(_ generation: UInt64) -> Int {
    var i = 0
    while i < pkgStoreMaxActivations {
        if pkgActivations[i].inUse && pkgActivations[i].generation == generation {
            return i
        }
        i += 1
    }
    return -1
}

private func pkgEnsurePayload(_ dataOffset: UInt64, _ dataSize: UInt64,
                              _ h0: UInt64, _ h1: UInt64, _ h2: UInt64, _ h3: UInt64) -> Int {
    let existing = pkgFindPayload(h0, h1, h2, h3)
    if existing >= 0 { return existing }
    var i = 0
    while i < pkgStoreMaxPayloads {
        if !pkgPayloads[i].inUse {
            pkgPayloads[i].inUse = true
            pkgPayloads[i].offset = dataOffset
            pkgPayloads[i].size = dataSize
            pkgPayloads[i].h0 = h0
            pkgPayloads[i].h1 = h1
            pkgPayloads[i].h2 = h2
            pkgPayloads[i].h3 = h3
            return i
        }
        i += 1
    }
    return -1
}

private func pkgEnsureActivation(_ generation: UInt64, _ dataOffset: UInt64, _ dataSize: UInt64) -> Bool {
    if pkgFindActivation(generation) >= 0 {
        if generation > pkgMaxGeneration { pkgMaxGeneration = generation }
        return true
    }
    if generation > pkgMaxGeneration { pkgMaxGeneration = generation }
    var i = 0
    while i < pkgStoreMaxActivations {
        if !pkgActivations[i].inUse {
            pkgActivations[i].inUse = true
            pkgActivations[i].generation = generation
            pkgActivations[i].offset = dataOffset
            pkgActivations[i].size = dataSize
            return true
        }
        i += 1
    }
    return false
}

private func pkgClearActivePayloads() {
    var i = 0
    while i < pkgStoreMaxPayloads {
        pkgPayloads[i].active = false
        pkgActivePayloadIndex[i] = -1
        i += 1
    }
    pkgActivePayloadCountValue = 0
}

private func pkgStoreS4dInvariantsLocked() -> Bool {
    if pkgActivePayloadCountValue < 0 || pkgActivePayloadCountValue > pkgStoreMaxPayloads {
        return false
    }
    if pkgNextRecordOffset < UInt64(pkgStoreHeaderSize) ||
       (pkgNextRecordOffset & UInt64(pkgStoreSectorSize - 1)) != 0 {
        return false
    }
    if virtioBlkPackageStoreAvailable() &&
       pkgNextRecordOffset > virtioBlkPackageStoreCapacityBytes() {
        return false
    }
    var i = 0
    while i < pkgActivePayloadCountValue {
        let pidx = pkgActivePayloadIndex[i]
        if pidx < 0 || pidx >= pkgStoreMaxPayloads { return false }
        var j = 0
        while j < i {
            if pkgActivePayloadIndex[j] == pidx { return false }
            j += 1
        }
        let payload = pkgPayloads[pidx]
        if !payload.inUse || !payload.active { return false }
        i += 1
    }
    return true
}

private func pkgLoadActivation(_ activation: PackageStoreActivation) -> Bool {
    if activation.size < UInt64(pkgStoreActivationHeaderSize) { return false }
    if activation.size > 4096 { return false }
    guard let raw = swiftos_kernel_alloc(UInt(activation.size), 16) else { return false }
    if virtioBlkReadPackageStoreRange(activation.offset, raw, UInt32(activation.size)) != 0 {
        return false
    }
    let p = raw.bindMemory(to: UInt8.self, capacity: Int(activation.size))
    if !pkgBytesEqual(p, 0, "SWPACT01") { return false }
    if pkgLe32(p, 8) != 1 { return false }
    let count = Int(pkgLe32(p, 12))
    if count < 0 || count > pkgStoreMaxPayloads { return false }
    let required = pkgStoreActivationHeaderSize + count * pkgStoreActivationEntrySize
    if UInt64(required) > activation.size { return false }

    var h0s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    var h1s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    var h2s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    var h3s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    var i = 0
    while i < count {
        let off = pkgStoreActivationHeaderSize + i * pkgStoreActivationEntrySize
        let (h0, h1, h2, h3) = pkgRecordHashParts(p, off)
        h0s[i] = h0
        h1s[i] = h1
        h2s[i] = h2
        h3s[i] = h3
        i += 1
    }

    let daif = pkgStoreLock()
    pkgClearActivePayloads()
    i = 0
    while i < count {
        let payload = pkgFindPayload(h0s[i], h1s[i], h2s[i], h3s[i])
        if payload < 0 {
            pkgClearActivePayloads()
            pkgStoreUnlock(daif)
            return false
        }
        pkgPayloads[payload].active = true
        pkgActivePayloadIndex[pkgActivePayloadCountValue] = payload
        pkgActivePayloadCountValue += 1
        i += 1
    }
    let ok = pkgStoreS4dInvariantsLocked()
    pkgStoreUnlock(daif)
    return ok
}

private func pkgPublishInstalledPayloads(generation: UInt64,
                                         payloadOffset: UInt64,
                                         payloadSize: UInt64,
                                         payloadHash: UnsafePointer<UInt8>,
                                         activationOffset: UInt64,
                                         activationSize: UInt64,
                                         h0s: [UInt64], h1s: [UInt64],
                                         h2s: [UInt64], h3s: [UInt64],
                                         count: Int) -> Bool {
    let (h0, h1, h2, h3) = pkgRecordHashParts(payloadHash, 0)
    let daif = pkgStoreLock()
    defer { pkgStoreUnlock(daif) }

    if count <= 0 || count > pkgStoreMaxPayloads { return false }
    let payload = pkgEnsurePayload(payloadOffset, payloadSize, h0, h1, h2, h3)
    if payload < 0 { return false }
    if !pkgEnsureActivation(generation, activationOffset, activationSize) {
        return false
    }
    pkgClearActivePayloads()
    var i = 0
    while i < count {
        let p = pkgFindPayload(h0s[i], h1s[i], h2s[i], h3s[i])
        if p < 0 {
            pkgClearActivePayloads()
            return false
        }
        pkgPayloads[p].active = true
        pkgActivePayloadIndex[pkgActivePayloadCountValue] = p
        pkgActivePayloadCountValue += 1
        i += 1
    }
    pkgActiveGeneration = generation
    if generation > pkgMaxGeneration { pkgMaxGeneration = generation }
    return pkgStoreS4dInvariantsLocked()
}

func pkgStoreInit() {
    withUnsafeMutablePointer(to: &pkgStoreLockWord) { word in
        smpAtomicStore(word, 0)
    }
    withUnsafeMutablePointer(to: &pkgStoreLockAcquireCount) { count in
        smpAtomicStore(count, 0)
    }
    withUnsafeMutablePointer(to: &pkgStoreLockContentionCount) { count in
        smpAtomicStore(count, 0)
    }

    var daif = pkgStoreLock()
    pkgStoreMutationInProgress = false
    pkgClear()
    pkgStoreUnlock(daif)

    if !virtioBlkPackageStoreAvailable() { return }

    var header = [UInt8](repeating: 0, count: pkgStoreHeaderSize)
    let hok = header.withUnsafeMutableBytes { raw -> Bool in
        virtioBlkReadPackageStoreRange(0, raw.baseAddress, UInt32(pkgStoreHeaderSize)) == 0
    }
    if !hok { return }
    let goodHeader = header.withUnsafeBufferPointer { bp -> Bool in
        let p = bp.baseAddress!
        if p[0] != pkgStoreMagic0 { return false }
        if !pkgBytesEqual(p, 0, "SWPKGST1") { return false }
        if pkgLe32(p, 8) != 1 { return false }
        if pkgLe32(p, 12) != UInt32(pkgStoreHeaderSize) { return false }
        return true
    }
    if !goodHeader { return }

    var off: UInt64 = UInt64(pkgStoreHeaderSize)
    let cap = virtioBlkPackageStoreCapacityBytes()
    var records = 0
    while records < pkgStoreMaxRecords && off + UInt64(pkgStoreRecordHeaderSize) <= cap {
        var rh = [UInt8](repeating: 0, count: pkgStoreRecordHeaderSize)
        let rok = rh.withUnsafeMutableBytes { raw -> Bool in
            virtioBlkReadPackageStoreRange(off, raw.baseAddress, UInt32(pkgStoreRecordHeaderSize)) == 0
        }
        if !rok { break }
        let advanced = rh.withUnsafeBufferPointer { bp -> UInt64 in
            let p = bp.baseAddress!
            if !pkgBytesEqual(p, 0, "SWPSREC1") { return 0 }
            if pkgLe32(p, 8) != 1 { return 0 }
            if pkgLe32(p, 12) != UInt32(pkgStoreRecordHeaderSize) { return 0 }
            let kind = pkgLe32(p, 16)
            let generation = pkgLe64(p, 24)
            let dataOffset = pkgLe64(p, 32)
            let dataSize = pkgLe64(p, 40)
            if dataOffset != off + UInt64(pkgStoreRecordHeaderSize) { return 0 }
            let (dataEnd, overflow) = dataOffset.addingReportingOverflow(dataSize)
            if overflow || dataEnd > cap { return 0 }
            let (h0, h1, h2, h3) = pkgRecordHashParts(p, 48)
            let next = pkgAlignUp(dataEnd, UInt64(pkgStoreSectorSize))
            if next < dataEnd || next > cap { return 0 }
            let recordDaif = pkgStoreLock()
            if kind == pkgRecordKindPayload {
                pkgAddPayload(dataOffset, dataSize, h0, h1, h2, h3)
            } else if kind == pkgRecordKindActivation {
                pkgAddActivation(generation, dataOffset, dataSize)
            } else if kind == pkgRecordKindActivePointer {
                pkgActiveGeneration = generation
            }
            pkgNextRecordOffset = next
            pkgStoreUnlock(recordDaif)
            return next
        }
        if advanced == 0 { break }
        off = advanced
        records += 1
    }

    daif = pkgStoreLock()
    if off > pkgNextRecordOffset { pkgNextRecordOffset = off }
    let activeGeneration = pkgActiveGeneration
    var activation = PackageStoreActivation()
    if activeGeneration != 0 {
        let act = pkgFindActivation(activeGeneration)
        if act >= 0 { activation = pkgActivations[act] }
    }
    pkgStoreUnlock(daif)

    if activeGeneration != 0 && activation.inUse && pkgLoadActivation(activation) {
        klog(.info, "pkg", "P3: package store active generation", activeGeneration)
    }
}

func pkgStoreActivePayloadCount() -> Int {
    let daif = pkgStoreLock()
    let count = pkgActivePayloadCountValue
    pkgStoreUnlock(daif)
    return count
}

func pkgStoreReadActivePayloadRange(_ activeIndex: Int, _ byteOff: UInt64,
                                    _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    var payloadOffset: UInt64 = 0
    var payloadSize: UInt64 = 0
    let daif = pkgStoreLock()
    if activeIndex < 0 || activeIndex >= pkgActivePayloadCountValue {
        pkgStoreUnlock(daif)
        return -1
    }
    let pidx = pkgActivePayloadIndex[activeIndex]
    if pidx < 0 || pidx >= pkgStoreMaxPayloads {
        pkgStoreUnlock(daif)
        return -1
    }
    let payload = pkgPayloads[pidx]
    if !payload.inUse || !payload.active {
        pkgStoreUnlock(daif)
        return -1
    }
    payloadOffset = payload.offset
    payloadSize = payload.size
    pkgStoreUnlock(daif)

    let (end, overflow) = byteOff.addingReportingOverflow(UInt64(len))
    if overflow || end > payloadSize { return -1 }
    return virtioBlkReadPackageStoreRange(payloadOffset + byteOff, buf, len)
}

private func pkgReadPackageHeader(fd: Int, _ out: UnsafeMutablePointer<UInt8>) -> Int {
    let got = vfsKernelReadFile(fd: fd, offset: 0, buffer: UnsafeMutableRawPointer(out), count: swpkgHeaderSize)
    return got == swpkgHeaderSize ? 0 : -22
}

private func pkgCheckedRange(offset: UInt64, size: UInt64, fileSize: UInt64) -> Bool {
    let (end, overflow) = offset.addingReportingOverflow(size)
    return !overflow && offset <= fileSize && end <= fileSize
}

func pkgStoreInstall(fd: Int, nameVA: UInt, versionVA: UInt) -> Int {
    if processCurrentPrincipal() != 1 { return -13 }
    if !virtioBlkPackageStoreAvailable() { return -2 }
    if !pkgStoreBeginMutation() { return -11 }
    defer { pkgStoreEndMutation() }

    let fileSize = vfsKernelFileSize(fd: fd)
    if fileSize < swpkgHeaderSize { return -22 }
    let fileSize64 = UInt64(fileSize)

    var name = [UInt8](repeating: 0, count: 32)
    var version = [UInt8](repeating: 0, count: 16)
    let nameLen = name.withUnsafeMutableBufferPointer { bp in
        pkgCopyCString(nameVA, 32, bp.baseAddress!, 32)
    }
    if nameLen < 0 { return nameLen }
    let versionLen = version.withUnsafeMutableBufferPointer { bp in
        pkgCopyCString(versionVA, 16, bp.baseAddress!, 16)
    }
    if versionLen < 0 { return versionLen }

    var header = [UInt8](repeating: 0, count: swpkgHeaderSize)
    let readHeader = header.withUnsafeMutableBufferPointer { bp in
        pkgReadPackageHeader(fd: fd, bp.baseAddress!)
    }
    if readHeader != 0 { return readHeader }

    let validHeader = header.withUnsafeBufferPointer { bp -> Bool in
        let h = bp.baseAddress!
        if !pkgBytesEqual(h, 0, "SWPKG001") { return false }
        if pkgLe32(h, 8) != 1 || pkgLe32(h, 12) != UInt32(swpkgHeaderSize) { return false }
        let manifestOffset = pkgLe64(h, 16)
        let manifestSize = pkgLe64(h, 24)
        let payloadOffset = pkgLe64(h, 32)
        let payloadSize = pkgLe64(h, 40)
        let signatureOffset = pkgLe64(h, 112)
        let signatureSize = pkgLe64(h, 120)
        if signatureOffset != 0 || signatureSize != 0 { return false }
        if manifestOffset != UInt64(swpkgHeaderSize) { return false }
        if payloadOffset != manifestOffset + manifestSize { return false }
        if manifestSize == 0 || payloadSize == 0 { return false }
        if !pkgCheckedRange(offset: manifestOffset, size: manifestSize, fileSize: fileSize64) { return false }
        if !pkgCheckedRange(offset: payloadOffset, size: payloadSize, fileSize: fileSize64) { return false }
        return true
    }
    if !validHeader { return -22 }

    let manifestOffset = header.withUnsafeBufferPointer { pkgLe64($0.baseAddress!, 16) }
    let manifestSize = header.withUnsafeBufferPointer { pkgLe64($0.baseAddress!, 24) }
    let payloadOffset = header.withUnsafeBufferPointer { pkgLe64($0.baseAddress!, 32) }
    let payloadSize = header.withUnsafeBufferPointer { pkgLe64($0.baseAddress!, 40) }

    var manifestHash = [UInt8](repeating: 0, count: 32)
    var payloadHash = [UInt8](repeating: 0, count: 32)
    let mh = manifestHash.withUnsafeMutableBufferPointer { bp in
        pkgHashFileRange(fd: fd, offset: manifestOffset, size: manifestSize, out: bp.baseAddress!)
    }
    if mh != 0 { return mh }
    let ph = payloadHash.withUnsafeMutableBufferPointer { bp in
        pkgHashFileRange(fd: fd, offset: payloadOffset, size: payloadSize, out: bp.baseAddress!)
    }
    if ph != 0 { return ph }

    let hashesOk = header.withUnsafeBufferPointer { hp -> Bool in
        manifestHash.withUnsafeBufferPointer { mhp -> Bool in
            payloadHash.withUnsafeBufferPointer { php -> Bool in
                pkgBytesEqualRaw(mhp.baseAddress!, hp.baseAddress! + 48, 32) &&
                pkgBytesEqualRaw(php.baseAddress!, hp.baseAddress! + 80, 32)
            }
        }
    }
    if !hashesOk { return -22 }

    var payloadHeader = [UInt8](repeating: 0, count: 64)
    let phdr = payloadHeader.withUnsafeMutableBufferPointer { bp in
        vfsKernelReadFile(fd: fd, offset: Int(payloadOffset), buffer: UnsafeMutableRawPointer(bp.baseAddress!),
                          count: 64)
    }
    if phdr != 64 { return -22 }
    let payloadLooksPacked = payloadHeader.withUnsafeBufferPointer { bp -> Bool in
        let p = bp.baseAddress!
        return pkgBytesEqual(p, 0, "SWOSBASE") && pkgLe32(p, 8) == 2
    }
    if !payloadLooksPacked { return -22 }

    let generation = pkgStoreNextGeneration()
    let install = name.withUnsafeBufferPointer { nbp in
        version.withUnsafeBufferPointer { vbp in
            payloadHash.withUnsafeBufferPointer { hp in
                pkgAppendFilePayload(fd: fd, fileOffset: payloadOffset, size: payloadSize,
                                     hash: hp.baseAddress!,
                                     name: nbp.baseAddress!, nameLen: nameLen,
                                     version: vbp.baseAddress!, versionLen: versionLen)
            }
        }
    }
    if install.rc != 0 { return install.rc }

    var h0s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    var h1s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    var h2s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    var h3s = [UInt64](repeating: 0, count: pkgStoreMaxPayloads)
    let newParts = payloadHash.withUnsafeBufferPointer { hp in
        pkgRecordHashParts(hp.baseAddress!, 0)
    }
    var activationCount = 0
    var alreadyActive = false
    let activeDaif = pkgStoreLock()
    var activeIndex = 0
    while activeIndex < pkgActivePayloadCountValue && activationCount < pkgStoreMaxPayloads {
        let pidx = pkgActivePayloadIndex[activeIndex]
        if pidx >= 0 && pidx < pkgStoreMaxPayloads {
            let p = pkgPayloads[pidx]
            if p.inUse && p.active {
                if p.h0 == newParts.0 && p.h1 == newParts.1 && p.h2 == newParts.2 && p.h3 == newParts.3 {
                    alreadyActive = true
                }
                h0s[activationCount] = p.h0
                h1s[activationCount] = p.h1
                h2s[activationCount] = p.h2
                h3s[activationCount] = p.h3
                activationCount += 1
            }
        }
        activeIndex += 1
    }
    pkgStoreUnlock(activeDaif)
    if !alreadyActive {
        if activationCount >= pkgStoreMaxPayloads { return -28 }
        h0s[activationCount] = newParts.0
        h1s[activationCount] = newParts.1
        h2s[activationCount] = newParts.2
        h3s[activationCount] = newParts.3
        activationCount += 1
    }

    var activation = [UInt8](repeating: 0,
                             count: pkgStoreActivationHeaderSize + activationCount * pkgStoreActivationEntrySize)
    let actOk = activation.withUnsafeMutableBufferPointer { bp -> Bool in
        let a = bp.baseAddress!
        pkgActivationMagicString.withUTF8Buffer { m in
            var i = 0
            while i < 8 { a[i] = m[i]; i += 1 }
        }
        pkgPutLe32(a, 8, 1)
        pkgPutLe32(a, 12, UInt32(activationCount))
        var entry = 0
        while entry < activationCount {
            let off = pkgStoreActivationHeaderSize + entry * pkgStoreActivationEntrySize
            pkgPutLe64(a, off, h0s[entry])
            pkgPutLe64(a, off + 8, h1s[entry])
            pkgPutLe64(a, off + 16, h2s[entry])
            pkgPutLe64(a, off + 24, h3s[entry])
            let namesOk: Bool
            if entry == activationCount - 1 && !alreadyActive {
                namesOk = name.withUnsafeBufferPointer { nbp in
                    version.withUnsafeBufferPointer { vbp in
                        pkgCopyPadded(a, off + 32, 32, nbp.baseAddress!, nameLen) &&
                        pkgCopyPadded(a, off + 64, 16, vbp.baseAddress!, versionLen)
                    }
                }
            } else {
                namesOk = pkgCopyStaticPadded(a, off + 32, 32, "active") &&
                          pkgCopyStaticPadded(a, off + 64, 16, "0")
            }
            if !namesOk { return false }
            entry += 1
        }
        return true
    }
    if !actOk { return -22 }
    var activationHash = [UInt8](repeating: 0, count: 32)
    activation.withUnsafeBytes { raw in
        activationHash.withUnsafeMutableBufferPointer { hp in
            sha256(raw.baseAddress!, activation.count, hp.baseAddress!)
        }
    }
    let activationRecord = activation.withUnsafeBytes { raw in
        activationHash.withUnsafeBufferPointer { hp in
            name.withUnsafeBufferPointer { nbp in
                version.withUnsafeBufferPointer { vbp in
                    pkgAppendRecord(kind: pkgRecordKindActivation, generation: generation,
                                    dataPtr: raw.baseAddress, dataSize: UInt64(activation.count),
                                    dataHash: hp.baseAddress!,
                                    name: nbp.baseAddress!, nameLen: nameLen,
                                    version: vbp.baseAddress!, versionLen: versionLen)
                }
            }
        }
    }
    if activationRecord.rc != 0 { return activationRecord.rc }

    var emptyHash = [UInt8](repeating: 0, count: 32)
    emptyHash.withUnsafeMutableBufferPointer { hp in
        sha256(UnsafeRawPointer(bitPattern: 1)!, 0, hp.baseAddress!)
    }
    let activeName: StaticString = "active"
    let activeVersion: StaticString = "0"
    let activeRecord = emptyHash.withUnsafeBufferPointer { hp in
        activeName.withUTF8Buffer { an in
            activeVersion.withUTF8Buffer { av in
                pkgAppendRecord(kind: pkgRecordKindActivePointer, generation: generation,
                                dataPtr: nil, dataSize: 0, dataHash: hp.baseAddress!,
                                name: an.baseAddress!, nameLen: an.count,
                                version: av.baseAddress!, versionLen: av.count)
            }
        }
    }
    if activeRecord.rc != 0 { return activeRecord.rc }

    let published = payloadHash.withUnsafeBufferPointer { hp in
        pkgPublishInstalledPayloads(generation: generation,
                                    payloadOffset: install.dataOffset,
                                    payloadSize: payloadSize,
                                    payloadHash: hp.baseAddress!,
                                    activationOffset: activationRecord.dataOffset,
                                    activationSize: UInt64(activation.count),
                                    h0s: h0s, h1s: h1s,
                                    h2s: h2s, h3s: h3s,
                                    count: activationCount)
    }
    if !published { return -28 }
    let mountRc = vfsMountActivePackageStore()
    if mountRc != 0 { return mountRc }
    klog(.info, "pkg", "P3b: package installed and activated", generation)
    return 0
}

func pkgStoreS4dLockAcquireCount() -> UInt64 {
    pkgStoreAtomicLoad(&pkgStoreLockAcquireCount)
}

func pkgStoreS4dLockContentionCount() -> UInt64 {
    pkgStoreAtomicLoad(&pkgStoreLockContentionCount)
}

func pkgStoreS4dReadinessSelfTest() -> Bool {
    let daif = pkgStoreLock()
    defer { pkgStoreUnlock(daif) }
    return pkgStoreS4dInvariantsLocked()
}

func pkgStoreS4dLockBoundaryHeldSelfTest() -> Bool {
    if pkgStoreAtomicLoad(&pkgStoreLockWord) != 0 || pkgStoreS4dLockAcquireCount() == 0 {
        return false
    }
    return pkgStoreS4dReadinessSelfTest()
}

func pkgStoreActiveInfo(_ activeIndex: Int, _ outVA: UInt, _ cap: UInt) -> Int {
    var payloadOffset: UInt64 = 0
    let daif = pkgStoreLock()
    if activeIndex < 0 || activeIndex >= pkgActivePayloadCountValue {
        pkgStoreUnlock(daif)
        return -2
    }
    let pidx = pkgActivePayloadIndex[activeIndex]
    if pidx < 0 || pidx >= pkgStoreMaxPayloads {
        pkgStoreUnlock(daif)
        return -2
    }
    let payload = pkgPayloads[pidx]
    if !payload.inUse || !payload.active || payload.offset < UInt64(pkgStoreRecordHeaderSize) {
        pkgStoreUnlock(daif)
        return -2
    }
    payloadOffset = payload.offset
    pkgStoreUnlock(daif)

    if cap == 0 { return 0 }
    guard let out = userWritableBuffer(outVA, cap) else { return -22 }
    var rh = [UInt8](repeating: 0, count: pkgStoreRecordHeaderSize)
    let rc = rh.withUnsafeMutableBytes { raw in
        virtioBlkReadPackageStoreRange(payloadOffset - UInt64(pkgStoreRecordHeaderSize),
                                       raw.baseAddress, UInt32(pkgStoreRecordHeaderSize))
    }
    if rc != 0 { return Int(rc) }
    return rh.withUnsafeBufferPointer { bp -> Int in
        let h = bp.baseAddress!
        var written: UInt = 0
        func put(_ c: UInt8) {
            if written + 1 < cap { out[Int(written)] = c }
            written += 1
        }
        var i = 0
        while i < 32 && h[80 + i] != 0 { put(h[80 + i]); i += 1 }
        put(0x2D)
        i = 0
        while i < 16 && h[112 + i] != 0 { put(h[112 + i]); i += 1 }
        if written < cap {
            out[Int(written)] = 0
        } else {
            out[Int(cap - 1)] = 0
        }
        return Int(written)
    }
}
