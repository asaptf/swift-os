// SPDX-License-Identifier: Apache-2.0
// tls-ts-probe.swift — login-shell probe for tls_truststore_test.
//
// busybox ash currently faults after console-login on aarch64 Linux CI before
// any typed command runs (see tests/log_export_test.sh). This probe is the root
// login shell for a dedicated base image: after password auth it runs the three
// /bin/tlsget cases against a host openssl s_server without interactive ash.
//
// Host contract (tests/tls_truststore_test.sh):
//   * s_server listens on 10.0.2.2:44381 with a leaf signed by the CA at
//     /etc/ssl/test-ca.pem (baked into the probe image)
//   * system trust store is the default /etc/ssl/cert.pem

private func cstr(_ s: StaticString) -> [CChar] {
    return s.withUTF8Buffer { buf in
        var out = [CChar]()
        out.reserveCapacity(buf.count + 1)
        var i = 0
        while i < buf.count {
            out.append(CChar(bitPattern: buf[i]))
            i += 1
        }
        out.append(0)
        return out
    }
}

/// Run `/bin/tlsget` with a fixed argv; returns the child exit status.
private func runTlsgetDefault() -> Int {
    var path = cstr("/bin/tlsget")
    var a0 = cstr("tlsget")
    var a1 = cstr("10.0.2.2")
    var a2 = cstr("44381")
    var a3 = cstr("10.0.2.2")
    return path.withUnsafeMutableBufferPointer { p in
        a0.withUnsafeMutableBufferPointer { p0 in
            a1.withUnsafeMutableBufferPointer { p1 in
                a2.withUnsafeMutableBufferPointer { p2 in
                    a3.withUnsafeMutableBufferPointer { p3 in
                        var argv: [UnsafeMutablePointer<CChar>?] =
                            [p0.baseAddress, p1.baseAddress, p2.baseAddress, p3.baseAddress, nil]
                        return argv.withUnsafeMutableBufferPointer { av in
                            Int(swiftos_run(p.baseAddress!, av.baseAddress!))
                        }
                    }
                }
            }
        }
    }
}

private func runTlsgetCafile() -> Int {
    var path = cstr("/bin/tlsget")
    var a0 = cstr("tlsget")
    var a1 = cstr("--cafile")
    var a2 = cstr("/etc/ssl/test-ca.pem")
    var a3 = cstr("10.0.2.2")
    var a4 = cstr("44381")
    var a5 = cstr("10.0.2.2")
    return path.withUnsafeMutableBufferPointer { p in
        a0.withUnsafeMutableBufferPointer { p0 in
            a1.withUnsafeMutableBufferPointer { p1 in
                a2.withUnsafeMutableBufferPointer { p2 in
                    a3.withUnsafeMutableBufferPointer { p3 in
                        a4.withUnsafeMutableBufferPointer { p4 in
                            a5.withUnsafeMutableBufferPointer { p5 in
                                var argv: [UnsafeMutablePointer<CChar>?] =
                                    [p0.baseAddress, p1.baseAddress, p2.baseAddress,
                                     p3.baseAddress, p4.baseAddress, p5.baseAddress, nil]
                                return argv.withUnsafeMutableBufferPointer { av in
                                    Int(swiftos_run(p.baseAddress!, av.baseAddress!))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private func runTlsgetInsecure() -> Int {
    var path = cstr("/bin/tlsget")
    var a0 = cstr("tlsget")
    var a1 = cstr("--insecure")
    var a2 = cstr("10.0.2.2")
    var a3 = cstr("44381")
    return path.withUnsafeMutableBufferPointer { p in
        a0.withUnsafeMutableBufferPointer { p0 in
            a1.withUnsafeMutableBufferPointer { p1 in
                a2.withUnsafeMutableBufferPointer { p2 in
                    a3.withUnsafeMutableBufferPointer { p3 in
                        var argv: [UnsafeMutablePointer<CChar>?] =
                            [p0.baseAddress, p1.baseAddress, p2.baseAddress, p3.baseAddress, nil]
                        return argv.withUnsafeMutableBufferPointer { av in
                            Int(swiftos_run(p.baseAddress!, av.baseAddress!))
                        }
                    }
                }
            }
        }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    swiftos_puts("TLS-TS-PROBE-START\n")

    // A) Default verify against the system store — test leaf is untrusted.
    swiftos_puts("TLS-TS-PROBE-A\n")
    _ = runTlsgetDefault()

    // B) Explicit test CA — chain should verify.
    swiftos_puts("TLS-TS-PROBE-B\n")
    _ = runTlsgetCafile()

    // C) Insecure opt-out.
    swiftos_puts("TLS-TS-PROBE-C\n")
    _ = runTlsgetInsecure()

    swiftos_puts("TLS-TS-PROBE-DONE\n")
    // Stay alive so the host can scrape the serial log before QEMU dies.
    while true {
        swiftos_nanosleep(1, 0)
    }
}
