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

private func anchorTarget(_ target: String) -> String? {
    guard let hash = target.firstIndex(of: "#") else {
        return nil
    }
    let raw = String(target[target.index(after: hash)...])
    if raw.isEmpty {
        return nil
    }
    return raw.removingPercentEncoding ?? raw
}

private func markdownAnchorSlug(_ heading: String) -> String {
    var text = heading
    while text.hasPrefix("#") {
        text.removeFirst()
    }
    text = text.trimmingCharacters(in: .whitespaces).lowercased()

    var slug = ""
    for scalar in text.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
            slug.unicodeScalars.append(scalar)
        } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            slug.append("-")
        }
    }
    return slug
}

private var markdownAnchorCache: [String: Set<String>] = [:]

private func markdownAnchors(at path: String) -> Set<String>? {
    if let cached = markdownAnchorCache[path] {
        return cached
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read for anchor validation")
        ok = false
        return nil
    }

    var anchors = Set<String>()
    var counts: [String: Int] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        guard line.hasPrefix("#") else { continue }
        let base = markdownAnchorSlug(line)
        guard !base.isEmpty else { continue }
        let count = counts[base] ?? 0
        counts[base] = count + 1
        anchors.insert(count == 0 ? base : "\(base)-\(count)")
    }

    markdownAnchorCache[path] = anchors
    return anchors
}

private func checkMarkdownAnchor(source file: String,
                                 line: Int,
                                 target: String,
                                 resolvedPath: String) {
    guard resolvedPath.hasSuffix(".md"),
          let anchor = anchorTarget(target) else {
        return
    }
    guard let anchors = markdownAnchors(at: resolvedPath) else {
        return
    }
    if !anchors.contains(anchor) {
        fail("\(file):\(line): broken Markdown anchor \(target)")
        ok = false
    }
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
    if FileManager.default.fileExists(atPath: "ports/README.md") &&
        !mapText.contains("(../ports/README.md)") {
        fail("\(mapPath): missing public documentation map link for ports/README.md")
        ok = false
    }
}

private func documentationMapTargets() -> [String] {
    let mapPath = "docs/DOCUMENTATION.md"
    guard let mapText = try? String(contentsOfFile: mapPath, encoding: .utf8) else {
        fail("\(mapPath): could not read")
        ok = false
        return []
    }

    let linkRegex = try! NSRegularExpression(pattern: #"\(([^)#]+\.md)\)"#)
    let nsText = mapText as NSString
    let matches = linkRegex.matches(in: mapText, range: NSRange(location: 0, length: nsText.length))
    var targets = Set<String>()
    for match in matches {
        let rawTarget = nsText.substring(with: match.range(at: 1))
        if rawTarget.hasPrefix("../ports/") {
            targets.insert(String(rawTarget.dropFirst(3)))
        } else if !rawTarget.contains("/") {
            targets.insert("docs/\(rawTarget)")
        }
    }
    return targets.sorted()
}

private func checkReadmeDocumentationFrontDoorCoverage() {
    let path = "README.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    for target in documentationMapTargets() where !text.contains(target) {
        fail("\(path): missing front-door link for \(target) from docs/DOCUMENTATION.md")
        ok = false
    }
}

private func checkExampleVerificationCoverage() {
    let path = "docs/EXAMPLES.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var currentHeading: String?
    var currentStart = 0
    var currentHasVerification = false

    func finishCurrent(at line: Int) {
        guard let heading = currentHeading else { return }
        if !currentHasVerification {
            fail("\(path):\(currentStart): numbered example `\(heading)` is missing a verification block before line \(line)")
            ok = false
        }
    }

    for (index, line) in lines.enumerated() {
        if line.range(of: #"^## [0-9]+\. "#, options: .regularExpression) != nil {
            finishCurrent(at: index + 1)
            currentHeading = line
            currentStart = index + 1
            currentHasVerification = false
            continue
        }
        if currentHeading != nil &&
            (line == "Verification:" ||
             line == "Equivalent automated check:" ||
             line == "Automated checks:") {
            currentHasVerification = true
        }
    }
    finishCurrent(at: lines.count + 1)
}

private func makeTargetNames() -> Set<String> {
    let path = "Makefile"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return []
    }

    let targetRegex = try! NSRegularExpression(pattern: #"^([A-Za-z0-9_.-]+):"#)
    var targets = Set<String>()
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix(".PHONY:") {
            for target in line.dropFirst(".PHONY:".count).split(separator: " ") {
                targets.insert(String(target))
            }
            continue
        }
        if let groups = firstMatchGroups(targetRegex, in: line, groupCount: 1) {
            targets.insert(groups[0])
        }
    }
    if targets.isEmpty {
        fail("\(path): no make targets found")
        ok = false
    }
    return targets
}

private func validateVerificationCommand(_ line: String,
                                         in path: String,
                                         lineNumber: Int,
                                         makeTargets: Set<String>) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("#") {
        return
    }

    let tokens = trimmed.split { $0 == " " || $0 == "\t" }.map(String.init)
    var index = 0
    while index < tokens.count &&
          tokens[index].contains("=") &&
          !tokens[index].hasPrefix("./") {
        index += 1
    }
    guard index < tokens.count else { return }

    let command = tokens[index]
    if command == "make" {
        for arg in tokens.dropFirst(index + 1) {
            if arg.hasPrefix("-") || arg.contains("=") {
                continue
            }
            if !makeTargets.contains(arg) {
                fail("\(path):\(lineNumber): unknown make target `\(arg)` in verification block")
                ok = false
            }
        }
        return
    }

    if command.hasPrefix("./tests/") {
        if !FileManager.default.fileExists(atPath: String(command.dropFirst(2))) {
            fail("\(path):\(lineNumber): missing verification script `\(command)`")
            ok = false
        }
        return
    }

    fail("\(path):\(lineNumber): verification command should be `make ...` or `./tests/...`, got `\(command)`")
    ok = false
}

private func checkVerificationCommandCoverage(in path: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    let makeTargets = makeTargetNames()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var pendingVerificationFence = false
    var inVerificationFence = false

    for (index, line) in lines.enumerated() {
        if line == "Verification:" ||
            line == "Equivalent automated check:" ||
            line == "Automated checks:" {
            pendingVerificationFence = true
            continue
        }

        if line.hasPrefix("```") {
            if inVerificationFence {
                inVerificationFence = false
                continue
            }
            if pendingVerificationFence {
                inVerificationFence = true
                pendingVerificationFence = false
                continue
            }
        }

        if inVerificationFence {
            validateVerificationCommand(line,
                                        in: path,
                                        lineNumber: index + 1,
                                        makeTargets: makeTargets)
        }
    }
}

private func checkApiCompleteExampleVerificationCoverage() {
    let path = "docs/API_REFERENCE.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var currentHeading: String?
    var currentStart = 0
    var currentHasVerification = false

    func finishCurrent(at line: Int) {
        guard let heading = currentHeading else { return }
        if !currentHasVerification {
            fail("\(path):\(currentStart): complete API example `\(heading)` is missing a verification block before line \(line)")
            ok = false
        }
    }

    for (index, line) in lines.enumerated() {
        if line.hasPrefix("## Complete Example: ") {
            finishCurrent(at: index + 1)
            currentHeading = line
            currentStart = index + 1
            currentHasVerification = false
            continue
        }
        if currentHeading != nil && line == "Verification:" {
            currentHasVerification = true
        }
    }
    finishCurrent(at: lines.count + 1)
}

private func codeSpans(in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    let nsText = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map {
        nsText.substring(with: $0.range(at: 1))
    }
}

private func checkDocumentedPath(_ ref: String, in path: String, lineNumber: Int) {
    if ref.hasSuffix("/*") {
        let dir = String(ref.dropLast(2))
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) ||
            !isDir.boolValue {
            fail("\(path):\(lineNumber): missing documented directory `\(dir)`")
            ok = false
            return
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: dir).isEmpty) != false {
            fail("\(path):\(lineNumber): documented directory `\(dir)` is empty")
            ok = false
        }
        return
    }

    if !FileManager.default.fileExists(atPath: ref) {
        fail("\(path):\(lineNumber): missing documented path `\(ref)`")
        ok = false
    }
}

private func validateApiVerificationReference(_ ref: String,
                                              in path: String,
                                              lineNumber: Int,
                                              makeTargets: Set<String>) {
    if ref.hasPrefix("make ") || ref.hasPrefix("./tests/") {
        validateVerificationCommand(ref,
                                    in: path,
                                    lineNumber: lineNumber,
                                    makeTargets: makeTargets)
        return
    }

    if ref.hasPrefix("tests/") {
        checkDocumentedPath(ref, in: path, lineNumber: lineNumber)
        return
    }

    fail("\(path):\(lineNumber): API verification reference should be `make ...`, `./tests/...`, or `tests/...`, got `\(ref)`")
    ok = false
}

private func checkApiRecipeVerificationCoverage() {
    let path = "docs/API_REFERENCE.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    let makeTargets = makeTargetNames()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var inRecipeIndex = false
    for (index, line) in lines.enumerated() {
        if line == "## API Recipe Index" {
            inRecipeIndex = true
            continue
        }
        if inRecipeIndex && line.hasPrefix("## ") {
            break
        }
        guard inRecipeIndex,
              line.hasPrefix("|"),
              !line.contains("---") else {
            continue
        }

        let cells = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 5 else { continue }
        let task = cells[1]
        let sources = cells[2]
        let verification = cells[cells.count - 2]
        if task == "Task" {
            continue
        }

        let sourceRefs = codeSpans(in: sources)
        if sourceRefs.isEmpty {
            fail("\(path):\(index + 1): API recipe `\(task)` has no source reference")
            ok = false
        }
        for source in sourceRefs where source.hasPrefix("userland/") {
            if !FileManager.default.fileExists(atPath: source) {
                fail("\(path):\(index + 1): API recipe `\(task)` references missing source `\(source)`")
                ok = false
            }
        }

        let commands = codeSpans(in: verification)
        if commands.isEmpty {
            fail("\(path):\(index + 1): API recipe `\(task)` has no verification command")
            ok = false
        }
        for command in commands {
            validateVerificationCommand(command,
                                        in: path,
                                        lineNumber: index + 1,
                                        makeTargets: makeTargets)
        }
    }
}

private func checkApiVerificationMapReferences() {
    let path = "docs/API_REFERENCE.md"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        ok = false
        return
    }

    let makeTargets = makeTargetNames()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var inMap = false
    for (index, line) in lines.enumerated() {
        if line == "## API Verification Map" {
            inMap = true
            continue
        }
        if inMap && line.hasPrefix("## ") {
            break
        }
        guard inMap,
              line.hasPrefix("|"),
              !line.contains("---") else {
            continue
        }

        let cells = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 4 else { continue }
        let area = cells[1]
        let primaryFiles = cells[2]
        let verification = cells[cells.count - 2]
        if area == "API area" {
            continue
        }

        let primaryRefs = codeSpans(in: primaryFiles)
        if primaryRefs.isEmpty {
            fail("\(path):\(index + 1): API verification area `\(area)` has no primary file reference")
            ok = false
        }
        for ref in primaryRefs {
            checkDocumentedPath(ref, in: path, lineNumber: index + 1)
        }

        let verificationRefs = codeSpans(in: verification)
        if verificationRefs.isEmpty {
            fail("\(path):\(index + 1): API verification area `\(area)` has no focused verification reference")
            ok = false
        }
        for ref in verificationRefs {
            validateApiVerificationReference(ref,
                                           in: path,
                                           lineNumber: index + 1,
                                           makeTargets: makeTargets)
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

private func checkedPortRecipePaths() -> [String] {
    guard let categories = try? FileManager.default.contentsOfDirectory(atPath: "ports") else {
        fail("ports: could not list ports directory")
        ok = false
        return []
    }

    var paths: [String] = []
    for category in categories.sorted() {
        let categoryPath = "ports/\(category)"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: categoryPath, isDirectory: &isDir),
              isDir.boolValue,
              let ports = try? FileManager.default.contentsOfDirectory(atPath: categoryPath) else {
            continue
        }
        for port in ports.sorted() {
            let recipePath = "\(categoryPath)/\(port)/Port.json"
            if FileManager.default.fileExists(atPath: recipePath) {
                paths.append(recipePath)
            }
        }
    }

    if paths.isEmpty {
        fail("ports: no checked Port.json recipes found")
        ok = false
    }
    return paths
}

private func checkPortRecipeDocumentationCoverage() {
    let docs = [
        "ports/README.md",
        "docs/PACKAGE_GUIDE.md",
        "docs/PACKAGE_BUILD_AUTOMATION.md",
        "docs/HOST_TOOL_REFERENCE.md",
    ]
    var texts: [String: String] = [:]
    for path in docs {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("\(path): could not read")
            ok = false
            continue
        }
        texts[path] = text
    }

    for recipePath in checkedPortRecipePaths() {
        let shortPath = recipePath
            .replacingOccurrences(of: "ports/", with: "")
            .replacingOccurrences(of: "/Port.json", with: "")
        for doc in docs {
            guard let text = texts[doc] else { continue }
            if !text.contains(recipePath) && !text.contains(shortPath) {
                fail("\(doc): missing checked port recipe `\(recipePath)`")
                ok = false
            }
        }
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
            let resolved: String
            if target.hasPrefix("#") {
                resolved = URL(fileURLWithPath: file).standardizedFileURL.path
            } else {
                guard let local = localPathTarget(target) else { continue }
                let base = URL(fileURLWithPath: file).deletingLastPathComponent()
                resolved = base.appendingPathComponent(local).standardizedFileURL.path
            }
            if !FileManager.default.fileExists(atPath: resolved) {
                fail("\(file):\(index + 1): broken local link \(target)")
                ok = false
                continue
            }
            checkMarkdownAnchor(source: file, line: index + 1, target: target, resolvedPath: resolved)
        }
    }

    if inFence {
        fail("\(file): unclosed fenced code block")
        ok = false
    }
}

checkSyscallTableSync()
checkDocumentationMapCoverage()
checkReadmeDocumentationFrontDoorCoverage()
checkExampleVerificationCoverage()
checkApiCompleteExampleVerificationCoverage()
checkApiRecipeVerificationCoverage()
checkApiVerificationMapReferences()
checkVerificationCommandCoverage(in: "docs/EXAMPLES.md")
checkVerificationCommandCoverage(in: "docs/API_REFERENCE.md")
checkCommandReferenceCoverage()
checkHostToolReferenceCoverage()
checkPortRecipeDocumentationCoverage()
checkSwiftBridgeCoverage()

if !ok {
    exit(1)
}

print("PASS: documentation markdown fences, local links/anchors, API table, Swift bridge, map/front-door coverage, example/API verification coverage, command coverage, host tool coverage, and port recipe coverage are valid")
