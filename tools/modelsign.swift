// SPDX-License-Identifier: Apache-2.0
//
// modelsign.swift — host-side Ed25519 signing for model-bundle manifests (I7).
//
// Subcommands:
//   keygen <seed-out> <pub-out>      generate a keypair (raw 32-byte files)
//   sign   <manifest.toml> <seed>    sign the manifest body in place: any
//                                    existing [signature] table is stripped,
//                                    the body is signed (kernel/crypto/
//                                    ed25519.swift), and the table is appended
//   verify <manifest.toml> <pub>     check the signature; exit 0/1
//
// The signature covers every byte before the [signature] table header line
// (modelManifestSignedRange in userland/lib/modelbundle.swift — the same
// logic /bin/llmd verifies with on the target). The trust root (the public
// key) ships in the base image at /etc/swos/model-signing.pub; the manifest
// deliberately does NOT carry the key.

import Foundation

@main
struct ModelSignTool {
    static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("modelsign: \(msg)\n".utf8))
        exit(1)
    }

    static func read(_ path: String) -> Data {
        guard let d = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
        return d
    }

    static func write(_ data: Data, _ path: String) {
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch { die("cannot write \(path): \(error)") }
    }

    static func hex(_ b: [UInt8]) -> String {
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            die("usage: modelsign keygen <seed-out> <pub-out> | sign <manifest> <seed> | verify <manifest> <pub>")
        }

        switch args[1] {
        case "keygen":
            var seed = [UInt8](repeating: 0, count: 32)
            var rng = SystemRandomNumberGenerator()
            for i in 0..<32 { seed[i] = UInt8.random(in: 0...255, using: &rng) }
            var pub = [UInt8](repeating: 0, count: 32)
            seed.withUnsafeBytes { sb in
                pub.withUnsafeMutableBytes { pb in
                    ed25519PublicKey(seed: sb.baseAddress!, publicKey: pb.baseAddress!)
                }
            }
            write(Data(seed), args[2])
            write(Data(pub), args[3])
            print("modelsign: keygen OK, public key \(hex(pub))")

        case "sign":
            let manifestPath = args[2]
            let manifest = read(manifestPath)
            let seed = read(args[3])
            guard seed.count == 32 else { die("seed must be 32 bytes") }

            var body: Data = manifest.withUnsafeBytes { raw in
                manifest.subdata(in: 0..<modelManifestSignedRange(raw))
            }
            if body.isEmpty { die("empty manifest body") }
            if body.last != 0x0A { body.append(0x0A) }

            var sig = [UInt8](repeating: 0, count: 64)
            body.withUnsafeBytes { bb in
                seed.withUnsafeBytes { sb in
                    sig.withUnsafeMutableBytes { gb in
                        ed25519Sign(message: bb.baseAddress!, body.count,
                                    seed: sb.baseAddress!, signature: gb.baseAddress!)
                    }
                }
            }
            var out = body
            out.append(Data("[signature]\nalgo = \"ed25519\"\nsig = \"\(hex(sig))\"\n".utf8))
            write(out, manifestPath)
            print("modelsign: signed \(manifestPath) (\(body.count) bytes covered)")

        case "verify":
            let manifest = read(args[2])
            let pub = read(args[3])
            guard pub.count == 32 else { die("public key must be 32 bytes") }
            let okay: Bool = manifest.withUnsafeBytes { raw in
                guard let m = modelManifestParse(raw), !m.signatureHex.isEmpty,
                      let sig = modelSignatureDecode(m.signatureHex) else { return false }
                let range = modelManifestSignedRange(raw)
                return sig.withUnsafeBytes { sb in
                    pub.withUnsafeBytes { pb in
                        ed25519Verify(message: raw.baseAddress!, range,
                                      signature: sb.baseAddress!, publicKey: pb.baseAddress!)
                    }
                }
            }
            print(okay ? "modelsign: signature OK" : "modelsign: signature INVALID")
            exit(okay ? 0 : 1)

        default:
            die("unknown subcommand \(args[1])")
        }
    }
}
