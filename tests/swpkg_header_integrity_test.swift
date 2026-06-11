// SPDX-License-Identifier: Apache-2.0
// swpkg_header_integrity_test.swift - host negative test for .swpkg header trust fields.

import Foundation

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

private func output(_ result: CommandResult) -> String {
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
        let text = output(result)
        fail("\(context) failed with status \(result.status)\(text.isEmpty ? "" : ": \(text)")")
    }
}

private func requireFailure(_ result: CommandResult, _ context: String, contains needle: String) {
    guard result.status != 0 else {
        let text = output(result)
        fail("\(context) unexpectedly succeeded\(text.isEmpty ? "" : ": \(text)")")
    }
    let text = output(result)
    guard text.contains(needle) else {
        fail("\(context) failed with unexpected output: \(text)")
    }
}

private func readPackage(_ url: URL) -> Data {
    do {
        return try Data(contentsOf: url)
    } catch {
        fail("could not read \(url.path): \(error)")
    }
}

private func writePackage(_ data: Data, to url: URL) {
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fail("could not write \(url.path): \(error)")
    }
}

private func tamper(_ package: Data, byteOffset: Int, output url: URL) {
    guard byteOffset >= 0 && byteOffset < package.count else {
        fail("tamper offset \(byteOffset) is outside package size \(package.count)")
    }
    var data = package
    data[byteOffset] ^= 0x01
    writePackage(data, to: url)
}

let headerSize = 128
let manifestHashOffset = 48
let payloadHashOffset = 80
let signatureOffsetOffset = 112
let signatureSizeOffset = 120

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let tool = repo.appendingPathComponent("build/swpkg")
let validPackage = repo.appendingPathComponent("build/pkghello.swpkg")

guard FileManager.default.isExecutableFile(atPath: tool.path) else {
    fail("missing executable build/swpkg; run make swpkg first")
}
guard FileManager.default.isReadableFile(atPath: validPackage.path) else {
    fail("missing build/pkghello.swpkg; run make package-fixture first")
}

let packageData = readPackage(validPackage)
guard packageData.count >= headerSize else {
    fail("fixture package shorter than the .swpkg header")
}
guard Array(packageData[0..<8]) == Array("SWPKG001".utf8) else {
    fail("fixture package has bad .swpkg magic")
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("swpkg-header-integrity-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
} catch {
    fail("could not create temp dir: \(error)")
}
defer { try? FileManager.default.removeItem(at: temp) }

requireSuccess(run(tool, ["verify", validPackage.path]), "verify valid package")
requireSuccess(run(tool, [
    "extract-payload",
    validPackage.path,
    temp.appendingPathComponent("valid-payload.img").path,
]), "extract payload from valid package")

let cases: [(name: String, offset: Int, expected: String)] = [
    ("manifest-hash", manifestHashOffset, "manifest SHA-256 mismatch"),
    ("payload-hash", payloadHashOffset, "payload SHA-256 mismatch"),
    ("reserved-signature-offset", signatureOffsetOffset, "package signatures are reserved"),
    ("reserved-signature-size", signatureSizeOffset, "package signatures are reserved"),
]

for c in cases {
    let bad = temp.appendingPathComponent("\(c.name).swpkg")
    tamper(packageData, byteOffset: c.offset, output: bad)

    requireFailure(run(tool, ["verify", bad.path]),
                   "verify \(c.name)-tampered package",
                   contains: c.expected)
    requireFailure(run(tool, [
        "extract-payload",
        bad.path,
        temp.appendingPathComponent("\(c.name)-payload.img").path,
    ]), "extract \(c.name)-tampered package", contains: c.expected)
}

print("PASS: swpkg rejects tampered header hashes and reserved signature fields before extraction")
