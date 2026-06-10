// SPDX-License-Identifier: Apache-2.0
// store.swift - narrow read-only package-store activation reader (P3).

private let pkgStoreMagic0: UInt8 = 0x53 // S
private let pkgStoreHeaderSize = 512
private let pkgStoreRecordHeaderSize = 128
private let pkgStoreSectorSize = 512
private let pkgStoreMaxRecords = 32
private let pkgStoreMaxPayloads = 8
private let pkgStoreMaxActivations = 8
private let pkgStoreActivationHeaderSize = 16
private let pkgStoreActivationEntrySize = 80

private let pkgRecordKindPayload: UInt32 = 1
private let pkgRecordKindActivation: UInt32 = 2
private let pkgRecordKindActivePointer: UInt32 = 3

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

    var i = 0
    while i < count {
        let off = pkgStoreActivationHeaderSize + i * pkgStoreActivationEntrySize
        let (h0, h1, h2, h3) = pkgRecordHashParts(p, off)
        let payload = pkgFindPayload(h0, h1, h2, h3)
        if payload < 0 { return false }
        pkgPayloads[payload].active = true
        pkgActivePayloadIndex[pkgActivePayloadCountValue] = payload
        pkgActivePayloadCountValue += 1
        i += 1
    }
    return true
}

func pkgStoreInit() {
    pkgClear()
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
            if dataOffset + dataSize > cap { return 0 }
            let (h0, h1, h2, h3) = pkgRecordHashParts(p, 48)
            if kind == pkgRecordKindPayload {
                pkgAddPayload(dataOffset, dataSize, h0, h1, h2, h3)
            } else if kind == pkgRecordKindActivation {
                pkgAddActivation(generation, dataOffset, dataSize)
            } else if kind == pkgRecordKindActivePointer {
                pkgActiveGeneration = generation
            }
            return pkgAlignUp(dataOffset + dataSize, UInt64(pkgStoreSectorSize))
        }
        if advanced == 0 { break }
        off = advanced
        records += 1
    }

    if pkgActiveGeneration == 0 { return }
    let act = pkgFindActivation(pkgActiveGeneration)
    if act < 0 { return }
    if pkgLoadActivation(pkgActivations[act]) {
        klog(.info, "pkg", "P3: package store active generation", pkgActiveGeneration)
    }
}

func pkgStoreActivePayloadCount() -> Int {
    pkgActivePayloadCountValue
}

func pkgStoreReadActivePayloadRange(_ activeIndex: Int, _ byteOff: UInt64,
                                    _ buf: UnsafeMutableRawPointer?, _ len: UInt32) -> Int32 {
    if activeIndex < 0 || activeIndex >= pkgActivePayloadCountValue { return -1 }
    let pidx = pkgActivePayloadIndex[activeIndex]
    if pidx < 0 || pidx >= pkgStoreMaxPayloads { return -1 }
    let payload = pkgPayloads[pidx]
    if !payload.inUse || !payload.active { return -1 }
    if byteOff + UInt64(len) > payload.size { return -1 }
    return virtioBlkReadPackageStoreRange(payload.offset + byteOff, buf, len)
}
