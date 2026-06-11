// SPDX-License-Identifier: Apache-2.0
// stability_coverage_test.swift - guard broad stability/security test coverage.

import Foundation

private var ok = true

private func fail(_ message: String) {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    ok = false
}

private func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("\(path): could not read")
        return ""
    }
    return text
}

private func targetBody(_ target: String, in makefile: String) -> String {
    let lines = makefile.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var body: [String] = []
    var active = false

    for line in lines {
        if line.hasPrefix("\(target):") {
            active = true
            body.append(line)
            continue
        }
        if active {
            if !line.isEmpty,
               !line.hasPrefix("\t"),
               !line.hasPrefix(" "),
               !line.hasPrefix("#"),
               line.contains(":") {
                break
            }
            body.append(line)
        }
    }
    if body.isEmpty {
        fail("Makefile: missing target `\(target)`")
    }
    return body.joined(separator: "\n")
}

private func require(_ text: String, _ needle: String, _ label: String) {
    if !text.contains(needle) {
        fail("\(label): missing `\(needle)`")
    }
}

private struct CoverageGroup {
    let name: String
    let needles: [String]
}

private func requireGroup(_ group: CoverageGroup, in text: String, label: String) {
    for needle in group.needles {
        require(text, needle, "\(label) \(group.name)")
    }
}

let makefile = read("Makefile")
let testingGuide = read("docs/TESTING_GUIDE.md")
let configReference = read("docs/CONFIGURATION_REFERENCE.md")
let roadmap = read("docs/RISK_REMEDIATION_ROADMAP.md")
let notes = read("docs/NOTES.md")

let docsTestBody = targetBody("docs-test", in: makefile)
let fullTestBody = targetBody("test", in: makefile)
let c5Body = targetBody("c5-test", in: makefile)
let s5Body = targetBody("s5-test", in: makefile)

require(docsTestBody, "$(MAKE) stability-coverage-test", "docs-test")
require(makefile, "stability-coverage-test:", "Makefile")

private let fullGateGroups = [
    CoverageGroup(
        name: "memory/resource safety",
        needles: [
            "tests/page_allocator_test.swift",
            "$(MAKE) page-allocator-refcount-lifecycle-test",
            "./tests/s4_resource_stress_test.sh",
            "./tests/smp_resource_stress_test.sh",
            "./tests/threads_test.sh",
            "./tests/mmap_test.sh"
        ]
    ),
    CoverageGroup(
        name: "SMP and hardware/QEMU",
        needles: [
            "$(QEMU_DTB)",
            "$(QEMU_DTB_SMP4)",
            "tests/fdt_test.swift",
            "./tests/qemu_virt_hardware_map_test.sh",
            "./tests/smp_boot_test.sh",
            "./tests/top_test.sh",
            "./tests/virtio_blk_test.sh",
            "./tests/virtio_net_test.sh",
            "./tests/uefi_boot_test.sh",
            "./tests/fb_vi_test.sh"
        ]
    ),
    CoverageGroup(
        name: "security/isolation",
        needles: [
            "tests/handle_test.swift",
            "tests/swpkg_header_integrity_test.swift",
            "./tests/console_login_test.sh",
            "./tests/cap_enforce_test.sh",
            "./tests/signed_image_test.sh",
            "./tests/ab_rollback_test.sh",
            "./tests/uefi_krollback_test.sh",
            "$(MAKE) c5-test"
        ]
    ),
    CoverageGroup(
        name: "crypto and TLS",
        needles: [
            "tests/crypto_test.swift",
            "tests/hkdf_test.swift",
            "tests/x25519_test.swift",
            "tests/tls_handshake_test.swift",
            "tests/ed25519_test.swift",
            "tests/loader_ed25519_test.c",
            "./tests/tls_test.sh"
        ]
    ),
    CoverageGroup(
        name: "networking",
        needles: [
            "tests/net_test.swift",
            "./tests/ipv6_smoke_test.sh",
            "./tests/udp_echo_test.sh",
            "./tests/tcp_echo_test.sh",
            "./tests/httpd_test.sh",
            "./tests/dns_test.sh",
            "./tests/sshd_runtime_entropy_test.sh",
            "./tests/net_zero_copy_throughput_test.sh"
        ]
    ),
    CoverageGroup(
        name: "update/rollback",
        needles: [
            "./tests/ab_update_test.sh",
            "./tests/ab_confirm_test.sh",
            "./tests/ab_rollback_test.sh",
            "./tests/ab_flush_test.sh",
            "./tests/uefi_kernel_ab_test.sh",
            "./tests/uefi_kattempt_test.sh",
            "./tests/uefi_kconfirm_test.sh",
            "./tests/uefi_krollback_test.sh"
        ]
    ),
    CoverageGroup(
        name: "package/userland integration",
        needles: [
            "./tests/package_overlay_test.sh",
            "./tests/pkg_store_boot_test.sh",
            "./tests/pkg_local_install_test.sh",
            "./tests/busybox_test.sh",
            "./tests/swift_coreutils_test.sh",
            "./tests/llm_run_test.sh",
            "./tests/llm_serve_test.sh"
        ]
    )
]

for group in fullGateGroups {
    requireGroup(group, in: fullTestBody, label: "make test")
}

require(c5Body, "c5-driver-service-test", "c5 aggregate")
require(c5Body, "c5-device-authority-test", "c5 aggregate")
require(c5Body, "c5-device-rights-test", "c5 aggregate")
require(c5Body, "device-authority-cap-test", "c5 aggregate")
require(s5Body, "s5-run-any-placement-test", "s5 aggregate")
require(makefile, "qemu-virt-hardware-map-test:", "Makefile focused hardware map")
require(makefile, "page-allocator-refcount-lifecycle-test:", "Makefile focused page allocator lifecycle")
require(makefile, "tests/page_allocator_refcount_lifecycle_test.swift", "Makefile focused page allocator lifecycle")
require(makefile, "smp-resource-stress-test:", "Makefile focused resource stress")
require(makefile, "s4-resource-stress-test:", "Makefile focused resource stress")
require(makefile, "c5-device-authority-test:", "Makefile focused device authority")
require(makefile, "device-authority-cap-test:", "Makefile focused device authority capability")
require(makefile, "tests/device_authority_cap_test.sh", "Makefile focused device authority capability")
require(makefile, "swpkg-header-integrity-test:", "Makefile focused package integrity")

for doc in [testingGuide, configReference] {
    require(doc, "make test", "testing/config docs")
    require(doc, "make c5-test", "testing/config docs")
    require(doc, "make s5-test", "testing/config docs")
    require(doc, "make s4-resource-stress-test", "testing/config docs")
    require(doc, "make qemu-virt-hardware-map-test", "testing/config docs")
    require(doc, "make swpkg-header-integrity-test", "testing/config docs")
}
require(testingGuide, "Full-gate coverage guard", "testing guide")
require(testingGuide, "C5 driver-service/device-authority readiness", "testing guide")
require(testingGuide, "make device-authority-cap-test", "testing guide")
require(configReference, "`make stability-coverage-test`", "configuration reference")
require(roadmap, "C5 aggregate readiness gate", "roadmap")
require(roadmap, "C5g", "roadmap")
require(notes, "Full-gate coverage hardening", "notes")
require(notes, "C5g", "notes")

if ok {
    print("PASS: stability coverage guard found required memory, hardware, security, network, update, package, C5, and SMP gates")
    exit(0)
}
exit(1)
