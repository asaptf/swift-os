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
    EFI_STATUS (*HandleProtocol)(EFI_HANDLE Handle, EFI_GUID *Protocol, void **Interface);
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
    void                  *GetNextMonotonicCount;
    void                  *Stall;
    void                  *SetWatchdogTimer;
    void                  *ConnectController;
    void                  *DisconnectController;
    void                  *OpenProtocol;
    void                  *CloseProtocol;
    void                  *OpenProtocolInformation;
    void                  *ProtocolsPerHandle;
    void                  *LocateHandleBuffer;
    EFI_STATUS (*LocateProtocol)(EFI_GUID *Protocol, void *Registration, void **Interface);
    // Remaining members (InstallMultipleProtocolInterfaces ...) are unused.
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

// Graphics Output Protocol — the loader queries it (before ExitBootServices) for
// the linear framebuffer it hands to the kernel for an on-screen console.
#define EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID \
    { 0x9042a9de, 0x23dc, 0x4a38, { 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a } }

typedef struct {
    UINT32 Version;
    UINT32 HorizontalResolution;
    UINT32 VerticalResolution;
    UINT32 PixelFormat;          // 0=RGBX8, 1=BGRX8, 2=BitMask, 3=BltOnly
    UINT32 PixelInformation[4];  // EFI_PIXEL_BITMASK (red/green/blue/reserved)
    UINT32 PixelsPerScanLine;
} EFI_GRAPHICS_OUTPUT_MODE_INFORMATION;

typedef struct {
    UINT32                                MaxMode;
    UINT32                                Mode;
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
    UINTN                                 SizeOfInfo;
    EFI_PHYSICAL_ADDRESS                  FrameBufferBase;
    UINTN                                 FrameBufferSize;
} EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;

typedef struct {
    void                             *QueryMode;
    void                             *SetMode;
    void                             *Blt;
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode;
} EFI_GRAPHICS_OUTPUT_PROTOCOL;

// --- Simple File System: read the kernel image from the ESP (U1g) -----------
// The loader gets the volume it was loaded from via the Loaded Image protocol,
// opens its root with the Simple File System protocol, and reads a kernel image
// file with the File protocol. Only the members the loader calls are typed.

#define EFI_LOADED_IMAGE_PROTOCOL_GUID \
    { 0x5b1b31a1, 0x9562, 0x11d2, { 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID \
    { 0x964e5b22, 0x6459, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define EFI_FILE_INFO_ID \
    { 0x09576e92, 0x6d3f, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }

#define EFI_FILE_MODE_READ 0x0000000000000001ULL

// Loaded Image: we read only up to DeviceHandle (the volume we booted from).
typedef struct {
    UINT32            Revision;
    EFI_HANDLE        ParentHandle;
    EFI_SYSTEM_TABLE *SystemTable;
    EFI_HANDLE        DeviceHandle;   // the handle of the device we were loaded from
    void             *FilePath;
    void             *Reserved;
    UINT32            LoadOptionsSize;
    void             *LoadOptions;
    void             *ImageBase;
    UINT64            ImageSize;
    // Remaining members unused.
} EFI_LOADED_IMAGE_PROTOCOL;

struct EFI_FILE_PROTOCOL;
typedef struct EFI_FILE_PROTOCOL {
    UINT64 Revision;
    EFI_STATUS (*Open)(struct EFI_FILE_PROTOCOL *This, struct EFI_FILE_PROTOCOL **New,
                       CHAR16 *FileName, UINT64 OpenMode, UINT64 Attributes);
    EFI_STATUS (*Close)(struct EFI_FILE_PROTOCOL *This);
    EFI_STATUS (*Delete)(struct EFI_FILE_PROTOCOL *This);
    EFI_STATUS (*Read)(struct EFI_FILE_PROTOCOL *This, UINTN *BufferSize, void *Buffer);
    EFI_STATUS (*Write)(struct EFI_FILE_PROTOCOL *This, UINTN *BufferSize, void *Buffer);
    EFI_STATUS (*GetPosition)(struct EFI_FILE_PROTOCOL *This, UINT64 *Position);
    EFI_STATUS (*SetPosition)(struct EFI_FILE_PROTOCOL *This, UINT64 Position);
    EFI_STATUS (*GetInfo)(struct EFI_FILE_PROTOCOL *This, EFI_GUID *InformationType,
                          UINTN *BufferSize, void *Buffer);
    void *SetInfo;
    void *Flush;
} EFI_FILE_PROTOCOL;

typedef struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL {
    UINT64 Revision;
    EFI_STATUS (*OpenVolume)(struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *This,
                             EFI_FILE_PROTOCOL **Root);
} EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;

// EFI_FILE_INFO prefix: FileSize sits at byte offset 8 (after the Size field).
typedef struct {
    UINT64 Size;
    UINT64 FileSize;
    UINT64 PhysicalSize;
    // Times / Attribute / FileName[] follow; unused here.
} EFI_FILE_INFO;

#endif // SWIFT_OS_EFI_H
