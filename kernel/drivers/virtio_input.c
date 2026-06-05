// virtio_input.c — minimal polled virtio-input (keyboard) driver.
//
// Gives the graphical QEMU window (-device virtio-keyboard-device) a keyboard:
// the virt board exposes virtio devices over virtio-mmio (32 slots at
// 0x0A000000). We find the input device, set up its event virtqueue with a few
// receive buffers, and POLL the used ring — no IRQ wiring. virtio_kbd_getchar()
// decodes evdev key presses into ASCII; the kernel drains it on each timer tick
// and feeds the tty (kernel/main.swift), so typing reaches the busybox shell.
//
// The virtqueue rings live in cacheable RAM that QEMU's device reads/writes by
// DMA, so we clean what we write and invalidate what the device writes. (Under
// TCG these are effectively no-ops; under a caching accelerator they are not.)

#include <stdint.h>

#define VIRTIO_MMIO_BASE   0x0A000000ULL
#define VIRTIO_MMIO_STRIDE 0x200
#define VIRTIO_MMIO_COUNT  32
#define VIRTIO_ID_INPUT    18

// virtio-mmio register offsets.
#define R_MAGIC      0x000
#define R_VERSION    0x004
#define R_DEVID      0x008
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

#define S_ACK    1
#define S_DRV    2
#define S_DRVOK  4
#define S_FEATOK 8

#define QSZ 8
#define VIRTQ_DESC_F_WRITE 2

struct vq_desc { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; };
struct vq_avail { uint16_t flags; uint16_t idx; uint16_t ring[QSZ]; uint16_t used_event; };
struct vq_used_elem { uint32_t id; uint32_t len; };
struct vq_used { uint16_t flags; uint16_t idx; struct vq_used_elem ring[QSZ]; uint16_t avail_event; };

static volatile uint8_t *g_mmio = 0;
static struct vq_desc  g_desc[QSZ]  __attribute__((aligned(64)));
static struct vq_avail g_avail      __attribute__((aligned(64)));
static struct vq_used  g_used       __attribute__((aligned(64)));
static uint8_t         g_evbuf[QSZ][8] __attribute__((aligned(64)));
static uint32_t g_qn = 0;
static uint16_t g_last_used = 0;

static uint8_t g_pending[64];
static int g_phead = 0, g_ptail = 0;
static int g_shift = 0;

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

// US-keyboard evdev keycode -> ASCII (unshifted and shifted).
static const char km[128] = {
    [1]=27, [2]='1',[3]='2',[4]='3',[5]='4',[6]='5',[7]='6',[8]='7',[9]='8',[10]='9',[11]='0',
    [12]='-',[13]='=',[14]=8,[15]='\t',
    [16]='q',[17]='w',[18]='e',[19]='r',[20]='t',[21]='y',[22]='u',[23]='i',[24]='o',[25]='p',
    [26]='[',[27]=']',[28]='\r',
    [30]='a',[31]='s',[32]='d',[33]='f',[34]='g',[35]='h',[36]='j',[37]='k',[38]='l',[39]=';',[40]='\'',[41]='`',
    [43]='\\',[44]='z',[45]='x',[46]='c',[47]='v',[48]='b',[49]='n',[50]='m',[51]=',',[52]='.',[53]='/',
    [57]=' ',
};
static const char km_shift[128] = {
    [2]='!',[3]='@',[4]='#',[5]='$',[6]='%',[7]='^',[8]='&',[9]='*',[10]='(',[11]=')',
    [12]='_',[13]='+',[14]=8,[15]='\t',
    [16]='Q',[17]='W',[18]='E',[19]='R',[20]='T',[21]='Y',[22]='U',[23]='I',[24]='O',[25]='P',
    [26]='{',[27]='}',[28]='\r',
    [30]='A',[31]='S',[32]='D',[33]='F',[34]='G',[35]='H',[36]='J',[37]='K',[38]='L',[39]=':',[40]='"',[41]='~',
    [43]='|',[44]='Z',[45]='X',[46]='C',[47]='V',[48]='B',[49]='N',[50]='M',[51]='<',[52]='>',[53]='?',
    [57]=' ',
};

static uint32_t g_dbg_version = 0;

// Returns a small diagnostic code: 0 = no input device found, otherwise
// version*1000 + queue_size once the queue is up.
int virtio_kbd_init(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; i++) {
        volatile uint8_t *m = (volatile uint8_t *)(VIRTIO_MMIO_BASE + (uint64_t)i * VIRTIO_MMIO_STRIDE);
        if (*(volatile uint32_t *)(m + R_MAGIC) != 0x74726976) continue; // "virt"
        if (*(volatile uint32_t *)(m + R_DEVID) != VIRTIO_ID_INPUT) continue;
        g_mmio = m;
        break;
    }
    if (!g_mmio) return 0;
    g_dbg_version = r32(R_VERSION);

    w32(R_STATUS, 0);                  // reset
    w32(R_STATUS, S_ACK);
    w32(R_STATUS, S_ACK | S_DRV);
    w32(R_DRVFEATSEL, 1); w32(R_DRVFEAT, 1); // accept VIRTIO_F_VERSION_1 (bit 32)
    w32(R_DRVFEATSEL, 0); w32(R_DRVFEAT, 0);
    w32(R_STATUS, S_ACK | S_DRV | S_FEATOK);
    if (!(r32(R_STATUS) & S_FEATOK)) { g_mmio = 0; return -1; }

    w32(R_QSEL, 0);
    uint32_t max = r32(R_QNUMMAX);
    if (max == 0) { g_mmio = 0; return -2; }
    g_qn = max < QSZ ? max : QSZ;
    w32(R_QNUM, g_qn);

    for (uint32_t j = 0; j < g_qn; j++) {
        g_desc[j].addr = (uint64_t)(uintptr_t)g_evbuf[j];
        g_desc[j].len = 8;
        g_desc[j].flags = VIRTQ_DESC_F_WRITE; // device writes events into it
        g_desc[j].next = 0;
    }
    g_avail.flags = 0; g_avail.idx = 0;
    g_used.flags = 0; g_used.idx = 0;
    clean(g_desc, sizeof(g_desc));
    clean(&g_used, sizeof(g_used));

    uint64_t da = (uint64_t)(uintptr_t)g_desc;
    uint64_t aa = (uint64_t)(uintptr_t)&g_avail;
    uint64_t ua = (uint64_t)(uintptr_t)&g_used;
    w32(R_QDESCL, (uint32_t)da); w32(R_QDESCH, (uint32_t)(da >> 32));
    w32(R_QDRVL,  (uint32_t)aa); w32(R_QDRVH,  (uint32_t)(aa >> 32));
    w32(R_QDEVL,  (uint32_t)ua); w32(R_QDEVH,  (uint32_t)(ua >> 32));
    w32(R_QREADY, 1);
    w32(R_STATUS, S_ACK | S_DRV | S_FEATOK | S_DRVOK);

    // Offer every buffer to the device.
    for (uint32_t j = 0; j < g_qn; j++) g_avail.ring[j] = (uint16_t)j;
    g_avail.idx = (uint16_t)g_qn;
    clean(&g_avail, sizeof(g_avail));
    w32(R_QNOTIFY, 0);
    return (int)(g_dbg_version * 1000 + g_qn);
}

static void pump(void) {
    if (!g_mmio) return;
    invalidate(&g_used, sizeof(g_used));
    uint16_t uidx = g_used.idx;
    while (g_last_used != uidx) {
        uint32_t id = g_used.ring[g_last_used % g_qn].id % g_qn;
        invalidate(g_evbuf[id], 8);
        uint16_t type = (uint16_t)(g_evbuf[id][0] | (g_evbuf[id][1] << 8));
        uint16_t code = (uint16_t)(g_evbuf[id][2] | (g_evbuf[id][3] << 8));
        uint32_t value = (uint32_t)(g_evbuf[id][4] | (g_evbuf[id][5] << 8) |
                                    (g_evbuf[id][6] << 16) | (g_evbuf[id][7] << 24));
        if (type == 1) { // EV_KEY
            if (code == 42 || code == 54) {        // L/R shift
                g_shift = (value != 0);
            } else if (value == 1 || value == 2) { // press or auto-repeat
                char c = g_shift ? km_shift[code & 0x7f] : km[code & 0x7f];
                if (c) {
                    int nt = (g_ptail + 1) % 64;
                    if (nt != g_phead) { g_pending[g_ptail] = (uint8_t)c; g_ptail = nt; }
                }
            }
        }
        // Hand the buffer back to the device.
        g_avail.ring[g_avail.idx % g_qn] = (uint16_t)id;
        g_avail.idx++;
        clean(&g_avail, sizeof(g_avail));
        g_last_used++;
    }
    w32(R_QNOTIFY, 0);
    uint32_t is = r32(R_ISTATUS);
    if (is) w32(R_IACK, is); // keep the device quiet even though we poll
}

// Return the next typed ASCII byte, or -1 if nothing is queued.
int virtio_kbd_getchar(void) {
    pump();
    if (g_phead == g_ptail) return -1;
    uint8_t b = g_pending[g_phead];
    g_phead = (g_phead + 1) % 64;
    return (int)b;
}
