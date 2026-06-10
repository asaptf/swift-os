// SPDX-License-Identifier: Apache-2.0
// phase1_roadmap_test.swift - host guard for Phase 1 roadmap/test drift.

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

private func require(_ text: String, _ needle: String, _ label: String) {
    if !text.contains(needle) {
        fail("\(label): missing `\(needle)`")
    }
}

private func requireTarget(_ makefile: String, _ target: String, _ fragments: [String]) {
    require(makefile, "\(target):", "Makefile target \(target)")
    for fragment in fragments {
        require(makefile, fragment, "Makefile target \(target)")
    }
}

private struct Milestone {
    let id: String
    let roadmapNeedle: String
    let notesNeedle: String
    let target: String
    let targetFragments: [String]
    let markerNeedles: [String]
    let docsNeedles: [String]
}

let roadmap = read("docs/RISK_REMEDIATION_ROADMAP.md")
let notes = read("docs/NOTES.md")
let makefile = read("Makefile")
let smpBootTest = read("tests/smp_boot_test.sh")
let driverServiceTest = read("tests/driver_service_test.sh")
let testingGuide = read("docs/TESTING_GUIDE.md")
let configReference = read("docs/CONFIGURATION_REFERENCE.md")

private let milestones: [Milestone] = [
    Milestone(
        id: "S5a",
        roadmapNeedle: "S5a preflight (2026-06-10)",
        notesNeedle: "### S5a — per-CPU utilization export (DONE, 2026-06-10)",
        target: "smp-cpu-utilization-test",
        targetFragments: ["./tests/top_test.sh"],
        markerNeedles: ["S5a OK: per-CPU utilization counters ready"],
        docsNeedles: ["make smp-cpu-utilization-test"]
    ),
    Milestone(
        id: "S5b",
        roadmapNeedle: "S5b placement batch (2026-06-10)",
        notesNeedle: "### S5b — bounded EL0 scheduler placement batch (DONE, 2026-06-10)",
        target: "s5-scheduler-placement-test",
        targetFragments: ["./tests/smp_boot_test.sh"],
        markerNeedles: ["S5b OK: three EL0 processes ran with scheduler placement"],
        docsNeedles: ["make s5-scheduler-placement-test"]
    ),
    Milestone(
        id: "S5c",
        roadmapNeedle: "S5c placement stress (2026-06-10)",
        notesNeedle: "### S5c — repeated EL0 placement stress + run queue lock (DONE, 2026-06-10)",
        target: "s5-placement-stress-test",
        targetFragments: ["./tests/smp_boot_test.sh"],
        markerNeedles: ["S5c OK: repeated EL0 placement stress completed"],
        docsNeedles: ["make s5-placement-stress-test"]
    ),
    Milestone(
        id: "S5d",
        roadmapNeedle: "S5d fanout (2026-06-10)",
        notesNeedle: "### S5d — independent EL0 fanout across scheduler CPUs (DONE, 2026-06-10)",
        target: "s5-el0-fanout-test",
        targetFragments: ["./tests/smp_boot_test.sh"],
        markerNeedles: ["S5d OK: EL0 fanout ran across scheduler CPUs"],
        docsNeedles: ["make s5-el0-fanout-test"]
    ),
    Milestone(
        id: "S5e",
        roadmapNeedle: "S5e thread fanout (2026-06-10)",
        notesNeedle: "### S5e — shared-address-space thread fanout (DONE, 2026-06-10)",
        target: "s5-thread-fanout-test",
        targetFragments: ["./tests/smp_boot_test.sh"],
        markerNeedles: ["S5e OK: shared-address-space thread fanout completed"],
        docsNeedles: ["make s5-thread-fanout-test"]
    ),
    Milestone(
        id: "S5f",
        roadmapNeedle: "S5f run-any placement (2026-06-10)",
        notesNeedle: "### S5f — run-any EL0 placement policy (DONE, 2026-06-10)",
        target: "s5-run-any-placement-test",
        targetFragments: ["./tests/smp_boot_test.sh"],
        markerNeedles: ["S5f OK: run-any placement policy completed"],
        docsNeedles: ["make s5-run-any-placement-test"]
    ),
    Milestone(
        id: "C5a",
        roadmapNeedle: "### C5a — restartable driver-service supervisor smoke (DONE, 2026-06-10)",
        notesNeedle: "### C5a — restartable driver-service supervisor smoke (DONE, 2026-06-10)",
        target: "c5-driver-service-test",
        targetFragments: ["./tests/driver_service_test.sh"],
        markerNeedles: ["C5a OK: restartable driver service recovered over IPC"],
        docsNeedles: ["make c5-driver-service-test"]
    ),
    Milestone(
        id: "C5b",
        roadmapNeedle: "### C5b — opaque device-handle handoff scaffold (DONE, 2026-06-10)",
        notesNeedle: "### C5b — opaque device-handle handoff scaffold (DONE, 2026-06-10)",
        target: "c5-device-handle-test",
        targetFragments: ["c5-driver-service-test"],
        markerNeedles: ["C5b OK: opaque device handle transferred and released"],
        docsNeedles: ["make c5-device-handle-test"]
    ),
    Milestone(
        id: "C5c",
        roadmapNeedle: "### C5c — virtio-input device discovery and manifest matching (DONE, 2026-06-10)",
        notesNeedle: "### C5c — virtio-input device discovery and manifest matching (DONE, 2026-06-10)",
        target: "c5-device-discovery-test",
        targetFragments: ["c5-driver-service-test"],
        markerNeedles: ["C5c OK: virtio-input device grant discovered and matched"],
        docsNeedles: ["make c5-device-discovery-test"]
    ),
    Milestone(
        id: "C5d",
        roadmapNeedle: "### C5d — virtio-input discovery metadata (DONE, 2026-06-10)",
        notesNeedle: "### C5d — virtio-input discovery metadata (DONE, 2026-06-10)",
        target: "c5-device-metadata-test",
        targetFragments: ["C5_INPUT_DEVICE=1", "./tests/driver_service_test.sh"],
        markerNeedles: ["C5d OK: virtio input discovery metadata surfaced"],
        docsNeedles: ["make c5-device-metadata-test"]
    ),
    Milestone(
        id: "C5e",
        roadmapNeedle: "### C5e — device authority envelope preflight (DONE, 2026-06-10)",
        notesNeedle: "### C5e — device authority envelope preflight (DONE, 2026-06-10)",
        target: "c5-device-authority-test",
        targetFragments: ["C5_AUTHORITY_TEST=1", "C5_INPUT_DEVICE=1", "./tests/driver_service_test.sh"],
        markerNeedles: ["C5e OK: device authority withheld until explicit handoff"],
        docsNeedles: ["make c5-device-authority-test"]
    ),
    Milestone(
        id: "C5f",
        roadmapNeedle: "### C5f — metadata-only device grant rights contract (DONE, 2026-06-10)",
        notesNeedle: "### C5f — metadata-only device grant rights contract (DONE, 2026-06-10)",
        target: "c5-device-rights-test",
        targetFragments: ["tests/handle_test.swift", "tests/device_authority_guard_test.sh"],
        markerNeedles: ["C5f OK: device grant rights stayed metadata-only"],
        docsNeedles: ["make c5-device-rights-test"]
    )
]

for milestone in milestones {
    require(roadmap, milestone.roadmapNeedle, "\(milestone.id) roadmap")
    require(notes, milestone.notesNeedle, "\(milestone.id) notes")
    requireTarget(makefile, milestone.target, milestone.targetFragments)

    let markerSource = milestone.id.hasPrefix("S") ? smpBootTest : driverServiceTest
    for marker in milestone.markerNeedles {
        require(markerSource, marker, "\(milestone.id) executable marker")
    }
    for docNeedle in milestone.docsNeedles {
        if !testingGuide.contains(docNeedle) && !configReference.contains(docNeedle) {
            fail("\(milestone.id) docs: missing `\(docNeedle)` in testing/configuration docs")
        }
    }
}

if ok {
    print("PASS: Phase 1 roadmap, notes, Makefile targets, docs, and executable markers are aligned")
    exit(0)
}
exit(1)
