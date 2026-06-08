// SPDX-License-Identifier: Apache-2.0
// swpkg_tool_test.swift - host test for the P1 .swpkg tool.

import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

private func readData(_ url: URL, _ label: String) -> Data {
    do {
        return try Data(contentsOf: url)
    } catch {
        fail("could not read \(label): \(error)")
    }
}

private func writeData(_ data: Data, to url: URL, _ label: String) {
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("could not write \(label): \(error)")
    }
}

private func commandOutput(_ result: CommandResult) -> String {
    (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func run(_ executable: URL, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        fail("could not run \(executable.path): \(error)")
    }

    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus,
        stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
}

private func requireSuccess(_ result: CommandResult, _ context: String) {
    guard result.status == 0 else {
        let output = commandOutput(result)
        fail("\(context) failed with status \(result.status)\(output.isEmpty ? "" : ": \(output)")")
    }
}

private func requireFailure(_ result: CommandResult, _ context: String) {
    guard result.status != 0 else {
        let output = commandOutput(result)
        fail("\(context) unexpectedly succeeded\(output.isEmpty ? "" : ": \(output)")")
    }
}

private func corruptFirstOccurrence(in input: URL, output: URL, needle: String, label: String) {
    var data = readData(input, "valid package")
    let needleData = Data(needle.utf8)
    guard let range = data.range(of: needleData), !range.isEmpty else {
        fail("could not find \(label) bytes in package")
    }
    data[range.lowerBound] ^= 0x01
    writeData(data, to: output, label)
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let tool = repo.appendingPathComponent("build/swpkg")
let fixture = repo.appendingPathComponent("fixtures/pkghello", isDirectory: true)
let manifest = fixture.appendingPathComponent("manifest.json")
let root = fixture.appendingPathComponent("root", isDirectory: true)
let installedFile = root.appendingPathComponent("usr/bin/pkghello")

guard FileManager.default.isExecutableFile(atPath: tool.path) else {
    fail("missing executable build/swpkg; build the P1 host tool first")
}
guard FileManager.default.isReadableFile(atPath: installedFile.path) else {
    fail("missing fixture file \(installedFile.path)")
}
guard FileManager.default.isExecutableFile(atPath: installedFile.path) else {
    fail("fixture file is not executable: \(installedFile.path)")
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("swpkg-tool-test-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
} catch {
    fail("could not create temp dir: \(error)")
}
defer { try? FileManager.default.removeItem(at: temp) }

let packageA = temp.appendingPathComponent("pkghello-a.swpkg")
let packageB = temp.appendingPathComponent("pkghello-b.swpkg")
let manifestCorrupt = temp.appendingPathComponent("pkghello-manifest-corrupt.swpkg")
let payloadCorrupt = temp.appendingPathComponent("pkghello-payload-corrupt.swpkg")

requireSuccess(run(tool, [
    "create",
    "--manifest", manifest.path,
    "--root", root.path,
    "--output", packageA.path
]), "create first package")
requireSuccess(run(tool, [
    "create",
    "--manifest", manifest.path,
    "--root", root.path,
    "--output", packageB.path
]), "create second package")

let dataA = readData(packageA, "first package")
let dataB = readData(packageB, "second package")
guard dataA == dataB else {
    fail("create output is not deterministic: \(dataA.count) bytes vs \(dataB.count) bytes")
}

requireSuccess(run(tool, ["verify", packageA.path]), "verify valid package")

let inspect = run(tool, ["inspect", packageA.path])
requireSuccess(inspect, "inspect package")
let inspectText = commandOutput(inspect)
guard inspectText.contains("pkghello") else {
    fail("inspect output does not include pkghello")
}
guard inspectText.contains("/usr/bin/pkghello") else {
    fail("inspect output does not include /usr/bin/pkghello")
}

corruptFirstOccurrence(in: packageA, output: payloadCorrupt,
                       needle: "pkghello fixture payload", label: "payload")
requireFailure(run(tool, ["verify", payloadCorrupt.path]), "verify payload-corrupt package")

corruptFirstOccurrence(in: packageA, output: manifestCorrupt,
                       needle: "1.0.0", label: "manifest")
requireFailure(run(tool, ["verify", manifestCorrupt.path]), "verify manifest-corrupt package")

print("PASS: swpkg create/inspect/verify is deterministic and rejects corrupt packages")
