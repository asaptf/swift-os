// virtio_blk.c — minimal polled virtio 1.0 (modern, MMIO) block driver.
//
// M11b: gives the kernel synchronous, read-only access to a virtio-blk disk so
// the packed read-only base image can be served from a real disk instead of
// kernel literals (M11c). The QEMU `virt` board exposes virtio transports over
// virtio-mmio; we scan the device-tree-discovered window (kernel HAL) for a
// block device (device id 2), negotiate VIRTIO_F_VERSION_1, bring up one
// request virtqueue, and read 512-byte sectors one at a time by driving the
// descriptor chain and POLLING the used ring — no IRQ wiring, like the
// virtio-input keyboard.
//
// Single-threaded blocking reads are fine for a read-only base. The rings and
// the bounce buffer live in cacheable RAM that QEMU reads/writes by DMA, so we
// clean what the device reads and invalidate what it writes. (No-ops under TCG,
// real work under a caching accelerator.)

#include <stdint.h>

// virtio-mmio register offsets (same layout as virtio_input.c).
#define R_MAGIC      0x000
#define R_VERSION    0x004
#define R_DEVID      0x008
#define R_DEVFEAT    0x010
#define R_DEVFEATSEL 0x014
#define R_DRVFEAT    0x020
#define R_DRVFEATSEL 0x024
#define R_QSEL       0x030
#define R_QNUMMAX    0x034
#define R_QNUM       0x038
#define R_QREADY     0x044
#define R_QNOTIFY    0x050
#define R_ISTATUS    0x060
#define R_IACK       0x064
#define R_STATUS     0x070
#define R_QDESCL     0x080
#define R_QDESCH     0x084
#define R_QDRVL      0x090
#define R_QDRVH      0x094
#define R_QDEVL      0x0a0
#define R_QDEVH      0x0a4
#define R_CONFIG     0x100

#define VIRTIO_MAGIC    0x74726976 // "virt"
#define VIRTIO_ID_BLOCK 2

#define S_ACK    1
#define S_DRV    2
#define S_DRVOK  4
#define S_FEATOK 8

#define QSZ 8
#define VIRTQ_DESC_F_NEXT  1
#define VIRTQ_DESC_F_WRITE 2

#define VIRTIO_BLK_T_IN  0  // read from disk into memory
#define VIRTIO_BLK_S_OK  0

#define SECTOR_SIZE 512

struct vq_desc { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; };
struct vq_avail { uint16_t flags; uint16_t idx; uint16_t ring[QSZ]; uint16_t used_event; };
struct vq_used_elem { uint32_t id; uint32_t len; };
struct vq_used { uint16_t flags; uint16_t idx; struct vq_used_elem ring[QSZ]; uint16_t avail_event; };

// virtio-blk request header (device-readable part of the chain).
struct blk_req_hdr { uint32_t type; uint32_t reserved; uint64_t sector; };

static volatile uint8_t *g_mmio = 0;
static struct vq_desc  g_desc[QSZ]  __attribute__((aligned(64)));
static struct vq_avail g_avail      __attribute__((aligned(64)));
static struct vq_used  g_used       __attribute__((aligned(64)));
static struct blk_req_hdr g_hdr     __attribute__((aligned(64)));
static uint8_t  g_status            __attribute__((aligned(64)));
static uint8_t  g_bounce[SECTOR_SIZE] __attribute__((aligned(64)));
static uint32_t g_qn = 0;
static uint16_t g_last_used = 0;
static uint64_t g_capacity = 0; // device capacity in 512-byte sectors

static inline void w32(uint32_t off, uint32_t v) { *(volatile uint32_t *)(g_mmio + off) = v; }
static inline uint32_t r32(uint32_t off) { return *(volatile uint32_t *)(g_mmio + off); }

static void clean(void *p, uint64_t n) {
    uint64_t a = (uint64_t)(uintptr_t)p & ~63ULL;
    for (; a < (uint64_t)(uintptr_t)p + n; a += 64) {
        __asm__ volatile("dc cvac, %0" :: "r"(a) : "memory");
    }
    __asm__ volatile("dsb sy" ::: "memory");
}

static void invalidate(void *p, uint64_t n) {
    __asm__ volatile("dsb sy" ::: "memory");
    uint64_t a = (uint64_t)(uintptr_t)p & ~63ULL;
    for (; a < (uint64_t)(uintptr_t)p + n; a += 64) {
        __asm__ volatile("dc ivac, %0" :: "r"(a) : "memory");
    }
    __asm__ volatile("dsb sy" ::: "memory");
}

// Scan the virtio-mmio window (base/stride/count from the HAL) for a block
// device and bring up its request queue. Returns the capacity in 512-byte
// sectors, or 0 if no usable block device was found.
uint64_t virtio_blk_init(uint64_t base, uint64_t stride, uint32_t count) {
    g_mmio = 0;
    for (uint32_t i = 0; i < count; i++) {
        volatile uint8_t *m = (volatile uint8_t *)(uintptr_t)(base + (uint64_t)i * stride);
        if (*(volatile uint32_t *)(m + R_MAGIC) != VIRTIO_MAGIC) continue;
        if (*(volatile uint32_t *)(m + R_VERSION) != 2) continue; // modern only
        if (*(volatile uint32_t *)(m + R_DEVID) != VIRTIO_ID_BLOCK) continue;
        g_mmio = m;
        break;
    }
    if (!g_mmio) return 0;

    w32(R_STATUS, 0);                  // reset
    w32(R_STATUS, S_ACK);
    w32(R_STATUS, S_ACK | S_DRV);
    // Accept only VIRTIO_F_VERSION_1 (feature bit 32); ignore block features.
    w32(R_DRVFEATSEL, 1); w32(R_DRVFEAT, 1);
    w32(R_DRVFEATSEL, 0); w32(R_DRVFEAT, 0);
    w32(R_STATUS, S_ACK | S_DRV | S_FEATOK);
    if (!(r32(R_STATUS) & S_FEATOK)) { g_mmio = 0; return 0; }

    w32(R_QSEL, 0);
    uint32_t max = r32(R_QNUMMAX);
    if (max == 0) { g_mmio = 0; return 0; }
    g_qn = max < QSZ ? max : QSZ;
    w32(R_QNUM, g_qn);

    g_avail.flags = 0; g_avail.idx = 0;
    g_used.flags = 0; g_used.idx = 0;
    g_last_used = 0;
    clean(&g_avail, sizeof(g_avail));
    clean(&g_used, sizeof(g_used));

    uint64_t da = (uint64_t)(uintptr_t)g_desc;
    uint64_t aa = (uint64_t)(uintptr_t)&g_avail;
    uint64_t ua = (uint64_t)(uintptr_t)&g_used;
    w32(R_QDESCL, (uint32_t)da); w32(R_QDESCH, (uint32_t)(da >> 32));
    w32(R_QDRVL,  (uint32_t)aa); w32(R_QDRVH,  (uint32_t)(aa >> 32));
    w32(R_QDEVL,  (uint32_t)ua); w32(R_QDEVH,  (uint32_t)(ua >> 32));
    w32(R_QREADY, 1);
    w32(R_STATUS, S_ACK | S_DRV | S_FEATOK | S_DRVOK);

    // Capacity (config space offset 0): number of 512-byte sectors, LE u64.
    uint32_t lo = r32(R_CONFIG + 0);
    uint32_t hi = r32(R_CONFIG + 4);
    g_capacity = ((uint64_t)hi << 32) | lo;
    return g_capacity;
}

int virtio_blk_available(void) { return g_mmio != 0; }
uint64_t virtio_blk_capacity(void) { return g_capacity; }

// Read one 512-byte sector into `buf`. Returns 0 on success, negative on error.
// Blocking: issues the request and spins on the used ring until it completes.
int virtio_blk_read(uint64_t sector, void *buf) {
    if (!g_mmio) return -1;
    if (g_capacity != 0 && sector >= g_capacity) return -2;

    g_hdr.type = VIRTIO_BLK_T_IN;
    g_hdr.reserved = 0;
    g_hdr.sector = sector;
    g_status = 0xFF;
    clean(&g_hdr, sizeof(g_hdr));
    clean(&g_status, sizeof(g_status));
    clean(g_bounce, sizeof(g_bounce));

    // Three-descriptor chain: header (device-read), data (device-write),
    // status (device-write).
    g_desc[0].addr = (uint64_t)(uintptr_t)&g_hdr;
    g_desc[0].len = sizeof(g_hdr);
    g_desc[0].flags = VIRTQ_DESC_F_NEXT;
    g_desc[0].next = 1;
    g_desc[1].addr = (uint64_t)(uintptr_t)g_bounce;
    g_desc[1].len = SECTOR_SIZE;
    g_desc[1].flags = VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE;
    g_desc[1].next = 2;
    g_desc[2].addr = (uint64_t)(uintptr_t)&g_status;
    g_desc[2].len = 1;
    g_desc[2].flags = VIRTQ_DESC_F_WRITE;
    g_desc[2].next = 0;
    clean(g_desc, sizeof(g_desc));

    g_avail.ring[g_avail.idx % g_qn] = 0; // chain head descriptor index
    g_avail.idx++;
    clean(&g_avail, sizeof(g_avail));

    w32(R_QNOTIFY, 0);

    // Poll the used ring for completion.
    uint16_t target = g_last_used + 1;
    for (;;) {
        invalidate(&g_used, sizeof(g_used));
        if (g_used.idx == target) break;
    }
    g_last_used = target;

    uint32_t is = r32(R_ISTATUS);
    if (is) w32(R_IACK, is);

    invalidate(&g_status, sizeof(g_status));
    if (g_status != VIRTIO_BLK_S_OK) return -3;

    invalidate(g_bounce, sizeof(g_bounce));
    uint8_t *dst = (uint8_t *)buf;
    for (int i = 0; i < SECTOR_SIZE; i++) dst[i] = g_bounce[i];
    return 0;
}
