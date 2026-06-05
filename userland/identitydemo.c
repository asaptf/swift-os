// identitydemo.c - M12a principal/session/capability smoke test.

#include "lib/syscall.h"

int puts_raw(const char *s);

#define CAP_CONSOLE         (1UL << 0)
#define CAP_SPAWN           (1UL << 1)
#define CAP_FS_READ         (1UL << 2)
#define CAP_TMP_WRITE       (1UL << 3)
#define CAP_PROCESS_INSPECT (1UL << 4)

static int same_context(const struct security_info *a, const struct security_info *b) {
    return a->principal == b->principal && a->session == b->session && a->caps == b->caps;
}

int main(void) {
    struct security_info self;
    if (security_info(&self) != 0) {
        puts_raw("identitydemo: security_info failed\n");
        return 1;
    }

    unsigned long expected = CAP_CONSOLE | CAP_SPAWN | CAP_FS_READ | CAP_TMP_WRITE | CAP_PROCESS_INSPECT;
    if (self.principal != 1 || self.session != 1 || (self.caps & expected) != expected) {
        puts_raw("identitydemo: boot context mismatch\n");
        return 1;
    }
    puts_raw("identitydemo: boot principal/session/caps OK\n");

    int pid = fork();
    if (pid < 0) {
        puts_raw("identitydemo: fork failed\n");
        return 1;
    }
    if (pid == 0) {
        struct security_info child;
        if (security_info(&child) != 0 || !same_context(&self, &child)) {
            puts_raw("identitydemo: child context mismatch\n");
            return 2;
        }
        puts_raw("identitydemo: child inherited security context\n");
        return 0;
    }

    int status = 0;
    if (waitpid(pid, &status, 0) != pid || status != 0) {
        puts_raw("identitydemo: child wait failed\n");
        return 1;
    }
    puts_raw("identitydemo: parent observed inherited context\n");
    return 0;
}
