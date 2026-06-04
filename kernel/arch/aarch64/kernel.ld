/* kernel.ld — link map for the QEMU `virt` kernel image.
 *
 * QEMU loads a `-kernel` raw image at RAM_BASE + 0x80000 = 0x40080000 on the
 * aarch64 `virt` board. We link at that address and keep `.text.boot` first so
 * `_start` is the very first instruction. The image is position-dependent;
 * the MMU is off until M3.
 */

ENTRY(_start)

PHYS_BASE = 0x40080000;
STACK_SIZE = 0x10000; /* 64 KiB boot stack */
HEAP_SIZE = 0x40000;  /* 256 KiB early bump heap */

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
