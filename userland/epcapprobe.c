// SPDX-License-Identifier: Apache-2.0
// epcapprobe.c — prove IPC endpoint pool capacity is above the historic 16.
//
// Creates endpoint pairs until the kernel refuses, prints the count, closes
// them, creates one more to prove recovery, and exits 0 only when n > 16.
// Focused PT1 follow-up gate (maxEndpoints raised 16 → 32).

#include "lib/syscall.h"

int puts_raw(const char *s);

#define ENDPOINT_GUARD 96
#define MIN_ABOVE_HISTORIC 17

static void put_uint(unsigned long v) {
    char buf[24];
    int pos = 24;
    buf[--pos] = 0;
    if (v == 0) {
        buf[--pos] = '0';
    } else {
        while (v != 0 && pos > 0) {
            buf[--pos] = (char)('0' + (int)(v % 10));
            v /= 10;
        }
    }
    puts_raw(&buf[pos]);
}

int main(void) {
    int ends[ENDPOINT_GUARD][2];
    int n = 0;

    puts_raw("EPCAP-START\n");
    while (n < ENDPOINT_GUARD) {
        if (endpoint_create(ends[n]) != 0) {
            break;
        }
        n += 1;
    }

    if (n == 0) {
        puts_raw("EPCAP-FAIL none\n");
        return 1;
    }
    if (n >= ENDPOINT_GUARD) {
        puts_raw("EPCAP-FAIL cap-never-engaged n=");
        put_uint((unsigned long)n);
        puts_raw("\n");
        for (int i = 0; i < n; i += 1) {
            close(ends[i][0]);
            close(ends[i][1]);
        }
        return 1;
    }

    puts_raw("EPCAP-ALLOC n=");
    put_uint((unsigned long)n);
    puts_raw("\n");

    for (int i = 0; i < n; i += 1) {
        close(ends[i][0]);
        close(ends[i][1]);
    }

    int e[2];
    if (endpoint_create(e) != 0) {
        puts_raw("EPCAP-FAIL no-recover\n");
        return 1;
    }
    close(e[0]);
    close(e[1]);

    if (n < MIN_ABOVE_HISTORIC) {
        puts_raw("EPCAP-FAIL below-historic n=");
        put_uint((unsigned long)n);
        puts_raw("\n");
        return 1;
    }

    puts_raw("EPCAP-OK n=");
    put_uint((unsigned long)n);
    puts_raw("\n");
    return 0;
}
