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
let bzip2Recipe = repo.appendingPathComponent("ports/archivers/bzip2/Port.json")
let zstdRecipe = repo.appendingPathComponent("ports/archivers/zstd/Port.json")
let caRecipe = repo.appendingPathComponent("ports/security/ca-certificates/Port.json")
let pcre2Recipe = repo.appendingPathComponent("ports/devel/pcre2/Port.json")
let tzdataRecipe = repo.appendingPathComponent("ports/sysutils/tzdata/Port.json")
let nginxRecipe = repo.appendingPathComponent("ports/www/nginx/Port.json")
let sqliteRecipe = repo.appendingPathComponent("ports/databases/sqlite/Port.json")
guard FileManager.default.isReadableFile(atPath: tzdataRecipe.path) else {
    fail("missing ports/sysutils/tzdata/Port.json")
}
guard FileManager.default.isReadableFile(atPath: bzip2Recipe.path) else {
    fail("missing ports/archivers/bzip2/Port.json")
}
guard FileManager.default.isReadableFile(atPath: zstdRecipe.path) else {
    fail("missing ports/archivers/zstd/Port.json")
}
guard FileManager.default.isReadableFile(atPath: nginxRecipe.path) else {
    fail("missing ports/www/nginx/Port.json")
}
guard FileManager.default.isReadableFile(atPath: sqliteRecipe.path) else {
    fail("missing ports/databases/sqlite/Port.json")
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

let bzip2Validate = run(swport, ["recipe", "validate", "archivers/bzip2"])
requireSuccess(bzip2Validate, "validate bzip2 recipe")
guard output(bzip2Validate).contains("recipe: OK bzip2-1.0.8_1") else {
    fail("validate output did not confirm bzip2 recipe: \(output(bzip2Validate))")
}

let bzip2ManifestURL = temp.appendingPathComponent("bzip2-manifest.json")
let bzip2Manifest = run(swport, ["recipe", "manifest", "archivers/bzip2", "--output", bzip2ManifestURL.path])
requireSuccess(bzip2Manifest, "generate bzip2 manifest")
do {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: bzip2ManifestURL)) as? [String: Any] else {
        fail("generated bzip2 manifest is not a JSON object")
    }
    requireString(object, "name", "bzip2")
    requireString(object, "version", "1.0.8")
    guard let provides = object["provides"] as? [String],
          Set(provides) == ["bzip2", "bunzip2", "bzcat", "libbz2"] else {
        fail("bzip2 manifest provides were \(String(describing: object["provides"]))")
    }
    let filePaths = Set((object["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    guard filePaths == [
        "/usr/bin/bzip2",
        "/usr/bin/bunzip2",
        "/usr/bin/bzcat",
        "/usr/bin/bzip2recover",
        "/usr/include/bzlib.h",
        "/usr/lib/libbz2.a",
        "/usr/lib/pkgconfig/bzip2.pc",
        "/usr/share/bzip2/swiftos-bzip2.version",
    ] else {
        fail("unexpected bzip2 manifest files: \(filePaths.sorted())")
    }
} catch {
    fail("could not parse generated bzip2 manifest: \(error)")
}

let bzip2Root = temp.appendingPathComponent("bzip2-root", isDirectory: true)
do {
    let files: [(String, Data, Int)] = [
        ("usr/bin/bzip2", Data("#!/bin/sh\necho bzip2\n".utf8), 0o755),
        ("usr/bin/bunzip2", Data("#!/bin/sh\necho bunzip2\n".utf8), 0o755),
        ("usr/bin/bzcat", Data("#!/bin/sh\necho bzcat\n".utf8), 0o755),
        ("usr/bin/bzip2recover", Data("#!/bin/sh\necho bzip2recover\n".utf8), 0o755),
        ("usr/include/bzlib.h", Data("/* bzlib */\n".utf8), 0o644),
        ("usr/lib/libbz2.a", Data("!<arch>\n".utf8), 0o644),
        ("usr/lib/pkgconfig/bzip2.pc", Data("Name: bzip2\nVersion: 1.0.8\n".utf8), 0o644),
        ("usr/share/bzip2/swiftos-bzip2.version", Data("bzip2 1.0.8 swift-os static-tools\n".utf8), 0o644),
    ]
    for (path, data, mode) in files {
        let url = bzip2Root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
} catch {
    fail("could not stage dummy bzip2 package root: \(error)")
}

let bzip2PackageURL = temp.appendingPathComponent("bzip2.swpkg")
let bzip2PackageResult = run(swport, [
    "recipe", "package", "archivers/bzip2",
    "--root", bzip2Root.path,
    "--output", bzip2PackageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(bzip2PackageResult, "package dummy bzip2 root")
let bzip2Verify = run(swpkg, ["verify", bzip2PackageURL.path])
requireSuccess(bzip2Verify, "verify dummy bzip2 package")
guard output(bzip2Verify).contains("OK: bzip2-1.0.8_1") else {
    fail("swpkg verify did not identify bzip2 package: \(output(bzip2Verify))")
}

let bzip2RepoRoot = temp.appendingPathComponent("bzip2-repo-root", isDirectory: true)
let bzip2Pubkey = temp.appendingPathComponent("bzip2-repo-root.pub")
let bzip2RepoFixture = run(swport, [
    "recipe", "repo-fixture", "archivers/bzip2",
    "--root", bzip2Root.path,
    "--output", bzip2RepoRoot.path,
    "--pubkey", bzip2Pubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(bzip2RepoFixture, "create bzip2 repository fixture")
let bzip2Catalog = bzip2RepoRoot.appendingPathComponent("aarch64/current/catalog.signed")
let bzip2RepoVerify = run(pkgrepo, ["verify", "--catalog-signed", bzip2Catalog.path, "--pubkey", bzip2Pubkey.path])
requireSuccess(bzip2RepoVerify, "verify bzip2 repository fixture")
let bzip2RepoInspect = run(pkgrepo, ["inspect", bzip2Catalog.path])
requireSuccess(bzip2RepoInspect, "inspect bzip2 repository fixture")
guard output(bzip2RepoInspect).contains("bzip2-1.0.8_1") else {
    fail("repo fixture catalog did not include bzip2 package: \(output(bzip2RepoInspect))")
}

let zstdValidate = run(swport, ["recipe", "validate", "archivers/zstd"])
requireSuccess(zstdValidate, "validate zstd recipe")
guard output(zstdValidate).contains("recipe: OK zstd-1.5.7_1") else {
    fail("validate output did not confirm zstd recipe: \(output(zstdValidate))")
}

let zstdManifestURL = temp.appendingPathComponent("zstd-manifest.json")
let zstdManifest = run(swport, ["recipe", "manifest", "archivers/zstd", "--output", zstdManifestURL.path])
requireSuccess(zstdManifest, "generate zstd manifest")
do {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: zstdManifestURL)) as? [String: Any] else {
        fail("generated zstd manifest is not a JSON object")
    }
    requireString(object, "name", "zstd")
    requireString(object, "version", "1.5.7")
    guard let provides = object["provides"] as? [String],
          Set(provides) == ["zstd", "unzstd", "zstdcat", "libzstd"] else {
        fail("zstd manifest provides were \(String(describing: object["provides"]))")
    }
    let filePaths = Set((object["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    guard filePaths == [
        "/usr/bin/zstd",
        "/usr/bin/unzstd",
        "/usr/bin/zstdcat",
        "/usr/include/zstd.h",
        "/usr/include/zstd_errors.h",
        "/usr/include/zdict.h",
        "/usr/lib/libzstd.a",
        "/usr/lib/pkgconfig/libzstd.pc",
        "/usr/share/zstd/swiftos-zstd.version",
    ] else {
        fail("unexpected zstd manifest files: \(filePaths.sorted())")
    }
} catch {
    fail("could not parse generated zstd manifest: \(error)")
}

let zstdRoot = temp.appendingPathComponent("zstd-root", isDirectory: true)
do {
    let files: [(String, Data, Int)] = [
        ("usr/bin/zstd", Data("#!/bin/sh\necho zstd\n".utf8), 0o755),
        ("usr/bin/unzstd", Data("#!/bin/sh\necho unzstd\n".utf8), 0o755),
        ("usr/bin/zstdcat", Data("#!/bin/sh\necho zstdcat\n".utf8), 0o755),
        ("usr/include/zstd.h", Data("/* zstd */\n".utf8), 0o644),
        ("usr/include/zstd_errors.h", Data("/* zstd errors */\n".utf8), 0o644),
        ("usr/include/zdict.h", Data("/* zdict */\n".utf8), 0o644),
        ("usr/lib/libzstd.a", Data("!<arch>\n".utf8), 0o644),
        ("usr/lib/pkgconfig/libzstd.pc", Data("Name: zstd\nVersion: 1.5.7\n".utf8), 0o644),
        ("usr/share/zstd/swiftos-zstd.version", Data("zstd 1.5.7 swift-os static-single-thread\n".utf8), 0o644),
    ]
    for (path, data, mode) in files {
        let url = zstdRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
} catch {
    fail("could not stage dummy zstd package root: \(error)")
}

let zstdPackageURL = temp.appendingPathComponent("zstd.swpkg")
let zstdPackageResult = run(swport, [
    "recipe", "package", "archivers/zstd",
    "--root", zstdRoot.path,
    "--output", zstdPackageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(zstdPackageResult, "package dummy zstd root")
let zstdVerify = run(swpkg, ["verify", zstdPackageURL.path])
requireSuccess(zstdVerify, "verify dummy zstd package")
guard output(zstdVerify).contains("OK: zstd-1.5.7_1") else {
    fail("swpkg verify did not identify zstd package: \(output(zstdVerify))")
}

let zstdRepoRoot = temp.appendingPathComponent("zstd-repo-root", isDirectory: true)
let zstdPubkey = temp.appendingPathComponent("zstd-repo-root.pub")
let zstdRepoFixture = run(swport, [
    "recipe", "repo-fixture", "archivers/zstd",
    "--root", zstdRoot.path,
    "--output", zstdRepoRoot.path,
    "--pubkey", zstdPubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(zstdRepoFixture, "create zstd repository fixture")
let zstdCatalog = zstdRepoRoot.appendingPathComponent("aarch64/current/catalog.signed")
let zstdRepoVerify = run(pkgrepo, ["verify", "--catalog-signed", zstdCatalog.path, "--pubkey", zstdPubkey.path])
requireSuccess(zstdRepoVerify, "verify zstd repository fixture")
let zstdRepoInspect = run(pkgrepo, ["inspect", zstdCatalog.path])
requireSuccess(zstdRepoInspect, "inspect zstd repository fixture")
guard output(zstdRepoInspect).contains("zstd-1.5.7_1") else {
    fail("repo fixture catalog did not include zstd package: \(output(zstdRepoInspect))")
}

let caValidate = run(swport, ["recipe", "validate", "security/ca-certificates"])
requireSuccess(caValidate, "validate ca-certificates recipe")
guard output(caValidate).contains("recipe: OK ca-certificates-2026.05.14_1") else {
    fail("validate output did not confirm ca-certificates recipe: \(output(caValidate))")
}

let caManifestURL = temp.appendingPathComponent("ca-certificates-manifest.json")
let caManifest = run(swport, ["recipe", "manifest", "security/ca-certificates", "--output", caManifestURL.path])
requireSuccess(caManifest, "generate ca-certificates manifest")
do {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: caManifestURL)) as? [String: Any] else {
        fail("generated ca-certificates manifest is not a JSON object")
    }
    requireString(object, "name", "ca-certificates")
    requireString(object, "version", "2026.05.14")
    guard let provides = object["provides"] as? [String],
          Set(provides) == ["ca-certificates", "ssl-cert-file"] else {
        fail("ca-certificates manifest provides were \(String(describing: object["provides"]))")
    }
    let filePaths = Set((object["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    guard filePaths == [
        "/usr/etc/ssl/cert.pem",
        "/usr/share/certs/ca-certificates.crt",
        "/usr/share/certs/swiftos-ca-bundle.version",
    ] else {
        fail("unexpected ca-certificates manifest files: \(filePaths.sorted())")
    }
} catch {
    fail("could not parse generated ca-certificates manifest: \(error)")
}

let caRoot = temp.appendingPathComponent("ca-certificates-root", isDirectory: true)
do {
    let certData = Data("-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n".utf8)
    let files: [(String, Data, Int)] = [
        ("usr/etc/ssl/cert.pem", certData, 0o644),
        ("usr/share/certs/ca-certificates.crt", certData, 0o644),
        ("usr/share/certs/swiftos-ca-bundle.version", Data("curl-ca-bundle 2026-05-14 121 certificates\n".utf8), 0o644),
    ]
    for (path, data, mode) in files {
        let url = caRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
} catch {
    fail("could not stage dummy ca-certificates package root: \(error)")
}

let caPackageURL = temp.appendingPathComponent("ca-certificates.swpkg")
let caPackageResult = run(swport, [
    "recipe", "package", "security/ca-certificates",
    "--root", caRoot.path,
    "--output", caPackageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(caPackageResult, "package dummy ca-certificates root")
let caVerify = run(swpkg, ["verify", caPackageURL.path])
requireSuccess(caVerify, "verify dummy ca-certificates package")
guard output(caVerify).contains("OK: ca-certificates-2026.05.14_1") else {
    fail("swpkg verify did not identify ca-certificates package: \(output(caVerify))")
}

let caRepoRoot = temp.appendingPathComponent("ca-certificates-repo-root", isDirectory: true)
let caPubkey = temp.appendingPathComponent("ca-certificates-repo-root.pub")
let caRepoFixture = run(swport, [
    "recipe", "repo-fixture", "security/ca-certificates",
    "--root", caRoot.path,
    "--output", caRepoRoot.path,
    "--pubkey", caPubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(caRepoFixture, "create ca-certificates repository fixture")
let caCatalog = caRepoRoot.appendingPathComponent("aarch64/current/catalog.signed")
let caRepoVerify = run(pkgrepo, ["verify", "--catalog-signed", caCatalog.path, "--pubkey", caPubkey.path])
requireSuccess(caRepoVerify, "verify ca-certificates repository fixture")
let caRepoInspect = run(pkgrepo, ["inspect", caCatalog.path])
requireSuccess(caRepoInspect, "inspect ca-certificates repository fixture")
guard output(caRepoInspect).contains("ca-certificates-2026.05.14_1") else {
    fail("repo fixture catalog did not include ca-certificates package: \(output(caRepoInspect))")
}

let pcre2Validate = run(swport, ["recipe", "validate", "devel/pcre2"])
requireSuccess(pcre2Validate, "validate pcre2 recipe")
guard output(pcre2Validate).contains("recipe: OK pcre2-10.47_1") else {
    fail("validate output did not confirm pcre2 recipe: \(output(pcre2Validate))")
}

let pcre2ManifestURL = temp.appendingPathComponent("pcre2-manifest.json")
let pcre2Manifest = run(swport, ["recipe", "manifest", "devel/pcre2", "--output", pcre2ManifestURL.path])
requireSuccess(pcre2Manifest, "generate pcre2 manifest")
do {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: pcre2ManifestURL)) as? [String: Any] else {
        fail("generated pcre2 manifest is not a JSON object")
    }
    requireString(object, "name", "pcre2")
    requireString(object, "version", "10.47")
    guard let provides = object["provides"] as? [String],
          Set(provides) == ["pcre2", "libpcre2-8", "libpcre2-posix"] else {
        fail("pcre2 manifest provides were \(String(describing: object["provides"]))")
    }
    let filePaths = Set((object["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    guard filePaths == [
        "/usr/bin/pcre2grep",
        "/usr/include/pcre2.h",
        "/usr/include/pcre2posix.h",
        "/usr/lib/libpcre2-8.a",
        "/usr/lib/libpcre2-posix.a",
        "/usr/lib/pkgconfig/libpcre2-8.pc",
        "/usr/lib/pkgconfig/libpcre2-posix.pc",
    ] else {
        fail("unexpected pcre2 manifest files: \(filePaths.sorted())")
    }
} catch {
    fail("could not parse generated pcre2 manifest: \(error)")
}

let pcre2Root = temp.appendingPathComponent("pcre2-root", isDirectory: true)
do {
    let files: [(String, Data, Int)] = [
        ("usr/bin/pcre2grep", Data("#!/bin/sh\necho pcre2grep\n".utf8), 0o755),
        ("usr/include/pcre2.h", Data("/* pcre2 */\n".utf8), 0o644),
        ("usr/include/pcre2posix.h", Data("/* pcre2 posix */\n".utf8), 0o644),
        ("usr/lib/libpcre2-8.a", Data("!<arch>\n".utf8), 0o644),
        ("usr/lib/libpcre2-posix.a", Data("!<arch>\n".utf8), 0o644),
        ("usr/lib/pkgconfig/libpcre2-8.pc", Data("Name: libpcre2-8\nVersion: 10.47\n".utf8), 0o644),
        ("usr/lib/pkgconfig/libpcre2-posix.pc", Data("Name: libpcre2-posix\nVersion: 10.47\n".utf8), 0o644),
    ]
    for (path, data, mode) in files {
        let url = pcre2Root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
} catch {
    fail("could not stage dummy pcre2 package root: \(error)")
}

let pcre2PackageURL = temp.appendingPathComponent("pcre2.swpkg")
let pcre2PackageResult = run(swport, [
    "recipe", "package", "devel/pcre2",
    "--root", pcre2Root.path,
    "--output", pcre2PackageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(pcre2PackageResult, "package dummy pcre2 root")
let pcre2Verify = run(swpkg, ["verify", pcre2PackageURL.path])
requireSuccess(pcre2Verify, "verify dummy pcre2 package")
guard output(pcre2Verify).contains("OK: pcre2-10.47_1") else {
    fail("swpkg verify did not identify pcre2 package: \(output(pcre2Verify))")
}

let pcre2RepoRoot = temp.appendingPathComponent("pcre2-repo-root", isDirectory: true)
let pcre2Pubkey = temp.appendingPathComponent("pcre2-repo-root.pub")
let pcre2RepoFixture = run(swport, [
    "recipe", "repo-fixture", "devel/pcre2",
    "--root", pcre2Root.path,
    "--output", pcre2RepoRoot.path,
    "--pubkey", pcre2Pubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(pcre2RepoFixture, "create pcre2 repository fixture")
let pcre2Catalog = pcre2RepoRoot.appendingPathComponent("aarch64/current/catalog.signed")
let pcre2RepoVerify = run(pkgrepo, ["verify", "--catalog-signed", pcre2Catalog.path, "--pubkey", pcre2Pubkey.path])
requireSuccess(pcre2RepoVerify, "verify pcre2 repository fixture")
let pcre2RepoInspect = run(pkgrepo, ["inspect", pcre2Catalog.path])
requireSuccess(pcre2RepoInspect, "inspect pcre2 repository fixture")
guard output(pcre2RepoInspect).contains("pcre2-10.47_1") else {
    fail("repo fixture catalog did not include pcre2 package: \(output(pcre2RepoInspect))")
}

let tzdataValidate = run(swport, ["recipe", "validate", "sysutils/tzdata"])
requireSuccess(tzdataValidate, "validate tzdata recipe")
guard output(tzdataValidate).contains("recipe: OK tzdata-2026b_1") else {
    fail("validate output did not confirm tzdata recipe: \(output(tzdataValidate))")
}

let tzdataRoot = temp.appendingPathComponent("tzdata-root", isDirectory: true)
do {
    let files: [(String, Data, Int)] = [
        ("usr/share/zoneinfo/UTC", Data("TZif fixture UTC\n".utf8), 0o644),
        ("usr/share/zoneinfo/Europe/Madrid", Data("TZif fixture Madrid\n".utf8), 0o644),
        ("usr/share/zoneinfo/swiftos-tzdata.version", Data("iana-tzdata 2026b fixture\n".utf8), 0o644),
    ]
    for (path, data, mode) in files {
        let url = tzdataRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
} catch {
    fail("could not stage dummy tzdata package root: \(error)")
}

let tzdataPackageURL = temp.appendingPathComponent("tzdata.swpkg")
let tzdataPackageResult = run(swport, [
    "recipe", "package", "sysutils/tzdata",
    "--root", tzdataRoot.path,
    "--output", tzdataPackageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(tzdataPackageResult, "package dummy tzdata root")
let tzdataVerify = run(swpkg, ["verify", tzdataPackageURL.path])
requireSuccess(tzdataVerify, "verify dummy tzdata package")
guard output(tzdataVerify).contains("OK: tzdata-2026b_1") else {
    fail("swpkg verify did not identify tzdata package: \(output(tzdataVerify))")
}

let tzdataRepoRoot = temp.appendingPathComponent("tzdata-repo-root", isDirectory: true)
let tzdataPubkey = temp.appendingPathComponent("tzdata-repo-root.pub")
let tzdataRepoFixture = run(swport, [
    "recipe", "repo-fixture", "sysutils/tzdata",
    "--root", tzdataRoot.path,
    "--output", tzdataRepoRoot.path,
    "--pubkey", tzdataPubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(tzdataRepoFixture, "create tzdata repository fixture")
let tzdataCatalog = tzdataRepoRoot.appendingPathComponent("aarch64/current/catalog.signed")
let tzdataRepoVerify = run(pkgrepo, ["verify", "--catalog-signed", tzdataCatalog.path, "--pubkey", tzdataPubkey.path])
requireSuccess(tzdataRepoVerify, "verify tzdata repository fixture")
let tzdataRepoInspect = run(pkgrepo, ["inspect", tzdataCatalog.path])
requireSuccess(tzdataRepoInspect, "inspect tzdata repository fixture")
guard output(tzdataRepoInspect).contains("tzdata-2026b_1") else {
    fail("repo fixture catalog did not include tzdata package: \(output(tzdataRepoInspect))")
}

let sqliteValidate = run(swport, ["recipe", "validate", "databases/sqlite"])
requireSuccess(sqliteValidate, "validate sqlite recipe")
guard output(sqliteValidate).contains("recipe: OK sqlite-3.53.2_1") else {
    fail("validate output did not confirm sqlite recipe: \(output(sqliteValidate))")
}

let sqliteManifestURL = temp.appendingPathComponent("sqlite-manifest.json")
let sqliteManifest = run(swport, ["recipe", "manifest", "databases/sqlite", "--output", sqliteManifestURL.path])
requireSuccess(sqliteManifest, "generate sqlite manifest")
do {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: sqliteManifestURL)) as? [String: Any] else {
        fail("generated sqlite manifest is not a JSON object")
    }
    requireString(object, "name", "sqlite")
    requireString(object, "version", "3.53.2")
    guard let provides = object["provides"] as? [String],
          Set(provides) == ["sqlite", "sqlite3", "libsqlite3"] else {
        fail("sqlite manifest provides were \(String(describing: object["provides"]))")
    }
    let filePaths = Set((object["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
    guard filePaths == [
        "/usr/bin/sqlite3",
        "/usr/include/sqlite3.h",
        "/usr/include/sqlite3ext.h",
        "/usr/lib/libsqlite3.a",
        "/usr/lib/pkgconfig/sqlite3.pc",
        "/usr/share/sqlite/swiftos-sqlite.version",
    ] else {
        fail("unexpected sqlite manifest files: \(filePaths.sorted())")
    }
} catch {
    fail("could not parse generated sqlite manifest: \(error)")
}

let sqliteRoot = temp.appendingPathComponent("sqlite-root", isDirectory: true)
do {
    let files: [(String, Data, Int)] = [
        ("usr/bin/sqlite3", Data("#!/bin/sh\necho sqlite3\n".utf8), 0o755),
        ("usr/include/sqlite3.h", Data("/* sqlite3 */\n".utf8), 0o644),
        ("usr/include/sqlite3ext.h", Data("/* sqlite3ext */\n".utf8), 0o644),
        ("usr/lib/libsqlite3.a", Data("!<arch>\n".utf8), 0o644),
        ("usr/lib/pkgconfig/sqlite3.pc", Data("Name: SQLite\nVersion: 3.53.2\n".utf8), 0o644),
        ("usr/share/sqlite/swiftos-sqlite.version", Data("sqlite 3.53.2 swift-os static-shell\n".utf8), 0o644),
    ]
    for (path, data, mode) in files {
        let url = sqliteRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
} catch {
    fail("could not stage dummy sqlite package root: \(error)")
}

let sqlitePackageURL = temp.appendingPathComponent("sqlite.swpkg")
let sqlitePackageResult = run(swport, [
    "recipe", "package", "databases/sqlite",
    "--root", sqliteRoot.path,
    "--output", sqlitePackageURL.path,
    "--swpkg", swpkg.path,
])
requireSuccess(sqlitePackageResult, "package dummy sqlite root")
let sqliteVerify = run(swpkg, ["verify", sqlitePackageURL.path])
requireSuccess(sqliteVerify, "verify dummy sqlite package")
guard output(sqliteVerify).contains("OK: sqlite-3.53.2_1") else {
    fail("swpkg verify did not identify sqlite package: \(output(sqliteVerify))")
}

let sqliteRepoRoot = temp.appendingPathComponent("sqlite-repo-root", isDirectory: true)
let sqlitePubkey = temp.appendingPathComponent("sqlite-repo-root.pub")
let sqliteRepoFixture = run(swport, [
    "recipe", "repo-fixture", "databases/sqlite",
    "--root", sqliteRoot.path,
    "--output", sqliteRepoRoot.path,
    "--pubkey", sqlitePubkey.path,
    "--swpkg", swpkg.path,
    "--pkgrepo", pkgrepo.path,
])
requireSuccess(sqliteRepoFixture, "create sqlite repository fixture")
let sqliteCatalog = sqliteRepoRoot.appendingPathComponent("aarch64/current/catalog.signed")
let sqliteRepoVerify = run(pkgrepo, ["verify", "--catalog-signed", sqliteCatalog.path, "--pubkey", sqlitePubkey.path])
requireSuccess(sqliteRepoVerify, "verify sqlite repository fixture")
let sqliteRepoInspect = run(pkgrepo, ["inspect", sqliteCatalog.path])
requireSuccess(sqliteRepoInspect, "inspect sqlite repository fixture")
guard output(sqliteRepoInspect).contains("sqlite-3.53.2_1") else {
    fail("repo fixture catalog did not include sqlite package: \(output(sqliteRepoInspect))")
}

print("PASS: swport validates, packages, and publishes lua, zlib, bzip2, zstd, ca-certificates, pcre2, tzdata, nginx, and sqlite recipe fixtures")
