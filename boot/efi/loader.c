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
// Supplied by the Makefile per board (-DKERNEL_LOAD_ADDR=…); the default matches
// the QEMU `virt` link base. VirtualBox ARM uses 0x08080000 (see docs/VIRTUALBOX.md).
#ifndef KERNEL_LOAD_ADDR
#define KERNEL_LOAD_ADDR 0x40080000ULL
#endif

// Embedded flat kernel image (boot/efi/kernel_blob.S -> build/kernel.bin).
extern const unsigned char kernel_blob[];
extern const unsigned char kernel_blob_end[];

#ifdef BOARD_VIRTUALBOX
// On VirtualBox ARM the firmware's ConOut does not reach our serial capture
// (no graphics console, and EFI's console is not the PL011 we record). Mirror
// loader output straight to the PL011 at 0xFFDD_F000 so the boot trace — and
// especially an AllocatePages failure — is visible before the kernel runs.
#define PL011 0xFFDDF000ULL
static void pl011_init(void) {
    volatile unsigned int *cr   = (volatile unsigned int *)(PL011 + 0x30);
    volatile unsigned int *icr  = (volatile unsigned int *)(PL011 + 0x44);
    volatile unsigned int *ibrd = (volatile unsigned int *)(PL011 + 0x24);
    volatile unsigned int *fbrd = (volatile unsigned int *)(PL011 + 0x28);
    volatile unsigned int *lcrh = (volatile unsigned int *)(PL011 + 0x2C);
    *cr = 0;            // disable while reconfiguring
    *icr = 0x7FF;       // clear pending interrupts
    *ibrd = 13;         // ~115200 @ 24MHz UARTCLK (emulation tolerates this)
    *fbrd = 1;
    *lcrh = (3u << 5) | (1u << 4); // 8-bit words, FIFO enable
    *cr = (1u << 0) | (1u << 8) | (1u << 9); // UARTEN | TXE | RXE
}
static void pl011_putc(char c) {
    volatile unsigned int *dr = (volatile unsigned int *)PL011;
    volatile unsigned int *fr = (volatile unsigned int *)(PL011 + 0x18);
    while (*fr & (1u << 5)) { } // FR.TXFF: wait while the TX FIFO is full.
    *dr = (unsigned int)(unsigned char)c;
}
static void pl011_puts(const char *s) {
    while (*s) {
        if (*s == '\n') pl011_putc('\r');
        pl011_putc(*s++);
    }
}
#define DBG_PUTS(s) pl011_puts(s)
#else
#define DBG_PUTS(s) ((void)0)
#endif

static void puts16(EFI_SYSTEM_TABLE *st, const char *s) {
    DBG_PUTS(s);
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
#ifdef BOARD_VIRTUALBOX
    char a[19];
    for (int i = 0; i < 18; i++) a[i] = (char)buf[i];
    a[18] = 0;
    pl011_puts(a);
#endif
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

#ifdef BOARD_VIRTUALBOX
    pl011_init(); // VBox does not use the PL011 as its EFI console; enable TX.
#endif
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

    // Survey what the firmware exposes. On a non-QEMU board (VirtualBox), the
    // table set and memory map differ; this report is what we use to adapt the
    // HAL, and it prints regardless of whether the kernel can drive the UART.
    EFI_GUID acpi = EFI_ACPI_20_TABLE_GUID;
    int have_acpi = 0;
    for (UINTN i = 0; i < st->NumberOfTableEntries; i++) {
        if (guid_eq(&st->ConfigurationTable[i].VendorGuid, &acpi)) {
            have_acpi = 1;
        }
    }
    puts16(st, "UEFI: ACPI 2.0 table ");
    puts16(st, have_acpi ? "present\r\n" : "absent\r\n");

    {
        UINTN ms = sizeof(mmap_buf), mk = 0, ds = 0;
        UINT32 dv = 0;
        if (bs->GetMemoryMap(&ms, mmap_buf, &mk, &ds, &dv) == EFI_SUCCESS &&
            ds >= sizeof(EFI_MEMORY_DESCRIPTOR)) {
            UINT64 best_base = 0, best_pages = 0;
            for (UINTN off = 0; off + ds <= ms; off += ds) {
                EFI_MEMORY_DESCRIPTOR *d = (EFI_MEMORY_DESCRIPTOR *)(mmap_buf + off);
                if (d->Type == EfiConventionalMemory && d->NumberOfPages > best_pages) {
                    best_pages = d->NumberOfPages;
                    best_base = d->PhysicalStart;
                }
            }
            puts16(st, "UEFI: largest RAM region base ");
            puthex(st, best_base);
            puts16(st, " size ");
            puthex(st, best_pages * 4096);
            puts16(st, "\r\n");
        }
    }

    // Query the Graphics Output Protocol for a linear framebuffer to hand the
    // kernel for an on-screen console. Absent (headless firmware) leaves it 0,
    // and the kernel stays serial-only.
    UINT64 fb_base = 0, fb_dims = 0, fb_strfmt = 0;
    {
        EFI_GUID gop_guid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID;
        EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = 0;
        if (bs->LocateProtocol(&gop_guid, 0, (void **)&gop) == EFI_SUCCESS &&
            gop && gop->Mode && gop->Mode->Info) {
            EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *mi = gop->Mode->Info;
            fb_base = gop->Mode->FrameBufferBase;
            fb_dims = ((UINT64)mi->HorizontalResolution << 32) | mi->VerticalResolution;
            fb_strfmt = ((UINT64)mi->PixelsPerScanLine << 32) | mi->PixelFormat;
            puts16(st, "UEFI: GOP framebuffer at ");
            puthex(st, fb_base);
            puts16(st, "\r\n");
        } else {
            puts16(st, "UEFI: no GOP framebuffer (serial console only)\r\n");
        }
    }

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

    // x0=dtb, x1=framebuffer base, x2=(width<<32|height), x3=(stride<<32|format).
    typedef void (*kernel_entry_t)(UINT64, UINT64, UINT64, UINT64);
    kernel_entry_t enter = (kernel_entry_t)(UINTN)KERNEL_LOAD_ADDR;
    enter((UINT64)(UINTN)dtb, fb_base, fb_dims, fb_strfmt);

    for (;;) {}
    return EFI_SUCCESS;
}
