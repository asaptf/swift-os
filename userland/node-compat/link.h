// SPDX-License-Identifier: Apache-2.0
// link.h - minimal dynamic-link introspection for the masquerade. Abseil's
// elf_mem_image / symbolizer include this for the ElfW() macro and the
// link_map/r_debug/dl_iterate_phdr surface. SwiftOS is statically linked with no
// dynamic loader, so dl_iterate_phdr reports nothing and symbolization is inert;
// the types only need to exist so the debugging code compiles.
#ifndef _SWOS_NODE_COMPAT_LINK_H
#define _SWOS_NODE_COMPAT_LINK_H

#include <elf.h>
#include <stddef.h>

/* AArch64 is LP64 -> the 64-bit ELF types. */
#define ElfW(type) Elf64_##type

struct link_map {
    Elf64_Addr       l_addr;   /* base address of the object */
    char            *l_name;   /* object path */
    Elf64_Dyn       *l_ld;     /* DYNAMIC section */
    struct link_map *l_next;
    struct link_map *l_prev;
};

struct r_debug {
    int              r_version;
    struct link_map *r_map;
    Elf64_Addr       r_brk;
    int              r_state;
    Elf64_Addr       r_ldbase;
};
extern struct r_debug _r_debug;

struct dl_phdr_info {
    Elf64_Addr        dlpi_addr;
    const char       *dlpi_name;
    const Elf64_Phdr *dlpi_phdr;
    Elf64_Half        dlpi_phnum;
};

#ifdef __cplusplus
extern "C"
#endif
int dl_iterate_phdr(int (*callback)(struct dl_phdr_info *info,
                                    size_t size, void *data),
                    void *data);

#endif /* _SWOS_NODE_COMPAT_LINK_H */
