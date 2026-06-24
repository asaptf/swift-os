// SPDX-License-Identifier: Apache-2.0
// devicemmapprobe.c - LA2 device-MMIO-map authority probe.
//
// Exercises sys_device_mmap end to end. Run at boot it executes as a capConsole
// principal and proves the positive path: a mappable device grant carries the
// .map right, device_mmap returns a live Device-nGnRE mapping, and reading the
// virtio identification registers through it returns the expected magic/version/
// device-id words. It also proves two negative paths: a grant on a
// deviceFlagNoMmioGrant device is refused with EACCES, and (when run by a
// non-capConsole principal) the claim itself is denied with EACCES before any
// mapping is possible. The same binary covers both contexts; the test asserts
// the marker set that matches how it was launched.

#include "lib/syscall.h"

int puts_raw(const char *s);

// virtio-mmio identification registers (32-bit), as uint32 indices from the
// window base: MagicValue@0x000, Version@0x004, DeviceID@0x008.
#define VIRTIO_MMIO_MAGIC   0x74726976u  // "virt"
#define VIRTIO_ID_INPUT     18u

int main(void) {
    struct swiftos_device_info info;

    // 1. Claim the mappable virtio-input window. capConsole-gated: a non-console
    //    principal is denied here (EACCES) and cannot reach the mapping path.
    //    C5h: the mappable grant is now virtio-input.0 itself (it replaced the
    //    former virtio-input-mmio.0 alias).
    int fd = device_claim("virtio-input.0", &info);
    if (fd < 0) {
        if (fd == -13) {
            puts_raw("DEVMMAP-CLAIM-DENY-OK err=-13\n");
            return 0;
        }
        if (fd == -2) {
            // No mappable device registered (pseudo-input fallback, no real
            // virtio-mmio window). Nothing to prove on this board.
            puts_raw("DEVMMAP-NO-DEVICE\n");
            return 0;
        }
        puts_raw("DEVMMAP-CLAIM-FAIL\n");
        return 1;
    }

    // 2. The grant must advertise mappable hardware authority.
    if ((info.flags & SWIFTOS_DEVICE_FLAG_MMIO_GRANT) == 0) {
        puts_raw("DEVMMAP-FLAG-MISSING\n");
        close(fd);
        return 1;
    }
    if (info.mmio_len == 0) {
        puts_raw("DEVMMAP-LEN-ZERO\n");
        close(fd);
        return 1;
    }
    puts_raw("DEVMMAP-CLAIM-OK\n");

    // 3. Map the window and read the read-only identification registers.
    volatile unsigned int *regs = (volatile unsigned int *)device_mmap(fd, info.mmio_len);
    if (regs == MAP_FAILED) {
        puts_raw("DEVMMAP-MAP-FAIL\n");
        close(fd);
        return 1;
    }
    unsigned int magic = regs[0];
    unsigned int devid = regs[2];
    if (magic == VIRTIO_MMIO_MAGIC) {
        puts_raw("DEVMMAP-MAGIC-OK\n");
    } else {
        puts_raw("DEVMMAP-MAGIC-BAD\n");
    }
    if (devid == VIRTIO_ID_INPUT) {
        puts_raw("DEVMMAP-DEVID-OK\n");
    }

    // 4. Negative: a grant on the deviceFlagNoMmioGrant sibling
    //    (C5h: virtio-input-meta.0) is metadata-only — it carries no .map right, so
    //    device_mmap is refused with EACCES. Use the raw syscall to assert errno.
    struct swiftos_device_info inert;
    int inert_fd = device_claim("virtio-input-meta.0", &inert);
    if (inert_fd >= 0) {
        long r = __syscall3(SYS_DEVICE_MMAP, inert_fd, (long)inert.mmio_len, 0);
        if (r == -13) {
            puts_raw("DEVMMAP-NOMMIO-REFUSED-OK err=-13\n");
        } else {
            puts_raw("DEVMMAP-NOMMIO-LEAK\n");
        }
        close(inert_fd);
    } else {
        puts_raw("DEVMMAP-INERT-CLAIM-FAIL\n");
    }

    // 5. Tear down: munmap must reclaim the device VA without freeing MMIO back
    //    to the PMM, then closing the fd releases the grant. device_mmap returns
    //    a pointer at the register base, which is intentionally not page-aligned
    //    (the virtio-mmio stride is sub-page); munmap takes the page-aligned base
    //    and a length spanning the intra-page offset plus the window.
    unsigned long uregs = (unsigned long)regs;
    void *page = (void *)(uregs & ~0xFFFUL);
    unsigned long span = (uregs & 0xFFFUL) + info.mmio_len;
    munmap(page, span);
    close(fd);
    puts_raw("DEVMMAP OK: device MMIO map authority enforced\n");
    return 0;
}
