#ifndef _SWIFTOS_SYSMACROS_H
#define _SWIFTOS_SYSMACROS_H
#define major(d) ((int)(((unsigned)(d) >> 8) & 0xff))
#define minor(d) ((int)((unsigned)(d) & 0xff))
#define makedev(ma, mi) ((((ma) & 0xff) << 8) | ((mi) & 0xff))
#endif
