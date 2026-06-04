/* termios.h — full termios for swift-os (newlib aarch64-elf ships none).
 * struct layout and c_lflag bits match the kernel ABI (kernel/vfs+tty + the
 * tcgetattr/tcsetattr syscalls): four 32-bit flag words, c_lflag at offset 12,
 * with ICANON=1, ECHO=2, ISIG=4. */
#ifndef _SWIFTOS_TERMIOS_H
#define _SWIFTOS_TERMIOS_H

typedef unsigned int   tcflag_t;
typedef unsigned char  cc_t;
typedef unsigned int   speed_t;

#define NCCS 32
struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;   /* offset 12 — matches the kernel */
    cc_t     c_line;
    cc_t     c_cc[NCCS];
    speed_t  c_ispeed;
    speed_t  c_ospeed;
};

/* c_lflag */
#define ICANON 0x0001
#define ECHO   0x0002
#define ISIG   0x0004
#define ECHOE  0x0010
#define ECHOK  0x0020
#define ECHONL 0x0040
#define NOFLSH 0x0080
#define TOSTOP 0x0100
#define IEXTEN 0x0200
/* c_iflag */
#define IGNBRK 0x0001
#define BRKINT 0x0002
#define INLCR  0x0040
#define IGNCR  0x0080
#define ICRNL  0x0100
#define ISTRIP 0x0020
#define INPCK  0x0010
#define IXON   0x0400
#define IXOFF  0x1000
/* c_oflag */
#define OPOST  0x0001
#define ONLCR  0x0004
/* c_cflag */
#define CS8    0x0030
#define CREAD  0x0080
#define CLOCAL 0x0800
/* c_cc indices */
#define VMIN  6
#define VTIME 5
#define VINTR 0
#define VEOF  4
/* tcsetattr actions */
#define TCSANOW   0
#define TCSADRAIN 1
#define TCSAFLUSH 2
/* tcflush queues */
#define TCIFLUSH  0
#define TCOFLUSH  1
#define TCIOFLUSH 2


/* Baud-rate constants (values arbitrary for our tty; needed to compile). */
#define B0 0
#define B50 1
#define B75 2
#define B110 3
#define B134 4
#define B150 5
#define B200 6
#define B300 7
#define B600 8
#define B1200 9
#define B1800 10
#define B2400 11
#define B4800 12
#define B9600 13
#define B19200 14
#define B38400 15
#define B57600 0x1001
#define B115200 0x1002
#define B230400 0x1003
#define B460800 0x1004
#define B500000 0x1005
#define B576000 0x1006
#define B921600 0x1007
#define B1000000 0x1008
#define B1152000 0x1009
#define B1500000 0x100a
#define B2000000 0x100b
#define B2500000 0x100c
#define B3000000 0x100d
#define B3500000 0x100e
#define B4000000 0x100f
#define CBAUD 0x100f

int tcgetattr(int fd, struct termios *t);
int tcsetattr(int fd, int actions, const struct termios *t);
int tcflush(int fd, int queue_selector);
int tcdrain(int fd);
int tcsendbreak(int fd, int duration);
int tcflow(int fd, int action);
speed_t cfgetispeed(const struct termios *t);
speed_t cfgetospeed(const struct termios *t);
int cfsetispeed(struct termios *t, speed_t speed);
int cfsetospeed(struct termios *t, speed_t speed);
void cfmakeraw(struct termios *t);
#endif
