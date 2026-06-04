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

.balign 8
.global fsdemo_elf_start
.global fsdemo_elf_end
fsdemo_elf_start:
.incbin "build/fsdemo.elf"
fsdemo_elf_end:

.balign 8
.global brkdemo_elf_start
.global brkdemo_elf_end
brkdemo_elf_start:
.incbin "build/brkdemo.elf"
brkdemo_elf_end:

.balign 8
.global newlibtest_elf_start
.global newlibtest_elf_end
newlibtest_elf_start:
.incbin "build/newlibtest.elf"
newlibtest_elf_end:

.balign 8
.global coproc_elf_start
.global coproc_elf_end
coproc_elf_start:
.incbin "build/coproc.elf"
coproc_elf_end:

.balign 8
.global forkdemo_elf_start
.global forkdemo_elf_end
forkdemo_elf_start:
.incbin "build/forkdemo.elf"
forkdemo_elf_end:

.balign 8
.global execdemo_elf_start
.global execdemo_elf_end
execdemo_elf_start:
.incbin "build/execdemo.elf"
execdemo_elf_end:

.balign 8
.global securitydemo_elf_start
.global securitydemo_elf_end
securitydemo_elf_start:
.incbin "build/securitydemo.elf"
securitydemo_elf_end:
