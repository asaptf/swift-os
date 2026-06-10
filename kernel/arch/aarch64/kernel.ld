/* kernel.ld — link map for the kernel image.
 *
 * The image is position-dependent (the boot stub runs with the MMU off and uses
 * absolute addresses), so it must be linked at the physical address the loader
 * places it. The base is board-specific and supplied by the Makefile via
 * `--defsym __kernel_phys_base=…` (RAM_BASE + 0x80000): 0x40080000 on the QEMU
 * `virt` board, 0x08080000 on VirtualBox ARM (see docs/VIRTUALBOX.md). We keep
 * `.text.boot` first so `_start` is the very first instruction.
 */

ENTRY(_start)

PHYS_BASE = DEFINED(__kernel_phys_base) ? __kernel_phys_base : 0x40080000;
STACK_SIZE = 0x10000; /* 64 KiB boot stack */
HEAP_SIZE = 0x800000; /* 8 MiB early bump heap */

SECTIONS
{
    . = PHYS_BASE;

    .text : ALIGN(16) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(16) {
        *(.data .data.*)
    }

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    /* Boot stack lives just past BSS; grows down from __stack_top. */
    . = ALIGN(16);
    . += STACK_SIZE;
    __stack_top = .;

    . = ALIGN(16);
    __heap_start = .;
    . += HEAP_SIZE;
    __heap_end = .;

    __image_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
        *(.interp)
    }
}
