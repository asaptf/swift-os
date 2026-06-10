// SPDX-License-Identifier: Apache-2.0
// api_complete_examples_test.swift - guard API complete-example verification.

import Foundation

private var ok = true

private func fail(_ message: String) {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    ok = false
}

private func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        return ""
    }
    return text
}

private func makeTargetNames() -> Set<String> {
    let text = read("Makefile")
    let regex = try! NSRegularExpression(pattern: #"^([A-Za-z0-9_.-]+):"#)
    var targets = Set<String>()

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix(".PHONY:") {
            for target in line.dropFirst(".PHONY:".count).split(separator: " ") {
                targets.insert(String(target))
            }
            continue
        }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        if let match = regex.firstMatch(in: line, range: range) {
            targets.insert(nsLine.substring(with: match.range(at: 1)))
        }
    }
    if targets.isEmpty {
        fail("Makefile: no targets found")
    }
    return targets
}

private func validateCommand(_ commandLine: String,
                             heading: String,
                             makeTargets: Set<String>) {
    let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
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
            if arg.hasPrefix("-") || arg.contains("=") { continue }
            if !makeTargets.contains(arg) {
                fail("\(heading): unknown make target `\(arg)`")
            }
        }
        return
    }

    if command == "bash" && index + 1 < tokens.count && tokens[index + 1].hasPrefix("./tests/") {
        let path = String(tokens[index + 1].dropFirst(2))
        if !FileManager.default.fileExists(atPath: path) {
            fail("\(heading): missing verification script `\(tokens[index + 1])`")
        }
        return
    }

    if command.hasPrefix("./tests/") {
        let path = String(command.dropFirst(2))
        if !FileManager.default.fileExists(atPath: path) {
            fail("\(heading): missing verification script `\(command)`")
        }
        return
    }

    fail("\(heading): verification command should be `make ...` or `./tests/...`, got `\(command)`")
}

private func fencedCommands(afterVerificationIn lines: [String],
                            start: Int,
                            end: Int,
                            heading: String) -> [String] {
    var i = start
    while i < end {
        if lines[i] == "Verification:" {
            var j = i + 1
            while j < end && lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                j += 1
            }
            guard j < end && lines[j].hasPrefix("```") else {
                fail("\(heading): Verification block is missing a fenced command block")
                return []
            }
            var commands: [String] = []
            j += 1
            while j < end && !lines[j].hasPrefix("```") {
                commands.append(lines[j])
                j += 1
            }
            if j >= end {
                fail("\(heading): Verification command fence is not closed")
            }
            return commands
        }
        i += 1
    }
    fail("\(heading): missing Verification block")
    return []
}

let path = "docs/API_REFERENCE.md"
let lines = read(path).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
let makeTargets = makeTargetNames()
var headings: [(String, Int)] = []

for (index, line) in lines.enumerated() where line.hasPrefix("## Complete Example: ") {
    headings.append((line, index))
}

if headings.isEmpty {
    fail("\(path): no complete examples found")
}

for (offset, item) in headings.enumerated() {
    let end = offset + 1 < headings.count ? headings[offset + 1].1 : lines.count
    let commands = fencedCommands(afterVerificationIn: lines,
                                  start: item.1 + 1,
                                  end: end,
                                  heading: item.0)
    if commands.isEmpty {
        fail("\(item.0): verification command block is empty")
    }
    for command in commands {
        validateCommand(command, heading: item.0, makeTargets: makeTargets)
    }
}

if ok {
    print("PASS: API complete examples have runnable verification commands")
    exit(0)
}
exit(1)
