#ifndef _SWIFTOS_IOCTL_H
#define _SWIFTOS_IOCTL_H
#define TCGETS 0x5401
#define TCSETS 0x5402
#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414
#define TIOCGPGRP 0x540F
#define TIOCSPGRP 0x5410
#define FIONREAD 0x541B
#define FIOASYNC 0x5452
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
int ioctl(int fd, unsigned long request, ...);
#endif
