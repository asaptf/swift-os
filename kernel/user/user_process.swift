// user_process.swift — minimal EL0 process/syscall probe.

private let userTextVA: UInt = 0x8010_0000
private let userStackTopVA: UInt = 0x8010_2000

func userProcessStart() {
    uartPuts("M5 user: preparing EL0 syscall test\n")

    guard let codePage = swiftos_kernel_alloc(4096, 4096),
          let stackPage = swiftos_kernel_alloc(4096, 4096) else {
        uartPuts("panic: user process page allocation failed\n")
        while true {}
    }

    user_program_install(codePage, stackPage)

    let codePA = UInt(bitPattern: codePage)
    let stackPA = UInt(bitPattern: stackPage)
    if vm_map_user_code_page(userTextVA, codePA) != 0 ||
        vm_map_user_data_page(userStackTopVA - 4096, stackPA) != 0 {
        uartPuts("panic: user process mapping failed\n")
        while true {}
    }

    uartPuts("M5 user: entering EL0\n")
    enter_el0(userTextVA, userStackTopVA)

    while true {}
}
