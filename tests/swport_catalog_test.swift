// SPDX-License-Identifier: Apache-2.0
// swport_catalog_test.swift - host test for the P6a ports catalog tool.

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

private func output(_ result: CommandResult) -> String {
    (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func requireSuccess(_ result: CommandResult, _ context: String) {
    guard result.status == 0 else {
        fail("\(context) failed with status \(result.status): \(output(result))")
    }
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let tool = repo.appendingPathComponent("build/swport")
let catalog = repo.appendingPathComponent("ports/catalog.json")

guard FileManager.default.isExecutableFile(atPath: tool.path) else {
    fail("missing executable build/swport; build swport first")
}
guard FileManager.default.isReadableFile(atPath: catalog.path) else {
    fail("missing ports/catalog.json")
}

let validate = run(tool, ["catalog", "validate", catalog.path])
requireSuccess(validate, "validate catalog")
guard output(validate).contains("catalog: OK") else {
    fail("validate output did not confirm catalog status")
}

let list = run(tool, ["catalog", "list", catalog.path])
requireSuccess(list, "list catalog")
let listText = output(list)
guard listText.contains("tier2 nginx packages L www/nginx") else {
    fail("list output did not include nginx")
}
guard listText.contains("tier0 ca-certificates packages S security/ca-certificates") else {
    fail("list output did not include packaged ca-certificates")
}
guard listText.contains("tier0 bzip2 packages S archivers/bzip2") else {
    fail("list output did not include packaged bzip2")
}
guard listText.contains("tier0 zstd packages S archivers/zstd") else {
    fail("list output did not include packaged zstd")
}
guard listText.contains("tier0 xz packages M archivers/xz") else {
    fail("list output did not include packaged xz")
}
guard listText.contains("tier0 pcre2 packages S devel/pcre2") else {
    fail("list output did not include packaged pcre2")
}
guard listText.contains("tier3 sqlite packages S databases/sqlite") else {
    fail("list output did not include packaged sqlite")
}
guard listText.contains("tier4 nodejs blocked XL lang/nodejs") else {
    fail("list output did not include blocked nodejs")
}

let inspect = run(tool, ["catalog", "inspect", "nginx", catalog.path])
requireSuccess(inspect, "inspect nginx")
let inspectText = output(inspect)
guard inspectText.contains("runtimeDependencies: none") else {
    fail("nginx inspect output did not show its minimal runtime dependency state")
}
let sqliteInspect = run(tool, ["catalog", "inspect", "sqlite", catalog.path])
requireSuccess(sqliteInspect, "inspect sqlite")
guard output(sqliteInspect).contains("runtimeDependencies: none") else {
    fail("sqlite inspect output did not show its runtime dependency state")
}
let bzip2Inspect = run(tool, ["catalog", "inspect", "bzip2", catalog.path])
requireSuccess(bzip2Inspect, "inspect bzip2")
guard output(bzip2Inspect).contains("runtimeDependencies: none") else {
    fail("bzip2 inspect output did not show its runtime dependency state")
}
let zstdInspect = run(tool, ["catalog", "inspect", "zstd", catalog.path])
requireSuccess(zstdInspect, "inspect zstd")
guard output(zstdInspect).contains("runtimeDependencies: none") else {
    fail("zstd inspect output did not show its runtime dependency state")
}
let xzInspect = run(tool, ["catalog", "inspect", "xz", catalog.path])
requireSuccess(xzInspect, "inspect xz")
guard output(xzInspect).contains("runtimeDependencies: none") else {
    fail("xz inspect output did not show its runtime dependency state")
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("swport-catalog-test-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
} catch {
    fail("could not create temp dir: \(error)")
}
defer { try? FileManager.default.removeItem(at: temp) }

do {
    guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any],
          var packages = root["packages"] as? [[String: Any]],
          !packages.isEmpty else {
        fail("could not parse catalog for negative test")
    }
    packages[0]["runtimeDependencies"] = ["missing-dependency"]
    root["packages"] = packages
    let badData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    let badCatalog = temp.appendingPathComponent("bad-catalog.json")
    try badData.write(to: badCatalog)
    let bad = run(tool, ["catalog", "validate", badCatalog.path])
    guard bad.status != 0, output(bad).contains("unknown runtime dependency missing-dependency") else {
        fail("invalid catalog unexpectedly passed: \(output(bad))")
    }
} catch {
    fail("negative catalog test failed: \(error)")
}

print("PASS: swport validates the seed catalog and rejects unknown dependencies")
