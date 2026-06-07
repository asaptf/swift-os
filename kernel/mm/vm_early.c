// vm.c — early AArch64 stage-1 translation tables.
//
// M3 keeps the first mapping deliberately small and conservative:
// - identity-map low devices (0x00000000..0x3fffffff) as Device-nGnRnE;
// - identity-map RAM/kernel (0x40000000..0x7fffffff) as normal cacheable;
// - reserve one L3 page table under VA 0x80000000 for map/unmap probes.

#include <stdint.h>

#define PAGE_SIZE 4096ULL
#define ENTRIES_PER_TABLE 512U

#define DESC_VALID (1ULL << 0)
#define DESC_TABLE (1ULL << 1)
#define DESC_AF (1ULL << 10)
#define DESC_SH_INNER (3ULL << 8)
#define DESC_AP_EL1_RW (0ULL << 6)
#define DESC_AP_EL0_RW (1ULL << 6)
#define DESC_AP_EL0_RO (3ULL << 6)
#define DESC_ATTR_SHIFT 2
#define DESC_UXN (1ULL << 54)
#define DESC_PXN (1ULL << 53)

#define ATTR_NORMAL 0U
#define ATTR_DEVICE 1U

#define BLOCK_1G_MASK 0x0000ffffc0000000ULL
#define BLOCK_2M_MASK 0x0000ffffffe00000ULL
#define PAGE_4K_MASK 0x0000fffffffff000ULL

static uint64_t l0_table[ENTRIES_PER_TABLE] __attribute__((aligned(PAGE_SIZE)));
static uint64_t l1_table[ENTRIES_PER_TABLE] __attribute__((aligned(PAGE_SIZE)));
static uint64_t probe_l2_table[ENTRIES_PER_TABLE] __attribute__((aligned(PAGE_SIZE)));
static uint64_t probe_l3_table[ENTRIES_PER_TABLE] __attribute__((aligned(PAGE_SIZE)));

static uint64_t table_desc(uint64_t table_addr) {
    return (table_addr & PAGE_4K_MASK) | DESC_TABLE | DESC_VALID;
}

static uint64_t mem_attrs(uint32_t attr_index, int executable, int user_access, int user_read_only) {
    uint64_t desc = DESC_AF;
    if (user_read_only) {
        desc |= DESC_AP_EL0_RO;
    } else if (user_access) {
        desc |= DESC_AP_EL0_RW;
    } else {
        desc |= DESC_AP_EL1_RW;
    }
    if (!executable) {
        desc |= DESC_UXN | DESC_PXN;
    } else if (user_access) {
        desc |= DESC_PXN;
    }
    desc |= ((uint64_t)attr_index) << DESC_ATTR_SHIFT;
    if (attr_index == ATTR_NORMAL) {
        desc |= DESC_SH_INNER;
    }
    return desc;
}

static uint64_t block_desc_1g(uint64_t pa, uint32_t attr_index) {
    int executable = attr_index == ATTR_NORMAL;
    return (pa & BLOCK_1G_MASK) | mem_attrs(attr_index, executable, 0, 0) | DESC_VALID;
}

static uint64_t page_desc(uint64_t pa, uint32_t attr_index) {
    return (pa & PAGE_4K_MASK) | mem_attrs(attr_index, 0, 0, 0) | DESC_TABLE | DESC_VALID;
}

static uint64_t user_code_page_desc(uint64_t pa) {
    return (pa & PAGE_4K_MASK) | mem_attrs(ATTR_NORMAL, 1, 1, 1) | DESC_TABLE | DESC_VALID;
}

static uint64_t user_data_page_desc(uint64_t pa) {
    return (pa & PAGE_4K_MASK) | mem_attrs(ATTR_NORMAL, 0, 1, 0) | DESC_TABLE | DESC_VALID;
}

static void zero_table(uint64_t *table) {
    for (unsigned i = 0; i < ENTRIES_PER_TABLE; i += 1) {
        table[i] = 0;
    }
}

static inline void dsb_sy(void) {
    __asm__ volatile("dsb sy" ::: "memory");
}

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

void mmu_init_identity_map(void) {
    zero_table(l0_table);
    zero_table(l1_table);
    zero_table(probe_l2_table);
    zero_table(probe_l3_table);

    l0_table[0] = table_desc((uint64_t)(uintptr_t)l1_table);

#ifdef BOARD_VIRTUALBOX
    // VirtualBox ARM: RAM (incl. the kernel) lives in the first 1 GiB at
    // 0x0800_0000, and the UART/GIC sit in the top 1 GiB (PL011 0xFFDD_F000,
    // GIC 0xFCD3_0000). Map the low block as normal so the kernel executes, and
    // the high block as device for the MMIO. (Flash/PCI in the low block are
    // mapped normal but untouched during bring-up.)
    l1_table[0] = block_desc_1g(0x00000000ULL, ATTR_NORMAL);
    l1_table[3] = block_desc_1g(0xC0000000ULL, ATTR_DEVICE);
#else
    l1_table[0] = block_desc_1g(0x00000000ULL, ATTR_DEVICE);
    l1_table[1] = block_desc_1g(0x40000000ULL, ATTR_NORMAL);
#endif
    l1_table[2] = table_desc((uint64_t)(uintptr_t)probe_l2_table);
    probe_l2_table[0] = table_desc((uint64_t)(uintptr_t)probe_l3_table);
}

void mmu_configure_translation(void) {
    uint64_t mair = (0xffULL << 0) | (0x00ULL << 8);
    uint64_t tcr =
        16ULL |          // T0SZ: 48-bit TTBR0 VA space.
        (1ULL << 8) |    // IRGN0: normal memory inner WB/WA.
        (1ULL << 10) |   // ORGN0: normal memory outer WB/WA.
        (3ULL << 12) |   // SH0: inner shareable.
        (1ULL << 23) |   // EPD1: disable TTBR1 walks for now.
        (1ULL << 32);    // IPS: 36-bit physical address space.

    __asm__ volatile("msr mair_el1, %0" :: "r"(mair) : "memory");
    __asm__ volatile("msr tcr_el1, %0" :: "r"(tcr) : "memory");
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"((uint64_t)(uintptr_t)l0_table) : "memory");
    dsb_sy();
    isb();
    tlbi_all();
}

void mmu_enable_sctlr(void) {
    uint64_t sctlr;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    sctlr &= ~((1ULL << 1) | (1ULL << 3) | (1ULL << 4)); // A, SA, SA0 off.
    sctlr |= (1ULL << 0) | (1ULL << 2) | (1ULL << 12);   // M, C, I on.
    __asm__ volatile("msr sctlr_el1, %0" :: "r"(sctlr) : "memory");
    isb();
}

void mmu_enable(void) {
    mmu_configure_translation();
    mmu_enable_sctlr();
}

int mmu_is_enabled(void) {
    uint64_t sctlr;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    return (sctlr & 1ULL) != 0;
}

int vm_map_page(uintptr_t va, uintptr_t pa, uint32_t attr_index) {
    if ((va & (PAGE_SIZE - 1)) != 0 || (pa & (PAGE_SIZE - 1)) != 0) {
        return -1;
    }
    if (va < 0x80000000ULL || va >= 0x80200000ULL) {
        return -2;
    }
    if (attr_index > ATTR_DEVICE) {
        return -3;
    }

    unsigned l3_index = (unsigned)((va >> 12) & 0x1ffU);
    probe_l3_table[l3_index] = page_desc(pa, attr_index);
    dsb_sy();
    tlbi_va(va);
    return 0;
}

static int vm_map_user_page_with_desc(uintptr_t va, uintptr_t pa, uint64_t desc) {
    if ((va & (PAGE_SIZE - 1)) != 0 || (pa & (PAGE_SIZE - 1)) != 0) {
        return -1;
    }
    if (va < 0x80000000ULL || va >= 0x80200000ULL) {
        return -2;
    }

    unsigned l3_index = (unsigned)((va >> 12) & 0x1ffU);
    probe_l3_table[l3_index] = desc;
    dsb_sy();
    tlbi_va(va);
    return 0;
}

int vm_map_user_code_page(uintptr_t va, uintptr_t pa) {
    return vm_map_user_page_with_desc(va, pa, user_code_page_desc(pa));
}

int vm_map_user_data_page(uintptr_t va, uintptr_t pa) {
    return vm_map_user_page_with_desc(va, pa, user_data_page_desc(pa));
}

int vm_unmap_page(uintptr_t va) {
    if ((va & (PAGE_SIZE - 1)) != 0) {
        return -1;
    }
    if (va < 0x80000000ULL || va >= 0x80200000ULL) {
        return -2;
    }

    unsigned l3_index = (unsigned)((va >> 12) & 0x1ffU);
    probe_l3_table[l3_index] = 0;
    dsb_sy();
    tlbi_va(va);
    return 0;
}

uintptr_t vm_translate(uintptr_t va) {
    if (va < 0x80000000ULL || va >= 0x80200000ULL) {
        return 0;
    }

    unsigned l3_index = (unsigned)((va >> 12) & 0x1ffU);
    uint64_t desc = probe_l3_table[l3_index];
    if ((desc & (DESC_VALID | DESC_TABLE)) != (DESC_VALID | DESC_TABLE)) {
        return 0;
    }
    return (uintptr_t)((desc & PAGE_4K_MASK) | (va & (PAGE_SIZE - 1)));
}

// --- Per-process address spaces -------------------------------------------
//
// Frames for page tables come from the PMM (kernel/mm/pmm.swift). RAM is
// identity-mapped, so a physical frame address doubles as its kernel pointer.

extern uintptr_t pmm_alloc_page(void); // from pmm.swift

uintptr_t mmu_kernel_ttbr0(void) {
    return (uintptr_t)l0_table;
}

static uint64_t perm_page_desc(uintptr_t pa, int perm) {
    int executable, user, read_only;
    switch (perm) {
    case 1: executable = 1; user = 1; read_only = 1; break; // USER_CODE
    case 2: executable = 0; user = 1; read_only = 0; break; // USER_DATA
    default: executable = 1; user = 0; read_only = 0; break; // KERNEL_RW
    }
    return (pa & PAGE_4K_MASK)
         | mem_attrs(ATTR_NORMAL, executable, user, read_only)
         | DESC_TABLE | DESC_VALID;
}

// Return the next-level table for `idx`, allocating+linking it if absent.
static uint64_t *next_table(uint64_t *table, unsigned idx) {
    uint64_t desc = table[idx];
    if (desc & DESC_VALID) {
        return (uint64_t *)(uintptr_t)(desc & PAGE_4K_MASK);
    }
    uintptr_t frame = pmm_alloc_page();
    if (frame == 0) {
        return 0;
    }
    zero_table((uint64_t *)frame);
    table[idx] = table_desc((uint64_t)frame);
    return (uint64_t *)frame;
}

uintptr_t address_space_create(void) {
    uintptr_t l0 = pmm_alloc_page();
    uintptr_t l1 = pmm_alloc_page();
    if (l0 == 0 || l1 == 0) {
        return 0;
    }
    zero_table((uint64_t *)l0);
    zero_table((uint64_t *)l1);

    ((uint64_t *)l0)[0] = table_desc((uint64_t)l1);
    // Identity-map the kernel and device 1 GiB blocks into every space. The
    // split is board-specific (see mmu_init_identity_map): the kernel must stay
    // executable (normal) while MMIO stays device after a TTBR0 switch.
#ifdef BOARD_VIRTUALBOX
    ((uint64_t *)l1)[0] = block_desc_1g(0x00000000ULL, ATTR_NORMAL);
    ((uint64_t *)l1)[3] = block_desc_1g(0xC0000000ULL, ATTR_DEVICE);
#else
    ((uint64_t *)l1)[0] = block_desc_1g(0x00000000ULL, ATTR_DEVICE);
    ((uint64_t *)l1)[1] = block_desc_1g(0x40000000ULL, ATTR_NORMAL);
#endif
    return l0;
}

int address_space_map(uintptr_t ttbr0, uintptr_t va, uintptr_t pa, int perm) {
    if ((va & (PAGE_SIZE - 1)) != 0 || (pa & (PAGE_SIZE - 1)) != 0) {
        return -1;
    }
    uint64_t *l0 = (uint64_t *)ttbr0;
    uint64_t *l1 = next_table(l0, (unsigned)((va >> 39) & 0x1ffU));
    if (!l1) return -2;
    uint64_t *l2 = next_table(l1, (unsigned)((va >> 30) & 0x1ffU));
    if (!l2) return -2;
    uint64_t *l3 = next_table(l2, (unsigned)((va >> 21) & 0x1ffU));
    if (!l3) return -2;

    l3[(unsigned)((va >> 12) & 0x1ffU)] = perm_page_desc(pa, perm);
    dsb_sy();
    tlbi_va(va);
    return 0;
}

void address_space_switch(uintptr_t ttbr0) {
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"((uint64_t)ttbr0) : "memory");
    dsb_sy();
    isb();
    tlbi_all();
}

uintptr_t address_space_translate(uintptr_t ttbr0, uintptr_t va) {
    uint64_t *table = (uint64_t *)ttbr0;
    unsigned shifts[4] = {39, 30, 21, 12};
    for (int level = 0; level < 4; level += 1) {
        unsigned idx = (unsigned)((va >> shifts[level]) & 0x1ffU);
        uint64_t desc = table[idx];
        if (!(desc & DESC_VALID)) {
            return 0;
        }
        if (level < 3 && !(desc & DESC_TABLE)) {
            // 1 GiB or 2 MiB block: combine block base with the low offset.
            uint64_t mask = (level == 1) ? BLOCK_1G_MASK : BLOCK_2M_MASK;
            uint64_t block_size = (level == 1) ? 0x40000000ULL : 0x200000ULL;
            return (uintptr_t)((desc & mask) | (va & (block_size - 1)));
        }
        if (level == 3) {
            return (uintptr_t)((desc & PAGE_4K_MASK) | (va & (PAGE_SIZE - 1)));
        }
        table = (uint64_t *)(uintptr_t)(desc & PAGE_4K_MASK);
    }
    return 0;
}

extern void pmm_free_page(uintptr_t addr); // from pmm.swift

// Tear down a per-process address space created by address_space_create() /
// address_space_clone(): free every USER leaf frame (VA >= 0x8000_0000, i.e. L1
// index >= 2) and the L3/L2 page tables that map them, then the L1 and L0
// frames. The kernel/device identity entries (L1 indices 0,1) are 1 GiB *block*
// descriptors, not tables — they own no frames and are skipped by the
// DESC_TABLE test, so the shared kernel mapping is never freed. Eager fork
// gives each space private leaf frames (no COW sharing), so a flat free is
// correct — no refcounting needed.
//
// Frame reclamation is the inverse of the leak that made the OS unusable for
// long-running workloads (~2 MiB lost per busybox command). Safe to call on a
// partially built space (failed createProcess) — it frees whatever exists.
//
// If the doomed space is the currently installed TTBR0 (the common case when
// the kernel scheduler reaps a just-exited top-level process, whose tables are
// still live in the register), switch to the kernel identity map first so the
// MMU never walks frames we are about to hand back to the PMM.
void address_space_destroy(uintptr_t ttbr0) {
    if (ttbr0 == 0 || ttbr0 == (uintptr_t)l0_table) {
        return;
    }

    uint64_t cur;
    __asm__ volatile("mrs %0, ttbr0_el1" : "=r"(cur));
    if ((uintptr_t)(cur & PAGE_4K_MASK) == ttbr0) {
        address_space_switch((uintptr_t)l0_table);
    }

    uint64_t *l0 = (uint64_t *)ttbr0;
    uint64_t d0 = l0[0];
    if ((d0 & DESC_VALID) && (d0 & DESC_TABLE)) {
        uint64_t *l1 = (uint64_t *)(uintptr_t)(d0 & PAGE_4K_MASK);
        for (unsigned i1 = 2; i1 < ENTRIES_PER_TABLE; i1 += 1) {
            uint64_t d1 = l1[i1];
            if (!(d1 & DESC_VALID) || !(d1 & DESC_TABLE)) continue;
            uint64_t *l2 = (uint64_t *)(uintptr_t)(d1 & PAGE_4K_MASK);
            for (unsigned i2 = 0; i2 < ENTRIES_PER_TABLE; i2 += 1) {
                uint64_t d2 = l2[i2];
                if (!(d2 & DESC_VALID) || !(d2 & DESC_TABLE)) continue;
                uint64_t *l3 = (uint64_t *)(uintptr_t)(d2 & PAGE_4K_MASK);
                for (unsigned i3 = 0; i3 < ENTRIES_PER_TABLE; i3 += 1) {
                    uint64_t d3 = l3[i3];
                    if (d3 & DESC_VALID) {
                        pmm_free_page((uintptr_t)(d3 & PAGE_4K_MASK)); // leaf user frame
                    }
                }
                pmm_free_page((uintptr_t)l3); // L3 table
            }
            pmm_free_page((uintptr_t)l2); // L2 table
        }
        pmm_free_page((uintptr_t)l1); // L1 table
    }
    pmm_free_page(ttbr0); // L0 table
}

extern void *memcpy(void *dst, const void *src, unsigned long n); // string.c

// Eager fork: create a new address space and copy every mapped USER page
// (VA >= 0x8000_0000, i.e. L1 index >= 2) from `parent`, preserving each page's
// permission/attribute bits. The kernel/device identity blocks come fresh from
// address_space_create(). Returns the child TTBR0, or 0 on failure.
uintptr_t address_space_clone(uintptr_t parent) {
    uintptr_t child = address_space_create();
    if (child == 0) {
        return 0;
    }
    uint64_t *pl0 = (uint64_t *)parent;
    uint64_t *cl0 = (uint64_t *)child;
    if (!(pl0[0] & DESC_VALID)) {
        return child;
    }
    uint64_t *pl1 = (uint64_t *)(uintptr_t)(pl0[0] & PAGE_4K_MASK);

    for (unsigned i1 = 2; i1 < ENTRIES_PER_TABLE; i1 += 1) {
        uint64_t d1 = pl1[i1];
        if (!(d1 & DESC_VALID) || !(d1 & DESC_TABLE)) continue;
        uint64_t *pl2 = (uint64_t *)(uintptr_t)(d1 & PAGE_4K_MASK);
        for (unsigned i2 = 0; i2 < ENTRIES_PER_TABLE; i2 += 1) {
            uint64_t d2 = pl2[i2];
            if (!(d2 & DESC_VALID) || !(d2 & DESC_TABLE)) continue;
            uint64_t *pl3 = (uint64_t *)(uintptr_t)(d2 & PAGE_4K_MASK);
            for (unsigned i3 = 0; i3 < ENTRIES_PER_TABLE; i3 += 1) {
                uint64_t d3 = pl3[i3];
                if (!(d3 & DESC_VALID)) continue;

                uintptr_t va = ((uintptr_t)i1 << 30) | ((uintptr_t)i2 << 21) | ((uintptr_t)i3 << 12);
                uintptr_t srcpa = (uintptr_t)(d3 & PAGE_4K_MASK);
                uintptr_t dstpa = pmm_alloc_page();
                if (dstpa == 0) return 0;
                memcpy((void *)dstpa, (void *)srcpa, PAGE_SIZE);

                uint64_t *cl1 = next_table(cl0, (unsigned)((va >> 39) & 0x1ffU));
                if (!cl1) return 0;
                uint64_t *cl2 = next_table(cl1, (unsigned)((va >> 30) & 0x1ffU));
                if (!cl2) return 0;
                uint64_t *cl3 = next_table(cl2, (unsigned)((va >> 21) & 0x1ffU));
                if (!cl3) return 0;
                cl3[(unsigned)((va >> 12) & 0x1ffU)] = (d3 & ~PAGE_4K_MASK) | (dstpa & PAGE_4K_MASK);
            }
        }
    }
    dsb_sy();
    tlbi_all();
    return child;
}
