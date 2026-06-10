// SPDX-License-Identifier: Apache-2.0
// basepack.swift - build the swift-os packed read-only base image.
//
// I8: with a signing seed (raw 32 bytes, the dev image key minted by
// `modelsign keygen`), the image is emitted in the signed v3 layout — a
// 32-byte SHA-256 per file entry and an Ed25519 signature over
// header|entries|strings — which the kernel verifies at mount against the
// trust root compiled into it. Without a seed the legacy v2 layout is kept
// (used by host-only consumers such as swpkg payloads).

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("basepack: \(message)\n".utf8))
    exit(1)
}

@main
struct BasepackTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 4 else {
            fail("usage: basepack <root-dir> <output-image> [signing-seed]")
        }

        var hashEntry: ((Data) -> Data)? = nil
        var sign: ((Data) -> Data)? = nil
        if args.count == 4 {
            guard let seed = FileManager.default.contents(atPath: args[3]), seed.count == 32 else {
                fail("cannot read 32-byte signing seed \(args[3])")
            }
            hashEntry = { data in
                var digest = Data(repeating: 0, count: 32)
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    digest.withUnsafeMutableBytes { out in
                        // sha256 of an empty payload still needs a valid pointer.
                        sha256(raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                               data.count, out.baseAddress!)
                    }
                }
                return digest
            }
            sign = { bytes in
                var sig = Data(repeating: 0, count: 64)
                bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    seed.withUnsafeBytes { (sb: UnsafeRawBufferPointer) in
                        sig.withUnsafeMutableBytes { out in
                            ed25519Sign(message: raw.baseAddress!, bytes.count,
                                        seed: sb.baseAddress!, signature: out.baseAddress!)
                        }
                    }
                }
                return sig
            }
        }

        do {
            let entries = try collectPackedFSEntries(root: URL(fileURLWithPath: args[1]))
            let image = try buildPackedFS(entries: entries, hashEntry: hashEntry, sign: sign)
            let output = URL(fileURLWithPath: args[2])
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try image.data.write(to: output, options: .atomic)
            let kind = hashEntry != nil ? "signed v3" : "v2"
            print("basepack: wrote \(image.entries.count) entries (\(kind)) to \(output.path)")
        } catch {
            fail("\(error)")
        }
    }
}
