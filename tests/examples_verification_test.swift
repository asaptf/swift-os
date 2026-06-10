// SPDX-License-Identifier: Apache-2.0
// examples_verification_test.swift - guard runnable checks in docs/EXAMPLES.md.

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

private func makeTargets() -> Set<String> {
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

private func validateCommand(_ raw: String,
                             section: String,
                             lineNumber: Int,
                             targets: Set<String>) {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
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
            if !targets.contains(arg) {
                fail("\(section):\(lineNumber): unknown make target `\(arg)`")
            }
        }
        return
    }

    if command == "bash" && index + 1 < tokens.count && tokens[index + 1].hasPrefix("./tests/") {
        let path = String(tokens[index + 1].dropFirst(2))
        if !FileManager.default.fileExists(atPath: path) {
            fail("\(section):\(lineNumber): missing verification script `\(tokens[index + 1])`")
        }
        return
    }

    if command.hasPrefix("./tests/") {
        let path = String(command.dropFirst(2))
        if !FileManager.default.fileExists(atPath: path) {
            fail("\(section):\(lineNumber): missing verification script `\(command)`")
        }
        return
    }

    fail("\(section):\(lineNumber): verification command should be `make ...` or `./tests/...`, got `\(command)`")
}

private func currentHeading(_ lines: [String], before index: Int) -> String {
    var i = index
    while i >= 0 {
        if lines[i].hasPrefix("## ") {
            return lines[i]
        }
        i -= 1
    }
    return "docs/EXAMPLES.md"
}

let path = "docs/EXAMPLES.md"
let lines = read(path).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
let targets = makeTargets()
let labels = Set(["Verification:", "Equivalent automated check:", "Automated checks:"])
var blocks = 0

var i = 0
while i < lines.count {
    if !labels.contains(lines[i]) {
        i += 1
        continue
    }

    blocks += 1
    let labelLine = i + 1
    let heading = currentHeading(lines, before: i)
    i += 1
    while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
        i += 1
    }
    guard i < lines.count && lines[i].hasPrefix("```") else {
        fail("\(heading):\(labelLine): verification label is missing a fenced command block")
        continue
    }
    i += 1

    var commandCount = 0
    while i < lines.count && !lines[i].hasPrefix("```") {
        if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            commandCount += 1
        }
        validateCommand(lines[i], section: heading, lineNumber: i + 1, targets: targets)
        i += 1
    }

    if commandCount == 0 {
        fail("\(heading):\(labelLine): verification command block is empty")
    }
    if i >= lines.count {
        fail("\(heading):\(labelLine): verification command fence is not closed")
    }
    i += 1
}

if blocks == 0 {
    fail("\(path): no verification blocks found")
}

if ok {
    print("PASS: examples verification blocks point to runnable tests or Makefile targets")
    exit(0)
}
exit(1)
