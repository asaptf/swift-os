# swift-os — top-level build.
#
# Targets:
#   make build   Build the kernel image (build/kernel.elf).
#   make run     Boot the kernel in QEMU on the serial console.
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

# Swift sources (kernel). Whole-module optimization compiles them together.
SWIFT_SRCS := \
	kernel/main.swift \
	kernel/drivers/uart.swift \
	kernel/drivers/gic.swift \
	kernel/timer/generic_timer.swift \
	kernel/sched/scheduler.swift \
	kernel/syscall/syscall.swift \
	kernel/user/user_process.swift \
	kernel/user/process.swift \
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
	-import-objc-header $(BRIDGE)

ASM_FLAGS := --target=$(TRIPLE) -ffreestanding -c
C_FLAGS   := --target=$(TRIPLE) -ffreestanding -O2 -Wall -Wextra -c
# -fno-builtin so mem* implementations are not turned into calls to themselves.
C_FLAGS_NB := --target=$(TRIPLE) -ffreestanding -fno-builtin -O2 -Wall -Wextra -c
# Userland (EL0) build: freestanding, static, our own libc/crt0, no host libc.
USER_CFLAGS  := --target=$(TRIPLE) -ffreestanding -fno-builtin -nostdlib -Os -Wall -Wextra \
	-Iuserland -Iuserland/lib -c
USER_LDFLAGS := -nostdlib -static -T userland/user.ld -z max-page-size=4096
# Garbage-collect unused sections; entry is _start from the boot stub.
LD_FLAGS  := --gc-sections -nostdlib -T $(LINKER)

# ---- QEMU ------------------------------------------------------------------
QEMU_FLAGS := -M virt -cpu cortex-a72 -m 256M -nographic -kernel $(BUILD)/kernel.elf

# ---- Objects ---------------------------------------------------------------
BOOT_OBJ   := $(BUILD)/boot.o
EXC_OBJ    := $(BUILD)/exceptions.o
SWITCH_OBJ := $(BUILD)/switch.o
HEAP_OBJ   := $(BUILD)/heap.o
STRING_OBJ := $(BUILD)/string.o
VM_OBJ     := $(BUILD)/vm.o
EL0_OBJ    := $(BUILD)/el0.o
ELF_OBJ    := $(BUILD)/elf.o
USER_ENTRY_OBJ := $(BUILD)/user_entry.o
USER_BLOB_OBJ  := $(BUILD)/user_blob.o
KERNEL_OBJ := $(BUILD)/kernel.o
KERNEL_ELF := $(BUILD)/kernel.elf
KERNEL_BIN := $(BUILD)/kernel.bin

# Userland artifacts (a static C hello-world, embedded into the kernel image).
USER_HELLO_ELF := $(BUILD)/hello.elf

.PHONY: build run debug gdb test clean tools-check

build: $(KERNEL_ELF)

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

$(EL0_OBJ): kernel/user/el0.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(ELF_OBJ): kernel/user/elf.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(USER_ENTRY_OBJ): $(ARCH_DIR)/user_entry.S Makefile | $(BUILD)/.dir
	$(CLANG) $(ASM_FLAGS) $< -o $@

# --- Userland (EL0) -------------------------------------------------------
$(BUILD)/user_crt0.o: userland/lib/crt0.S userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/lib/crt0.S -o $@

$(BUILD)/user_libc.o: userland/lib/libc.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/lib/libc.c -o $@

$(BUILD)/user_hello.o: userland/hello.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/hello.c -o $@

$(USER_HELLO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_hello.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_hello.o -o $@

# Embed the userland ELF into the kernel image (no block device yet).
$(USER_BLOB_OBJ): kernel/user/user_blob.S $(USER_HELLO_ELF) Makefile | $(BUILD)/.dir
	$(CLANG) $(ASM_FLAGS) $< -o $@

$(KERNEL_OBJ): $(SWIFT_SRCS) $(BRIDGE) Makefile | $(BUILD)/.dir
	$(SWIFTC) $(SWIFT_FLAGS) -c $(SWIFT_SRCS) -o $@

# Link the freestanding image.
KERNEL_OBJS := $(BOOT_OBJ) $(EXC_OBJ) $(SWITCH_OBJ) $(USER_ENTRY_OBJ) $(HEAP_OBJ) $(STRING_OBJ) \
	$(VM_OBJ) $(EL0_OBJ) $(ELF_OBJ) $(USER_BLOB_OBJ) $(KERNEL_OBJ)

$(KERNEL_ELF): $(KERNEL_OBJS) $(LINKER)
	$(LDBIN) $(LD_FLAGS) $(KERNEL_OBJS) -o $@
	$(OBJCOPY) -O binary $@ $(KERNEL_BIN)
	@echo "Built $(KERNEL_ELF)"

run: build
	$(QEMU) $(QEMU_FLAGS)

# Paused under the gdbstub on tcp::1234. Attach with `make gdb` in another shell.
debug: build
	$(QEMU) $(QEMU_FLAGS) -s -S

gdb:
	$(GDB) $(KERNEL_ELF) -ex 'target remote :1234'

test: build
	$(HOST_SWIFTC) tests/page_allocator_test.swift kernel/mm/page_allocator.swift -o $(BUILD)/page_allocator_test
	$(BUILD)/page_allocator_test
	./tests/userland_elf_test.sh
	./tests/boot_test.sh

clean:
	rm -rf $(BUILD)/*.o $(BUILD)/*.elf $(BUILD)/*.bin

# Print the resolved toolchain so failures are easy to diagnose.
tools-check:
	@echo "SWIFTC  = $(SWIFTC)";  $(SWIFTC) --version | head -1
	@echo "HOST_SWIFTC = $(HOST_SWIFTC)"; $(HOST_SWIFTC) --version | head -1
	@echo "CLANG   = $(CLANG)";   $(CLANG) --version | head -1
	@echo "LDBIN   = $(LDBIN)";   $(LDBIN) --version | head -1
	@echo "OBJCOPY = $(OBJCOPY)"; $(OBJCOPY) --version | head -1
	@echo "QEMU    = $(QEMU)";    $(QEMU) --version | head -1
