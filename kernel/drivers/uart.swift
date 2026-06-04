// uart.swift — PL011 UART driver for QEMU `virt`.
//
// The PL011 is mapped at 0x0900_0000. For M0 we only transmit: QEMU resets the
// UART into a usable state, so no baud/line configuration is required to get
// characters onto the serial console. MMIO goes through the volatile accessors
// in io.h (imported via the bridging header).

/// Base address of UART0, discovered into the HAL (QEMU `virt` default
/// 0x0900_0000). Computed so it tracks `platformInit` overriding it.
private var uart0Base: UInt { platform.uartBase }

// Register offsets (ARM PrimeCell PL011, DDI0183).
private let uartDR: UInt = 0x00     // Data register.
private let uartFR: UInt = 0x18     // Flag register.
private let uartIMSC: UInt = 0x38   // Interrupt mask set/clear.
private let uartICR: UInt = 0x44    // Interrupt clear.

// Flag register bits.
private let frRXFE: UInt32 = 1 << 4 // Receive FIFO empty.
private let frTXFF: UInt32 = 1 << 5 // Transmit FIFO full.

// Interrupt bits (IMSC/ICR/MIS).
private let intRX: UInt32 = 1 << 4  // Receive interrupt.
private let intRT: UInt32 = 1 << 6  // Receive timeout interrupt.

/// PL011 GIC interrupt id, discovered into the HAL (QEMU `virt`: SPI 1 →
/// INTID 33). Computed so it tracks `platformInit` overriding it.
var uartIrqId: UInt32 { platform.uartIrq }

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

func uartPutHex(_ value: UInt) {
    uartPuts("0x")
    var shift = (MemoryLayout<UInt>.size * 8) - 4
    while shift >= 0 {
        let nibble = UInt8((value >> UInt(shift)) & 0xF)
        uartPutc(nibble < 10 ? 0x30 + nibble : 0x41 + (nibble - 10))
        if shift == 0 { break }
        shift -= 4
    }
}

/// Enable receive interrupts (RX + receive-timeout) and route the line through
/// the GIC. Call after gicInit(). TX stays polled.
func uartRxInit() {
    mmio_write32(uart0Base + uartICR, 0x7FF)          // clear any stale interrupts
    mmio_write32(uart0Base + uartIMSC, intRX | intRT) // unmask RX + RX-timeout
    gicEnableInterrupt(uartIrqId)
}

/// Non-blocking RX poll: returns the next received byte, or -1 if the FIFO is
/// empty. Used by ttyRead to service a blocking read with IRQs masked, avoiding
/// a nested EL1 interrupt that would clobber ELR_EL1/SPSR_EL1.
func uartTryReadByte() -> Int {
    if (mmio_read32(uart0Base + uartFR) & frRXFE) == 0 {
        return Int(mmio_read32(uart0Base + uartDR) & 0xFF)
    }
    return -1
}

/// Drain the RX FIFO into the tty line discipline. Called from the IRQ handler.
func uartHandleRx() {
    while (mmio_read32(uart0Base + uartFR) & frRXFE) == 0 {
        let byte = UInt8(mmio_read32(uart0Base + uartDR) & 0xFF)
        ttyOnInput(byte)
    }
    mmio_write32(uart0Base + uartICR, intRX | intRT)  // acknowledge at the UART
}

func uartPutUInt(_ value: UInt64) {
    var divisor: UInt64 = 1
    while value / divisor >= 10 {
        divisor *= 10
    }

    var remaining = value
    while divisor > 0 {
        let digit = UInt8(remaining / divisor)
        uartPutc(0x30 + digit)
        remaining %= divisor
        divisor /= 10
    }
}
