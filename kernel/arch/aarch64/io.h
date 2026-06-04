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
extern uint8_t __image_end[];

void swiftos_heap_init(void);
uintptr_t swiftos_kernel_heap_used_bytes(void);
void *swiftos_kernel_alloc(uintptr_t byte_count, uintptr_t alignment);

// Physical memory manager (implemented in Swift, kernel/mm/pmm.swift).
// Frames are 4 KiB. Allocation returns a physical address, or 0 on failure
// (frame 0 never lies inside the managed region, so 0 is a safe sentinel).
void pmm_init(void);
uintptr_t pmm_alloc_page(void);
uintptr_t pmm_alloc_pages(long count);
void pmm_free_page(uintptr_t addr);
long pmm_free_count(void);

void mmu_init_identity_map(void);
void mmu_configure_translation(void);
void mmu_enable_sctlr(void);
void mmu_enable(void);
int mmu_is_enabled(void);
int vm_map_page(uintptr_t va, uintptr_t pa, uint32_t attr_index);
int vm_map_user_code_page(uintptr_t va, uintptr_t pa);
int vm_map_user_data_page(uintptr_t va, uintptr_t pa);
int vm_unmap_page(uintptr_t va);
uintptr_t vm_translate(uintptr_t va);

// Per-process address spaces. A TTBR0 value is the physical address of the L0
// table; every address space identity-maps the kernel/device 1 GiB blocks so
// kernel code keeps running with any process's tables installed.
uintptr_t mmu_kernel_ttbr0(void);
uintptr_t address_space_create(void);
int address_space_map(uintptr_t ttbr0, uintptr_t va, uintptr_t pa, int perm);
void address_space_switch(uintptr_t ttbr0);
uintptr_t address_space_translate(uintptr_t ttbr0, uintptr_t va);

void user_program_install(void *code_dst, void *data_dst);
void enter_el0(uintptr_t entry, uintptr_t stack_top);

// Kernel thread context switch (kernel/arch/aarch64/switch.S).
void cpu_switch_context(void *prev, void *next);
uintptr_t thread_trampoline_addr(void);
void thread_exit(void); // provided by kernel/sched/scheduler.swift

enum {
    VM_ATTR_NORMAL = 0,
    VM_ATTR_DEVICE = 1
};

enum {
    VM_PERM_KERNEL_RW = 0, // EL1 read/write, no EL0 access, executable.
    VM_PERM_USER_CODE = 1, // EL0 read/execute, EL1 no-execute.
    VM_PERM_USER_DATA = 2  // EL0 read/write, execute-never.
};

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

static inline uintptr_t swiftos_image_end(void) {
    return (uintptr_t)__image_end;
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

static inline uint64_t read_spsr_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, spsr_el1" : "=r"(value));
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

static inline uint64_t read_tcr_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, tcr_el1" : "=r"(value));
    return value;
}

static inline uint64_t read_ttbr0_el1(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, ttbr0_el1" : "=r"(value));
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
