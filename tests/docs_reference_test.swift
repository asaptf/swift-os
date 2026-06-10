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

private struct SyscallDocEntry {
    let number: Int
    let name: String
}

private func firstMatchGroups(_ regex: NSRegularExpression,
                              in line: String,
                              groupCount: Int) -> [String]? {
    let nsLine = line as NSString
    let range = NSRange(location: 0, length: nsLine.length)
    guard let match = regex.firstMatch(in: line, range: range) else {
        return nil
    }
    var groups: [String] = []
    for index in 1...groupCount {
        let groupRange = match.range(at: index)
        guard groupRange.location != NSNotFound else {
            return nil
        }
        groups.append(nsLine.substring(with: groupRange))
    }
    return groups
}

private func syscallName(from macro: String) -> String {
    macro.lowercased()
}

private func parseHeaderSyscalls() -> [SyscallDocEntry] {
    let path = "userland/lib/syscall.h"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return []
    }

    let defineRegex = try! NSRegularExpression(
        pattern: #"^\s*#define\s+SYS_([A-Z0-9_]+)\s+([0-9]+)\b"#
    )
    var entries: [SyscallDocEntry] = []
    var seenNumbers: [Int: String] = [:]

    for (index, rawLine) in text.split(separator: "\n",
                                       omittingEmptySubsequences: false).enumerated() {
        let line = String(rawLine)
        guard let groups = firstMatchGroups(defineRegex, in: line, groupCount: 2),
              let number = Int(groups[1]) else {
            continue
        }

        let name = syscallName(from: groups[0])
        if let previous = seenNumbers[number] {
            fail("\(path):\(index + 1): SYS_\(groups[0]) reuses number \(number) from \(previous)")
            ok = false
        }
        seenNumbers[number] = "SYS_\(groups[0])"
        entries.append(SyscallDocEntry(number: number, name: name))
    }

    if entries.isEmpty {
        fail("\(path): no SYS_* definitions found")
        ok = false
    }
    return entries.sorted { $0.number < $1.number }
}

private func parseDocumentedSyscalls() -> [SyscallDocEntry] {
    let path = "docs/API_REFERENCE.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return []
    }

    let rowRegex = try! NSRegularExpression(
        pattern: #"^\|\s*([0-9]+)\s*\|\s*`([^`]+)`\s*\|"#
    )
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var inTable = false
    var entries: [SyscallDocEntry] = []
    var seenNumbers: [Int: String] = [:]
    var previousNumber: Int?

    for (index, rawLine) in lines.enumerated() {
        let line = String(rawLine)
        if line == "## Syscall Table" {
            inTable = true
            continue
        }
        if inTable && line.hasPrefix("Notes:") {
            break
        }
        guard inTable,
              let groups = firstMatchGroups(rowRegex, in: line, groupCount: 2),
              let number = Int(groups[0]) else {
            continue
        }

        let name = groups[1]
        if let previous = previousNumber, number <= previous {
            fail("\(path):\(index + 1): syscall table is not sorted by number")
            ok = false
        }
        previousNumber = number
        if let previous = seenNumbers[number] {
            fail("\(path):\(index + 1): \(name) reuses number \(number) from \(previous)")
            ok = false
        }
        seenNumbers[number] = name
        entries.append(SyscallDocEntry(number: number, name: name))
    }

    if entries.isEmpty {
        fail("\(path): syscall table has no rows")
        ok = false
    }
    return entries
}

private func checkSyscallTableSync() {
    let headerEntries = parseHeaderSyscalls()
    let documentedEntries = parseDocumentedSyscalls()
    var headerByNumber: [Int: String] = [:]
    var documentedByNumber: [Int: String] = [:]

    for entry in headerEntries {
        headerByNumber[entry.number] = entry.name
    }
    for entry in documentedEntries {
        documentedByNumber[entry.number] = entry.name
    }

    for entry in headerEntries {
        guard let documented = documentedByNumber[entry.number] else {
            fail("docs/API_REFERENCE.md: missing syscall \(entry.number) `\(entry.name)` from userland/lib/syscall.h")
            ok = false
            continue
        }
        if documented != entry.name {
            fail("docs/API_REFERENCE.md: syscall \(entry.number) is documented as `\(documented)`, expected `\(entry.name)`")
            ok = false
        }
    }

    for entry in documentedEntries where headerByNumber[entry.number] == nil {
        fail("docs/API_REFERENCE.md: syscall \(entry.number) `\(entry.name)` is not defined in userland/lib/syscall.h")
        ok = false
    }
}

private func checkDocumentationMapCoverage() {
    let mapPath = "docs/DOCUMENTATION.md"
    guard let mapText = try? String(contentsOfFile: mapPath, encoding: .utf8) else {
        fail("\(mapPath): could not read")
        ok = false
        return
    }
    guard let docs = try? FileManager.default.contentsOfDirectory(atPath: "docs") else {
        fail("docs: could not list documentation directory")
        ok = false
        return
    }

    for name in docs.sorted() where name.hasSuffix(".md") && name != "DOCUMENTATION.md" {
        if !mapText.contains("(\(name))") {
            fail("\(mapPath): missing public documentation map link for docs/\(name)")
            ok = false
        }
    }
}

private func stagedBaseCommands() -> [String] {
    let path = "Makefile"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return []
    }

    let copyRegex = try! NSRegularExpression(
        pattern: #"^\s*cp\s+.+\Q$(BASE_ROOT)/bin/\E([A-Za-z0-9._+-]+)\s*$"#
    )
    var commands = Set<String>()
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if let groups = firstMatchGroups(copyRegex, in: String(line), groupCount: 1) {
            commands.insert(groups[0])
        }
    }
    if commands.isEmpty {
        fail("\(path): no base image /bin copy rules found")
        ok = false
    }
    return commands.sorted()
}

private func checkCommandReferenceCoverage() {
    let path = "docs/COMMAND_REFERENCE.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    for command in stagedBaseCommands() {
        let hasHeading = text.contains("### `\(command)`")
        let hasTableRow = text.contains("| `\(command)` |")
        if !hasHeading && !hasTableRow {
            fail("\(path): missing command reference entry for /bin/\(command)")
            ok = false
        }
    }
}

private func hostToolExecutables() -> [String] {
    let path = "Makefile"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return []
    }

    let toolRegex = try! NSRegularExpression(
        pattern: #"\btools/([A-Za-z0-9_-]+)\.swift\b"#
    )
    var tools = Set<String>()
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if !line.contains("$(HOST_SWIFTC)") || !line.contains("-o $@") {
            continue
        }
        let nsLine = line as NSString
        let matches = toolRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard let first = matches.first else { continue }
        let name = nsLine.substring(with: first.range(at: 1))
        if name != "packfs" {
            tools.insert(name)
        }
    }
    if tools.isEmpty {
        fail("\(path): no host tool build rules found")
        ok = false
    }
    return tools.sorted()
}

private func checkHostToolReferenceCoverage() {
    let path = "docs/HOST_TOOL_REFERENCE.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    for tool in hostToolExecutables() where !text.contains("build/\(tool)") {
        fail("\(path): missing host tool reference entry for build/\(tool)")
        ok = false
    }
}

private func checkSwiftBridgeCoverage() {
    let headerPath = "userland/lib/swift_user.h"
    guard let headerText = try? String(contentsOfFile: headerPath, encoding: .utf8) else {
        fail("\(headerPath): could not read")
        ok = false
        return
    }
    let apiPath = "docs/API_REFERENCE.md"
    guard let apiText = try? String(contentsOfFile: apiPath, encoding: .utf8) else {
        fail("\(apiPath): could not read")
        ok = false
        return
    }

    let functionRegex = try! NSRegularExpression(
        pattern: #"\b(swiftos_[A-Za-z0-9_]+)\s*\("#
    )
    var functions = Set<String>()
    for rawLine in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if let groups = firstMatchGroups(functionRegex, in: line, groupCount: 1) {
            functions.insert(groups[0])
        }
    }
    if functions.isEmpty {
        fail("\(headerPath): no swiftos_* bridge functions found")
        ok = false
    }

    for name in functions.sorted() where !apiText.contains(name) {
        fail("\(apiPath): missing Swift bridge function `\(name)` from \(headerPath)")
        ok = false
    }
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

checkSyscallTableSync()
checkDocumentationMapCoverage()
checkCommandReferenceCoverage()
checkHostToolReferenceCoverage()
checkSwiftBridgeCoverage()

if !ok {
    exit(1)
}

print("PASS: documentation markdown fences, local links, API table, Swift bridge, map coverage, command coverage, and host tool coverage are valid")
