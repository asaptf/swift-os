/* user_newlib.ld — link map for newlib-linked swift-os EL0 programs.
 *
 * Linked high at 0x8000_0000. Uses explicit PHDRS so text/rodata land in a
 * read-execute PT_LOAD and data/bss in a separate read-write one — the kernel
 * ELF loader maps each segment with the right permissions (no RWX), so newlib's
 * writable globals (malloc state, _impure_ptr) work.
 */

ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5); /* PF_R | PF_X */
    data PT_LOAD FLAGS(6); /* PF_R | PF_W */
    tls  PT_TLS  FLAGS(4); /* PF_R: thread-local template (.tdata/.tbss) */
}

SECTIONS
{
    . = 0x80000000;

    .text : ALIGN(16) {
        KEEP(*(.text._start))
        *(.text .text.*)
    } :text

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
    } :text

    .preinit_array : {
        PROVIDE(__preinit_array_start = .);
        KEEP(*(.preinit_array))
        PROVIDE(__preinit_array_end = .);
    } :text
    .init_array : {
        PROVIDE(__init_array_start = .);
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE(__init_array_end = .);
    } :text
    .fini_array : {
        PROVIDE(__fini_array_start = .);
        KEEP(*(SORT(.fini_array.*)))
        KEEP(*(.fini_array))
        PROVIDE(__fini_array_end = .);
    } :text

    . = ALIGN(0x1000);

    /* Thread-local storage template. .tdata is loaded (part of :data) AND tagged
     * into the PT_TLS segment; .tbss is the zero-init TLS region (PT_TLS only).
     * crt0 reads __tdata_start/__tls_filesz/__tls_memsz to build the main
     * thread's TLS block and set tpidr_el0 (variant I: [16B TCB][tdata][tbss]). */
    .tdata : ALIGN(16) {
        __tdata_start = .;
        *(.tdata .tdata.* .gnu.linkonce.td.*)
        __tdata_end = .;
    } :data :tls
    .tbss (NOLOAD) : ALIGN(16) {
        *(.tbss .tbss.* .gnu.linkonce.tb.*)
        *(.tcommon)
        __tbss_end = .;
    } :tls

    .data : ALIGN(16) {
        *(.data .data.*)
    } :data
    .got : { *(.got .got.* .got.plt) } :data

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } :data

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
        *(.ARM.exidx*)
        *(.ARM.extab*)
    }
}
