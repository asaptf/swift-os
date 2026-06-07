// elf.c — minimal static ELF64 loader for AArch64 EL0 programs.
//
// Parses an in-memory ET_EXEC image and maps its PT_LOAD segments into a target
// address space (TTBR0), drawing frames from the PMM. Loading is page-driven,
// not segment-driven: two segments may share a page (our hello.elf packs text
// and rodata into one), so we allocate a frame per distinct virtual page and
// copy each segment's bytes into place. Per-page permission is "executable wins"
// (a page touched by any PF_X segment is mapped user-RX, otherwise user-RW).
//
// Returns the entry virtual address, or 0 on any validation/allocation failure.

#include "../arch/aarch64/io.h"

typedef struct {
    unsigned char e_ident[16];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
} Elf64_Ehdr;

typedef struct {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
} Elf64_Phdr;

#define PT_LOAD 1
#define PF_X 1
#define PF_W 2
#define ET_EXEC 2
#define EM_AARCH64 183
#define PAGE_SIZE 4096ULL

extern void *memset(void *dst, int value, unsigned long count);
extern void *memcpy(void *dst, const void *src, unsigned long count);

static uintptr_t page_down(uintptr_t v) { return v & ~(PAGE_SIZE - 1); }
static uintptr_t page_up(uintptr_t v) { return (v + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1); }

// Number of distinct user pages the most recent elf_load mapped (for /bin/top's
// per-process resident-memory accounting). Set at the start of each elf_load.
static unsigned long g_elf_load_pages = 0;
unsigned long elf_last_load_pages(void) { return g_elf_load_pages; }

// Copy `len` bytes to virtual address `va` in `ttbr0`, walking page by page and
// resolving each page to its physical (identity-mapped) frame.
static int copy_to_user(uintptr_t ttbr0, uintptr_t va, const unsigned char *src, uint64_t len) {
    while (len > 0) {
        uint64_t off = va & (PAGE_SIZE - 1);
        uint64_t chunk = PAGE_SIZE - off;
        if (chunk > len) {
            chunk = len;
        }
        uintptr_t pa = address_space_translate(ttbr0, va);
        if (pa == 0) {
            return -1;
        }
        memcpy((void *)pa, src, chunk);
        va += chunk;
        src += chunk;
        len -= chunk;
    }
    return 0;
}

uintptr_t elf_load(uintptr_t ttbr0, const void *image, unsigned long size) {
    if (size < sizeof(Elf64_Ehdr)) {
        return 0;
    }
    g_elf_load_pages = 0;
    const unsigned char *base = (const unsigned char *)image;
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)image;

    if (eh->e_ident[0] != 0x7f || eh->e_ident[1] != 'E' ||
        eh->e_ident[2] != 'L' || eh->e_ident[3] != 'F') {
        return 0;
    }
    if (eh->e_ident[4] != 2 /*ELFCLASS64*/ || eh->e_ident[5] != 1 /*little-endian*/) {
        return 0;
    }
    if (eh->e_type != ET_EXEC || eh->e_machine != EM_AARCH64) {
        return 0;
    }
    if (eh->e_phoff + (uint64_t)eh->e_phnum * eh->e_phentsize > size) {
        return 0;
    }

    for (unsigned i = 0; i < eh->e_phnum; i += 1) {
        const Elf64_Phdr *ph =
            (const Elf64_Phdr *)(base + eh->e_phoff + (uint64_t)i * eh->e_phentsize);
        if (ph->p_type != PT_LOAD || ph->p_memsz == 0) {
            continue;
        }
        if (ph->p_offset + ph->p_filesz > size || ph->p_filesz > ph->p_memsz) {
            return 0;
        }

        int perm = (ph->p_flags & PF_X) ? VM_PERM_USER_CODE : VM_PERM_USER_DATA;
        uintptr_t va_start = page_down(ph->p_vaddr);
        uintptr_t va_end = page_up(ph->p_vaddr + ph->p_memsz);

        for (uintptr_t va = va_start; va < va_end; va += PAGE_SIZE) {
            uintptr_t pa = address_space_translate(ttbr0, va);
            if (pa == 0) {
                pa = pmm_alloc_page();
                if (pa == 0) {
                    return 0;
                }
                memset((void *)pa, 0, PAGE_SIZE); // zero-fill (covers .bss)
                if (address_space_map(ttbr0, va, pa, perm) != 0) {
                    return 0;
                }
                g_elf_load_pages += 1; // a fresh frame (not a perm upgrade of a shared page)
            } else if (perm == VM_PERM_USER_CODE) {
                // A previous (data) segment already mapped this page; executable wins.
                if (address_space_map(ttbr0, va, pa, VM_PERM_USER_CODE) != 0) {
                    return 0;
                }
            }
        }

        if (copy_to_user(ttbr0, ph->p_vaddr, base + ph->p_offset, ph->p_filesz) != 0) {
            return 0;
        }
    }

    return (uintptr_t)eh->e_entry;
}
