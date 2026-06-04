#ifndef _SWIFTOS_SYSINFO_H
#define _SWIFTOS_SYSINFO_H
struct sysinfo {
    long uptime; unsigned long loads[3];
    unsigned long totalram, freeram, sharedram, bufferram;
    unsigned long totalswap, freeswap; unsigned short procs;
    unsigned long totalhigh, freehigh; unsigned int mem_unit;
};
int sysinfo(struct sysinfo *info);
#endif
