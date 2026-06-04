// kernel_blob.S - embed the flat kernel image into the UEFI loader.
//
// The loader has no filesystem driver, so it carries the kernel inside its own
// PE image (assembled for the same aarch64 Windows/COFF target) and copies it to
// the kernel's fixed load address after ExitBootServices. `build/kernel.bin` is
// the objcopy flat image whose byte 0 corresponds to the link base 0x40080000.

    .data
    .balign 16
    .globl kernel_blob
kernel_blob:
    .incbin "build/kernel.bin"
    .globl kernel_blob_end
kernel_blob_end:
