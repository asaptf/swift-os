// SPDX-License-Identifier: Apache-2.0
// Yaml.swift — a tiny, Foundation-free YAML-subset parser for the SwiftCube manifest (SC9).
//
// The manifest (SWIFTCUBE_DESIGN §10) is a compose-like YAML document. SwiftCube does not
// pull in a third-party YAML library: the build compiles Swift sources directly (no package
// manager), and the parser must be **Foundation-free** because `sctld` re-validates manifests
// server-side (the milestone's "kept Foundation-free where it is also linked server-side").
// So this is a focused recursive-descent parser for exactly the subset the manifest uses —
// not a general YAML 1.2 implementation.
//
// Supported subset:
//   • block mappings   `key: value` with space-indentation nesting
//   • block sequences  `- item` (scalar item, inline flow item, or a nested block mapping)
//   • flow mappings    `{ k: v, k2: { ... } }` (nestable)
//   • flow sequences   `[ a, b, [c, d] ]` (nestable)
//   • scalars          bare / 'single-quoted' / "double-quoted"
//   • `#` line comments (outside quotes)
// Tabs in indentation are rejected (YAML forbids them) and surface as a parse error. Every
// scalar stays a String; typing (UInt32 replicas, bool flags, `100m`/`64Mi`) is the
// ManifestParser's job, not the YAML layer's.
//
// The parser works over `[UInt8]` (the manifest is ASCII/UTF-8) rather than String.Index,
// which keeps it simple and Embedded-Swift friendly. Output is a `YamlNode` tree that
// preserves mapping key order (so encodings are deterministic and errors are stable).

// MARK: - Node model

/// One `key: value` pair in a mapping. A struct (not a tuple) so `YamlNode` synthesizes
/// `Equatable` for free.
struct YamlEntry: Equatable {
    let key: String
    let value: YamlNode
}

/// A parsed YAML value. `indirect` so the recursive cases compile; `Equatable` for golden tests.
indirect enum YamlNode: Equatable {
    case scalar(String)
    case mapping([YamlEntry])
    case sequence([YamlNode])

    var asScalar: String? { if case .scalar(let s) = self { return s }; return nil }
    var asMapping: [YamlEntry]? { if case .mapping(let m) = self { return m }; return nil }
    var asSequence: [YamlNode]? { if case .sequence(let s) = self { return s }; return nil }

    /// Mapping lookup by key (first match), or nil for a non-mapping / missing key.
    func child(_ key: String) -> YamlNode? {
        guard case .mapping(let entries) = self else { return nil }
        for e in entries where e.key == key { return e.value }
        return nil
    }
}

/// Parse outcome: a node or a human error (with a 1-based line number when known).
enum YamlResult: Equatable {
    case ok(YamlNode)
    case error(String)
}

// MARK: - Byte helpers (ASCII; no Foundation)

private let SPACE: UInt8 = 0x20
private let TAB: UInt8 = 0x09
private let HASH: UInt8 = 0x23
private let DASH: UInt8 = 0x2D
private let COLON: UInt8 = 0x3A
private let COMMA: UInt8 = 0x2C
private let LBRACE: UInt8 = 0x7B
private let RBRACE: UInt8 = 0x7D
private let LBRACK: UInt8 = 0x5B
private let RBRACK: UInt8 = 0x5D
private let SQUOTE: UInt8 = 0x27
private let DQUOTE: UInt8 = 0x22
private let CR: UInt8 = 0x0D
private let LF: UInt8 = 0x0A

private func str(_ b: ArraySlice<UInt8>) -> String { String(decoding: b, as: UTF8.self) }
private func str(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

/// Trim leading/trailing ASCII spaces (and CR) from a slice → a fresh array.
private func trimmed(_ b: ArraySlice<UInt8>) -> [UInt8] {
    var lo = b.startIndex, hi = b.endIndex
    while lo < hi, b[lo] == SPACE || b[lo] == TAB || b[lo] == CR { lo += 1 }
    while hi > lo, b[hi - 1] == SPACE || b[hi - 1] == TAB || b[hi - 1] == CR { hi -= 1 }
    return Array(b[lo..<hi])
}

// MARK: - Line model

/// A non-blank source line, reduced to its indentation depth and comment-stripped content.
private struct Line {
    var indent: Int          // count of leading spaces
    var text: [UInt8]        // content after indentation, comments removed, right-trimmed
    var lineNo: Int          // 1-based, for error messages
}

/// Strip an unquoted `#…` comment from one raw line and split off its indentation. Returns nil
/// for a blank/comment-only line (skipped). Returns a Line, or throws a message on a tab indent.
private func makeLine(_ raw: ArraySlice<UInt8>, lineNo: Int) -> (line: Line?, error: String?) {
    // Indentation: count spaces; a tab in the indent is an error.
    var i = raw.startIndex
    var indent = 0
    while i < raw.endIndex, raw[i] == SPACE { indent += 1; i += 1 }
    if i < raw.endIndex, raw[i] == TAB {
        return (nil, "line \(lineNo): tab in indentation (use spaces)")
    }
    // Walk the rest, dropping an unquoted comment.
    var out: [UInt8] = []
    var inS = false, inD = false
    var prevWasSpaceOrStart = true
    var j = i
    while j < raw.endIndex {
        let c = raw[j]
        if c == CR { j += 1; continue }
        if inS { out.append(c); if c == SQUOTE { inS = false }; prevWasSpaceOrStart = false; j += 1; continue }
        if inD { out.append(c); if c == DQUOTE { inD = false }; prevWasSpaceOrStart = false; j += 1; continue }
        if c == SQUOTE { inS = true; out.append(c); prevWasSpaceOrStart = false; j += 1; continue }
        if c == DQUOTE { inD = true; out.append(c); prevWasSpaceOrStart = false; j += 1; continue }
        if c == HASH && prevWasSpaceOrStart { break }   // start of a comment
        out.append(c)
        prevWasSpaceOrStart = (c == SPACE)
        j += 1
    }
    let content = trimmed(out[...])
    if content.isEmpty { return (nil, nil) }            // blank or comment-only
    return (Line(indent: indent, text: content, lineNo: lineNo), nil)
}

// MARK: - Top-level entry

/// Parse a manifest document into a `YamlNode`. The document root must be a block mapping.
func parseYaml(_ bytes: [UInt8]) -> YamlResult {
    // Split into lines, strip comments/indentation, drop blanks.
    var lines: [Line] = []
    var start = 0
    var lineNo = 0
    var k = 0
    while k <= bytes.count {
        if k == bytes.count || bytes[k] == LF {
            lineNo += 1
            let (ln, err) = makeLine(bytes[start..<k], lineNo: lineNo)
            if let err = err { return .error(err) }
            if let ln = ln { lines.append(ln) }
            start = k + 1
        }
        k += 1
    }
    if lines.isEmpty { return .error("empty manifest") }

    var cursor = 0
    let baseIndent = lines[0].indent
    let (node, err) = parseBlock(lines, &cursor, indent: baseIndent)
    if let err = err { return .error(err) }
    guard let node = node else { return .error("line \(lines[0].lineNo): malformed document") }
    if cursor != lines.count {
        return .error("line \(lines[cursor].lineNo): unexpected indentation")
    }
    return .ok(node)
}

// MARK: - Block parsing

/// Parse a block (mapping or sequence) whose entries sit at column `indent`, advancing `cursor`.
private func parseBlock(_ lines: [Line], _ cursor: inout Int, indent: Int) -> (YamlNode?, String?) {
    guard cursor < lines.count else { return (.mapping([]), nil) }
    if lines[cursor].text.first == DASH && isDashItem(lines[cursor].text) {
        return parseSequence(lines, &cursor, indent: indent)
    }
    return parseMapping(lines, &cursor, indent: indent)
}

/// True if a line's content is a sequence item: `-` alone or `- …`.
private func isDashItem(_ text: [UInt8]) -> Bool {
    guard text.first == DASH else { return false }
    return text.count == 1 || text[1] == SPACE
}

private func parseMapping(_ lines: [Line], _ cursor: inout Int, indent: Int) -> (YamlNode?, String?) {
    var entries: [YamlEntry] = []
    while cursor < lines.count {
        let ln = lines[cursor]
        if ln.indent < indent { break }
        if ln.indent > indent { return (nil, "line \(ln.lineNo): unexpected indentation") }
        if ln.text.first == DASH && isDashItem(ln.text) {
            return (nil, "line \(ln.lineNo): sequence item where a mapping key was expected")
        }
        // Split `key: value` at the first top-level "colon-space" or trailing colon.
        guard let (keyB, rest, hadColon) = splitKey(ln.text) else {
            return (nil, "line \(ln.lineNo): expected 'key: value'")
        }
        if !hadColon { return (nil, "line \(ln.lineNo): expected ':' after key '\(str(keyB))'") }
        let key = str(keyB)
        cursor += 1
        if rest.isEmpty {
            // Nested block (deeper indent) or an empty scalar.
            if cursor < lines.count && lines[cursor].indent > indent {
                let (child, err) = parseBlock(lines, &cursor, indent: lines[cursor].indent)
                if let err = err { return (nil, err) }
                entries.append(YamlEntry(key: key, value: child ?? .scalar("")))
            } else {
                entries.append(YamlEntry(key: key, value: .scalar("")))
            }
        } else {
            let (val, err) = parseFlow(rest, lineNo: ln.lineNo)
            if let err = err { return (nil, err) }
            entries.append(YamlEntry(key: key, value: val ?? .scalar("")))
        }
    }
    return (.mapping(entries), nil)
}

private func parseSequence(_ lines: [Line], _ cursor: inout Int, indent: Int) -> (YamlNode?, String?) {
    var items: [YamlNode] = []
    while cursor < lines.count {
        let ln = lines[cursor]
        if ln.indent < indent { break }
        if ln.indent > indent { return (nil, "line \(ln.lineNo): unexpected indentation") }
        guard ln.text.first == DASH && isDashItem(ln.text) else { break }

        // Content after the dash (and the single following space, if any).
        var c = 1
        while c < ln.text.count && ln.text[c] == SPACE { c += 1 }
        let contentCol = indent + c
        let content = Array(ln.text[c...])

        if content.isEmpty {
            // A bare `-`: the item is a nested block below at a deeper indent.
            cursor += 1
            if cursor < lines.count && lines[cursor].indent > indent {
                let (child, err) = parseBlock(lines, &cursor, indent: lines[cursor].indent)
                if let err = err { return (nil, err) }
                items.append(child ?? .scalar(""))
            } else {
                items.append(.scalar(""))
            }
            continue
        }

        // The dash line carries content. If it is a `key: …` pair, the item is a block mapping
        // whose first entry is on this line and whose remaining entries are indented to
        // `contentCol`. We rewrite this line to sit at `contentCol` and parse a sub-block that
        // consumes the contiguous run of lines with indent >= contentCol.
        if let (_, _, hadColon) = splitKey(content), hadColon, !startsFlow(content) {
            var sub: [Line] = [Line(indent: contentCol, text: content, lineNo: ln.lineNo)]
            cursor += 1
            while cursor < lines.count && lines[cursor].indent >= contentCol {
                sub.append(lines[cursor]); cursor += 1
            }
            var subCursor = 0
            let (child, err) = parseBlock(sub, &subCursor, indent: contentCol)
            if let err = err { return (nil, err) }
            items.append(child ?? .scalar(""))
        } else {
            // A scalar or flow item entirely on this line.
            let (val, err) = parseFlow(content, lineNo: ln.lineNo)
            if let err = err { return (nil, err) }
            items.append(val ?? .scalar(""))
            cursor += 1
        }
    }
    return (.sequence(items), nil)
}

// MARK: - Flow parsing (single-line values: scalars, `{…}`, `[…]`)

private func startsFlow(_ b: [UInt8]) -> Bool { b.first == LBRACE || b.first == LBRACK }

/// Parse a single-line value: a flow mapping, a flow sequence, or a scalar.
private func parseFlow(_ b: [UInt8], lineNo: Int) -> (YamlNode?, String?) {
    let t = trimmed(b[...])
    if t.isEmpty { return (.scalar(""), nil) }
    if t.first == LBRACE { return parseFlowMap(t, lineNo: lineNo) }
    if t.first == LBRACK { return parseFlowSeq(t, lineNo: lineNo) }
    return (.scalar(unquote(t)), nil)
}

private func parseFlowMap(_ b: [UInt8], lineNo: Int) -> (YamlNode?, String?) {
    guard b.first == LBRACE, b.last == RBRACE else { return (nil, "line \(lineNo): malformed flow mapping") }
    let inner = trimmed(b[(b.startIndex + 1)..<(b.endIndex - 1)])
    if inner.isEmpty { return (.mapping([]), nil) }
    guard let parts = splitTopLevel(inner, COMMA, lineNo: lineNo) else {
        return (nil, "line \(lineNo): unbalanced flow mapping")
    }
    var entries: [YamlEntry] = []
    for p in parts {
        let pt = trimmed(p[...])
        if pt.isEmpty { continue }
        guard let (keyB, rest, hadColon) = splitKey(pt), hadColon else {
            return (nil, "line \(lineNo): flow mapping entry missing ':' near '\(str(pt))'")
        }
        let (val, err) = parseFlow(rest, lineNo: lineNo)
        if let err = err { return (nil, err) }
        entries.append(YamlEntry(key: str(keyB), value: val ?? .scalar("")))
    }
    return (.mapping(entries), nil)
}

private func parseFlowSeq(_ b: [UInt8], lineNo: Int) -> (YamlNode?, String?) {
    guard b.first == LBRACK, b.last == RBRACK else { return (nil, "line \(lineNo): malformed flow sequence") }
    let inner = trimmed(b[(b.startIndex + 1)..<(b.endIndex - 1)])
    if inner.isEmpty { return (.sequence([]), nil) }
    guard let parts = splitTopLevel(inner, COMMA, lineNo: lineNo) else {
        return (nil, "line \(lineNo): unbalanced flow sequence")
    }
    var items: [YamlNode] = []
    for p in parts {
        let pt = trimmed(p[...])
        if pt.isEmpty { continue }
        let (val, err) = parseFlow(pt, lineNo: lineNo)
        if let err = err { return (nil, err) }
        items.append(val ?? .scalar(""))
    }
    return (.sequence(items), nil)
}

// MARK: - Scalar / key splitting

/// Remove a matching pair of surrounding quotes, if present.
private func unquote(_ b: [UInt8]) -> String {
    if b.count >= 2, (b.first == DQUOTE && b.last == DQUOTE) || (b.first == SQUOTE && b.last == SQUOTE) {
        return str(b[(b.startIndex + 1)..<(b.endIndex - 1)])
    }
    return str(b)
}

/// Split a `key: value` form at the first top-level `:` (followed by a space or end-of-token,
/// or a `:` immediately before a flow `{`/`[`). Returns (key, value, hadColon). `hadColon ==
/// false` ⇒ no key/value separator was present (the whole token is the "key").
private func splitKey(_ b: [UInt8]) -> (key: [UInt8], value: [UInt8], hadColon: Bool)? {
    var depth = 0
    var inS = false, inD = false
    var i = b.startIndex
    while i < b.endIndex {
        let c = b[i]
        if inS { if c == SQUOTE { inS = false }; i += 1; continue }
        if inD { if c == DQUOTE { inD = false }; i += 1; continue }
        switch c {
        case SQUOTE: inS = true
        case DQUOTE: inD = true
        case LBRACE, LBRACK: depth += 1
        case RBRACE, RBRACK: depth -= 1
        case COLON where depth == 0:
            let next = i + 1
            if next == b.endIndex || b[next] == SPACE || b[next] == LBRACE || b[next] == LBRACK {
                let key = trimmed(b[b.startIndex..<i])
                let value = next == b.endIndex ? [] : trimmed(b[next..<b.endIndex])
                return (key, value, true)
            }
        default: break
        }
        i += 1
    }
    return (trimmed(b[...]), [], false)
}

/// Split a flow body on `sep` at the top nesting level (outside quotes/braces/brackets).
/// Returns nil if the brackets are unbalanced.
private func splitTopLevel(_ b: [UInt8], _ sep: UInt8, lineNo: Int) -> [[UInt8]]? {
    var parts: [[UInt8]] = []
    var depth = 0
    var inS = false, inD = false
    var startIdx = b.startIndex
    var i = b.startIndex
    while i < b.endIndex {
        let c = b[i]
        if inS { if c == SQUOTE { inS = false }; i += 1; continue }
        if inD { if c == DQUOTE { inD = false }; i += 1; continue }
        switch c {
        case SQUOTE: inS = true
        case DQUOTE: inD = true
        case LBRACE, LBRACK: depth += 1
        case RBRACE, RBRACK: depth -= 1; if depth < 0 { return nil }
        case sep where depth == 0:
            parts.append(Array(b[startIdx..<i])); startIdx = i + 1
        default: break
        }
        i += 1
    }
    if depth != 0 || inS || inD { return nil }
    parts.append(Array(b[startIdx..<b.endIndex]))
    return parts
}
