// user_blob.S — embed the userland ELFs into the kernel image.
//
// Until there is a block device + packed base FS (M8), the demo programs are
// baked into the kernel. Each `*_elf_start`/`*_elf_end` pair bounds one image;
// the ELF loader parses the bytes in place. Paths are relative to the build cwd
// (the repo root, where `make` runs).

.section ".rodata.userblob", "a"

.balign 8
.global hello_elf_start
.global hello_elf_end
hello_elf_start:
.incbin "build/hello.elf"
hello_elf_end:

.balign 8
.global ttydemo_elf_start
.global ttydemo_elf_end
ttydemo_elf_start:
.incbin "build/ttydemo.elf"
ttydemo_elf_end:

.balign 8
.global argvdemo_elf_start
.global argvdemo_elf_end
argvdemo_elf_start:
.incbin "build/argvdemo.elf"
argvdemo_elf_end:

.balign 8
.global spawndemo_elf_start
.global spawndemo_elf_end
spawndemo_elf_start:
.incbin "build/spawndemo.elf"
spawndemo_elf_end:
