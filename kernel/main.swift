// main.swift — Swift kernel entry point.
//
// The assembly boot stub (arch/aarch64/boot.S) sets up the stack and clears
// BSS, then calls `kernel_main`. We are at EL1, single core, MMU off.
//
// M0 goal: prove the Swift toolchain, boot path, and UART all work by printing
// a banner to the serial console. Everything else arrives in later milestones.

/// Kernel entry point, called from the boot stub. Must never return.
@_cdecl("kernel_main")
func kernelMain() {
    uartPuts("Hello from Swift kernel\n")
    uartPuts("swift-os M0: boot skeleton up on QEMU virt (aarch64, EL1)\n")

    // Nothing to schedule yet — halt the core forever.
    while true {
        // wfi would be nicer, but interrupts aren't set up until M2.
    }
}
