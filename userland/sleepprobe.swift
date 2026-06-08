// SPDX-License-Identifier: Apache-2.0
// sleepprobe.swift — native Swift probe that proves nanosleep actually blocks.
//
// Reads the RTC wall clock (time() syscall), sleeps 2 seconds via the real
// nanosleep path, reads the clock again, and prints "SLEEP_DELTA=<n>" where n is
// the elapsed whole seconds. With the old no-op stub this would be 0; a working
// timer-backed sleep yields >= 2. The boot test (tests/sleep_test.sh) asserts on
// this line.

private let sleepSeconds: UInt = 2

private func putUInt(_ value: UInt) {
    if value == 0 {
        swiftos_putc(0x30) // "0"
        return
    }
    var digits = [UInt8](repeating: 0, count: 20)
    var n = value
    var count = 0
    while n > 0 {
        digits[count] = UInt8(0x30 + Int(n % 10))
        n /= 10
        count += 1
    }
    while count > 0 {
        count -= 1
        swiftos_putc(digits[count])
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    let t0 = swiftos_time()
    swiftos_nanosleep(sleepSeconds, 0)
    let t1 = swiftos_time()
    let delta = t1 >= t0 ? t1 - t0 : 0
    swiftos_puts("SLEEP_DELTA=")
    putUInt(delta)
    swiftos_putc(0x0A) // "\n"
    return 0
}
