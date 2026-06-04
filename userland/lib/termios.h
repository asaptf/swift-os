// termios.h — swift-os userland terminal control (our own ABI, not Linux).
//
// Layout must match kernel/syscall/syscall.swift: four 32-bit flag words; only
// c_lflag is interpreted today. Flag bit values must match kernel/tty/tty.swift.

#ifndef SWIFTOS_TERMIOS_H
#define SWIFTOS_TERMIOS_H

#include "syscall.h"

struct termios {
    unsigned int c_iflag;
    unsigned int c_oflag;
    unsigned int c_cflag;
    unsigned int c_lflag;
};

#define ICANON (1u << 0)
#define ECHO   (1u << 1)
#define ISIG   (1u << 2)

#define TCSANOW 0

static inline int tcgetattr(int fd, struct termios *t) {
    return (int)__syscall3(SYS_TCGETATTR, fd, (long)t, 0);
}

static inline int tcsetattr(int fd, int actions, const struct termios *t) {
    return (int)__syscall3(SYS_TCSETATTR, fd, actions, (long)t);
}

#endif // SWIFTOS_TERMIOS_H
