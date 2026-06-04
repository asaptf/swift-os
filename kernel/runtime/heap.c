// heap.c — early kernel heap and Swift allocation hooks.
//
// The exported swift_* names are runtime ABI hooks, so keep them in C rather
// than declaring reserved Swift runtime symbols from Swift code.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

extern uint8_t __heap_start[];
extern uint8_t __heap_end[];

static uintptr_t heap_cursor;
static uintptr_t heap_limit;
static bool heap_initialized;

uintptr_t __stack_chk_guard = 0x21534654534f5357ULL;

static uintptr_t align_up(uintptr_t value, uintptr_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

void swiftos_heap_init(void) {
    heap_cursor = (uintptr_t)__heap_start;
    heap_limit = (uintptr_t)__heap_end;
    heap_initialized = true;
}

uintptr_t swiftos_kernel_heap_used_bytes(void) {
    if (!heap_initialized) {
        return 0;
    }
    return heap_cursor - (uintptr_t)__heap_start;
}

void *swiftos_kernel_alloc(uintptr_t byte_count, uintptr_t alignment) {
    if (!heap_initialized) {
        swiftos_heap_init();
    }

    uintptr_t effective_alignment = alignment < 16 ? 16 : alignment;
    uintptr_t start = align_up(heap_cursor, effective_alignment);
    uintptr_t end = start + byte_count;
    if (end < start || end > heap_limit) {
        return NULL;
    }

    heap_cursor = end;
    return (void *)start;
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
