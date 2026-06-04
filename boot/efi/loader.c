// loader.c - swift-os UEFI loader (M10a).
//
// Built as an AArch64 PE32+ EFI application (\EFI\BOOT\BOOTAA64.EFI) and launched
// by UEFI firmware (QEMU + AAVMF/edk2). This first stage proves the boot path
// the project is moving to: a real firmware loads us from a disk's EFI System
// Partition instead of QEMU's `-kernel` shortcut.
//
// M10a scope: come up under firmware, print to the UEFI console (which is the
// serial line under `-nographic`), and locate the flattened device tree the
// firmware passes via its configuration table - the same hardware map the M9
// HAL parses. M10b will add GetMemoryMap + ExitBootServices and hand off to the
// Swift kernel.
//
// The loader must NOT return: returning hands control back to the firmware Boot
// Manager, which then runs its setup UI. We halt after reporting instead.

#include "efi.h"

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

EFI_STATUS efi_main(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st) {
    (void)image_handle;

    puts16(st, "\r\nswift-os UEFI loader (M10a)\r\n");

    void *dtb = find_device_tree(st);
    if (dtb) {
        puts16(st, "UEFI: device tree found at ");
        puthex(st, (UINT64)dtb);
        puts16(st, "\r\n");
    } else {
        puts16(st, "UEFI: device tree NOT found in configuration table\r\n");
    }

    puts16(st, "UEFI: M10a OK loader reached firmware handoff point\r\n");

    // Do not return to the Boot Manager; M10b will ExitBootServices and jump
    // into the kernel from here instead.
    for (;;) {
    }
    return EFI_SUCCESS;
}
