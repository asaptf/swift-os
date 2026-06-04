// loader.c - swift-os UEFI loader (M10).
//
// Built as an AArch64 PE32+ EFI application (\EFI\BOOT\BOOTAA64.EFI) and launched
// by UEFI firmware (QEMU + AAVMF/edk2). It replaces QEMU's `-kernel` shortcut: a
// real firmware loads us from a disk's EFI System Partition, and we hand off to
// the Swift kernel.
//
// Flow:
//   1. Print to the UEFI console (the serial line under `-nographic`).
//   2. Locate the flattened device tree via the FDT configuration-table GUID
//      (the firmware must run in device-tree mode: `-M virt,acpi=off`).
//   3. Reserve the kernel's fixed load address and copy the embedded flat kernel
//      image there, cleaning it to the point of coherency.
//   4. GetMemoryMap + ExitBootServices to take ownership of the machine.
//   5. Mask interrupts and jump to the kernel entry with the DTB pointer in x0.
//
// The firmware hands us EL1 with the MMU on (verified on AAVMF); the kernel's
// boot stub turns the MMU and caches off, so no work is needed here beyond a
// data-cache clean of the freshly written kernel image.

#include "efi.h"

// Kernel link/load base (kernel.ld). The embedded flat image's byte 0 maps here.
#define KERNEL_LOAD_ADDR 0x40080000ULL

// Embedded flat kernel image (boot/efi/kernel_blob.S -> build/kernel.bin).
extern const unsigned char kernel_blob[];
extern const unsigned char kernel_blob_end[];

static void puts16(EFI_SYSTEM_TABLE *st, const char *s) {
    CHAR16 buf[160];
    int i = 0;
    while (*s && i < 159) {
        buf[i++] = (CHAR16)(unsigned char)*s++;
    }
    buf[i] = 0;
    st->ConOut->OutputString(st->ConOut, buf);
}

static void puthex(EFI_SYSTEM_TABLE *st, UINT64 v) {
    CHAR16 buf[19];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; i++) {
        int nibble = (int)((v >> ((15 - i) * 4)) & 0xF);
        buf[2 + i] = (CHAR16)(nibble < 10 ? '0' + nibble : 'A' + nibble - 10);
    }
    buf[18] = 0;
    st->ConOut->OutputString(st->ConOut, buf);
}

static int guid_eq(const EFI_GUID *a, const EFI_GUID *b) {
    const UINT8 *x = (const UINT8 *)a;
    const UINT8 *y = (const UINT8 *)b;
    for (int i = 0; i < 16; i++) {
        if (x[i] != y[i]) {
            return 0;
        }
    }
    return 1;
}

static void *find_device_tree(EFI_SYSTEM_TABLE *st) {
    EFI_GUID fdt = EFI_FDT_TABLE_GUID;
    for (UINTN i = 0; i < st->NumberOfTableEntries; i++) {
        if (guid_eq(&st->ConfigurationTable[i].VendorGuid, &fdt)) {
            return st->ConfigurationTable[i].VendorTable;
        }
    }
    return 0;
}

static void copy_mem(unsigned char *dst, const unsigned char *src, UINTN n) {
    for (UINTN i = 0; i < n; i++) {
        dst[i] = src[i];
    }
}

// Clean the data cache by VA to the point of coherency over [start, start+len),
// so the kernel image we just wrote is in RAM before the kernel runs with the
// data cache off.
static void clean_dcache(UINT64 start, UINT64 len) {
    const UINT64 line = 64;
    for (UINT64 a = start & ~(line - 1); a < start + len; a += line) {
        __asm__ volatile("dc cvac, %0" :: "r"(a) : "memory");
    }
    __asm__ volatile("dsb sy; isb" ::: "memory");
}

// Memory map scratch (static so requesting it does not perturb the map between
// GetMemoryMap and ExitBootServices). QEMU virt's map is well under this.
static UINT8 mmap_buf[16384];

EFI_STATUS efi_main(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st) {
    EFI_BOOT_SERVICES *bs = st->BootServices;

    puts16(st, "\r\nswift-os UEFI loader (M10)\r\n");

    void *dtb = find_device_tree(st);
    if (dtb) {
        puts16(st, "UEFI: device tree found at ");
        puthex(st, (UINT64)dtb);
        puts16(st, "\r\n");
    } else {
        puts16(st, "UEFI: device tree NOT in config table; kernel will scan RAM\r\n");
    }

    UINT64 current_el, sctlr;
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(current_el));
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    puts16(st, "UEFI: CurrentEL ");
    puthex(st, (current_el >> 2) & 0x3);
    puts16(st, " MMU ");
    puthex(st, sctlr & 1);
    puts16(st, "\r\n");

    // Reserve the kernel's fixed load address and stage the embedded image.
    UINTN ksize = (UINTN)(kernel_blob_end - kernel_blob);
    UINTN npages = (ksize + 0xFFF) / 0x1000;
    EFI_PHYSICAL_ADDRESS kaddr = KERNEL_LOAD_ADDR;
    EFI_STATUS s = bs->AllocatePages(AllocateAddress, EfiLoaderData, npages, &kaddr);
    if (s != EFI_SUCCESS) {
        puts16(st, "UEFI: FAIL could not reserve kernel load address ");
        puthex(st, (UINT64)s);
        puts16(st, "\r\n");
        for (;;) {}
    }
    copy_mem((unsigned char *)(UINTN)KERNEL_LOAD_ADDR, kernel_blob, ksize);
    clean_dcache(KERNEL_LOAD_ADDR, ksize);
    puts16(st, "UEFI: kernel staged, launching (no more firmware output)\r\n");

    // Take ownership of the machine: get the current memory map key, then exit
    // boot services. Retry once if the map changed underneath us.
    UINTN msize = sizeof(mmap_buf), mkey = 0, dsize = 0;
    UINT32 dver = 0;
    bs->GetMemoryMap(&msize, mmap_buf, &mkey, &dsize, &dver);
    s = bs->ExitBootServices(image_handle, mkey);
    if (s != EFI_SUCCESS) {
        msize = sizeof(mmap_buf);
        bs->GetMemoryMap(&msize, mmap_buf, &mkey, &dsize, &dver);
        s = bs->ExitBootServices(image_handle, mkey);
    }

    // Firmware is gone. Mask interrupts (its timer is still armed but unhandled)
    // and enter the kernel with the device-tree pointer in x0.
    __asm__ volatile("msr daifset, #0xf" ::: "memory");

    typedef void (*kernel_entry_t)(UINT64);
    kernel_entry_t enter = (kernel_entry_t)(UINTN)KERNEL_LOAD_ADDR;
    enter((UINT64)(UINTN)dtb);

    for (;;) {}
    return EFI_SUCCESS;
}
