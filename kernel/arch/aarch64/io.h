// io.h — volatile MMIO accessors, exposed to Swift via a bridging header.
//
// Embedded Swift has no `volatile`, and the optimizer is free to drop or
// reorder plain pointer stores. Memory-mapped device registers must use
// volatile access, so we route every MMIO read/write through these C
// inlines. Importing this header makes them callable from Swift at zero cost.

#ifndef SWIFT_OS_IO_H
#define SWIFT_OS_IO_H

#include <stdbool.h>
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
void pmm_frame_ref(uintptr_t addr);
bool pmm_frame_unref(uintptr_t addr);
long pmm_frame_refcount(uintptr_t addr);
long pmm_free_count(void);
long pmm_total_count(void); // total managed frames (for /bin/top memory stats)

// Framebuffer text console (kernel/drivers/fb.c). The loader passes a GOP
// framebuffer; fb_init(0,...) leaves it disabled (serial-only, e.g. QEMU
// -nographic). uartPutc mirrors output through fb_putc.
void fb_init(uint64_t base, uint32_t width, uint32_t height, uint32_t stride_px);
void fb_putc(uint8_t c);
void fb_cursor_blink(void); // blink the on-screen text cursor (timer-driven)
int fb_available(void);
uint64_t fb_phys_base(void);
uint64_t fb_phys_size(void);

// The virtio-input keyboard and virtio-blk block device are now Swift drivers
// (kernel/drivers/virtio_input.swift, virtio_blk.swift). Called only from Swift,
// they need no bridging declaration here; like virtio_net.swift they use this
// header solely for MMIO and cache maintenance.

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
uintptr_t address_space_clone(uintptr_t parent); // COW fork clone
void address_space_destroy(uintptr_t ttbr0);     // free a process's frames on teardown

// Track B: mmap/munmap/mprotect over the EL0 half of an address space. The
// caller (process.swift) owns the VA cursor + page accounting and passes an
// aligned base VA and a page count; these do the frame work and TLB flush.
// `prot` is a PROT_* bitmask (READ=1, WRITE=2, EXEC=4). W^X (WRITE|EXEC) and
// PROT_NONE are rejected. Return 0 on success or a negative errno.
int address_space_mmap(uintptr_t ttbr0, uintptr_t va, uintptr_t page_count, int prot);
int address_space_munmap(uintptr_t ttbr0, uintptr_t va, uintptr_t page_count);
int address_space_mprotect(uintptr_t ttbr0, uintptr_t va, uintptr_t page_count, int prot);

void user_program_install(void *code_dst, void *data_dst);
void enter_el0(uintptr_t entry, uintptr_t stack_top);

// Kernel thread context switch (kernel/arch/aarch64/switch.S).
void cpu_switch_context(void *prev, void *next);
uintptr_t thread_trampoline_addr(void);
void thread_exit(void); // provided by kernel/sched/scheduler.swift
uintptr_t trap_return_addr(void); // exceptions.S — fork child trap-return entry

// EL0 entry trampoline (user_entry.S). The ELF64 loader and the initial-stack
// builder are now Swift (kernel/user/elf.swift, ustack.swift), called only from
// Swift, so they need no bridging declaration here.
uintptr_t user_thread_launch_addr(void);
// rt-a: EL0 thread first-run trampoline, entry(arg) — see user_entry.S.
uintptr_t user_thread_launch_arg_addr(void);

// Userland programs (busybox + demos) are no longer embedded in the kernel
// image (M11d). They live in the packed base image on disk and are loaded via
// the VFS (vfsDiskImageExtent) + virtioBlkReadRange — see kernel/user/exec.swift.

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

// Cache maintenance for DMA. A Swift driver (kernel/drivers/virtio_net.swift)
// cleans (writes back) the cache lines a device reads and invalidates the lines
// a device writes, around each DMA. No-ops under TCG, real work under a caching
// accelerator — same discipline as the inline asm in virtio_blk.c.
static inline void dc_cvac(uintptr_t addr) {
    __asm__ volatile("dc cvac, %0" :: "r"(addr) : "memory");
}
static inline void dc_ivac(uintptr_t addr) {
    __asm__ volatile("dc ivac, %0" :: "r"(addr) : "memory");
}
static inline void dsb_sy(void) {
    __asm__ volatile("dsb sy" ::: "memory");
}

// --- C2: low-level barriers/TLB/TTBR0 bridges for the Swift VM port ---------
// kernel/mm/vm.swift (the per-process address-space half) drives stage-1 page
// tables but cannot emit `isb`/`tlbi`/`msr ttbr0_el1` directly in Embedded
// Swift, so it routes them through these inlines. tlbi_va/tlbi_all bundle the
// dsb;isb completion barriers, matching the originals in vm_early.c so the port
// is bit-exact.
static inline void isb(void) {
    __asm__ volatile("isb" ::: "memory");
}
static inline void tlbi_all(void) {
    __asm__ volatile("tlbi vmalle1" ::: "memory");
    dsb_sy();
    isb();
}
static inline void tlbi_va(uintptr_t va) {
    uintptr_t operand = va >> 12;
    __asm__ volatile("tlbi vae1, %0" :: "r"(operand) : "memory");
    dsb_sy();
    isb();
}
static inline void write_ttbr0_el1(uint64_t value) {
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"(value) : "memory");
}
// Kernel L0 table base (the identity map built by mmu_init_identity_map in
// vm_early.c). vm.swift returns it from mmu_kernel_ttbr0() and compares against
// it in address_space_destroy.
extern uint64_t l0_table[];
static inline uintptr_t vm_kernel_l0_table(void) {
    return (uintptr_t)l0_table;
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

// Save the current DAIF state and mask IRQs, returning the prior state so a
// later irq_restore() can put it back. Use to bracket a critical section that
// must not be re-entered by the timer IRQ (e.g. a context switch) without
// unconditionally enabling IRQs on the way out.
static inline uint64_t irq_save(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, daif" : "=r"(value));
    __asm__ volatile("msr daifset, #2" ::: "memory");
    return value;
}

static inline void irq_restore(uint64_t daif) {
    __asm__ volatile("msr daif, %0" :: "r"(daif) : "memory");
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
