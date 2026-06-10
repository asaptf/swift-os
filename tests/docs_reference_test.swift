// SPDX-License-Identifier: Apache-2.0
// docs_reference_test.swift - host-side documentation integrity test.

import Foundation

private func fail(_ message: String) {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
}

private func markdownFiles() -> [String] {
    var files = ["README.md"]
    if let docs = try? FileManager.default.contentsOfDirectory(atPath: "docs") {
        files += docs.filter { $0.hasSuffix(".md") }.map { "docs/\($0)" }
    }
    if FileManager.default.fileExists(atPath: "ports/README.md") {
        files.append("ports/README.md")
    }
    return files.sorted()
}

private func hasScheme(_ target: String) -> Bool {
    target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                 options: .regularExpression) != nil
}

private func linkTarget(from raw: String) -> String {
    var target = raw
    if target.hasPrefix("<") && target.hasSuffix(">") {
        target.removeFirst()
        target.removeLast()
    }
    return target
}

private func localPathTarget(_ target: String) -> String? {
    if target.hasPrefix("#") || hasScheme(target) {
        return nil
    }
    let pathPart = target.split(separator: "#", maxSplits: 1,
                                omittingEmptySubsequences: false).first.map(String.init) ?? ""
    if pathPart.isEmpty {
        return nil
    }
    return pathPart.removingPercentEncoding ?? pathPart
}

let linkPattern = #"!?\[[^\]\n]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#
let linkRegex = try! NSRegularExpression(pattern: linkPattern)

var ok = true

for file in markdownFiles() {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        fail("\(file): could not read")
        ok = false
        continue
    }

    var inFence = false
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, rawLine) in lines.enumerated() {
        let line = String(rawLine)
        if line.hasPrefix("```") {
            inFence.toggle()
            continue
        }
        if inFence {
            continue
        }

        let nsLine = line as NSString
        let matches = linkRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let rawTarget = nsLine.substring(with: match.range(at: 1))
            let target = linkTarget(from: rawTarget)
            guard let local = localPathTarget(target) else { continue }

            let base = URL(fileURLWithPath: file).deletingLastPathComponent()
            let resolved = base.appendingPathComponent(local).standardizedFileURL.path
            if !FileManager.default.fileExists(atPath: resolved) {
                fail("\(file):\(index + 1): broken local link \(target)")
                ok = false
            }
        }
    }

    if inFence {
        fail("\(file): unclosed fenced code block")
        ok = false
    }
}

if !ok {
    exit(1)
}

print("PASS: documentation markdown fences and local links are valid")
