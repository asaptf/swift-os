#ifndef _SWIFTOS_NET_IF_H
#define _SWIFTOS_NET_IF_H
#define IFNAMSIZ 16
struct ifreq { char ifr_name[IFNAMSIZ]; union { char ifr_data[24]; } ifr_ifru; };
unsigned int if_nametoindex(const char *ifname);
char *if_indextoname(unsigned int ifindex, char *ifname);
#endif
