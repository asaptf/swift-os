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

static uint64_t mem_attrs(uint32_t attr_index, int executable) {
    uint64_t desc = DESC_AF | DESC_AP_EL1_RW;
    if (!executable) {
        desc |= DESC_UXN | DESC_PXN;
    }
    desc |= ((uint64_t)attr_index) << DESC_ATTR_SHIFT;
    if (attr_index == ATTR_NORMAL) {
        desc |= DESC_SH_INNER;
    }
    return desc;
}

static uint64_t block_desc_1g(uint64_t pa, uint32_t attr_index) {
    int executable = attr_index == ATTR_NORMAL;
    return (pa & BLOCK_1G_MASK) | mem_attrs(attr_index, executable) | DESC_VALID;
}

static uint64_t page_desc(uint64_t pa, uint32_t attr_index) {
    return (pa & PAGE_4K_MASK) | mem_attrs(attr_index, 0) | DESC_TABLE | DESC_VALID;
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

    l1_table[0] = block_desc_1g(0x00000000ULL, ATTR_DEVICE);
    l1_table[1] = block_desc_1g(0x40000000ULL, ATTR_NORMAL);
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
