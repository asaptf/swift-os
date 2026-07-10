// SPDX-License-Identifier: Apache-2.0
//
// llmd.swift — /bin/llmd, the swift-os model-serving daemon (I3 of the
// AI-hosting proof arc): CPU inference served over TCP.
//
// Loads the llama2.c-format checkpoint + tokenizer from the read-only base
// image via file-backed mmap (I2), binds a TCP listener, and serves with a
// poll()-driven loop (the /bin/httpd pattern):
//
//   POST /completion   body = prompt → 200 text/plain, generated tokens
//                      STREAMED to the socket as they are produced
//                      (HTTP/1.0, Connection: close delimits the body)
//   GET  /health       200 "ok <model> dim=.. layers=.." liveness probe
//   GET  /metrics      200 text/plain serving counters: requests,
//                      tokens_total, last_ttft_ms, last_tok_s
//
// Per request the server logs `llmd: served N tokens ttft=X ms rate=Y tok/s`
// on the console — latency-to-first-token and throughput are the two
// AI-serving metrics the architecture doc calls for. Generation runs inline
// (single core; one request at a time); the poll loop still queues other
// connections meanwhile. Sockets are capability-gated (capNet) like every
// other network tool.

private let listenPort: UInt16 = 8080
private let maxConns = 8
private let pollIn: Int16 = 0x001
private let protRead: Int32 = 0x1
private let oRdOnly: Int32 = 0
private let defaultSteps = 64
private let reqCap = 2048
private let promptCap = 512

// ---- serving counters (GET /metrics) ---------------------------------------
private var mRequests: UInt = 0
private var mTokensTotal: UInt = 0
private var mLastTtftMs: UInt = 0
private var mLastTokS: UInt = 0

// ---- tiny output helpers ----------------------------------------------------

private func writeStr(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { _ = swiftos_write(fd, $0.baseAddress, UInt($0.count)) }
}

private func writeUInt(_ fd: Int32, _ v: UInt) {
    withUnsafeTemporaryAllocation(byteCount: 24, alignment: 1) { b in
        let p = b.baseAddress!
        var i = 24
        var x = v
        repeat {
            i -= 1
            p.storeBytes(of: UInt8(0x30 + (x % 10)), toByteOffset: i, as: UInt8.self)
            x /= 10
        } while x > 0
        _ = swiftos_write(fd, p + i, UInt(24 - i))
    }
}

private func putUInt(_ v: UInt) { writeUInt(1, v) }

// ---- model load (file-backed mmap, I2) --------------------------------------

private func loadFile(_ cpath: UnsafePointer<CChar>) -> (UnsafeRawPointer, Int)? {
    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    if swiftos_stat(cpath, &mode, &uid, &gid, &nlink, &size, &mtime) != 0 { return nil }
    if size == 0 { return nil }
    let fd = swiftos_open(cpath, oRdOnly)
    if fd < 0 { return nil }
    let base = swiftos_mmap_file(fd, size, protRead)
    _ = swiftos_close(fd)
    guard base != 0, let ptr = UnsafeRawPointer(bitPattern: base) else { return nil }
    return (ptr, Int(size))
}

@inline(__always)
private func staticPath(_ s: StaticString) -> UnsafePointer<CChar> {
    return UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self)
}

// ---- verified model bundles (I5) ---------------------------------------------
// /models/<name>/<generation>/{manifest.toml, model.bin, tokenizer.bin}.
// Policy: serve the highest generation whose manifest parses and whose payloads
// pass the size + SHA-256 checks (userland/lib/modelbundle.swift); a bad
// generation is logged and skipped — the documented "roll back if the new
// generation is unhealthy" flow, applied at load time. Verifying an mmap'd
// payload also faults it fully in, so "verified" implies "resident".

private let bundleRoot: StaticString = "/models/stories15M"
// LM3c/LM4: a dedicated model disk (LM3a/LM3b) mounts read-only at /srv/models. A
// real model is too big for the RAM-loaded base, so prefer the disk-delivered
// bundle when present and fall back to the base bundle otherwise. The disk roots
// are tried in order — the real TinyLlama (LM4) first, then the stories15M proof
// (LM3) — so whichever model disk is attached is served without reconfiguration.
private let diskBundleRoots: [StaticString] = ["/srv/models/tinyllama-gguf", "/srv/models/tinyllama", "/srv/models/stories15M"]
private let dentsCap = 2048
private let manifestCap = 4096

/// Run `body` with a NUL-terminated C path "<root>/<gen>/<leaf>". `leaf` must
/// be a bare filename (manifest paths with '/' are rejected by the caller).
private func withBundlePath<R>(_ root: StaticString, _ gen: Int, _ leaf: String,
                               _ body: (UnsafePointer<CChar>) -> R) -> R {
    var bytes: [UInt8] = []
    root.withUTF8Buffer { for b in $0 { bytes.append(b) } }
    bytes.append(0x2F)
    var digits: [UInt8] = []
    var g = gen
    repeat { digits.append(0x30 + UInt8(g % 10)); g /= 10 } while g > 0
    bytes.append(contentsOf: digits.reversed())
    bytes.append(0x2F)
    bytes.append(contentsOf: Array(leaf.utf8))
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { raw in
        body(UnsafeRawPointer(raw.baseAddress!).assumingMemoryBound(to: CChar.self))
    }
}

/// List the numeric child directories of the bundle root (candidate generations).
private func scanGenerations(_ root: StaticString) -> [Int] {
    let fd = swiftos_open(staticPath(root), oRdOnly)
    if fd < 0 { return [] }
    var gens: [Int] = []
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: dentsCap) { dbuf in
        let dbase = dbuf.baseAddress!
        while true {
            let n = swiftos_getdents(fd, UnsafeMutableRawPointer(dbase), UInt(dentsCap))
            if n <= 0 { break }
            var off = 0
            while off < Int(n) {
                let rec = dbase + off
                let reclen = Int(UInt16(rec[16]) | (UInt16(rec[17]) << 8))
                if reclen <= 0 { break }
                let namePtr = rec + 19
                var v = 0
                var len = 0
                var numeric = true
                while namePtr[len] != 0 {
                    let c = namePtr[len]
                    if c < 0x30 || c > 0x39 { numeric = false; break }
                    v = v * 10 + Int(c - 0x30)
                    len += 1
                }
                if numeric && len > 0 { gens.append(v) }
                off += reclen
            }
        }
    }
    _ = swiftos_close(fd)
    return gens
}

// I7: trust root for manifest signatures. When the base image provisions
// /etc/swos/model-signing.pub (32 raw bytes), every manifest MUST carry a
// valid Ed25519 signature over its pre-[signature] bytes; without a trust
// root the daemon runs in integrity-only mode (sha256 checks only).
private var trustRoot = [UInt8](repeating: 0, count: 32)
private var trustRootPresent = false

private func loadTrustRoot() {
    let fd = swiftos_open(staticPath("/etc/swos/model-signing.pub"), oRdOnly)
    if fd < 0 { return }
    let r = trustRoot.withUnsafeMutableBytes { swiftos_read(fd, $0.baseAddress!, 32) }
    _ = swiftos_close(fd)
    trustRootPresent = (r == 32)
}

private enum ManifestResult {
    case ok(ModelManifest)
    case malformed
    case badSignature
}

/// Read + parse "<root>/<gen>/manifest.toml"; with a trust root provisioned,
/// also require a valid Ed25519 manifest signature. Payloads are mmap'd
/// separately by the caller.
private func readManifest(_ root: StaticString, _ gen: Int) -> ManifestResult {
    return withBundlePath(root, gen, "manifest.toml") { cpath -> ManifestResult in
        let fd = swiftos_open(cpath, oRdOnly)
        if fd < 0 { return .malformed }
        defer { _ = swiftos_close(fd) }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: manifestCap) { buf in
            let r = swiftos_read(fd, buf.baseAddress!, UInt(manifestCap))
            if r <= 0 { return .malformed }
            let raw = UnsafeRawBufferPointer(start: buf.baseAddress!, count: Int(r))
            guard let m = modelManifestParse(raw) else { return .malformed }
            if trustRootPresent {
                guard !m.signatureHex.isEmpty,
                      let sig = modelSignatureDecode(m.signatureHex) else { return .badSignature }
                let range = modelManifestSignedRange(raw)
                let okay = sig.withUnsafeBytes { sb in
                    trustRoot.withUnsafeBytes { pb in
                        ed25519Verify(message: raw.baseAddress!, range,
                                      signature: sb.baseAddress!, publicKey: pb.baseAddress!)
                    }
                }
                if !okay { return .badSignature }
            }
            return .ok(m)
        }
    }
}

/// mmap + verify one bundle payload. Returns the mapped bytes on success.
private func loadVerified(_ root: StaticString, _ gen: Int, _ entry: ModelBundleFile)
    -> (UnsafeRawPointer, Int)? {
    if entry.path.isEmpty || entry.path.utf8.contains(0x2F) { return nil } // no '/' escapes
    guard let (ptr, len) = withBundlePath(root, gen, entry.path, { loadFile($0) }) else { return nil }
    if !modelBundleVerify(entry, ptr, len) { return nil }
    return (ptr, len)
}

/// Resolve the newest verified generation of the bundle. NOTE: a rejected
/// generation's partial mapping stays mapped until exit (lazy-VMA munmap is a
/// recorded follow-up); with 8 VMA slots and verify-model-first ordering a
/// rejected generation costs one slot, which the serving path never exhausts.
private func resolveBundle(_ root: StaticString)
    -> (model: UnsafeRawPointer, modelLen: Int, tok: UnsafeRawPointer, gen: Int, name: String)? {
    let gens = modelGenerationsNewestFirst(scanGenerations(root))
    for gen in gens {
        let m: ModelManifest
        switch readManifest(root, gen) {
        case .malformed:
            swiftos_puts("llmd: generation "); putUInt(UInt(gen))
            swiftos_puts(" rejected (manifest missing or malformed)\n")
            continue
        case .badSignature:
            swiftos_puts("llmd: generation "); putUInt(UInt(gen))
            swiftos_puts(" rejected (bad manifest signature)\n")
            continue
        case .ok(let parsed):
            m = parsed
        }
        guard let (modelPtr, modelLen) = loadVerified(root, gen, m.model) else {
            swiftos_puts("llmd: generation "); putUInt(UInt(gen))
            swiftos_puts(" rejected (model size/sha256 mismatch)\n")
            continue
        }
        guard let (tokPtr, _) = loadVerified(root, gen, m.tokenizer) else {
            swiftos_puts("llmd: generation "); putUInt(UInt(gen))
            swiftos_puts(" rejected (tokenizer size/sha256 mismatch)\n")
            continue
        }
        return (modelPtr, modelLen, tokPtr, gen, m.name)
    }
    return nil
}

// ---- wall clock (scheduler ticks) -------------------------------------------

private func nowTicks() -> UInt64 {
    _ = swiftos_sysinfo_refresh()
    return UInt64(swiftos_sys_uptime_ticks())
}

// ---- request handling --------------------------------------------------------

private func send400(_ fd: Int32, _ reason: StaticString) {
    writeStr(fd, "HTTP/1.0 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n")
    writeStr(fd, reason)
}

private func send404(_ fd: Int32) {
    writeStr(fd, "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
}

/// Read one HTTP request (headers + body) into `buf`. TCP may deliver it in
/// several segments, so keep reading until the blank line is seen and
/// Content-Length body bytes have arrived (bounded by the buffer and a small
/// read budget). Returns (total bytes, header end offset, content length).
private func readRequest(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ cap: Int) -> (Int, Int, Int) {
    var total = 0
    var headerEnd = -1
    var contentLen = 0
    var reads = 0
    while reads < 16 {
        reads += 1
        let r = swiftos_read(fd, buf + total, UInt(cap - total))
        if r <= 0 { break }
        total += Int(r)
        let b = buf.assumingMemoryBound(to: UInt8.self)
        if headerEnd < 0 {
            var i = 3
            while i < total {
                if b[i - 3] == 0x0D, b[i - 2] == 0x0A, b[i - 1] == 0x0D, b[i] == 0x0A {
                    headerEnd = i + 1
                    contentLen = parseContentLength(b, headerEnd)
                    break
                }
                i += 1
            }
        }
        if headerEnd >= 0 {
            if total >= headerEnd + contentLen { break }
        }
        if total >= cap { break }
    }
    return (total, headerEnd, contentLen)
}

/// Find "Content-Length:" in the header block (curl's canonical spelling, with
/// a lowercase fallback) and parse its decimal value.
private func parseContentLength(_ b: UnsafePointer<UInt8>, _ headerEnd: Int) -> Int {
    let upper: StaticString = "Content-Length:"
    let lower: StaticString = "content-length:"
    var i = 0
    while i < headerEnd {
        // match either spelling at a line start
        if i == 0 || (b[i - 1] == 0x0A) {
            var matched = true
            var k = 0
            upper.withUTF8Buffer { u in
                lower.withUTF8Buffer { l in
                    while k < u.count {
                        if i + k >= headerEnd { matched = false; break }
                        let c = b[i + k]
                        if c != u[k] && c != l[k] { matched = false; break }
                        k += 1
                    }
                }
            }
            if matched {
                var j = i + k
                while j < headerEnd && b[j] == 0x20 { j += 1 }
                var v = 0
                while j < headerEnd, b[j] >= 0x30, b[j] <= 0x39 {
                    v = v * 10 + Int(b[j] - 0x30); j += 1
                }
                return v
            }
        }
        i += 1
    }
    return 0
}

@inline(__always)
/// Byte offset just after "<name>=" on the request line (the query string of
/// `METHOD SP PATH SP VERSION`), matched only when preceded by '?' or '&' so a
/// key never trips on path text. Returns -1 when absent. Bounds the scan to the
/// first line (stops at CR/LF).
private func queryValueStart(_ b: UnsafePointer<UInt8>, _ n: Int, _ name: StaticString) -> Int {
    var lineEnd = 0
    while lineEnd < n && b[lineEnd] != 0x0d && b[lineEnd] != 0x0a { lineEnd += 1 }
    return name.withUTF8Buffer { nm -> Int in
        let m = nm.count
        if m == 0 { return -1 }
        var i = 0
        while i + m + 1 <= lineEnd {
            if i == 0 || b[i - 1] == 0x3f /* ? */ || b[i - 1] == 0x26 /* & */ {
                var k = 0, eq = true
                while k < m { if b[i + k] != nm[k] { eq = false; break }; k += 1 }
                if eq && b[i + m] == 0x3d /* = */ { return i + m + 1 }
            }
            i += 1
        }
        return -1
    }
}

/// Parse an unsigned int query param, or `def` when absent/malformed.
private func parseQueryInt(_ b: UnsafePointer<UInt8>, _ n: Int, _ name: StaticString, _ def: Int) -> Int {
    let s = queryValueStart(b, n, name)
    if s < 0 { return def }
    var j = s, val = 0, any = false
    while j < n, b[j] >= 0x30, b[j] <= 0x39 {
        val = val * 10 + Int(b[j] - 0x30); any = true; j += 1
        if val > 1_000_000 { return 1_000_000 }
    }
    return any ? val : def
}

/// Parse a non-negative decimal float query param (e.g. `0.7`), or `def`.
private func parseQueryFloat(_ b: UnsafePointer<UInt8>, _ n: Int, _ name: StaticString, _ def: Float) -> Float {
    let s = queryValueStart(b, n, name)
    if s < 0 { return def }
    var j = s, intPart = 0
    var any = false
    while j < n, b[j] >= 0x30, b[j] <= 0x39 { intPart = intPart * 10 + Int(b[j] - 0x30); any = true; j += 1 }
    var frac: Float = 0, scale: Float = 0.1
    if j < n, b[j] == 0x2e /* . */ {
        j += 1
        while j < n, b[j] >= 0x30, b[j] <= 0x39 { frac += Float(Int(b[j] - 0x30)) * scale; scale *= 0.1; any = true; j += 1 }
    }
    return any ? (Float(intPart) + frac) : def
}

private func matches(_ b: UnsafePointer<UInt8>, _ n: Int, _ s: StaticString) -> Bool {
    var ok = true
    s.withUTF8Buffer { sb in
        if n < sb.count { ok = false; return }
        var i = 0
        while i < sb.count { if b[i] != sb[i] { ok = false; return }; i += 1 }
    }
    return ok
}

/// Serve one connection: route GET /health, GET /metrics, POST /completion, POST /chat.
private func serveConnection<M: LlamaModel>(_ cfd: Int32, _ model: M, _ tok: LlamaTokenizer, _ hz: UInt64) {
    withUnsafeTemporaryAllocation(byteCount: reqCap, alignment: 16) { req in
        let rp = req.baseAddress!
        let (total, headerEnd, contentLen) = readRequest(cfd, rp, reqCap)
        if total <= 0 || headerEnd < 0 { send400(cfd, "incomplete request\n"); return }
        let b = rp.assumingMemoryBound(to: UInt8.self)

        if matches(b, total, "GET /health") {
            writeStr(cfd, "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nok model dim=")
            writeUInt(cfd, UInt(model.cfg.dim))
            writeStr(cfd, " layers=")
            writeUInt(cfd, UInt(model.cfg.nLayers))
            writeStr(cfd, " vocab=")
            writeUInt(cfd, UInt(model.cfg.vocabSize))
            writeStr(cfd, "\n")
            return
        }
        if matches(b, total, "GET /metrics") {
            writeStr(cfd, "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n")
            writeStr(cfd, "requests "); writeUInt(cfd, mRequests)
            writeStr(cfd, "\ntokens_total "); writeUInt(cfd, mTokensTotal)
            writeStr(cfd, "\nlast_ttft_ms "); writeUInt(cfd, mLastTtftMs)
            writeStr(cfd, "\nlast_tok_s "); writeUInt(cfd, mLastTokS)
            writeStr(cfd, "\n")
            return
        }
        // Two generative routes share the body/sampler/stream tail:
        //   POST /completion — raw prompt, greedy by default.
        //   POST /chat       — wrap the body in the TinyLlama chat template, and
        //                      sample by default (a chat wants variety); stop at EOS.
        let isChat = matches(b, total, "POST /chat")
        if !isChat && !matches(b, total, "POST /completion") { send404(cfd); return }

        // Prompt = the request body (bounded).
        var plen = total - headerEnd
        if plen > contentLen && contentLen > 0 { plen = contentLen }
        if plen <= 0 { send400(cfd, "empty prompt\n"); return }
        if plen > promptCap { plen = promptCap }
        var promptBytes = [UInt8](repeating: 0, count: plen)
        for i in 0..<plen { promptBytes[i] = b[headerEnd + i] }
        let body = String(decoding: promptBytes, as: UTF8.self)

        // Prompt tokens: chat template (with the real EOS) vs raw prompt.
        let promptTokens = isChat ? llamaChatTokens(tok, userMessage: body)
                                  : tok.encode(body, bos: true, eos: false)

        // Sampler from query params. LM6: ?temp, ?top_k, ?top_p, ?seed. Defaults:
        // /completion is greedy (temp 0, backward-compatible); /chat samples.
        let temp = parseQueryFloat(b, total, "temp", isChat ? 0.7 : 0.0)
        let topK = parseQueryInt(b, total, "top_k", isChat ? 40 : 0)
        let topP = parseQueryFloat(b, total, "top_p", isChat ? 0.9 : 1.0)
        let seed = UInt64(parseQueryInt(b, total, "seed", 12345))
        var sampler = LlamaSampler(temperature: temp, topK: topK, topP: topP, seed: seed)

        // `?n=N` caps TOTAL positions (prompt + generated); default 64. Clamp to seqLen.
        var want = parseQueryInt(b, total, "n", defaultSteps)
        if want < 1 { want = defaultSteps }
        let steps = want > model.cfg.seqLen ? model.cfg.seqLen : want

        // Stream: headers first, then each decoded piece (HTTP/1.0 close delimits).
        writeStr(cfd, "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n")
        let t0 = nowTicks()
        var tFirst: UInt64 = 0
        let produced = llamaGenerateSampled(model, tok, promptTokens: promptTokens, steps: steps,
                                            sampler: &sampler, stopOnEos: isChat) { piece in
            if piece.isEmpty { return }
            if tFirst == 0 { tFirst = nowTicks() }
            piece.withUnsafeBytes { raw in
                _ = swiftos_write(cfd, raw.baseAddress, UInt(raw.count))
            }
        }
        let t1 = nowTicks()

        // Serving metrics: latency-to-first-token + tokens/sec.
        let ttftMs = (tFirst >= t0 && hz > 0) ? UInt((tFirst - t0) * 1000 / hz) : 0
        let dticks = t1 >= t0 ? (t1 - t0) : 0
        let rate = (dticks > 0 && hz > 0) ? UInt(UInt64(produced) * hz / dticks) : 0
        mRequests += 1
        mTokensTotal += UInt(produced)
        mLastTtftMs = ttftMs
        mLastTokS = rate
        swiftos_puts("llmd: served "); putUInt(UInt(produced))
        swiftos_puts(" tokens ttft="); putUInt(ttftMs)
        swiftos_puts(" ms rate="); putUInt(rate)
        swiftos_puts(" tok/s\n")
    }
}

// ---- serve loop (generic over the engine: fp32 Llama2 or int8 QLlama2) -------

private func runServe<M: LlamaModel>(_ lfd: Int32, _ model: M, _ tok: LlamaTokenizer) -> Int32 {
    _ = swiftos_sysinfo_refresh()
    let hz = UInt64(swiftos_sys_hz())
    if swiftos_bind(lfd, listenPort) != 0 { swiftos_puts("llmd: bind failed\n"); return 1 }
    if swiftos_listen(lfd, Int32(maxConns)) != 0 { swiftos_puts("llmd: listen failed\n"); return 1 }
    swiftos_puts("llmd: serving on 8080 (POST /completion, GET /health, GET /metrics)\n")

    var conns = [Int32](repeating: -1, count: maxConns)
    while true {
        withUnsafeTemporaryAllocation(byteCount: (maxConns + 1) * 8, alignment: 8) { raw in
            let base = raw.baseAddress!
            base.storeBytes(of: lfd, toByteOffset: 0, as: Int32.self)
            base.storeBytes(of: pollIn, toByteOffset: 4, as: Int16.self)
            base.storeBytes(of: Int16(0), toByteOffset: 6, as: Int16.self)
            var n = 1
            for ci in 0..<maxConns where conns[ci] >= 0 {
                let off = n * 8
                base.storeBytes(of: conns[ci], toByteOffset: off, as: Int32.self)
                base.storeBytes(of: pollIn, toByteOffset: off + 4, as: Int16.self)
                base.storeBytes(of: Int16(0), toByteOffset: off + 6, as: Int16.self)
                n += 1
            }

            if swiftos_poll(base, UInt(n), -1) <= 0 { return }

            var slot = 1
            for ci in 0..<maxConns where conns[ci] >= 0 {
                let rev = base.load(fromByteOffset: slot * 8 + 6, as: Int16.self)
                slot += 1
                if (rev & pollIn) == 0 { continue }
                serveConnection(conns[ci], model, tok, hz)
                _ = swiftos_close(conns[ci])
                conns[ci] = -1
            }

            let lrev = base.load(fromByteOffset: 6, as: Int16.self)
            if (lrev & pollIn) != 0 {
                let c = swiftos_accept(lfd)
                if c >= 0 {
                    var placed = false
                    for ci in 0..<maxConns where conns[ci] < 0 { conns[ci] = Int32(c); placed = true; break }
                    if !placed { _ = swiftos_close(c) }
                }
            }
        }
    }
}

// ---- entry point -------------------------------------------------------------

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    // Default: resolve the verified stories15M bundle (I5) — newest generation
    // that passes manifest + sha256 checks. argv overrides with raw paths
    // (no verification): llmd [model.bin] [tokenizer.bin].
    let modelPtr: UnsafeRawPointer
    let tokPtr: UnsafeRawPointer
    var modelLen = 0
    if argc > 1, let argv = argv, let a = argv[1] {
        guard let (mp, mlen) = loadFile(UnsafePointer(a)) else {
            swiftos_puts("llmd: cannot load model file\n")
            return 1
        }
        modelLen = mlen
        var tp = staticPath("/models/tok512.bin")
        if argc > 2, let t = argv[2] { tp = UnsafePointer(t) }
        guard let (kp, _) = loadFile(tp) else {
            swiftos_puts("llmd: cannot load tokenizer file\n")
            return 1
        }
        modelPtr = mp; tokPtr = kp
    } else {
        loadTrustRoot()
        swiftos_puts(trustRootPresent
            ? "llmd: trust root loaded (/etc/swos/model-signing.pub)\n"
            : "llmd: no trust root; integrity-only mode\n")
        // LM3c: prefer the model disk (/srv/models) when one is mounted; fall
        // back to the base bundle (/models) otherwise.
        var fromDisk = false
        var picked: (model: UnsafeRawPointer, modelLen: Int, tok: UnsafeRawPointer, gen: Int, name: String)? = nil
        for root in diskBundleRoots {
            picked = resolveBundle(root)
            if picked != nil { fromDisk = true; break }
        }
        if picked == nil { picked = resolveBundle(bundleRoot) }
        guard let bundle = picked else {
            swiftos_puts("llmd: no verifiable model bundle generation\n")
            return 1
        }
        swiftos_puts(fromDisk
            ? "llmd: serving from model disk /srv/models\n"
            : "llmd: serving from base /models\n")
        swiftos_puts("llmd: bundle ")
        let nameBytes = Array(bundle.name.utf8)
        nameBytes.withUnsafeBytes { _ = swiftos_write(1, $0.baseAddress, UInt($0.count)) }
        swiftos_puts(" generation "); putUInt(UInt(bundle.gen))
        swiftos_puts(trustRootPresent ? " verified (ed25519+sha256)\n" : " verified (sha256)\n")
        modelPtr = bundle.model; tokPtr = bundle.tok; modelLen = bundle.modelLen
    }
    swiftos_puts("llmd: weights mmap'd file-backed from /models\n")

    // LM2: multi-thread matmul across present CPUs (S5g places workers on them).
    _ = swiftos_sysinfo_refresh()
    let cpus = Int(swiftos_sys_cpu_count())
    _ = llamaMatmulPoolStart(requested: cpus > 0 ? cpus : 1)

    let lfd = swiftos_socket_stream()
    if lfd < 0 { swiftos_puts("llmd: socket failed (capNet?)\n"); return 1 }

    // LM5: a GGUF (Q4_K_M) model — weights stay compressed, dequantized per block.
    if GGUFLlama.isGGUF(modelPtr) {
        guard let model = GGUFLlama(ggufBytes: modelPtr, count: modelLen) else {
            swiftos_puts("llmd: GGUF parse failed\n"); return 1
        }
        swiftos_puts("llmd: model GGUF k-quant dim="); putUInt(UInt(model.cfg.dim))
        swiftos_puts(" layers="); putUInt(UInt(model.cfg.nLayers))
        swiftos_puts(" vocab="); putUInt(UInt(model.cfg.vocabSize)); swiftos_puts("\n")
        let tok = LlamaTokenizer(tokenizerBytes: tokPtr, vocabSize: model.cfg.vocabSize)
        return runServe(lfd, model, tok)
    }
    if QLlama2.isQuantized(modelPtr) {
        let model = QLlama2(modelBytes: modelPtr)
        swiftos_puts("llmd: model int8 Q8_0 GS="); putUInt(UInt(model.gs))
        swiftos_puts(" dim="); putUInt(UInt(model.cfg.dim))
        swiftos_puts(" vocab="); putUInt(UInt(model.cfg.vocabSize)); swiftos_puts("\n")
        let tok = LlamaTokenizer(tokenizerBytes: tokPtr, vocabSize: model.cfg.vocabSize)
        return runServe(lfd, model, tok)
    }
    let model = Llama2(modelBytes: modelPtr)
    swiftos_puts("llmd: model fp32 dim="); putUInt(UInt(model.cfg.dim))
    swiftos_puts(" vocab="); putUInt(UInt(model.cfg.vocabSize)); swiftos_puts("\n")
    let tok = LlamaTokenizer(tokenizerBytes: tokPtr, vocabSize: model.cfg.vocabSize)
    return runServe(lfd, model, tok)
}
