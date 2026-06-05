# swift-os — top-level build.
#
# Targets:
#   make build   Build the kernel image (build/kernel.elf).
#   make run     Boot the kernel in QEMU on the serial console.
#   make run-gfx Boot the UEFI disk in a graphical window (ramfb framebuffer).
#   make debug   Boot under QEMU's gdbstub (paused), for `make gdb` / lldb.
#   make test    Build, then run the boot acceptance test(s).
#   make clean   Remove build artifacts.
#
# Tool locations are overridable on the command line, e.g.
#   make SWIFTC=/path/to/swiftc build
# See docs/NOTES.md for how these were chosen and pinned.

# ---- Toolchain -------------------------------------------------------------
TOOLCHAIN ?= $(HOME)/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain
SWIFTC    ?= $(TOOLCHAIN)/usr/bin/swiftc
HOST_SWIFTC ?= /usr/bin/swiftc
LLVM      ?= /opt/homebrew/opt/llvm/bin
CLANG     ?= $(LLVM)/clang
OBJCOPY   ?= $(LLVM)/llvm-objcopy
# Note: LD is a Make built-in (defaults to `ld`), so we use LDBIN to stay overridable.
# ld.lld (not GNU ld) so Embedded Swift's protected empty-Array/String singletons
# link without copy-relocation errors. See docs/NOTES.md.
LDBIN     ?= /opt/homebrew/opt/lld/bin/ld.lld
QEMU      ?= qemu-system-aarch64
GDB       ?= aarch64-elf-gdb

# ---- Target ----------------------------------------------------------------
TRIPLE    := aarch64-none-none-elf
ARCH_DIR  := kernel/arch/aarch64
BRIDGE    := $(ARCH_DIR)/io.h
LINKER    := $(ARCH_DIR)/kernel.ld
BUILD     := build
QEMU_DTB  := $(BUILD)/virt.dtb
QEMU_DTB_ADDR := 0x4FF00000
BASE_IMG  := $(BUILD)/base.img
BASEPACK  := $(BUILD)/basepack
BASE_ROOT := $(BUILD)/base-root
BASE_SEED_FILES := $(shell find base -type f | sort)

# ---- Board selection (M10.5) ----------------------------------------------
# BOARD=qemu (default) targets the QEMU `virt` board; BOARD=virtualbox targets
# VirtualBox's ARM machine, whose RAM/UART/GIC live at different addresses
# (RAM 0x0800_0000, PL011 0xFFDD_F000 — see docs/VIRTUALBOX.md). The board sets
# the kernel link/load base and a compile define the kernel/loader branch on.
BOARD ?= qemu
ifeq ($(BOARD),virtualbox)
  KPHYS_BASE  := 0x08080000
  BOARD_CDEF  := -DBOARD_VIRTUALBOX
  BOARD_SWDEF := -D BOARD_VIRTUALBOX
else ifeq ($(BOARD),qemu)
  KPHYS_BASE  := 0x40080000
  BOARD_CDEF  :=
  BOARD_SWDEF :=
else
  $(error unknown BOARD '$(BOARD)' — use qemu or virtualbox)
endif

# Switching boards changes the link base and compiled-in addresses, so the
# kernel/loader/disk must be rebuilt. Track the active board in a stamp and,
# when it changes, drop just those artifacts — the slow busybox.elf / base.img
# / newlib sysroot are board-independent and kept.
$(shell mkdir -p $(BUILD); \
        [ "$$(cat $(BUILD)/.board 2>/dev/null)" = "$(BOARD)" ] || { \
            rm -f $(BUILD)/kernel.o $(BUILD)/kernel.elf $(BUILD)/kernel.bin \
                  $(BUILD)/vm.o $(BUILD)/loader.obj $(BUILD)/kernel_blob.obj \
                  $(BUILD)/BOOTAA64.EFI $(BUILD)/swift-os.img $(BUILD)/swift-os.vdi; \
            rm -rf $(BUILD)/esp; \
            echo "$(BOARD)" > $(BUILD)/.board; })

# Swift sources (kernel). Whole-module optimization compiles them together.
SWIFT_SRCS := \
	kernel/main.swift \
	kernel/arch/aarch64/platform.swift \
	kernel/arch/aarch64/fdt.swift \
	kernel/drivers/uart.swift \
	kernel/drivers/gic.swift \
	kernel/timer/generic_timer.swift \
	kernel/sched/scheduler.swift \
	kernel/syscall/syscall.swift \
	kernel/tty/tty.swift \
	kernel/signal/signal.swift \
	kernel/user/user_access.swift \
	kernel/user/user_process.swift \
	kernel/user/process.swift \
	kernel/user/exec.swift \
	kernel/vfs/vfs.swift \
	kernel/mm/page_allocator.swift \
	kernel/mm/pmm.swift

# ---- Flags -----------------------------------------------------------------
# Embedded Swift: freestanding, no Foundation/stdlib, whole-module.
# -function-sections lets the linker drop unused runtime code.
SWIFT_FLAGS := \
	-target $(TRIPLE) \
	-enable-experimental-feature Embedded \
	-wmo -parse-as-library -Osize \
	-Xllvm -mattr=+strict-align,-neon \
	-Xfrontend -function-sections \
	$(BOARD_SWDEF) \
	-import-objc-header $(BRIDGE)

ASM_FLAGS := --target=$(TRIPLE) -ffreestanding -c
C_FLAGS   := --target=$(TRIPLE) -ffreestanding -O2 -Wall -Wextra $(BOARD_CDEF) -c
# -fno-builtin so mem* implementations are not turned into calls to themselves.
C_FLAGS_NB := --target=$(TRIPLE) -ffreestanding -fno-builtin -O2 -Wall -Wextra -c
# Userland (EL0) build: freestanding, static, our own libc/crt0, no host libc.
USER_CFLAGS  := --target=$(TRIPLE) -ffreestanding -fno-builtin -nostdlib -Os -Wall -Wextra \
	-Iuserland -Iuserland/lib -c
USER_LDFLAGS := -nostdlib -static -T userland/user.ld -z max-page-size=4096
USER_SWIFT_FLAGS := \
	-target $(TRIPLE) \
	-enable-experimental-feature Embedded \
	-wmo -parse-as-library -Osize \
	-Xllvm -mattr=+strict-align,-neon \
	-Xfrontend -function-sections \
	-import-objc-header userland/lib/swift_user.h
# Newlib-linked userland: aarch64-elf GNU toolchain + ./sysroot (run `make newlib`).
SYSROOT        := sysroot/aarch64-elf
NEWLIB_GCC     := aarch64-elf-gcc
NEWLIB_CFLAGS  := -ffreestanding -Os -Wall -isystem $(SYSROOT)/include -c
NEWLIB_LDFLAGS := -nostartfiles -nostdlib -static -T userland/user_newlib.ld -Wl,-z,max-page-size=4096 -L $(SYSROOT)/lib
NEWLIB_LIBS    := -Wl,--start-group -lc -lm -lgcc -Wl,--end-group
# Garbage-collect unused sections; entry is _start from the boot stub.
LD_FLAGS  := --gc-sections -nostdlib -T $(LINKER) --defsym __kernel_phys_base=$(KPHYS_BASE)

# ---- QEMU ------------------------------------------------------------------
# Attach the packed base image as a modern (v2) virtio-blk disk so the kernel
# serves the read-only base and /bin/* from disk (M11). force-legacy=false
# selects the v2 transport our driver speaks.
QEMU_FLAGS := -M virt -cpu cortex-a72 -m 256M -nographic \
	-global virtio-mmio.force-legacy=false \
	-device loader,file=$(QEMU_DTB),addr=$(QEMU_DTB_ADDR),force-raw=on \
	-drive file=$(BASE_IMG),format=raw,if=none,id=swosbase,readonly=on \
	-device virtio-blk-device,drive=swosbase \
	-kernel $(BUILD)/kernel.elf

# ---- UEFI loader (M10) -----------------------------------------------------
# The loader is an AArch64 PE32+ EFI application; clang targets Windows/COFF and
# lld-link emits the EFI subsystem image. Firmware is QEMU's prebuilt AAVMF/edk2.
LLDLINK    ?= /opt/homebrew/opt/lld/bin/lld-link
AAVMF_CODE ?= /opt/homebrew/share/qemu/edk2-aarch64-code.fd
EFI_CFLAGS := --target=aarch64-unknown-windows -ffreestanding -fno-stack-protector \
	-mcmodel=small -Os -Wall -Wextra $(BOARD_CDEF) -DKERNEL_LOAD_ADDR=$(KPHYS_BASE)ULL -c
EFI_APP    := $(BUILD)/BOOTAA64.EFI
ESP_DIR    := $(BUILD)/esp
# Boot from the EFI System Partition (a directory served as virtual FAT), not
# `-kernel`. No separate NVRAM vars store: AAVMF's default boot order scans
# removable media for \EFI\BOOT\BOOTAA64.EFI. `acpi=off` makes the firmware boot
# in device-tree mode and publish the FDT configuration table the loader reads
# (swift-os is a device-tree OS; see the M9 HAL).
# The packed base image rides along as a second, modern virtio-blk disk; the
# firmware boots off the ESP while the kernel serves the base FS / /bin from it.
UEFI_BASE_DISK := -global virtio-mmio.force-legacy=false \
	-drive file=$(BASE_IMG),format=raw,if=none,id=swosbase,readonly=on \
	-device virtio-blk-device,drive=swosbase
UEFI_QEMU_FLAGS := -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
	-bios $(AAVMF_CODE) \
	-drive file=fat:rw:$(ESP_DIR),format=raw,if=virtio \
	$(UEFI_BASE_DISK)

# ---- Objects ---------------------------------------------------------------
BOOT_OBJ   := $(BUILD)/boot.o
EXC_OBJ    := $(BUILD)/exceptions.o
SWITCH_OBJ := $(BUILD)/switch.o
HEAP_OBJ   := $(BUILD)/heap.o
STRING_OBJ := $(BUILD)/string.o
VM_OBJ     := $(BUILD)/vm.o
FB_OBJ     := $(BUILD)/fb.o
VIRTIO_OBJ := $(BUILD)/virtio_input.o
VIRTIO_BLK_OBJ := $(BUILD)/virtio_blk.o
EL0_OBJ    := $(BUILD)/el0.o
ELF_OBJ    := $(BUILD)/elf.o
USTACK_OBJ := $(BUILD)/ustack.o
USER_ENTRY_OBJ := $(BUILD)/user_entry.o
KERNEL_OBJ := $(BUILD)/kernel.o
KERNEL_ELF := $(BUILD)/kernel.elf
KERNEL_BIN := $(BUILD)/kernel.bin

# Userland artifacts (static C programs, embedded into the kernel image).
USER_HELLO_ELF := $(BUILD)/hello.elf
USER_TTYDEMO_ELF := $(BUILD)/ttydemo.elf
USER_ARGVDEMO_ELF := $(BUILD)/argvdemo.elf
USER_SPAWNDEMO_ELF := $(BUILD)/spawndemo.elf
USER_FSDEMO_ELF := $(BUILD)/fsdemo.elf
USER_BRKDEMO_ELF := $(BUILD)/brkdemo.elf
USER_NEWLIBTEST_ELF := $(BUILD)/newlibtest.elf
USER_COPROC_ELF := $(BUILD)/coproc.elf
USER_FORKDEMO_ELF := $(BUILD)/forkdemo.elf
USER_EXECDEMO_ELF := $(BUILD)/execdemo.elf
USER_FDOPSDEMO_ELF := $(BUILD)/fdopsdemo.elf
USER_SECURITYDEMO_ELF := $(BUILD)/securitydemo.elf
USER_PS_ELF := $(BUILD)/ps.elf
BASE_EXEC_ELFS := \
	$(USER_HELLO_ELF) \
	$(USER_TTYDEMO_ELF) \
	$(USER_ARGVDEMO_ELF) \
	$(USER_SPAWNDEMO_ELF) \
	$(USER_FSDEMO_ELF) \
	$(USER_BRKDEMO_ELF) \
	$(USER_NEWLIBTEST_ELF) \
	$(USER_COPROC_ELF) \
	$(USER_FORKDEMO_ELF) \
	$(USER_EXECDEMO_ELF) \
	$(USER_FDOPSDEMO_ELF) \
	$(USER_SECURITYDEMO_ELF) \
	$(USER_PS_ELF) \
	$(BUILD)/busybox.elf

.PHONY: build run debug gdb test clean tools-check newlib busybox busybox-check uefi uefi-run disk disk-run base-image

build: $(KERNEL_ELF)

$(QEMU_DTB): | $(BUILD)/.dir
	$(QEMU) -M virt,dumpdtb=$@ -cpu cortex-a72 -m 256M -nographic

$(BUILD)/.dir:
	@mkdir -p $(BUILD)
	@touch $@

# Assemble the boot stub with the LLVM cross clang.
$(BOOT_OBJ): $(ARCH_DIR)/boot.S Makefile | $(BUILD)/.dir
	$(CLANG) $(ASM_FLAGS) $< -o $@

# Compile all kernel Swift into a single object (whole-module).
$(EXC_OBJ): $(ARCH_DIR)/exceptions.S Makefile | $(BUILD)/.dir
	$(CLANG) $(ASM_FLAGS) $< -o $@

$(SWITCH_OBJ): $(ARCH_DIR)/switch.S Makefile | $(BUILD)/.dir
	$(CLANG) $(ASM_FLAGS) $< -o $@

$(HEAP_OBJ): kernel/runtime/heap.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(STRING_OBJ): kernel/runtime/string.c Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS_NB) $< -o $@

$(VM_OBJ): kernel/mm/vm.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(FB_OBJ): kernel/drivers/fb.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(VIRTIO_OBJ): kernel/drivers/virtio_input.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(VIRTIO_BLK_OBJ): kernel/drivers/virtio_blk.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(EL0_OBJ): kernel/user/el0.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(ELF_OBJ): kernel/user/elf.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(USTACK_OBJ): kernel/user/ustack.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(USER_ENTRY_OBJ): $(ARCH_DIR)/user_entry.S Makefile | $(BUILD)/.dir
	$(CLANG) $(ASM_FLAGS) $< -o $@

# --- Userland (EL0) -------------------------------------------------------
$(BUILD)/user_crt0.o: userland/lib/crt0.S userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/lib/crt0.S -o $@

$(BUILD)/user_libc.o: userland/lib/libc.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/lib/libc.c -o $@

$(BUILD)/user_swift_user.o: userland/lib/swift_user.c userland/lib/swift_user.h userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/lib/swift_user.c -o $@

$(BUILD)/user_hello.o: userland/hello.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/hello.c -o $@

$(BUILD)/user_ttydemo.o: userland/ttydemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/ttydemo.c -o $@

$(BUILD)/user_argvdemo.o: userland/argvdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/argvdemo.c -o $@

$(BUILD)/user_spawndemo.o: userland/spawndemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/spawndemo.c -o $@

$(BUILD)/user_fsdemo.o: userland/fsdemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/fsdemo.c -o $@

$(BUILD)/user_brkdemo.o: userland/brkdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/brkdemo.c -o $@

$(BUILD)/user_coproc.o: userland/coproc.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/coproc.c -o $@

$(BUILD)/user_forkdemo.o: userland/forkdemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/forkdemo.c -o $@

$(BUILD)/user_execdemo.o: userland/execdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/execdemo.c -o $@

$(BUILD)/user_fdopsdemo.o: userland/fdopsdemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/fdopsdemo.c -o $@

$(BUILD)/user_securitydemo.o: userland/securitydemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/securitydemo.c -o $@

$(BUILD)/user_ps.o: userland/ps.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ps.swift -o $@

$(USER_HELLO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_hello.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_hello.o -o $@

$(USER_TTYDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_ttydemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_ttydemo.o -o $@

$(USER_ARGVDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_argvdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_argvdemo.o -o $@

$(USER_SPAWNDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_spawndemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_spawndemo.o -o $@

$(USER_FSDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fsdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fsdemo.o -o $@

$(USER_BRKDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_brkdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_brkdemo.o -o $@

$(USER_COPROC_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_coproc.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_coproc.o -o $@

$(USER_FORKDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_forkdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_forkdemo.o -o $@

$(USER_EXECDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_execdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_execdemo.o -o $@

$(USER_FDOPSDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fdopsdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fdopsdemo.o -o $@

$(USER_SECURITYDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_securitydemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_securitydemo.o -o $@

$(USER_PS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o -o $@

# Newlib-linked program (built with the aarch64-elf GNU toolchain).
$(SYSROOT)/lib/libc.a:
	@echo "newlib not built. Run: make newlib" >&2; exit 1

$(BUILD)/n_crt0.o: userland/lib/crt0_newlib.S Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_CFLAGS) $< -o $@

$(BUILD)/n_syscalls.o: userland/lib/newlib_syscalls.c Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_CFLAGS) $< -o $@

$(BUILD)/n_newlibtest.o: userland/newlibtest.c Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_CFLAGS) $< -o $@

$(USER_NEWLIBTEST_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_newlibtest.o $(BUILD)/n_syscalls.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_newlibtest.o $(BUILD)/n_syscalls.o $(NEWLIB_LIBS) -o $@

# The userland ELFs are no longer embedded (M11d): they ship in the packed base
# image (see the $(BASE_IMG) rule) and the kernel loads them from disk.

$(KERNEL_OBJ): $(SWIFT_SRCS) $(BRIDGE) Makefile | $(BUILD)/.dir
	$(SWIFTC) $(SWIFT_FLAGS) -c $(SWIFT_SRCS) -o $@

# Link the freestanding image.
KERNEL_OBJS := $(BOOT_OBJ) $(EXC_OBJ) $(SWITCH_OBJ) $(USER_ENTRY_OBJ) $(HEAP_OBJ) $(STRING_OBJ) \
	$(VM_OBJ) $(FB_OBJ) $(VIRTIO_OBJ) $(VIRTIO_BLK_OBJ) $(EL0_OBJ) $(ELF_OBJ) $(USTACK_OBJ) $(KERNEL_OBJ)

$(KERNEL_ELF): $(KERNEL_OBJS) $(LINKER)
	$(LDBIN) $(LD_FLAGS) $(KERNEL_OBJS) -o $@
	$(OBJCOPY) -O binary $@ $(KERNEL_BIN)
	@echo "Built $(KERNEL_ELF)"

run: build $(QEMU_DTB) base-image
	$(QEMU) $(QEMU_FLAGS)

# Paused under the gdbstub on tcp::1234. Attach with `make gdb` in another shell.
debug: build $(QEMU_DTB) base-image
	$(QEMU) $(QEMU_FLAGS) -s -S

gdb:
	$(GDB) $(KERNEL_ELF) -ex 'target remote :1234'

test: build $(QEMU_DTB) disk base-image
	$(HOST_SWIFTC) tests/page_allocator_test.swift kernel/mm/page_allocator.swift -o $(BUILD)/page_allocator_test
	$(BUILD)/page_allocator_test
	$(HOST_SWIFTC) tests/base_image_test.swift -o $(BUILD)/base_image_test
	$(BUILD)/base_image_test $(BASE_IMG)
	$(HOST_SWIFTC) tests/fdt_test.swift kernel/arch/aarch64/fdt.swift -o $(BUILD)/fdt_test
	$(BUILD)/fdt_test $(BUILD)/virt.dtb
	./tests/userland_elf_test.sh
	./tests/boot_test.sh
	./tests/tty_test.sh
	./tests/virtio_blk_test.sh
	./tests/vfs_disk_test.sh
	./tests/disk_exec_test.sh
	./tests/busybox_test.sh
	UEFI_BOOT=disk ./tests/uefi_boot_test.sh

# ---- UEFI loader build + boot ----------------------------------------------
# The loader embeds the flat kernel image (no FS driver) and copies it to the
# kernel load address after ExitBootServices, so it depends on the built kernel.
$(BUILD)/kernel_blob.obj: boot/efi/kernel_blob.S $(KERNEL_ELF) Makefile | $(BUILD)/.dir
	$(CLANG) --target=aarch64-unknown-windows -c boot/efi/kernel_blob.S -o $@

$(EFI_APP): boot/efi/loader.c boot/efi/efi.h $(BUILD)/kernel_blob.obj Makefile | $(BUILD)/.dir
	$(CLANG) $(EFI_CFLAGS) boot/efi/loader.c -o $(BUILD)/loader.obj
	$(LLDLINK) -subsystem:efi_application -entry:efi_main -nodefaultlib -out:$@ \
		$(BUILD)/loader.obj $(BUILD)/kernel_blob.obj
	@echo "Built $(EFI_APP)"

# Stage the EFI System Partition firmware boots from.
$(ESP_DIR)/EFI/BOOT/BOOTAA64.EFI: $(EFI_APP)
	@mkdir -p $(ESP_DIR)/EFI/BOOT
	cp $(EFI_APP) $@

uefi: $(ESP_DIR)/EFI/BOOT/BOOTAA64.EFI

# Boot the UEFI loader under AAVMF (no `-kernel`). Exit QEMU serial with Ctrl-A X.
uefi-run: uefi base-image
	$(QEMU) $(UEFI_QEMU_FLAGS)

# Build a real bootable GPT disk image (ESP + BOOTAA64.EFI). Bootable under
# QEMU+AAVMF and attachable to VirtualBox / other hypervisors.
DISK_IMG := $(BUILD)/swift-os.img
disk: uefi
	./scripts/make-disk.sh $(DISK_IMG)

# Boot the real disk image under AAVMF (a genuine -drive, not virtual FAT).
disk-run: disk base-image
	$(QEMU) -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
		-bios $(AAVMF_CODE) -drive file=$(DISK_IMG),format=raw,if=virtio \
		$(UEFI_BASE_DISK)

# Boot the UEFI disk in a graphical window. `ramfb` gives the firmware a linear
# framebuffer (EFI GOP); the loader hands it to the kernel, which renders the
# boot log on screen. Serial is mirrored to this terminal. Close the window or
# Ctrl-C to stop.
# force-legacy=false makes the virtio-mmio devices use the modern (v2) interface
# our virtio-input driver speaks; the firmware still boots the disk over it.
run-gfx: disk base-image
	$(QEMU) -M virt,acpi=off -cpu cortex-a72 -m 256M -no-reboot \
		-global virtio-mmio.force-legacy=false \
		-bios $(AAVMF_CODE) -drive file=$(DISK_IMG),format=raw,if=virtio \
		-drive file=$(BASE_IMG),format=raw,if=none,id=swosbase,readonly=on \
		-device virtio-blk-device,drive=swosbase \
		-device ramfb -device virtio-keyboard-device -display cocoa -serial stdio

$(BASEPACK): tools/basepack.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/basepack.swift -o $@

$(BASE_IMG): $(BASEPACK) $(BASE_SEED_FILES) $(BASE_EXEC_ELFS) Makefile
	rm -rf $(BASE_ROOT)
	mkdir -p $(BASE_ROOT)
	cp -R base/. $(BASE_ROOT)/
	mkdir -p $(BASE_ROOT)/bin
	cp $(USER_HELLO_ELF) $(BASE_ROOT)/bin/hello
	cp $(USER_TTYDEMO_ELF) $(BASE_ROOT)/bin/ttydemo
	cp $(USER_ARGVDEMO_ELF) $(BASE_ROOT)/bin/argvdemo
	cp $(USER_SPAWNDEMO_ELF) $(BASE_ROOT)/bin/spawndemo
	cp $(USER_FSDEMO_ELF) $(BASE_ROOT)/bin/fsdemo
	cp $(USER_BRKDEMO_ELF) $(BASE_ROOT)/bin/brkdemo
	cp $(USER_NEWLIBTEST_ELF) $(BASE_ROOT)/bin/newlibtest
	cp $(USER_COPROC_ELF) $(BASE_ROOT)/bin/coproc
	cp $(USER_FORKDEMO_ELF) $(BASE_ROOT)/bin/forkdemo
	cp $(USER_EXECDEMO_ELF) $(BASE_ROOT)/bin/execdemo
	cp $(USER_FDOPSDEMO_ELF) $(BASE_ROOT)/bin/fdopsdemo
	cp $(USER_SECURITYDEMO_ELF) $(BASE_ROOT)/bin/securitydemo
	cp $(USER_PS_ELF) $(BASE_ROOT)/bin/ps
	cp $(BUILD)/busybox.elf $(BASE_ROOT)/bin/busybox
	$(BASEPACK) $(BASE_ROOT) $@

base-image: $(BASE_IMG)

newlib:
	./scripts/build-newlib.sh

busybox:
	./scripts/build-busybox.sh

# busybox.elf is produced by `make busybox` (slow; needs newlib + network).
$(BUILD)/busybox.elf:
	@echo "busybox not built. Run: make busybox" >&2; exit 1

busybox-check:
	./scripts/busybox-check.sh

clean:
	rm -rf $(BUILD)/*.o $(BUILD)/*.obj $(BUILD)/*.elf $(BUILD)/*.bin $(BUILD)/*.EFI $(BUILD)/*.img \
		$(BUILD)/basepack $(BUILD)/base_image_test $(BASE_ROOT) $(ESP_DIR)

# Print the resolved toolchain so failures are easy to diagnose.
tools-check:
	@echo "SWIFTC  = $(SWIFTC)";  $(SWIFTC) --version | head -1
	@echo "HOST_SWIFTC = $(HOST_SWIFTC)"; $(HOST_SWIFTC) --version | head -1
	@echo "CLANG   = $(CLANG)";   $(CLANG) --version | head -1
	@echo "LDBIN   = $(LDBIN)";   $(LDBIN) --version | head -1
	@echo "OBJCOPY = $(OBJCOPY)"; $(OBJCOPY) --version | head -1
	@echo "QEMU    = $(QEMU)";    $(QEMU) --version | head -1
