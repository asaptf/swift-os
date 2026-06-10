// SPDX-License-Identifier: Apache-2.0
// pkgstore_tool_test.swift - host test for the P3 package-store image tool.

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

private func commandOutput(_ result: CommandResult) -> String {
    (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func requireSuccess(_ result: CommandResult, _ context: String) {
    guard result.status == 0 else {
        let output = commandOutput(result)
        fail("\(context) failed with status \(result.status)\(output.isEmpty ? "" : ": \(output)")")
    }
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let tool = repo.appendingPathComponent("build/pkgstore")
let swpkg = repo.appendingPathComponent("build/pkghello.swpkg")

guard FileManager.default.isExecutableFile(atPath: tool.path) else {
    fail("missing executable build/pkgstore; build the P3 host tool first")
}
guard FileManager.default.isReadableFile(atPath: swpkg.path) else {
    fail("missing build/pkghello.swpkg; build package-fixture first")
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("pkgstore-tool-test-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
} catch {
    fail("could not create temp dir: \(error)")
}
defer { try? FileManager.default.removeItem(at: temp) }

let storeA = temp.appendingPathComponent("pkgstore-a.img")
let storeB = temp.appendingPathComponent("pkgstore-b.img")

requireSuccess(run(tool, [
    "create",
    "--package", swpkg.path,
    "--output", storeA.path,
    "--generation", "7",
]), "create first store")
requireSuccess(run(tool, [
    "create",
    "--package", swpkg.path,
    "--output", storeB.path,
    "--generation", "7",
]), "create second store")

guard let dataA = try? Data(contentsOf: storeA), let dataB = try? Data(contentsOf: storeB) else {
    fail("could not read generated store images")
}
guard dataA == dataB else {
    fail("pkgstore create output is not deterministic")
}
guard dataA.count % 512 == 0 else {
    fail("pkgstore image is not sector-aligned")
}

let inspect = run(tool, ["inspect", storeA.path])
requireSuccess(inspect, "inspect store")
let text = commandOutput(inspect)
guard text.contains("active_generation: 7") else {
    fail("inspect output does not include active generation")
}
guard text.contains("pkghello-1.0.0_1") else {
    fail("inspect output does not include pkghello payload")
}
guard text.contains("activations:") else {
    fail("inspect output does not include activations")
}

print("PASS: pkgstore create/inspect is deterministic and records active payload generation")
