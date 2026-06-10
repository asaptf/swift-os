// SPDX-License-Identifier: Apache-2.0
// swport_recipe_test.swift - host test for the first P6 port recipe workflow.

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

private func requireString(_ object: [String: Any], _ key: String, _ expected: String) {
    guard object[key] as? String == expected else {
        fail("manifest field \(key) was \(String(describing: object[key])), expected \(expected)")
    }
}

private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let swport = repo.appendingPathComponent("build/swport")
let swpkg = repo.appendingPathComponent("build/swpkg")
let pkgrepo = repo.appendingPathComponent("build/pkgrepo")
let recipe = repo.appendingPathComponent("ports/lang/lua/Port.json")
let zlibRecipe = repo.appendingPathComponent("ports/archivers/zlib/Port.json")

guard FileManager.default.isExecutableFile(atPath: swport.path) else {
    fail("missing executable build/swport; build swport first")
}
guard FileManager.default.isExecutableFile(atPath: swpkg.path) else {
    fail("missing executable build/swpkg; build swpkg first")
}
guard FileManager.default.isExecutableFile(atPath: pkgrepo.path) else {
    fail("missing executable build/pkgrepo; build pkgrepo first")
}
guard FileManager.default.isReadableFile(atPath: recipe.path) else {
    fail("missing ports/lang/lua/Port.json")
}
guard FileManager.default.isReadableFile(atPath: zlibRecipe.path) else {
    fail("missing ports/archivers/zlib/Port.json")
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("swport-recipe-test-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
} catch {
    fail("could not create temp dir: \(error)")
}
defer { try? FileManager.default.removeItem(at: temp) }

let validate = run(swport, ["recipe", "validate", "lang/lua"])
requireSuccess(validate, "validate lua recipe")
guard output(validate).contains("recipe: OK lua-5.4.8_1") else {
    fail("validate output did not confirm lua recipe: \(output(validate))")
}

let manifestURL = temp.appendingPathComponent("manifest.json")
let manifest = run(swport, ["recipe", "manifest", "lang/lua", "--output", manifestURL.path])
requireSuccess(manifest, "generate lua manifest")
guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
    fail("manifest command did not write \(manifestURL.path)")
}

do {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
        fail("generated manifest is not a JSON object")
    }
    requireString(object, "name", "lua")
    requireString(object, "version", "5.4.8")
    requireString(object, "arch", "aarch64")
    requireString(object, "target", "swift-os")
    guard (object["depends"] as? [[String: Any]])?.isEmpty == true else {
        fail("lua manifest should not declare runtime dependencies")
    }
    guard let abi = object["abi"] as? [String: Any],
          abi["os"] as? String == "swos-0",
          abi["linkage"] as? String == "static" else {
        fail("manifest ABI does not target static swos-0")
    }
    let filePaths = Set((object["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    guard filePaths == ["/usr/bin/lua"] else {
        fail("unexpected manifest files: \(filePaths.sorted())")
    }
} catch {
    fail("could not parse generated manifest: \(error)")
}

do {
    let binDir = temp.appendingPathComponent("root/usr/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    for name in ["lua"] {
        let executable = binDir.appendingPathComponent(name)
        try Data("#!/bin/sh\necho \(name)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
} catch {
    fail("could not stage dummy lua package root: \(error)")
}

let packageURL = temp.appendingPathComponent("lua.swpkg")
let packageResult = run(swport, [
    "recipe", "package", "lang/lua",
    "--root", temp.appendingPathComponent("root").path,
    "--output", packageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(packageResult, "package dummy lua root")
guard output(packageResult).contains("package: OK \(packageURL.path)") else {
    fail("recipe package did not report output path: \(output(packageResult))")
}
let verify = run(swpkg, ["verify", packageURL.path])
requireSuccess(verify, "verify dummy lua package")
guard output(verify).contains("OK: lua-5.4.8_1") else {
    fail("swpkg verify did not identify lua package: \(output(verify))")
}

let repoRoot = temp.appendingPathComponent("repo-root", isDirectory: true)
let pubkey = temp.appendingPathComponent("repo-root.pub")
let repoFixture = run(swport, [
    "recipe", "repo-fixture", "lang/lua",
    "--root", temp.appendingPathComponent("root").path,
    "--output", repoRoot.path,
    "--pubkey", pubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(repoFixture, "create lua repository fixture")
let channel = repoRoot.appendingPathComponent("aarch64/current", isDirectory: true)
guard output(repoFixture).contains("repo-fixture: OK \(channel.path)") else {
    fail("repo fixture did not report channel path: \(output(repoFixture))")
}
let catalog = channel.appendingPathComponent("catalog.signed")
guard FileManager.default.isReadableFile(atPath: catalog.path),
      FileManager.default.isReadableFile(atPath: pubkey.path) else {
    fail("repo fixture did not write signed catalog and public key")
}
let repoVerify = run(pkgrepo, ["verify", "--catalog-signed", catalog.path, "--pubkey", pubkey.path])
requireSuccess(repoVerify, "verify lua repository fixture")
guard output(repoVerify).contains("signature: OK") else {
    fail("pkgrepo verify did not accept lua catalog: \(output(repoVerify))")
}
let repoInspect = run(pkgrepo, ["inspect", catalog.path])
requireSuccess(repoInspect, "inspect lua repository fixture")
guard output(repoInspect).contains("lua-5.4.8_1") else {
    fail("repo fixture catalog did not include lua package: \(output(repoInspect))")
}

let zlibValidate = run(swport, ["recipe", "validate", "archivers/zlib"])
requireSuccess(zlibValidate, "validate zlib recipe")
guard output(zlibValidate).contains("recipe: OK zlib-1.3.1_1") else {
    fail("validate output did not confirm zlib recipe: \(output(zlibValidate))")
}

let zlibManifestURL = temp.appendingPathComponent("zlib-manifest.json")
let zlibManifest = run(swport, ["recipe", "manifest", "archivers/zlib", "--output", zlibManifestURL.path])
requireSuccess(zlibManifest, "generate zlib manifest")
do {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: zlibManifestURL)) as? [String: Any] else {
        fail("generated zlib manifest is not a JSON object")
    }
    requireString(object, "name", "zlib")
    requireString(object, "version", "1.3.1")
    guard let provides = object["provides"] as? [String],
          Set(provides) == ["zlib", "libz"] else {
        fail("zlib manifest provides were \(String(describing: object["provides"]))")
    }
    let filePaths = Set((object["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    guard filePaths == [
        "/usr/bin/minigzip",
        "/usr/include/zconf.h",
        "/usr/include/zlib.h",
        "/usr/lib/libz.a",
        "/usr/lib/pkgconfig/zlib.pc",
    ] else {
        fail("unexpected zlib manifest files: \(filePaths.sorted())")
    }
} catch {
    fail("could not parse generated zlib manifest: \(error)")
}

let zlibRoot = temp.appendingPathComponent("zlib-root", isDirectory: true)
do {
    let files: [(String, Data, Int)] = [
        ("usr/bin/minigzip", Data("#!/bin/sh\necho minigzip\n".utf8), 0o755),
        ("usr/include/zconf.h", Data("/* zconf */\n".utf8), 0o644),
        ("usr/include/zlib.h", Data("/* zlib */\n".utf8), 0o644),
        ("usr/lib/libz.a", Data("!<arch>\n".utf8), 0o644),
        ("usr/lib/pkgconfig/zlib.pc", Data("Name: zlib\nVersion: 1.3.1\n".utf8), 0o644),
    ]
    for (path, data, mode) in files {
        let url = zlibRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
} catch {
    fail("could not stage dummy zlib package root: \(error)")
}

let zlibPackageURL = temp.appendingPathComponent("zlib.swpkg")
let zlibPackageResult = run(swport, [
    "recipe", "package", "archivers/zlib",
    "--root", zlibRoot.path,
    "--output", zlibPackageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(zlibPackageResult, "package dummy zlib root")
let zlibVerify = run(swpkg, ["verify", zlibPackageURL.path])
requireSuccess(zlibVerify, "verify dummy zlib package")
guard output(zlibVerify).contains("OK: zlib-1.3.1_1") else {
    fail("swpkg verify did not identify zlib package: \(output(zlibVerify))")
}

let zlibRepoRoot = temp.appendingPathComponent("zlib-repo-root", isDirectory: true)
let zlibPubkey = temp.appendingPathComponent("zlib-repo-root.pub")
let zlibRepoFixture = run(swport, [
    "recipe", "repo-fixture", "archivers/zlib",
    "--root", zlibRoot.path,
    "--output", zlibRepoRoot.path,
    "--pubkey", zlibPubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(zlibRepoFixture, "create zlib repository fixture")
let zlibCatalog = zlibRepoRoot.appendingPathComponent("aarch64/current/catalog.signed")
let zlibRepoVerify = run(pkgrepo, ["verify", "--catalog-signed", zlibCatalog.path, "--pubkey", zlibPubkey.path])
requireSuccess(zlibRepoVerify, "verify zlib repository fixture")
let zlibRepoInspect = run(pkgrepo, ["inspect", zlibCatalog.path])
requireSuccess(zlibRepoInspect, "inspect zlib repository fixture")
guard output(zlibRepoInspect).contains("zlib-1.3.1_1") else {
    fail("repo fixture catalog did not include zlib package: \(output(zlibRepoInspect))")
}

do {
    let badRoot = temp.appendingPathComponent("missing-root", isDirectory: true)
    try FileManager.default.createDirectory(at: badRoot, withIntermediateDirectories: true)
    let bad = run(swport, [
        "recipe", "package", "lang/lua",
        "--root", badRoot.path,
        "--output", temp.appendingPathComponent("bad-missing.swpkg").path,
        "--swpkg", swpkg.path,
    ])
    guard bad.status != 0, output(bad).contains("staged root missing /usr/bin/lua") else {
        fail("incomplete staged root unexpectedly packaged: \(output(bad))")
    }
} catch {
    fail("negative staged-root test failed: \(error)")
}

do {
    guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: recipe)) as? [String: Any],
          var package = root["package"] as? [String: Any] else {
        fail("could not parse lua recipe for negative test")
    }
    package["depends"] = ["missing-dependency"]
    root["package"] = package
    let badRecipe = temp.appendingPathComponent("bad-dependency/Port.json")
    try writeJSON(root, to: badRecipe)
    let bad = run(swport, ["recipe", "validate", badRecipe.path])
    guard bad.status != 0, output(bad).contains("dependency missing-dependency is not listed in catalog") else {
        fail("invalid recipe dependency unexpectedly passed: \(output(bad))")
    }
} catch {
    fail("negative dependency test failed: \(error)")
}

do {
    guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: recipe)) as? [String: Any],
          var package = root["package"] as? [String: Any],
          var files = package["files"] as? [[String: Any]],
          files.count >= 1 else {
        fail("could not parse lua recipe files for negative test")
    }
    files[0]["mode"] = "75x5"
    package["files"] = files
    root["package"] = package
    let badRecipe = temp.appendingPathComponent("bad-files/Port.json")
    try writeJSON(root, to: badRecipe)
    let bad = run(swport, ["recipe", "validate", badRecipe.path])
    guard bad.status != 0, output(bad).contains("invalid file mode 75x5") else {
        fail("invalid package file mode unexpectedly passed: \(output(bad))")
    }
} catch {
    fail("negative file test failed: \(error)")
}

print("PASS: swport validates, packages, and publishes lua and zlib recipe fixtures")
