// uart.swift — PL011 UART driver for QEMU `virt`.
//
// The PL011 is mapped at 0x0900_0000. For M0 we only transmit: QEMU resets the
// UART into a usable state, so no baud/line configuration is required to get
// characters onto the serial console. MMIO goes through the volatile accessors
// in io.h (imported via the bridging header).

/// Base address of UART0 on the QEMU `virt` board.
private let uart0Base: UInt = 0x0900_0000

// Register offsets (ARM PrimeCell PL011, DDI0183).
private let uartDR: UInt = 0x00   // Data register.
private let uartFR: UInt = 0x18   // Flag register.

// Flag register bits.
private let frTXFF: UInt32 = 1 << 5 // Transmit FIFO full.

/// Write one byte to the UART, blocking until the TX FIFO has room.
@inline(__always)
func uartPutc(_ byte: UInt8) {
    while (mmio_read32(uart0Base + uartFR) & frTXFF) != 0 {
        // Spin: FIFO full.
    }
    mmio_write32(uart0Base + uartDR, UInt32(byte))
}

/// Write a static string, translating LF into CR+LF for terminal sanity.
func uartPuts(_ string: StaticString) {
    string.withUTF8Buffer { buffer in
        for byte in buffer {
            if byte == 0x0A { uartPutc(0x0D) }
            uartPutc(byte)
        }
    }
}
