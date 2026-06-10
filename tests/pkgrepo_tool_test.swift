// SPDX-License-Identifier: Apache-2.0
// pkgrepo_tool_test.swift - host test for the P5 static package repository tool.

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
let tool = repo.appendingPathComponent("build/pkgrepo")
let swpkg = repo.appendingPathComponent("build/pkghello.swpkg")
let seed = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

guard FileManager.default.isExecutableFile(atPath: tool.path) else {
    fail("missing executable build/pkgrepo; build the P5 host tool first")
}
guard FileManager.default.isReadableFile(atPath: swpkg.path) else {
    fail("missing build/pkghello.swpkg; build package-fixture first")
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("pkgrepo-tool-test-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
} catch {
    fail("could not create temp dir: \(error)")
}
defer { try? FileManager.default.removeItem(at: temp) }

let repoRoot = temp.appendingPathComponent("repo", isDirectory: true)
let pubkey = temp.appendingPathComponent("repo-root.pub")

requireSuccess(run(tool, [
    "pubkey",
    "--seed-hex", seed,
    "--output", pubkey.path,
]), "pubkey")

guard let pubData = try? Data(contentsOf: pubkey), pubData.count == 32 else {
    fail("public key was not written as 32 raw bytes")
}

requireSuccess(run(tool, [
    "create",
    "--package", swpkg.path,
    "--output", repoRoot.path,
    "--seed-hex", seed,
    "--generation", "11",
]), "create repo")

let channel = repoRoot.appendingPathComponent("aarch64/current", isDirectory: true)
let catalog = channel.appendingPathComponent("catalog.json")
let signedCatalog = channel.appendingPathComponent("catalog.signed")
let packages = channel.appendingPathComponent("packages", isDirectory: true)

guard FileManager.default.isReadableFile(atPath: catalog.path) else {
    fail("catalog.json was not created")
}
guard FileManager.default.isReadableFile(atPath: signedCatalog.path) else {
    fail("catalog.signed was not created")
}

let packageFiles = (try? FileManager.default.contentsOfDirectory(atPath: packages.path)) ?? []
guard packageFiles.count == 1, packageFiles[0].hasSuffix(".swpkg") else {
    fail("content-addressed package file was not created")
}

let verify = run(tool, [
    "verify",
    "--catalog-signed", signedCatalog.path,
    "--pubkey", pubkey.path,
])
requireSuccess(verify, "verify signed catalog")
guard commandOutput(verify).contains("signature: OK") else {
    fail("verify output did not report a valid signature")
}

let inspect = run(tool, ["inspect", signedCatalog.path])
requireSuccess(inspect, "inspect signed catalog")
let inspectText = commandOutput(inspect)
guard inspectText.contains("repository: swift-os-current") else {
    fail("inspect output does not include repository")
}
guard inspectText.contains("generation: 11") else {
    fail("inspect output does not include generation")
}
guard inspectText.contains("pkghello-1.0.0_1") else {
    fail("inspect output does not include pkghello")
}

let signedData = try Data(contentsOf: signedCatalog)
var tampered = signedData
tampered[tampered.count - 1] ^= 0x01
let tamperedCatalog = temp.appendingPathComponent("catalog-tampered.signed")
try tampered.write(to: tamperedCatalog)

let badVerify = run(tool, [
    "verify",
    "--catalog-signed", tamperedCatalog.path,
    "--pubkey", pubkey.path,
])
guard badVerify.status != 0, commandOutput(badVerify).contains("signature: INVALID") else {
    fail("tampered catalog unexpectedly verified")
}

print("PASS: pkgrepo creates deterministic signed catalogs and rejects tampering")
