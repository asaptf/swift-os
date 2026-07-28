// SPDX-License-Identifier: Apache-2.0
// malloclockprobe.c — first-malloc + concurrent heap stress via compat stubs.
//
// The login shell (busybox) and every newlib-linked program take the heap lock
// on the first malloc. A __thread depth counter on aarch64-elf can lower to
// libgcc emutls, which itself mallocs — unbounded recursion. This probe proves
// the fixed lock path works for main and worker threads under SMP.

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NWORKERS 4
#define NALLOCS  256
#define CHUNK    64

static void *worker(void *arg) {
    intptr_t id = (intptr_t)arg;
    for (int i = 0; i < NALLOCS; i++) {
        void *p = malloc(CHUNK);
        if (!p) {
            return (void *)(intptr_t)-1;
        }
        memset(p, (int)(id + i), CHUNK);
        free(p);
    }
    return (void *)(id + 1);
}

int main(void) {
    // First malloc on the main thread — the historical failure site when the
    // lock depth lived in emulated TLS.
    void *first = malloc(128);
    if (!first) {
        printf("malloclockprobe: FAIL first malloc\n");
        return 1;
    }
    memset(first, 0x5a, 128);
    free(first);
    printf("MALLOCLOCK-FIRST-OK\n");

    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0 ||
        pthread_attr_setstacksize(&attr, 65536) != 0 ||
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE) != 0) {
        printf("malloclockprobe: FAIL attr\n");
        return 1;
    }

    pthread_t ts[NWORKERS];
    for (int i = 0; i < NWORKERS; i++) {
        if (pthread_create(&ts[i], &attr, worker, (void *)(intptr_t)i) != 0) {
            printf("malloclockprobe: FAIL create %d\n", i);
            return 1;
        }
    }

    for (int i = 0; i < NWORKERS; i++) {
        void *ret = 0;
        if (pthread_join(ts[i], &ret) != 0) {
            printf("malloclockprobe: FAIL join %d\n", i);
            return 1;
        }
        if ((intptr_t)ret != (intptr_t)i + 1) {
            printf("malloclockprobe: FAIL worker %d ret %ld\n", i, (long)(intptr_t)ret);
            return 1;
        }
    }
    (void)pthread_attr_destroy(&attr);

    printf("MALLOCLOCK-THREADS-OK\n");
    printf("MALLOCLOCKPROBE-OK\n");
    return 0;
}
