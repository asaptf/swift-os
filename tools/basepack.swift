// SPDX-License-Identifier: Apache-2.0
// basepack.swift - build the swift-os packed read-only base image.

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("basepack: \(message)\n".utf8))
    exit(1)
}

@main
struct BasepackTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            fail("usage: basepack <root-dir> <output-image>")
        }

        do {
            let image = try buildPackedFS(root: URL(fileURLWithPath: args[1]))
            let output = URL(fileURLWithPath: args[2])
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try image.data.write(to: output, options: .atomic)
            print("basepack: wrote \(image.entries.count) entries to \(output.path)")
        } catch {
            fail("\(error)")
        }
    }
}
