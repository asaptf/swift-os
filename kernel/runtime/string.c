// string.c — freestanding mem* routines.
//
// The compiler lowers struct/array zeroing and copies to calls into these, so
// the kernel must provide them. Built with -fno-builtin so the obvious loops
// below are NOT re-recognised and turned into calls to themselves.

#include <stddef.h>
#include <stdint.h>

void *memset(void *dst, int value, size_t count) {
    uint8_t *p = (uint8_t *)dst;
    uint8_t v = (uint8_t)value;
    for (size_t i = 0; i < count; i += 1) {
        p[i] = v;
    }
    return dst;
}

void *memcpy(void *dst, const void *src, size_t count) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < count; i += 1) {
        d[i] = s[i];
    }
    return dst;
}

void *memmove(void *dst, const void *src, size_t count) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    if (d == s || count == 0) {
        return dst;
    }
    if (d < s) {
        for (size_t i = 0; i < count; i += 1) {
            d[i] = s[i];
        }
    } else {
        for (size_t i = count; i > 0; i -= 1) {
            d[i - 1] = s[i - 1];
        }
    }
    return dst;
}

int memcmp(const void *a, const void *b, size_t count) {
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    for (size_t i = 0; i < count; i += 1) {
        if (pa[i] != pb[i]) {
            return (int)pa[i] - (int)pb[i];
        }
    }
    return 0;
}
