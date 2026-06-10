// SPDX-License-Identifier: Apache-2.0
// swport.swift - host-side ports catalog bootstrap tool (P6a).

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

private let allowedStatuses: Set<String> = ["candidate", "planned", "blocked"]
private let allowedDifficulties: Set<String> = ["S", "M", "L", "XL"]
private let defaultCatalogPath = "ports/catalog.json"

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

private func loadAndValidate(_ path: String) throws -> Catalog {
    let catalog = try parseCatalog(path)
    try validate(catalog)
    return catalog
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

@main
struct SwportTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fail(usage()) }
        do {
            guard args[1] == "catalog" else { throw ToolError.message(usage()) }
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
        } catch {
            fail("\(error)")
        }
    }
}
