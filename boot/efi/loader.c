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
#include "loader_sha256.h"
#include "loader_ed25519.h"

// U1g-3b: the image-signing Ed25519 public key (boot/efi/efi_pubkey.S, the same
// root the kernel embeds). The loader verifies the signed kernel A/B manifest
// against it before trusting any slot selection.
extern const unsigned char efi_image_signing_pubkey[32];

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

// U1g: ESP paths, as CHAR16 (UTF-16) arrays so we do not depend on the
// toolchain's u"" literal. U1g-2 selects between two kernel slots (A/B) named by
// a small manifest; the manifest and both slot images live under \EFI\swift-os.
static CHAR16 KERNEL_A_PATH[] = {
    '\\','E','F','I','\\','s','w','i','f','t','-','o','s','\\',
    'k','e','r','n','e','l','A','.','b','i','n', 0
};
static CHAR16 KERNEL_B_PATH[] = {
    '\\','E','F','I','\\','s','w','i','f','t','-','o','s','\\',
    'k','e','r','n','e','l','B','.','b','i','n', 0
};
static CHAR16 KERNEL_MANIFEST_PATH[] = {
    '\\','E','F','I','\\','s','w','i','f','t','-','o','s','\\',
    'k','e','r','n','e','l','-','b','o','o','t', 0
};
// H3: the packed read-only base image, staged on the ESP so we can load it into
// RAM and hand the kernel a ramdisk (the Hetzner VM's boot disk is virtio-scsi,
// which the kernel does not drive; the firmware Simple File System does).
static CHAR16 BASE_IMG_PATH[] = {
    '\\','E','F','I','\\','s','w','i','f','t','-','o','s','\\',
    'b','a','s','e','.','i','m','g', 0
};
// U1g-5a: the writable boot-state (per-slot boot-attempt counter + state). Not
// signed — only hash-protected against torn/garbage writes — so the loader and OS
// can update it freely (the kernel images are independently signature/hash-checked).
static CHAR16 KERNEL_STATE_PATH[] = {
    '\\','E','F','I','\\','s','w','i','f','t','-','o','s','\\',
    'k','e','r','n','e','l','-','s','t','a','t','e', 0
};

static UINT32 ld32(const UINT8 *p) {
    return (UINT32)p[0] | ((UINT32)p[1] << 8) | ((UINT32)p[2] << 16) | ((UINT32)p[3] << 24);
}
static void st32(UINT8 *p, UINT32 v) {
    p[0] = (UINT8)v; p[1] = (UINT8)(v >> 8); p[2] = (UINT8)(v >> 16); p[3] = (UINT8)(v >> 24);
}

// Open a file on the volume the loader was loaded from (the ESP) and return its
// handle (*out_file) and size (*out_size). Returns 1 on success, 0 on any
// failure. U1g decouples the kernel image (and its A/B manifest) from the loader
// binary so they can be staged on disk.
static int open_esp_file(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st, CHAR16 *path,
                         EFI_FILE_PROTOCOL **out_file, UINT64 *out_size) {
    EFI_BOOT_SERVICES *bs = st->BootServices;
    EFI_GUID li_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
    EFI_GUID fs_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
    EFI_GUID info_guid = EFI_FILE_INFO_ID;

    EFI_LOADED_IMAGE_PROTOCOL *li = 0;
    if (bs->HandleProtocol(image_handle, &li_guid, (void **)&li) != EFI_SUCCESS || !li) {
        return 0;
    }
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs = 0;
    if (bs->HandleProtocol(li->DeviceHandle, &fs_guid, (void **)&fs) != EFI_SUCCESS || !fs) {
        return 0;
    }
    EFI_FILE_PROTOCOL *root = 0;
    if (fs->OpenVolume(fs, &root) != EFI_SUCCESS || !root) {
        return 0;
    }
    EFI_FILE_PROTOCOL *f = 0;
    if (root->Open(root, &f, path, EFI_FILE_MODE_READ, 0) != EFI_SUCCESS || !f) {
        root->Close(root);
        return 0;
    }
    root->Close(root);

    // GetInfo returns the full EFI_FILE_INFO: the fixed prefix (80 bytes) PLUS
    // the file name as a CHAR16 string, so the buffer must be generous or the
    // firmware answers EFI_BUFFER_TOO_SMALL.
    UINT8 info[512];
    UINTN isz = sizeof(info);
    if (f->GetInfo(f, &info_guid, &isz, info) != EFI_SUCCESS) {
        f->Close(f);
        return 0;
    }
    UINT64 fsize = ((EFI_FILE_INFO *)info)->FileSize;
    if (fsize == 0) {
        f->Close(f);
        return 0;
    }
    *out_file = f;
    *out_size = fsize;
    return 1;
}

// Read the whole open file into [dst, dst+size). The File protocol may return
// fewer bytes than requested per call, so loop until the file is consumed.
// Returns 1 on success, 0 if a read failed or EOF arrived early.
static int read_file_into(EFI_FILE_PROTOCOL *f, UINT64 dst, UINT64 size) {
    UINT64 off = 0;
    while (off < size) {
        UINTN chunk = (UINTN)(size - off);
        EFI_STATUS rs = f->Read(f, &chunk, (void *)(UINTN)(dst + off));
        if (rs != EFI_SUCCESS || chunk == 0) {
            return 0;
        }
        off += chunk;
    }
    return 1;
}

// U1g-2/3a/3b: the kernel A/B boot manifest (\EFI\swift-os\kernel-boot). Layout (LE):
//   0  u8[8] "SWOSKERN"   8  u32 version   12 u32 active(0/1)
//   16 u32 fallback(0/1)  20 u32 generation
//   24 u64 slotA_size   32 u8[32] slotA_sha256   (U1g-3a, integrity)
//   64 u64 slotB_size   72 u8[32] slotB_sha256   (104-byte signed body)
//   --- version 3 (U1g-3b, authenticity): ---
//   104 u8[64] Ed25519 signature over bytes [0,104)
// Returns 1 ONLY for a TRUSTED manifest: version 3 with a valid signature over
// its body, verified against the compiled-in image-signing key. Fills
// *active/*fallback/*gen and hashA/hashB. Returns 0 for absent / malformed /
// unsigned (v1/v2 — a signature is required) / bad-signature manifests; the
// caller then boots the embedded blob rather than honor an untrusted selection.
#define SWOSKERN_BODY_LEN 104
static int read_kernel_manifest(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st,
                                int *active, int *fallback, UINT32 *gen,
                                UINT8 hashA[32], UINT8 hashB[32]) {
    EFI_FILE_PROTOCOL *f = 0;
    UINT64 sz = 0;
    if (!open_esp_file(image_handle, st, KERNEL_MANIFEST_PATH, &f, &sz)) {
        return 0;
    }
    UINT8 buf[256];
    if (sz < SWOSKERN_BODY_LEN + 64 || sz > sizeof(buf)) { f->Close(f); return 0; }
    UINTN n = (UINTN)sz;
    EFI_STATUS rs = f->Read(f, &n, buf);
    f->Close(f);
    if (rs != EFI_SUCCESS || n < SWOSKERN_BODY_LEN + 64) {
        return 0;
    }
    static const char magic[8] = { 'S','W','O','S','K','E','R','N' };
    for (int i = 0; i < 8; i++) {
        if (buf[i] != (UINT8)magic[i]) return 0;
    }
    UINT32 version = ld32(buf + 8);
    if (version != 3) {
        puts16(st, "UEFI: kernel manifest is unsigned (version != 3), ignoring\r\n");
        return 0;
    }
    // Authenticity: the 64-byte signature at offset 104 must verify over the body.
    if (!ed25519_verify(buf + SWOSKERN_BODY_LEN, buf, SWOSKERN_BODY_LEN, efi_image_signing_pubkey)) {
        puts16(st, "UEFI: kernel manifest signature INVALID\r\n");
        return 0;
    }
    UINT32 a = ld32(buf + 12), fb = ld32(buf + 16);
    if (a > 1 || fb > 1) return 0;                // slot indices out of range
    *active = (int)a;
    *fallback = (int)fb;
    *gen = ld32(buf + 20);
    for (int i = 0; i < 32; i++) {
        hashA[i] = buf[32 + i];
        hashB[i] = buf[72 + i];
    }
    return 1;
}

// U1g-5a/5b/5c/5d: the ESP kernel-state record. Layout (512 bytes):
// "SWOSKSTA"(8) version(4) seq(4) attemptA(4) attemptB(4) stateA(4) stateB(4)
// lastBooted(4) active(4)
// ... reserved ... sha256[0,480) at offset 480. Not signed — the SHA-256 only
// guards against torn/garbage writes (the kernel images are independently
// signed/hashed, so the boot-state may be writable: the SWOSBOOT posture). The
// loader self-manages it: creates it on first boot, re-initializes it if corrupt.
#define KS_OFF_SEQ 12
#define KS_ATTEMPT(slot) ((slot) == 0 ? 16 : 20)
#define KS_STATE(slot)   ((slot) == 0 ? 24 : 28)
#define KS_LAST_BOOTED 32
#define KS_ACTIVE 36
#define KS_NO_SLOT 0xFFFFFFFF
#define KS_UNTRIED   0
#define KS_CONFIRMED 1
#define KS_FAILED    2
#define KS_MAX_ATTEMPTS 3

// Open the kernel-state file with `mode` (the same volume the loader booted from).
static EFI_FILE_PROTOCOL *loader_open_kstate(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st, UINT64 mode) {
    EFI_BOOT_SERVICES *bs = st->BootServices;
    EFI_GUID li_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
    EFI_GUID fs_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
    EFI_LOADED_IMAGE_PROTOCOL *li = 0;
    if (bs->HandleProtocol(image_handle, &li_guid, (void **)&li) != EFI_SUCCESS || !li) return 0;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs = 0;
    if (bs->HandleProtocol(li->DeviceHandle, &fs_guid, (void **)&fs) != EFI_SUCCESS || !fs) return 0;
    EFI_FILE_PROTOCOL *root = 0;
    if (fs->OpenVolume(fs, &root) != EFI_SUCCESS || !root) return 0;
    UINT64 attrs = (mode & EFI_FILE_MODE_CREATE) ? EFI_FILE_ARCHIVE : 0;
    EFI_FILE_PROTOCOL *f = 0;
    EFI_STATUS s = root->Open(root, &f, KERNEL_STATE_PATH, mode, attrs);
    root->Close(root);
    if (s != EFI_SUCCESS || !f) {
        if (mode & EFI_FILE_MODE_CREATE) {
            puts16(st, "UEFI: kernel-state open failed ");
            puthex(st, (UINT64)s);
            puts16(st, "\r\n");
        }
        return 0;
    }
    return f;
}

// Read the kernel-state into buf[512], validating magic/version/SHA-256;
// (re)initializes buf to a fresh record if absent or corrupt. Always leaves buf
// usable. Returns 1 if an existing valid record was read, 0 if reinitialized.
static int loader_read_kstate(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st, UINT8 *buf) {
    for (int i = 0; i < 512; i++) buf[i] = 0;
    int got = 0;
    EFI_FILE_PROTOCOL *f = loader_open_kstate(image_handle, st, EFI_FILE_MODE_READ);
    if (f) {
        UINTN want = 512;
        f->SetPosition(f, 0);
        f->Read(f, &want, buf);
        f->Close(f);
        got = (want >= 512);
    }
    static const char magic[8] = { 'S','W','O','S','K','S','T','A' };
    int valid = got;
    if (valid) for (int i = 0; i < 8; i++) if (buf[i] != (UINT8)magic[i]) { valid = 0; break; }
    if (valid && ld32(buf + 8) != 1) valid = 0;
    if (valid) {
        unsigned char h[32];
        sha256_hash(buf, 480, h);
        for (int i = 0; i < 32; i++) if (h[i] != buf[480 + i]) { valid = 0; break; }
    }
    if (!valid) {
        for (int i = 0; i < 512; i++) buf[i] = 0;
        for (int i = 0; i < 8; i++) buf[i] = (UINT8)magic[i];
        st32(buf + 8, 1);           // version
        st32(buf + KS_LAST_BOOTED, KS_NO_SLOT);
        st32(buf + KS_ACTIVE, KS_NO_SLOT);
        return 0;
    }
    return 1;
}

// Rehash and write buf[512] back to the ESP kernel-state (created if needed).
// Best-effort — a failure logs but never blocks boot.
static void loader_write_kstate(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st, UINT8 *buf) {
    unsigned char h[32];
    sha256_hash(buf, 480, h);
    for (int i = 0; i < 32; i++) buf[480 + i] = h[i];
    EFI_FILE_PROTOCOL *f = loader_open_kstate(image_handle, st,
                            EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE);
    if (!f) { puts16(st, "UEFI: kernel-state write failed (open)\r\n"); return; }
    f->SetPosition(f, 0);
    UINTN wlen = 512;
    EFI_STATUS ws = f->Write(f, &wlen, buf);
    f->Close(f); // Close flushes modified data per the UEFI spec
    if (ws != EFI_SUCCESS || wlen != 512) puts16(st, "UEFI: kernel-state write failed\r\n");
}

// U1g-3a: load a kernel slot's image into KERNEL_LOAD_ADDR and, if a hash is
// given, verify its SHA-256. Returns the image size, or 0 on any failure (file
// missing/unreadable, allocation failed, or integrity mismatch) with the staging
// pages freed so the caller can try another slot at the same address.
static UINT64 load_slot(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st, int slot,
                        const UINT8 *expect_hash) {
    EFI_BOOT_SERVICES *bs = st->BootServices;
    CHAR16 *path = slot == 0 ? KERNEL_A_PATH : KERNEL_B_PATH;
    EFI_FILE_PROTOCOL *f = 0;
    UINT64 size = 0;
    if (!open_esp_file(image_handle, st, path, &f, &size)) {
        return 0;
    }
    UINTN npages = (UINTN)((size + 0xFFF) / 0x1000);
    EFI_PHYSICAL_ADDRESS kaddr = KERNEL_LOAD_ADDR;
    if (bs->AllocatePages(AllocateAddress, EfiLoaderData, npages, &kaddr) != EFI_SUCCESS) {
        f->Close(f);
        return 0;
    }
    int okread = read_file_into(f, KERNEL_LOAD_ADDR, size);
    f->Close(f);
    if (!okread) {
        bs->FreePages(KERNEL_LOAD_ADDR, npages);
        return 0;
    }
    if (expect_hash) {
        unsigned char got[32];
        sha256_hash((const unsigned char *)(UINTN)KERNEL_LOAD_ADDR, size, got);
        int match = 1;
        for (int i = 0; i < 32; i++) {
            if (got[i] != expect_hash[i]) match = 0;
        }
        if (!match) {
            puts16(st, "UEFI: kernel slot ");
            puts16(st, slot == 0 ? "A" : "B");
            puts16(st, " FAILED integrity check (sha256)\r\n");
            bs->FreePages(KERNEL_LOAD_ADDR, npages);
            return 0;
        }
        puts16(st, "UEFI: kernel slot ");
        puts16(st, slot == 0 ? "A" : "B");
        puts16(st, " integrity verified (sha256)\r\n");
    }
    return size;
}

// H3: load the packed base image from the ESP into a RAM region below 2 GiB
// (the kernel identity-maps 0x4000_0000..0x7FFF_FFFF as normal memory), so the
// kernel can mount the read-only base FS from RAM with no block driver. Fills
// *out_base/*out_size, or leaves both 0 on any failure (the kernel then falls
// back to a virtio-blk base disk if one is attached). Uses boot services, so it
// must run before ExitBootServices.
static void load_base_ramdisk(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st,
                              UINT64 *out_base, UINT64 *out_size) {
    *out_base = 0;
    *out_size = 0;
    EFI_BOOT_SERVICES *bs = st->BootServices;
    EFI_FILE_PROTOCOL *f = 0;
    UINT64 size = 0;
    if (!open_esp_file(image_handle, st, BASE_IMG_PATH, &f, &size)) {
        puts16(st, "UEFI: no base.img on ESP (kernel will use a block disk)\r\n");
        return;
    }
    UINTN npages = (UINTN)((size + 0xFFF) / 0x1000);
    // AllocateMaxAddress bounds the TOP of the region, keeping the image below
    // 2 GiB and thus inside the kernel's identity-mapped normal-RAM block.
    EFI_PHYSICAL_ADDRESS addr = 0x80000000ULL;
    if (bs->AllocatePages(AllocateMaxAddress, EfiLoaderData, npages, &addr) != EFI_SUCCESS) {
        f->Close(f);
        puts16(st, "UEFI: base.img AllocatePages failed\r\n");
        return;
    }
    int ok = read_file_into(f, addr, size);
    f->Close(f);
    if (!ok) {
        bs->FreePages(addr, npages);
        puts16(st, "UEFI: base.img read failed\r\n");
        return;
    }
    clean_dcache(addr, size);
    *out_base = (UINT64)addr;
    *out_size = size;
    puts16(st, "UEFI: base.img staged in RAM at ");
    puthex(st, addr);
    puts16(st, " size ");
    puthex(st, size);
    puts16(st, "\r\n");
}

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
    UINT64 rsdp = 0;   // H5: ACPI RSDP, forwarded to the kernel for platform discovery.
    for (UINTN i = 0; i < st->NumberOfTableEntries; i++) {
        if (guid_eq(&st->ConfigurationTable[i].VendorGuid, &acpi)) {
            rsdp = (UINT64)(UINTN)st->ConfigurationTable[i].VendorTable;
        }
    }
    puts16(st, "UEFI: ACPI 2.0 table ");
    if (rsdp) { puts16(st, "present "); puthex(st, rsdp); puts16(st, "\r\n"); }
    else { puts16(st, "absent\r\n"); }

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

    // U1g: load the kernel image from a file on the ESP (decoupled from the loader
    // binary so it can be A/B-staged). The kernel A/B manifest is TRUSTED only if
    // it is a v3 manifest with a valid Ed25519 signature over its body (U1g-3b,
    // authenticity); then it selects the active slot (kernelA.bin / kernelB.bin)
    // and load_slot verifies that slot's SHA-256 (U1g-3a, integrity), rolling back
    // to the other slot if the active one is missing or fails its hash. If there
    // is NO trusted manifest (absent / unsigned / bad signature), the loader boots
    // its own embedded blob rather than honor an untrusted slot selection. All of
    // this happens before ExitBootServices.
    UINTN blob_size = (UINTN)(kernel_blob_end - kernel_blob);

    int active = 0, fallback = 1;
    UINT32 kgen = 0;
    UINT8 hashA[32], hashB[32];
    int trusted = read_kernel_manifest(image_handle, st, &active, &fallback, &kgen, hashA, hashB);

    UINTN ksize = 0;
    int loaded_slot = -1;
    if (trusted) {
        int manifest_active = active;
        puts16(st, "UEFI: kernel A/B manifest active slot ");
        puts16(st, manifest_active == 0 ? "A" : "B");
        puts16(st, " gen ");
        puthex(st, kgen);
        puts16(st, " (signature OK)\r\n");

        // Read the writable boot-state. U1g-5d moves mutable active selection
        // here: the signed manifest authenticates slot metadata and hashes, while
        // kernel-state carries the current active slot so runtime activation no
        // longer needs a pre-signed alternate manifest.
        UINT8 ks[512];
        loader_read_kstate(image_handle, st, ks);
        UINT32 state_active = ld32(ks + KS_ACTIVE);
        if (state_active <= 1) {
            active = (int)state_active;
        } else {
            active = manifest_active;
        }
        fallback = active == 0 ? 1 : 0;
        puts16(st, "UEFI: kernel boot-state active slot ");
        puts16(st, active == 0 ? "A" : "B");
        if (active != manifest_active) {
            puts16(st, " (overrides manifest)\r\n");
        } else {
            puts16(st, "\r\n");
        }

        // Apply attempt-based rollback (U1g-5b, the U1d analogue): an
        // unconfirmed active slot that has exhausted its boot attempts is presumed
        // unhealthy, so prefer the other slot. Otherwise try the active slot first
        // and fall back on a load/hash failure.
        UINT32 attemptS = ld32(ks + KS_ATTEMPT(active));
        UINT32 stateS = ld32(ks + KS_STATE(active));

        int first = active, second = fallback;
        if (stateS != KS_CONFIRMED && attemptS >= KS_MAX_ATTEMPTS && fallback != active) {
            first = fallback; second = active;
            puts16(st, "UEFI: kernel slot ");
            puts16(st, active == 0 ? "A" : "B");
            puts16(st, " unconfirmed after ");
            puthex(st, attemptS);
            puts16(st, " attempts, rolling back to slot ");
            puts16(st, fallback == 0 ? "A\r\n" : "B\r\n");
        }

        UINT64 sz = load_slot(image_handle, st, first, first == 0 ? hashA : hashB);
        if (sz) {
            loaded_slot = first; ksize = (UINTN)sz;
        } else if (second != first) {
            puts16(st, "UEFI: kernel slot unusable, trying slot ");
            puts16(st, second == 0 ? "A\r\n" : "B\r\n");
            sz = load_slot(image_handle, st, second, second == 0 ? hashA : hashB);
            if (sz) { loaded_slot = second; ksize = (UINTN)sz; }
        }

        if (loaded_slot >= 0) {
            // Persist boot-state: mark the displaced active slot FAILED, publish
            // the actually booted slot as active, and count this attempt (a
            // CONFIRMED slot stops counting).
            if (loaded_slot != active) st32(ks + KS_STATE(active), KS_FAILED);
            UINT32 attempt = ld32(ks + KS_ATTEMPT(loaded_slot));
            if (ld32(ks + KS_STATE(loaded_slot)) != KS_CONFIRMED) {
                attempt += 1;
                st32(ks + KS_ATTEMPT(loaded_slot), attempt);
            }
            st32(ks + KS_ACTIVE, (UINT32)loaded_slot);
            st32(ks + KS_LAST_BOOTED, (UINT32)loaded_slot);
            st32(ks + KS_OFF_SEQ, ld32(ks + KS_OFF_SEQ) + 1);
            loader_write_kstate(image_handle, st, ks);

            puts16(st, "UEFI: kernel loaded from ESP file ");
            puthex(st, (UINT64)ksize);
            puts16(st, " bytes\r\n");
            puts16(st, "UEFI: booted kernel slot ");
            puts16(st, loaded_slot == 0 ? "A\r\n" : "B\r\n");
            puts16(st, "UEFI: kernel slot ");
            puts16(st, loaded_slot == 0 ? "A" : "B");
            puts16(st, " boot attempt ");
            puthex(st, attempt);
            puts16(st, "\r\n");
        }
    }

    if (loaded_slot < 0) {
        // No slot file was usable: reserve and stage the embedded blob in place.
        UINTN npages = (blob_size + 0xFFF) / 0x1000;
        EFI_PHYSICAL_ADDRESS kaddr = KERNEL_LOAD_ADDR;
        EFI_STATUS s = bs->AllocatePages(AllocateAddress, EfiLoaderData, npages, &kaddr);
        if (s != EFI_SUCCESS) {
            puts16(st, "UEFI: FAIL could not reserve kernel load address ");
            puthex(st, (UINT64)s);
            puts16(st, "\r\n");
            for (;;) {}
        }
        copy_mem((unsigned char *)(UINTN)KERNEL_LOAD_ADDR, kernel_blob, blob_size);
        ksize = blob_size;
        puts16(st, "UEFI: no usable ESP kernel slot, using embedded blob\r\n");
    }
    clean_dcache(KERNEL_LOAD_ADDR, ksize);

    // H3: stage the read-only base image into RAM (must precede ExitBootServices).
    UINT64 ramdisk_base = 0, ramdisk_size = 0;
    load_base_ramdisk(image_handle, st, &ramdisk_base, &ramdisk_size);

    puts16(st, "UEFI: kernel staged, launching (no more firmware output)\r\n");

    // Take ownership of the machine: get the current memory map key, then exit
    // boot services. Retry once if the map changed underneath us.
    UINTN msize = sizeof(mmap_buf), mkey = 0, dsize = 0;
    UINT32 dver = 0;
    bs->GetMemoryMap(&msize, mmap_buf, &mkey, &dsize, &dver);
    EFI_STATUS s = bs->ExitBootServices(image_handle, mkey);
    if (s != EFI_SUCCESS) {
        msize = sizeof(mmap_buf);
        bs->GetMemoryMap(&msize, mmap_buf, &mkey, &dsize, &dver);
        s = bs->ExitBootServices(image_handle, mkey);
    }

    // Firmware is gone. Mask interrupts (its timer is still armed but unhandled)
    // and enter the kernel with the device-tree pointer in x0.
    __asm__ volatile("msr daifset, #0xf" ::: "memory");

    // x0=dtb, x1=framebuffer base, x2=(width<<32|height), x3=(stride<<32|format),
    // x4=ramdisk base, x5=ramdisk size (H3), x6=ACPI RSDP (H5; 0 when absent).
    typedef void (*kernel_entry_t)(UINT64, UINT64, UINT64, UINT64, UINT64, UINT64, UINT64);
    kernel_entry_t enter = (kernel_entry_t)(UINTN)KERNEL_LOAD_ADDR;
    enter((UINT64)(UINTN)dtb, fb_base, fb_dims, fb_strfmt, ramdisk_base, ramdisk_size, rsdp);

    for (;;) {}
    return EFI_SUCCESS;
}
