// SPDX-License-Identifier: Apache-2.0
// swport.swift - host-side ports and recipe bootstrap tool (P6).

import Foundation

private enum ToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private struct PortEntry {
    let name: String
    let portPath: String
    let tier: Int
    let category: String
    let status: String
    let difficulty: String
    let upstream: String
    let summary: String
    let runtimeDependencies: [String]
    let prerequisiteBundles: [String]
    let blockedBy: [String]
    let smokeTest: String
    let notes: String
}

private struct Catalog {
    let repository: String
    let targetArch: String
    let targetOS: String
    let targetABI: String
    let targetLinkage: String
    let prerequisiteBundles: Set<String>
    let packages: [PortEntry]
}

private struct SourceSpec {
    let url: String
    let sha256: String
}

private struct TargetSpec {
    let arch: String
    let os: String
    let abi: String
    let libc: String
    let linkage: String
}

private struct BuildSpec {
    let system: String
    let args: [String]
    let env: [String: String]
}

private struct InstallSpec {
    let destdir: Bool
    let command: [String]
}

private struct PackageFileSpec {
    let from: String
    let to: String
    let mode: String
}

private struct PackageSpec {
    let depends: [String]
    let provides: [String]
    let conflicts: [String]
    let files: [PackageFileSpec]
    let capabilities: [String: Any]
}

private struct TestSpec {
    let qemu: [String]
}

private struct Recipe {
    let name: String
    let version: String
    let revision: Int
    let category: String
    let summary: String
    let homepage: String
    let license: [String]
    let maturity: String
    let source: SourceSpec
    let target: TargetSpec
    let build: BuildSpec
    let install: InstallSpec
    let package: PackageSpec
    let test: TestSpec
    let notes: String
}

private let allowedStatuses: Set<String> = ["candidate", "planned", "blocked"]
private let allowedDifficulties: Set<String> = ["S", "M", "L", "XL"]
private let allowedRecipeMaturities: Set<String> = [
    "scaffolded", "fetches", "builds", "packages", "smoke-tested", "published",
]
private let defaultCatalogPath = "ports/catalog.json"
private let defaultRecipeName = "Port.json"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swport: \(message)\n".utf8))
    exit(1)
}

private func usage() -> String {
    """
    usage:
      swport catalog validate [catalog.json]
      swport catalog list [catalog.json]
      swport catalog inspect <name> [catalog.json]
      swport recipe validate <port|Port.json> [--catalog catalog.json]
      swport recipe manifest <port|Port.json> [--output manifest.json] [--catalog catalog.json]
      swport recipe fetch <port|Port.json> [--cache dir]
    """
}

private func str(_ object: [String: Any], _ key: String, context: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        throw ToolError.message("\(context): missing string field '\(key)'")
    }
    return value
}

private func optStringArray(_ object: [String: Any], _ key: String, context: String) throws -> [String] {
    guard let raw = object[key] else { return [] }
    guard let values = raw as? [String] else {
        throw ToolError.message("\(context): field '\(key)' must be an array of strings")
    }
    for value in values where value.isEmpty {
        throw ToolError.message("\(context): field '\(key)' contains an empty string")
    }
    return values
}

private func stringArray(_ object: [String: Any], _ key: String, context: String) throws -> [String] {
    let values = try optStringArray(object, key, context: context)
    if values.isEmpty {
        throw ToolError.message("\(context): field '\(key)' must not be empty")
    }
    return values
}

private func intField(_ object: [String: Any], _ key: String, context: String) throws -> Int {
    if let value = object[key] as? Int { return value }
    if let value = object[key] as? NSNumber { return value.intValue }
    throw ToolError.message("\(context): missing integer field '\(key)'")
}

private func boolField(_ object: [String: Any], _ key: String, context: String) throws -> Bool {
    if let value = object[key] as? Bool { return value }
    if let value = object[key] as? NSNumber { return value.boolValue }
    throw ToolError.message("\(context): missing boolean field '\(key)'")
}

private func objectField(_ object: [String: Any], _ key: String, context: String) throws -> [String: Any] {
    guard let value = object[key] as? [String: Any] else {
        throw ToolError.message("\(context): missing object field '\(key)'")
    }
    return value
}

private func stringMap(_ object: [String: Any], _ key: String, context: String) throws -> [String: String] {
    guard let raw = object[key] else { return [:] }
    guard let values = raw as? [String: String] else {
        throw ToolError.message("\(context): field '\(key)' must be an object of strings")
    }
    for (k, v) in values where k.isEmpty || v.isEmpty {
        throw ToolError.message("\(context): field '\(key)' contains an empty key or value")
    }
    return values
}

private func parseEntry(_ object: [String: Any]) throws -> PortEntry {
    let name = try str(object, "name", context: "package")
    let context = "package \(name)"
    return PortEntry(
        name: name,
        portPath: try str(object, "portPath", context: context),
        tier: try intField(object, "tier", context: context),
        category: try str(object, "category", context: context),
        status: try str(object, "status", context: context),
        difficulty: try str(object, "difficulty", context: context),
        upstream: try str(object, "upstream", context: context),
        summary: try str(object, "summary", context: context),
        runtimeDependencies: try optStringArray(object, "runtimeDependencies", context: context),
        prerequisiteBundles: try stringArray(object, "prerequisiteBundles", context: context),
        blockedBy: try optStringArray(object, "blockedBy", context: context),
        smokeTest: try str(object, "smokeTest", context: context),
        notes: try str(object, "notes", context: context)
    )
}

private func parseCatalog(_ path: String) throws -> Catalog {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.message("\(path): root must be a JSON object")
    }
    let schema = try intField(root, "schemaVersion", context: path)
    if schema != 1 { throw ToolError.message("\(path): unsupported schemaVersion \(schema)") }

    guard let target = root["target"] as? [String: Any] else {
        throw ToolError.message("\(path): missing target object")
    }
    let bundles = Set(try stringArray(root, "prerequisiteBundles", context: path))
    guard let packageObjects = root["packages"] as? [[String: Any]], !packageObjects.isEmpty else {
        throw ToolError.message("\(path): packages must be a non-empty array")
    }
    let packages = try packageObjects.map(parseEntry)
    return Catalog(
        repository: try str(root, "repository", context: path),
        targetArch: try str(target, "arch", context: "target"),
        targetOS: try str(target, "os", context: "target"),
        targetABI: try str(target, "abi", context: "target"),
        targetLinkage: try str(target, "linkage", context: "target"),
        prerequisiteBundles: bundles,
        packages: packages
    )
}

private func parsePackageFile(_ object: [String: Any], context: String) throws -> PackageFileSpec {
    PackageFileSpec(
        from: try str(object, "from", context: context),
        to: try str(object, "to", context: context),
        mode: try str(object, "mode", context: context)
    )
}

private func parseRecipe(_ path: String) throws -> Recipe {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.message("\(path): root must be a JSON object")
    }
    let schema = try intField(root, "schemaVersion", context: path)
    if schema != 1 { throw ToolError.message("\(path): unsupported schemaVersion \(schema)") }

    let name = try str(root, "name", context: path)
    let context = "recipe \(name)"
    let source = try objectField(root, "source", context: context)
    let target = try objectField(root, "target", context: context)
    let build = try objectField(root, "build", context: context)
    let install = try objectField(root, "install", context: context)
    let package = try objectField(root, "package", context: context)
    let test = try objectField(root, "test", context: context)

    guard let rawFiles = package["files"] as? [[String: Any]], !rawFiles.isEmpty else {
        throw ToolError.message("\(context): package.files must be a non-empty array")
    }
    let files = try rawFiles.enumerated().map { index, file in
        try parsePackageFile(file, context: "\(context) package.files[\(index)]")
    }

    return Recipe(
        name: name,
        version: try str(root, "version", context: context),
        revision: try intField(root, "revision", context: context),
        category: try str(root, "category", context: context),
        summary: try str(root, "summary", context: context),
        homepage: try str(root, "homepage", context: context),
        license: try stringArray(root, "license", context: context),
        maturity: try str(root, "maturity", context: context),
        source: SourceSpec(
            url: try str(source, "url", context: "\(context) source"),
            sha256: try str(source, "sha256", context: "\(context) source")
        ),
        target: TargetSpec(
            arch: try str(target, "arch", context: "\(context) target"),
            os: try str(target, "os", context: "\(context) target"),
            abi: try str(target, "abi", context: "\(context) target"),
            libc: try str(target, "libc", context: "\(context) target"),
            linkage: try str(target, "linkage", context: "\(context) target")
        ),
        build: BuildSpec(
            system: try str(build, "system", context: "\(context) build"),
            args: try stringArray(build, "args", context: "\(context) build"),
            env: try stringMap(build, "env", context: "\(context) build")
        ),
        install: InstallSpec(
            destdir: try boolField(install, "destdir", context: "\(context) install"),
            command: try stringArray(install, "command", context: "\(context) install")
        ),
        package: PackageSpec(
            depends: try optStringArray(package, "depends", context: "\(context) package"),
            provides: try optStringArray(package, "provides", context: "\(context) package"),
            conflicts: try optStringArray(package, "conflicts", context: "\(context) package"),
            files: files,
            capabilities: try objectField(package, "capabilities", context: "\(context) package")
        ),
        test: TestSpec(qemu: try stringArray(test, "qemu", context: "\(context) test")),
        notes: try str(root, "notes", context: context)
    )
}

private func validPackageName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    if bytes.isEmpty { return false }
    var i = 0
    while i < bytes.count {
        let ch = bytes[i]
        let ok = (ch >= 0x61 && ch <= 0x7A) ||
                 (ch >= 0x30 && ch <= 0x39) ||
                 ch == 0x2D || ch == 0x2B || ch == 0x2E || ch == 0x5F
        if !ok { return false }
        i += 1
    }
    let first = bytes[0]
    return (first >= 0x61 && first <= 0x7A) || (first >= 0x30 && first <= 0x39)
}

private func validHex(_ text: String, count: Int) -> Bool {
    let bytes = Array(text.utf8)
    if bytes.count != count { return false }
    for ch in bytes {
        let ok = (ch >= 0x30 && ch <= 0x39) ||
                 (ch >= 0x61 && ch <= 0x66)
        if !ok { return false }
    }
    return true
}

private func validMode(_ mode: String) -> Bool {
    let bytes = Array(mode.utf8)
    if bytes.count != 4 { return false }
    for ch in bytes {
        if ch < 0x30 || ch > 0x37 { return false }
    }
    return true
}

private func recipePath(_ spec: String) -> String {
    if spec.hasSuffix(".json") { return spec }
    if spec.contains("/") { return "ports/\(spec)/\(defaultRecipeName)" }
    return "ports/lang/\(spec)/\(defaultRecipeName)"
}

private func validate(_ catalog: Catalog) throws {
    if catalog.targetArch != "aarch64" || catalog.targetOS != "swift-os" ||
       catalog.targetABI != "swos-0" || catalog.targetLinkage != "static" {
        throw ToolError.message("catalog target must be aarch64/swift-os/swos-0/static")
    }
    if catalog.prerequisiteBundles.isEmpty {
        throw ToolError.message("catalog prerequisiteBundles must not be empty")
    }

    var names = Set<String>()
    var paths = Set<String>()
    for entry in catalog.packages {
        if !validPackageName(entry.name) {
            throw ToolError.message("package \(entry.name): invalid package name")
        }
        if !names.insert(entry.name).inserted {
            throw ToolError.message("package \(entry.name): duplicate package name")
        }
        if !paths.insert(entry.portPath).inserted {
            throw ToolError.message("package \(entry.name): duplicate portPath \(entry.portPath)")
        }
        if entry.tier < 0 || entry.tier > 6 {
            throw ToolError.message("package \(entry.name): tier must be between 0 and 6")
        }
        if !allowedStatuses.contains(entry.status) {
            throw ToolError.message("package \(entry.name): unsupported status \(entry.status)")
        }
        if !allowedDifficulties.contains(entry.difficulty) {
            throw ToolError.message("package \(entry.name): unsupported difficulty \(entry.difficulty)")
        }
        if entry.status == "blocked" && entry.blockedBy.isEmpty {
            throw ToolError.message("package \(entry.name): blocked packages must list blockedBy")
        }
        if entry.status != "blocked" && !entry.blockedBy.isEmpty {
            throw ToolError.message("package \(entry.name): blockedBy is only allowed for blocked packages")
        }
        for bundle in entry.prerequisiteBundles where !catalog.prerequisiteBundles.contains(bundle) {
            throw ToolError.message("package \(entry.name): unknown prerequisite bundle \(bundle)")
        }
    }

    for entry in catalog.packages {
        for dep in entry.runtimeDependencies {
            if dep == entry.name {
                throw ToolError.message("package \(entry.name): self dependency")
            }
            if !names.contains(dep) {
                throw ToolError.message("package \(entry.name): unknown runtime dependency \(dep)")
            }
        }
    }
}

private func catalogEntry(for recipe: Recipe, in catalog: Catalog) -> PortEntry? {
    catalog.packages.first { $0.name == recipe.name }
}

private func validate(_ recipe: Recipe, catalog: Catalog? = nil) throws {
    if !validPackageName(recipe.name) {
        throw ToolError.message("recipe \(recipe.name): invalid package name")
    }
    if recipe.revision <= 0 {
        throw ToolError.message("recipe \(recipe.name): revision must be positive")
    }
    if !allowedRecipeMaturities.contains(recipe.maturity) {
        throw ToolError.message("recipe \(recipe.name): unsupported maturity \(recipe.maturity)")
    }
    if URL(string: recipe.homepage) == nil || URL(string: recipe.source.url) == nil {
        throw ToolError.message("recipe \(recipe.name): homepage and source.url must be valid URLs")
    }
    if !validHex(recipe.source.sha256, count: 64) {
        throw ToolError.message("recipe \(recipe.name): source.sha256 must be 64 lowercase hex characters")
    }
    if recipe.target.arch != "aarch64" || recipe.target.os != "swift-os" ||
       recipe.target.abi != "swos-0" || recipe.target.linkage != "static" {
        throw ToolError.message("recipe \(recipe.name): target must be aarch64/swift-os/swos-0/static")
    }
    if recipe.target.libc.isEmpty {
        throw ToolError.message("recipe \(recipe.name): target.libc must not be empty")
    }
    if recipe.build.system.isEmpty || recipe.build.args.isEmpty {
        throw ToolError.message("recipe \(recipe.name): build system and args are required")
    }
    if !recipe.install.destdir {
        throw ToolError.message("recipe \(recipe.name): install.destdir must be true for reproducible packaging")
    }

    var paths = Set<String>()
    for file in recipe.package.files {
        if file.from.isEmpty {
            throw ToolError.message("recipe \(recipe.name): package file source is empty")
        }
        if !file.to.hasPrefix("/usr/") {
            throw ToolError.message("recipe \(recipe.name): package file target must live under /usr: \(file.to)")
        }
        if !validMode(file.mode) {
            throw ToolError.message("recipe \(recipe.name): invalid file mode \(file.mode)")
        }
        if !paths.insert(file.to).inserted {
            throw ToolError.message("recipe \(recipe.name): duplicate package file target \(file.to)")
        }
    }
    for dep in recipe.package.depends where !validPackageName(dep) {
        throw ToolError.message("recipe \(recipe.name): invalid dependency name \(dep)")
    }

    guard let catalog else { return }
    guard let entry = catalogEntry(for: recipe, in: catalog) else {
        throw ToolError.message("recipe \(recipe.name): not listed in catalog")
    }
    let expectedPath = "\(recipe.category)/\(recipe.name)"
    if entry.portPath != expectedPath {
        throw ToolError.message("recipe \(recipe.name): catalog portPath is \(entry.portPath), expected \(expectedPath)")
    }
    let catalogNames = Set(catalog.packages.map { $0.name })
    for dep in recipe.package.depends where !catalogNames.contains(dep) {
        throw ToolError.message("recipe \(recipe.name): dependency \(dep) is not listed in catalog")
    }
}

private func loadAndValidate(_ path: String) throws -> Catalog {
    let catalog = try parseCatalog(path)
    try validate(catalog)
    return catalog
}

private func loadAndValidateRecipe(_ spec: String, catalogPath: String = defaultCatalogPath) throws -> (Recipe, String) {
    let path = recipePath(spec)
    let recipe = try parseRecipe(path)
    let catalog = try? loadAndValidate(catalogPath)
    try validate(recipe, catalog: catalog)
    return (recipe, path)
}

private func manifestObject(for recipe: Recipe) -> [String: Any] {
    let depends = recipe.package.depends.map { ["name": $0] as [String: Any] }
    let files = recipe.package.files.map {
        [
            "path": $0.to,
            "mode": $0.mode,
            "sha256": "",
            "size": 0,
        ] as [String: Any]
    }
    return [
        "format": 1,
        "name": recipe.name,
        "version": recipe.version,
        "revision": recipe.revision,
        "summary": recipe.summary,
        "license": recipe.license,
        "arch": recipe.target.arch,
        "target": recipe.target.os,
        "abi": [
            "os": recipe.target.abi,
            "syscall": 1,
            "libc": recipe.target.libc,
            "linkage": recipe.target.linkage,
        ] as [String: Any],
        "depends": depends,
        "provides": recipe.package.provides.isEmpty ? [recipe.name] : recipe.package.provides,
        "conflicts": recipe.package.conflicts,
        "files": files,
        "capabilities": recipe.package.capabilities,
    ]
}

private func manifestData(for recipe: Recipe) throws -> Data {
    try JSONSerialization.data(withJSONObject: manifestObject(for: recipe),
                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

private func sha256Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: sha256DigestLen)
    data.withUnsafeBytes { input in
        digest.withUnsafeMutableBytes { output in
            sha256(input.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                   data.count,
                   output.baseAddress!)
        }
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func optionValue(_ flag: String, in args: [String], default defaultValue: String? = nil) throws -> String {
    guard let index = args.firstIndex(of: flag) else {
        if let defaultValue { return defaultValue }
        throw ToolError.message("missing \(flag)")
    }
    guard index + 1 < args.count else { throw ToolError.message("missing value after \(flag)") }
    return args[index + 1]
}

private func printSummary(_ catalog: Catalog) {
    var candidate = 0
    var planned = 0
    var blocked = 0
    for entry in catalog.packages {
        if entry.status == "candidate" { candidate += 1 }
        if entry.status == "planned" { planned += 1 }
        if entry.status == "blocked" { blocked += 1 }
    }
    print("catalog: OK (\(catalog.packages.count) packages, \(candidate) candidates, \(planned) planned, \(blocked) blocked)")
}

private func list(_ catalog: Catalog) {
    for entry in catalog.packages.sorted(by: { ($0.tier, $0.name) < ($1.tier, $1.name) }) {
        print("tier\(entry.tier) \(entry.name) \(entry.status) \(entry.difficulty) \(entry.portPath)")
    }
}

private func inspect(_ catalog: Catalog, name: String) throws {
    guard let entry = catalog.packages.first(where: { $0.name == name }) else {
        throw ToolError.message("package not found: \(name)")
    }
    print("name: \(entry.name)")
    print("portPath: \(entry.portPath)")
    print("tier: \(entry.tier)")
    print("status: \(entry.status)")
    print("difficulty: \(entry.difficulty)")
    print("upstream: \(entry.upstream)")
    print("summary: \(entry.summary)")
    print("runtimeDependencies: \(entry.runtimeDependencies.isEmpty ? "none" : entry.runtimeDependencies.joined(separator: ","))")
    print("prerequisiteBundles: \(entry.prerequisiteBundles.joined(separator: ","))")
    if !entry.blockedBy.isEmpty {
        print("blockedBy: \(entry.blockedBy.joined(separator: "; "))")
    }
    print("smokeTest: \(entry.smokeTest)")
}

private func validateRecipeCommand(_ spec: String, args: [String]) throws {
    let catalogPath = try optionValue("--catalog", in: args, default: defaultCatalogPath)
    let (recipe, path) = try loadAndValidateRecipe(spec, catalogPath: catalogPath)
    print("recipe: OK \(recipe.name)-\(recipe.version)_\(recipe.revision) \(path)")
}

private func manifestRecipeCommand(_ spec: String, args: [String]) throws {
    let catalogPath = try optionValue("--catalog", in: args, default: defaultCatalogPath)
    let (recipe, _) = try loadAndValidateRecipe(spec, catalogPath: catalogPath)
    let data = try manifestData(for: recipe)
    if let outputIndex = args.firstIndex(of: "--output") {
        guard outputIndex + 1 < args.count else { throw ToolError.message("missing value after --output") }
        let output = URL(fileURLWithPath: args[outputIndex + 1])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        print("manifest: \(output.path)")
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private func fetchRecipeCommand(_ spec: String, args: [String]) throws {
    let (recipe, _) = try loadAndValidateRecipe(spec)
    guard let sourceURL = URL(string: recipe.source.url), !sourceURL.lastPathComponent.isEmpty else {
        throw ToolError.message("recipe \(recipe.name): invalid source URL")
    }
    let cacheDir = URL(fileURLWithPath: try optionValue("--cache", in: args, default: "build/swport-distfiles"),
                      isDirectory: true)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let output = cacheDir.appendingPathComponent(sourceURL.lastPathComponent)

    let data: Data
    if FileManager.default.isReadableFile(atPath: output.path) {
        data = try Data(contentsOf: output)
    } else {
        data = try Data(contentsOf: sourceURL)
        try data.write(to: output, options: .atomic)
    }
    let digest = sha256Hex(data)
    guard digest == recipe.source.sha256 else {
        throw ToolError.message("recipe \(recipe.name): source SHA-256 mismatch \(digest)")
    }
    print("fetch: OK \(output.path)")
}

@main
struct SwportTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fail(usage()) }
        do {
            switch args[1] {
            case "catalog":
                switch args[2] {
                case "validate":
                    let path = args.count >= 4 ? args[3] : defaultCatalogPath
                    printSummary(try loadAndValidate(path))
                case "list":
                    let path = args.count >= 4 ? args[3] : defaultCatalogPath
                    list(try loadAndValidate(path))
                case "inspect":
                    guard args.count >= 4 else { throw ToolError.message("missing package name") }
                    let path = args.count >= 5 ? args[4] : defaultCatalogPath
                    try inspect(try loadAndValidate(path), name: args[3])
                default:
                    throw ToolError.message(usage())
                }
            case "recipe":
                guard args.count >= 4 else { throw ToolError.message("missing recipe or port path") }
                switch args[2] {
                case "validate":
                    try validateRecipeCommand(args[3], args: args)
                case "manifest":
                    try manifestRecipeCommand(args[3], args: args)
                case "fetch":
                    try fetchRecipeCommand(args[3], args: args)
                default:
                    throw ToolError.message(usage())
                }
            default:
                throw ToolError.message(usage())
            }
        } catch {
            fail("\(error)")
        }
    }
}
