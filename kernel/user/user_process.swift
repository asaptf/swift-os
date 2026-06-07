// SPDX-License-Identifier: Apache-2.0
// user_process.swift — minimal EL0 process/syscall probe.

private let userTextVA: UInt = 0x8010_0000
private let userStackTopVA: UInt = 0x8010_2000

func userProcessStart() {
    uartPuts("M5 user: preparing EL0 syscall test\n")

    let codePA = pmmAllocZeroedPage()
    let stackPA = pmmAllocZeroedPage()
    if codePA == 0 || stackPA == 0 {
        uartPuts("panic: user process page allocation failed\n")
        while true {}
    }

    let codePage = UnsafeMutableRawPointer(bitPattern: codePA)!
    let stackPage = UnsafeMutableRawPointer(bitPattern: stackPA)!
    user_program_install(codePage, stackPage)

    if vm_map_user_code_page(userTextVA, codePA) != 0 ||
        vm_map_user_data_page(userStackTopVA - 4096, stackPA) != 0 {
        uartPuts("panic: user process mapping failed\n")
        while true {}
    }

    uartPuts("M5 user: entering EL0\n")
    enter_el0(userTextVA, userStackTopVA)

    while true {}
}
