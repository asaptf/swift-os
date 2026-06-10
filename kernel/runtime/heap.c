// heap.c — early kernel heap and Swift allocation hooks.
//
// The exported swift_* names are runtime ABI hooks, so keep them in C rather
// than declaring reserved Swift runtime symbols from Swift code.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "../arch/aarch64/io.h"

extern uint8_t __heap_start[];
extern uint8_t __heap_end[];

static uintptr_t heap_cursor;
static uintptr_t heap_limit;
static bool heap_initialized;
static uint64_t heap_lock_word;
static uint64_t heap_lock_acquire_count;
static uint64_t heap_lock_contention_count;

uintptr_t __stack_chk_guard = 0x21534654534f5357ULL;

static uintptr_t align_up(uintptr_t value, uintptr_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static uint64_t heap_lock(void) {
    uint64_t daif = irq_save();
    bool contended = false;
    for (;;) {
        uint64_t expected = 0;
        if (smp_atomic_compare_exchange_u64(&heap_lock_word, &expected, 1)) {
            if (contended) {
                smp_atomic_fetch_add_u64(&heap_lock_contention_count, 1);
            }
            smp_atomic_fetch_add_u64(&heap_lock_acquire_count, 1);
            smp_dmb_ish();
            return daif;
        }
        contended = true;
        smp_dmb_ishld();
    }
}

static void heap_unlock(uint64_t daif) {
    smp_dmb_ish();
    smp_atomic_store_u64(&heap_lock_word, 0);
    irq_restore(daif);
}

static void heap_init_unlocked(void) {
    heap_cursor = (uintptr_t)__heap_start;
    heap_limit = (uintptr_t)__heap_end;
    heap_initialized = true;
}

void swiftos_heap_init(void) {
    uint64_t daif = heap_lock();
    if (!heap_initialized) {
        heap_init_unlocked();
    }
    heap_unlock(daif);
}

uintptr_t swiftos_kernel_heap_used_bytes(void) {
    uint64_t daif = heap_lock();
    if (!heap_initialized) {
        heap_unlock(daif);
        return 0;
    }
    uintptr_t used = heap_cursor - (uintptr_t)__heap_start;
    heap_unlock(daif);
    return used;
}

void *swiftos_kernel_alloc(uintptr_t byte_count, uintptr_t alignment) {
    uint64_t daif = heap_lock();
    if (!heap_initialized) {
        heap_init_unlocked();
    }

    uintptr_t effective_alignment = alignment < 16 ? 16 : alignment;
    uintptr_t start = align_up(heap_cursor, effective_alignment);
    uintptr_t end = start + byte_count;
    if (end < start || end > heap_limit) {
        heap_unlock(daif);
        return NULL;
    }

    heap_cursor = end;
    heap_unlock(daif);
    return (void *)start;
}

uint64_t swiftos_heap_lock_acquire_count(void) {
    return smp_atomic_load_u64(&heap_lock_acquire_count);
}

uint64_t swiftos_heap_lock_contention_count(void) {
    return smp_atomic_load_u64(&heap_lock_contention_count);
}

bool swiftos_heap_lock_boundary_self_test(void) {
    if (smp_atomic_load_u64(&heap_lock_word) != 0 ||
        swiftos_heap_lock_acquire_count() == 0) {
        return false;
    }

    uint64_t daif = heap_lock();
    bool ok = heap_initialized &&
              heap_limit == (uintptr_t)__heap_end &&
              heap_cursor >= (uintptr_t)__heap_start &&
              heap_cursor <= heap_limit;
    heap_unlock(daif);
    return ok && smp_atomic_load_u64(&heap_lock_word) == 0;
}

bool swiftos_heap_s4c_self_test(void) {
    uintptr_t before = swiftos_kernel_heap_used_bytes();
    void *a = swiftos_kernel_alloc(24, 16);
    void *b = swiftos_kernel_alloc(24, 64);
    uintptr_t after = swiftos_kernel_heap_used_bytes();
    if (a == NULL || b == NULL) {
        return false;
    }
    if (((uintptr_t)a & 15) != 0 || ((uintptr_t)b & 63) != 0) {
        return false;
    }
    return after > before && swiftos_heap_lock_boundary_self_test();
}

void *swift_slowAlloc(uintptr_t byte_count, uintptr_t align_mask) {
    uintptr_t alignment = align_mask == UINTPTR_MAX ? 16 : align_mask + 1;
    void *ptr = swiftos_kernel_alloc(byte_count, alignment);
    if (ptr != NULL) {
        return ptr;
    }

    for (;;) {
    }
}

void swift_slowDealloc(void *ptr, uintptr_t byte_count, uintptr_t align_mask) {
    (void)ptr;
    (void)byte_count;
    (void)align_mask;
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    void *ptr = swiftos_kernel_alloc((uintptr_t)size, (uintptr_t)alignment);
    if (ptr == NULL) {
        return 12; // ENOMEM
    }
    *memptr = ptr;
    return 0;
}

void free(void *ptr) {
    (void)ptr;
}

void __stack_chk_fail(void) {
    for (;;) {
    }
}

bool swift_stdlib_isStackAllocationSafe(uintptr_t byte_count, uintptr_t alignment) {
    (void)byte_count;
    (void)alignment;
    return true;
}
