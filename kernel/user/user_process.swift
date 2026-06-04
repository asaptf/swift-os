// user_process.swift — minimal EL0 process probe.

private let userTextVA: UInt = 0x8010_0000
private let userStackTopVA: UInt = 0x8010_2000

private var userTrapSeen = false

func userProcessStart() {
    uartPuts("M4 user: preparing EL0 process\n")

    guard let codePage = swiftos_kernel_alloc(4096, 4096),
          let stackPage = swiftos_kernel_alloc(4096, 4096) else {
        uartPuts("panic: user process page allocation failed\n")
        while true {}
    }

    user_program_install(codePage)

    let codePA = UInt(bitPattern: codePage)
    let stackPA = UInt(bitPattern: stackPage)
    if vm_map_user_code_page(userTextVA, codePA) != 0 ||
        vm_map_user_data_page(userStackTopVA - 4096, stackPA) != 0 {
        uartPuts("panic: user process mapping failed\n")
        while true {}
    }

    uartPuts("M4 user: entering EL0\n")
    enter_el0(userTextVA, userStackTopVA)

    while true {}
}

func userProcessHandleSVC(argument: UInt) {
    if !userTrapSeen {
        userTrapSeen = true
        uartPuts("M4 OK: EL0 process trapped back via SVC x0=")
        uartPutUInt(UInt64(argument))
        uartPuts("\n")
    }
}
