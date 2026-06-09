// SPDX-License-Identifier: Apache-2.0
// cpu.swift - minimal current-CPU helpers for the AArch64 S0 bring-up.
//
// S0 only identifies the running processing element. Secondary CPUs still park
// in boot.S, so this file must not enable or schedule work on other CPUs.

private let mpidrAff0Mask: UInt64 = 0xFF

/// Return the current QEMU virt CPU id from MPIDR_EL1 Aff0.
@inline(__always)
func archCurrentCpuId() -> UInt32 {
    UInt32(read_mpidr_el1() & mpidrAff0Mask)
}

/// Generic kernel spelling for the current CPU id.
@inline(__always)
func currentCpuId() -> UInt32 {
    archCurrentCpuId()
}
