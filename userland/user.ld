/* user.ld — link map for swift-os EL0 programs.
 *
 * We link userland high, at 0x8000_0000. Each process address space identity-
 * maps the kernel/device 1 GiB blocks at the low end (see kernel/mm/vm.c), so
 * user images must live above 0x8000_0000 to avoid them. We rebuild every tool
 * from source, so the traditional low link address buys us nothing.
 *
 * Text/rodata land in a read-execute PT_LOAD; data/bss in a read-write one.
 * The ELF loader maps each PT_LOAD page-by-page with permissions from p_flags.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x80000000;

    .text : ALIGN(16) {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
    }

    . = ALIGN(0x1000);

    .data : ALIGN(16) {
        *(.data .data.*)
    }

    .bss : ALIGN(16) {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }
}
