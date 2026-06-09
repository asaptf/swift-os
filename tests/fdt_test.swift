// SPDX-License-Identifier: Apache-2.0
// fdt_test.swift - host unit test for the flattened-device-tree reader.
//
// Compiled with the host Swift toolchain against the same kernel/arch/aarch64/
// fdt.swift the kernel uses (it is pure: no UART/MMIO/heap), then run against a
// real QEMU `virt` DTB dumped by `qemu-system-aarch64 -M virt,dumpdtb=...`.
// This proves the parser extracts the hardware map QEMU actually advertises,
// independent of booting the kernel.

import Foundation

@main
struct FdtTest {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: fdt_test <dtb-file> [expected-cpus]\n".utf8))
            exit(2)
        }
        let expectedCpus = args.count >= 3 ? UInt32(args[2])! : 1

        let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            let info = fdtParse(base)

            check(info.valid, "device-tree magic should be valid")

            check(info.haveRam, "should find a /memory node")
            check(info.ramBase == 0x4000_0000, "ram base 0x40000000, got 0x\(String(info.ramBase, radix: 16))")
            check(info.ramSize == 0x1000_0000, "ram size 256 MiB, got 0x\(String(info.ramSize, radix: 16))")

            check(info.haveUart, "should find an arm,pl011 UART")
            check(info.uartBase == 0x0900_0000, "uart base 0x9000000, got 0x\(String(info.uartBase, radix: 16))")
            check(info.haveUartIrq && info.uartIrq == 33, "uart IRQ should be INTID 33, got \(info.uartIrq)")

            check(info.haveGic, "should find a GICv2")
            check(info.gicDist == 0x0800_0000, "gic dist 0x8000000, got 0x\(String(info.gicDist, radix: 16))")
            check(info.gicCpu == 0x0801_0000, "gic cpu 0x8010000, got 0x\(String(info.gicCpu, radix: 16))")

            check(info.haveVirtio, "should find virtio-mmio transport slots")
            check(info.virtioBase == 0x0A00_0000, "virtio base 0xa000000, got 0x\(String(info.virtioBase, radix: 16))")
            check(info.virtioStride == 0x200, "virtio stride 0x200, got 0x\(String(info.virtioStride, radix: 16))")
            check(info.virtioCount == 32, "virtio slot count 32, got \(info.virtioCount)")

            check(info.haveCpuTopology, "should find /cpus topology")
            check(info.cpuCount == expectedCpus, "cpu count \(expectedCpus), got \(info.cpuCount)")
            check(info.havePsci, "should find a PSCI node")
            check(info.psciMethod == platformPsciMethodHvc, "PSCI method should be hvc, got \(info.psciMethod)")
            check(info.psciCpuOn == 0xC400_0003, "PSCI CPU_ON should be 0xc4000003, got 0x\(String(info.psciCpuOn, radix: 16))")
            var cpu: UInt32 = 0
            while cpu < expectedCpus {
                check(info.cpuAff0(cpu) == cpu, "cpu[\(cpu)] Aff0 \(cpu), got \(info.cpuAff0(cpu))")
                if expectedCpus > 1 {
                    check(info.cpuUsesPsci(cpu), "cpu[\(cpu)] should advertise enable-method psci")
                } else {
                    check(!info.cpuUsesPsci(cpu), "single CPU DTB should not need per-CPU enable-method")
                }
                cpu += 1
            }

            print("PASS: fdt parser extracted the QEMU virt hardware map, PSCI, and \(expectedCpus) CPUs")
        }
    }
}
