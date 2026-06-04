// user_blob.S — embed the userland ELF into the kernel image.
//
// Until there is a block device + packed base FS (M8), the M6 demo program is
// baked into the kernel. `hello_elf_start`/`hello_elf_end` bound the bytes; the
// ELF loader parses them in place. The path is relative to the build cwd (the
// repo root, where `make` runs).

.section ".rodata.userblob", "a"

.global hello_elf_start
.global hello_elf_end

.balign 8
hello_elf_start:
.incbin "build/hello.elf"
hello_elf_end:
