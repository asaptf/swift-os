// io.h — volatile MMIO accessors, exposed to Swift via a bridging header.
//
// Embedded Swift has no `volatile`, and the optimizer is free to drop or
// reorder plain pointer stores. Memory-mapped device registers must use
// volatile access, so we route every MMIO read/write through these C
// inlines. Importing this header makes them callable from Swift at zero cost.

#ifndef SWIFT_OS_IO_H
#define SWIFT_OS_IO_H

#include <stdint.h>

extern uint8_t __heap_start[];
extern uint8_t __heap_end[];

void swiftos_heap_init(void);
uintptr_t swiftos_kernel_heap_used_bytes(void);
void *swiftos_kernel_alloc(uintptr_t byte_count, uintptr_t alignment);

static inline void mmio_write32(uintptr_t addr, uint32_t value) {
    *(volatile uint32_t *)addr = value;
}

static inline uint32_t mmio_read32(uintptr_t addr) {
    return *(volatile uint32_t *)addr;
}

static inline uintptr_t swiftos_heap_start(void) {
    return (uintptr_t)__heap_start;
}

static inline uintptr_t swiftos_heap_end(void) {
    return (uintptr_t)__heap_end;
}

static inline uint64_t read_esr_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, esr_el1" : "=r"(value));
    return value;
}

static inline uint64_t read_elr_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, elr_el1" : "=r"(value));
    return value;
}

static inline uint64_t read_far_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, far_el1" : "=r"(value));
    return value;
}

static inline uint64_t read_sctlr_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(value));
    return value;
}

static inline uint64_t read_cpacr_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, cpacr_el1" : "=r"(value));
    return value;
}

static inline uint64_t read_daif(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, daif" : "=r"(value));
    return value;
}

static inline void enable_irq(void) {
    __asm__ volatile("msr daifclr, #2" ::: "memory");
}

static inline void disable_irq(void) {
    __asm__ volatile("msr daifset, #2" ::: "memory");
}

static inline void wfi(void) {
    __asm__ volatile("wfi" ::: "memory");
}

static inline uint64_t read_cntfrq_el0(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(value));
    return value;
}

static inline uint64_t read_cntpct_el0(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, cntpct_el0" : "=r"(value));
    return value;
}

static inline uint64_t read_cntp_ctl_el0(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, cntp_ctl_el0" : "=r"(value));
    return value;
}

static inline void write_cntp_ctl_el0(uint64_t value) {
    __asm__ volatile("msr cntp_ctl_el0, %0; isb" :: "r"(value) : "memory");
}

static inline void write_cntp_tval_el0(uint64_t value) {
    __asm__ volatile("msr cntp_tval_el0, %0; isb" :: "r"(value) : "memory");
}

#endif // SWIFT_OS_IO_H
