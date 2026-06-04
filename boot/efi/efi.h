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

typedef UINT64 EFI_PHYSICAL_ADDRESS;

typedef enum {
    AllocateAnyPages,
    AllocateMaxAddress,
    AllocateAddress,
    MaxAllocateType
} EFI_ALLOCATE_TYPE;

typedef enum {
    EfiReservedMemoryType,
    EfiLoaderCode,
    EfiLoaderData,
    EfiBootServicesCode,
    EfiBootServicesData,
    EfiRuntimeServicesCode,
    EfiRuntimeServicesData,
    EfiConventionalMemory,
    EfiUnusableMemory,
    EfiACPIReclaimMemory,
    EfiACPIMemoryNVS,
    EfiMemoryMappedIO,
    EfiMemoryMappedIOPortSpace,
    EfiPalCode,
    EfiPersistentMemory,
    EfiMaxMemoryType
} EFI_MEMORY_TYPE;

typedef EFI_STATUS (*EFI_ALLOCATE_PAGES)(EFI_ALLOCATE_TYPE, EFI_MEMORY_TYPE,
                                         UINTN pages, EFI_PHYSICAL_ADDRESS *memory);
typedef EFI_STATUS (*EFI_GET_MEMORY_MAP)(UINTN *map_size, void *map, UINTN *map_key,
                                         UINTN *desc_size, UINT32 *desc_version);
typedef EFI_STATUS (*EFI_EXIT_BOOT_SERVICES)(EFI_HANDLE image, UINTN map_key);

// Boot services. Only the members the loader calls are typed; everything else
// is a `void *` kept at its spec offset so the typed members land correctly.
typedef struct {
    EFI_TABLE_HEADER       Hdr;
    void                  *RaiseTPL;
    void                  *RestoreTPL;
    EFI_ALLOCATE_PAGES     AllocatePages;
    void                  *FreePages;
    EFI_GET_MEMORY_MAP     GetMemoryMap;
    void                  *AllocatePool;
    void                  *FreePool;
    void                  *CreateEvent;
    void                  *SetTimer;
    void                  *WaitForEvent;
    void                  *SignalEvent;
    void                  *CloseEvent;
    void                  *CheckEvent;
    void                  *InstallProtocolInterface;
    void                  *ReinstallProtocolInterface;
    void                  *UninstallProtocolInterface;
    void                  *HandleProtocol;
    void                  *Reserved;
    void                  *RegisterProtocolNotify;
    void                  *LocateHandle;
    void                  *LocateDevicePath;
    void                  *InstallConfigurationTable;
    void                  *LoadImage;
    void                  *StartImage;
    void                  *Exit;
    void                  *UnloadImage;
    EFI_EXIT_BOOT_SERVICES ExitBootServices;
    // Remaining members (GetNextMonotonicCount ... CopyMem/SetMem/...) are unused.
} EFI_BOOT_SERVICES;

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
    EFI_BOOT_SERVICES               *BootServices;
    UINTN                            NumberOfTableEntries;
    EFI_CONFIGURATION_TABLE         *ConfigurationTable;
} EFI_SYSTEM_TABLE;

typedef struct {
    UINT32               Type;
    UINT32               Pad;
    EFI_PHYSICAL_ADDRESS PhysicalStart;
    EFI_PHYSICAL_ADDRESS VirtualStart;
    UINT64               NumberOfPages;
    UINT64               Attribute;
} EFI_MEMORY_DESCRIPTOR;

// QEMU/AAVMF expose the flattened device tree through this configuration-table
// vendor GUID (the EDK2 gFdtTableGuid).
#define EFI_FDT_TABLE_GUID \
    { 0xb1b621d5, 0xf19c, 0x41a5, { 0x83, 0x0b, 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 } }

// ACPI 2.0+ root table (RSDP). Used only to report whether the firmware is
// ACPI-based (e.g. VirtualBox) vs device-tree based (QEMU virt, acpi=off).
#define EFI_ACPI_20_TABLE_GUID \
    { 0x8868e871, 0xe4f1, 0x11d3, { 0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81 } }

#endif // SWIFT_OS_EFI_H
