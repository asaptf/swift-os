// SPDX-License-Identifier: Apache-2.0
//
// llm.swift — /bin/llm, a native Embedded Swift CPU inference demo on swift-os.
//
// Loads a llama2.c-format checkpoint + tokenizer from the read-only base image
// (/models/...), reads them into anonymous mmap'd RAM, and greedily generates
// text to the console, reporting tokens/sec. The transformer + tokenizer live
// in userland/lib/llama2.swift, the same source the host TDD test pins to the
// upstream llama2.c reference. This is I1 of the AI-hosting proof arc: it proves
// the engine runs end to end as an isolated EL0 process on the OS.
//
// Weights are read into anonymous memory here; I2 replaces that with a
// file-backed mmap of the immutable model bundle (the documented "mmap-backed
// weights" primitive), and I3 serves generated tokens over the network.

private let protRead: Int32 = 0x1
private let oRdOnly: Int32 = 0

// ---- small output helpers (no libc; bridge only) ---------------------------

private func emit(_ bytes: [UInt8]) {
    if bytes.isEmpty { return }
    bytes.withUnsafeBytes { raw in
        _ = swiftos_write(1, raw.baseAddress, UInt(bytes.count))
    }
}

private func putUInt(_ value: UInt64) {
    var divisor: UInt64 = 1
    while value / divisor >= 10 { divisor *= 10 }
    var rest = value
    while divisor > 0 {
        swiftos_putc(0x30 + UInt8(rest / divisor))
        rest %= divisor
        divisor /= 10
    }
}

private func cString(_ p: UnsafeMutablePointer<CChar>) -> String {
    var bytes: [UInt8] = []
    var i = 0
    while p[i] != 0 { bytes.append(UInt8(bitPattern: p[i])); i += 1 }
    return String(decoding: bytes, as: UTF8.self)
}

private func parseInt(_ p: UnsafeMutablePointer<CChar>) -> Int? {
    var v = 0, i = 0
    var any = false
    while p[i] != 0 {
        let c = p[i]
        if c < 0x30 || c > 0x39 { return nil }
        v = v * 10 + Int(c - 0x30); i += 1; any = true
    }
    return any ? v : nil
}

/// mmap a base-image file read-only, file-backed (I2): the kernel maps the
/// file's on-disk extent into this process — no read-into-anonymous copy.
/// Returns the base pointer (kept mapped for the process lifetime) and length.
private func loadFile(_ path: StaticString) -> (UnsafeRawPointer, Int)? {
    let cpath = UnsafeRawPointer(path.utf8Start).assumingMemoryBound(to: CChar.self)
    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    if swiftos_stat(cpath, &mode, &uid, &gid, &nlink, &size, &mtime) != 0 { return nil }
    if size == 0 { return nil }
    let fd = swiftos_open(cpath, oRdOnly)
    if fd < 0 { return nil }
    let base = swiftos_mmap_file(fd, size, protRead)
    _ = swiftos_close(fd)   // the mapping owns the pages; the fd is no longer needed
    guard base != 0, let ptr = UnsafeRawPointer(bitPattern: base) else { return nil }
    return (ptr, Int(size))
}

// ---- entry point -----------------------------------------------------------

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    // Optional argv: [1] = prompt, [2] = step count. Defaults reproduce the
    // host test's reference run so the demo is verifiable.
    var prompt = "Once upon a time"
    var steps = 64
    if let argv = argv {
        if argc > 1, let a = argv[1] { prompt = cString(a) }
        if argc > 2, let a = argv[2], let n = parseInt(a) { steps = n }
    }

    guard let (modelPtr, _) = loadFile("/models/stories260K.bin") else {
        swiftos_puts("llm: cannot load /models/stories260K.bin (run `make model`?)\n")
        return 1
    }
    guard let (tokPtr, _) = loadFile("/models/tok512.bin") else {
        swiftos_puts("llm: cannot load /models/tok512.bin\n")
        return 1
    }
    swiftos_puts("llm: weights mmap'd file-backed from /models\n")

    let model = Llama2(modelBytes: modelPtr)
    let tok = LlamaTokenizer(tokenizerBytes: tokPtr, vocabSize: model.cfg.vocabSize)
    if steps > model.cfg.seqLen { steps = model.cfg.seqLen }

    let c = model.cfg
    swiftos_puts("llm: stories260K dim=")
    putUInt(UInt64(c.dim)); swiftos_puts(" layers="); putUInt(UInt64(c.nLayers))
    swiftos_puts(" heads="); putUInt(UInt64(c.nHeads)); swiftos_puts(" vocab=")
    putUInt(UInt64(c.vocabSize)); swiftos_puts("\n")
    swiftos_puts("llm: generating "); putUInt(UInt64(steps))
    swiftos_puts(" tokens (greedy)\n--- output ---\n")

    // Wall-clock via the kernel tick counter (sysinfo). Resolution = 1 tick.
    _ = swiftos_sysinfo_refresh()
    let hz = UInt64(swiftos_sys_hz())
    let t0 = UInt64(swiftos_sys_uptime_ticks())

    let produced = llamaGenerate(model, tok, prompt: prompt, steps: steps) { emit($0) }

    _ = swiftos_sysinfo_refresh()
    let t1 = UInt64(swiftos_sys_uptime_ticks())
    swiftos_puts("\n--- end ---\n")

    let dticks: UInt64 = t1 >= t0 ? (t1 - t0) : 0
    swiftos_puts("llm: "); putUInt(UInt64(produced)); swiftos_puts(" tokens in ")
    if hz > 0 { putUInt(dticks * 1000 / hz) } else { putUInt(dticks) }
    swiftos_puts(" ms")
    if dticks > 0 && hz > 0 {
        swiftos_puts(" ("); putUInt(UInt64(produced) * hz / dticks); swiftos_puts(" tok/s)")
    }
    swiftos_puts("\nllm: done\n")
    return 0
}
