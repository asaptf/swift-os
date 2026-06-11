// deviceauthdemo.c - C5g negative device-authority probe.
//
// A restricted principal must not be able to enumerate or mint opaque device
// grants. C5e/C5f cover rights after a boot-authority grant exists; this probe
// covers the earlier authority boundary.

#include "lib/syscall.h"

int puts_raw(const char *s);

static int failures = 0;

static void expect_deny(const char *ok, const char *leak, const char *fail, int r) {
    if (r == -13) {
        puts_raw(ok);
        return;
    }
    failures += 1;
    if (r >= 0) {
        puts_raw(leak);
        close(r);
    } else {
        puts_raw(fail);
    }
}

int main(void) {
    struct swiftos_device_info info;

    expect_deny("DEVICE-AUTH-DISCOVER-DENY-OK err=-13\n",
                "DEVICE-AUTH-DISCOVER-LEAK\n",
                "DEVICE-AUTH-DISCOVER-FAIL\n",
                device_discover(0, &info));

    expect_deny("DEVICE-AUTH-CLAIM-DENY-OK err=-13\n",
                "DEVICE-AUTH-CLAIM-LEAK\n",
                "DEVICE-AUTH-CLAIM-FAIL\n",
                device_claim("pseudo-input.0", &info));

    if (failures == 0) {
        puts_raw("C5g OK: non-console principal cannot discover or claim device grants\n");
    }
    return failures == 0 ? 0 : 1;
}
