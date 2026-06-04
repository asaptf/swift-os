// efi.h - the minimal slice of the UEFI interface the swift-os loader needs.
//
// We do not depend on gnu-efi or the EDK2 headers. UEFI on AArch64 uses the
// ordinary AAPCS64 calling convention, so firmware function pointers are called
// like any C function. Only the structures the loader actually touches are
// declared; their field order and sizes follow the UEFI specification so the
// offsets match what the firmware hands us. Anything unused is a typed `void *`
// placeholder kept at the right offset.

#ifndef SWIFT_OS_EFI_H
#define SWIFT_OS_EFI_H

typedef unsigned short     CHAR16;
typedef unsigned char      UINT8;
typedef unsigned short     UINT16;
typedef unsigned int       UINT32;
typedef unsigned long long UINT64;
typedef unsigned long long UINTN;   // 64-bit on AArch64.
typedef void              *EFI_HANDLE;
typedef UINTN              EFI_STATUS;

#define EFI_SUCCESS 0

typedef struct {
    UINT32 Data1;
    UINT16 Data2;
    UINT16 Data3;
    UINT8  Data4[8];
} EFI_GUID;

typedef struct {
    UINT64 Signature;
    UINT32 Revision;
    UINT32 HeaderSize;
    UINT32 CRC32;
    UINT32 Reserved;
} EFI_TABLE_HEADER;

// SIMPLE_TEXT_OUTPUT: we only call OutputString (UTF-16). Reset precedes it; the
// remaining members are unused and left off (we never read past OutputString).
struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;
typedef EFI_STATUS (*EFI_TEXT_RESET)(struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *, UINT8);
typedef EFI_STATUS (*EFI_TEXT_STRING)(struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *, CHAR16 *);
typedef struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
    EFI_TEXT_RESET  Reset;
    EFI_TEXT_STRING OutputString;
} EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;

typedef struct {
    EFI_GUID VendorGuid;
    void    *VendorTable;
} EFI_CONFIGURATION_TABLE;

typedef struct {
    EFI_TABLE_HEADER                 Hdr;
    CHAR16                          *FirmwareVendor;
    UINT32                           FirmwareRevision;
    EFI_HANDLE                       ConsoleInHandle;
    void                            *ConIn;
    EFI_HANDLE                       ConsoleOutHandle;
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
    EFI_HANDLE                       StandardErrorHandle;
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *StdErr;
    void                            *RuntimeServices;
    void                            *BootServices;
    UINTN                            NumberOfTableEntries;
    EFI_CONFIGURATION_TABLE         *ConfigurationTable;
} EFI_SYSTEM_TABLE;

// QEMU/AAVMF expose the flattened device tree through this configuration-table
// vendor GUID (the EDK2 gFdtTableGuid).
#define EFI_FDT_TABLE_GUID \
    { 0xb1b621d5, 0xf19c, 0x41a5, { 0x83, 0x0b, 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 } }

#endif // SWIFT_OS_EFI_H
