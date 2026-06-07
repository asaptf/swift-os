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
# Embedded Swift's prebuilt Unicode normalization/grapheme tables. Linked into
# userland programs that use dynamic String comparison/hashing (e.g. /bin/calc's
# Dictionary<String,Int64>); --gc-sections trims it to only the referenced data.
SWIFT_UNICODE_DATA := $(TOOLCHAIN)/usr/lib/swift/embedded/$(TRIPLE)/libswiftUnicodeDataTables.a
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
	kernel/drivers/fb.swift \
	kernel/drivers/gic.swift \
	kernel/drivers/virtio_net.swift \
	kernel/drivers/virtio_blk.swift \
	kernel/drivers/virtio_input.swift \
	kernel/net/packet.swift \
	kernel/net/ethernet.swift \
	kernel/net/arp.swift \
	kernel/net/ipv4.swift \
	kernel/net/icmp.swift \
	kernel/net/udp.swift \
	kernel/net/dns.swift \
	kernel/net/tcp.swift \
	kernel/net/stack.swift \
	kernel/net/socket.swift \
	kernel/crypto/chacha20poly1305.swift \
	kernel/timer/generic_timer.swift \
	kernel/sched/scheduler.swift \
	kernel/sched/futex.swift \
	kernel/syscall/syscall.swift \
	kernel/tty/tty.swift \
	kernel/signal/signal.swift \
	kernel/security/security.swift \
	kernel/user/user_access.swift \
	kernel/user/user_process.swift \
	kernel/user/process.swift \
	kernel/user/exec.swift \
	kernel/user/elf.swift \
	kernel/user/ustack.swift \
	kernel/vfs/handle.swift \
	kernel/vfs/vfs.swift \
	kernel/mm/page_allocator.swift \
	kernel/mm/pmm.swift \
	kernel/mm/vm.swift

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
EL0_OBJ    := $(BUILD)/el0.o
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
USER_IDENTITYDEMO_ELF := $(BUILD)/identitydemo.elf
USER_CONSOLELOGIN_ELF := $(BUILD)/console-login.elf
USER_PS_ELF := $(BUILD)/ps.elf
USER_ID_ELF := $(BUILD)/id.elf
USER_LS_ELF := $(BUILD)/ls.elf
USER_CAT_ELF := $(BUILD)/cat.elf
USER_ECHO_ELF := $(BUILD)/echo.elf
USER_PWD_ELF := $(BUILD)/pwd.elf
USER_MKDIR_ELF := $(BUILD)/mkdir.elf
USER_RMDIR_ELF := $(BUILD)/rmdir.elf
USER_RM_ELF := $(BUILD)/rm.elf
USER_MV_ELF := $(BUILD)/mv.elf
USER_CHMOD_ELF := $(BUILD)/chmod.elf
USER_CHOWN_ELF := $(BUILD)/chown.elf
USER_DATE_ELF := $(BUILD)/date.elf
USER_CALC_ELF := $(BUILD)/calc.elf
USER_KV_ELF := $(BUILD)/kv.elf
USER_HEAD_ELF := $(BUILD)/head.elf
USER_TOUCH_ELF := $(BUILD)/touch.elf
USER_WC_ELF := $(BUILD)/wc.elf
USER_TOP_ELF := $(BUILD)/top.elf
USER_UDPECHO_ELF := $(BUILD)/udpecho.elf
USER_TCPECHO_ELF := $(BUILD)/tcpecho.elf
USER_THREADSDEMO_ELF := $(BUILD)/threadsdemo.elf
USER_MMAPDEMO_ELF := $(BUILD)/mmapdemo.elf
USER_TCPGET_ELF := $(BUILD)/tcpget.elf
USER_TLSGET_ELF := $(BUILD)/tlsget.elf
USER_HTTPD_ELF := $(BUILD)/httpd.elf
USER_NSLOOKUP_ELF := $(BUILD)/nslookup.elf
BASE_EXEC_ELFS := \
	$(USER_CALC_ELF) \
	$(USER_KV_ELF) \
	$(USER_HEAD_ELF) \
	$(USER_TOUCH_ELF) \
	$(USER_WC_ELF) \
	$(USER_TOP_ELF) \
	$(USER_UDPECHO_ELF) \
	$(USER_TCPECHO_ELF) \
	$(USER_THREADSDEMO_ELF) \
	$(USER_MMAPDEMO_ELF) \
	$(USER_TCPGET_ELF) \
	$(USER_TLSGET_ELF) \
	$(USER_HTTPD_ELF) \
	$(USER_NSLOOKUP_ELF) \
	$(USER_CONSOLELOGIN_ELF) \
	$(USER_ID_ELF) \
	$(USER_LS_ELF) \
	$(USER_CAT_ELF) \
	$(USER_ECHO_ELF) \
	$(USER_PWD_ELF) \
	$(USER_MKDIR_ELF) \
	$(USER_RMDIR_ELF) \
	$(USER_RM_ELF) \
	$(USER_MV_ELF) \
	$(USER_CHMOD_ELF) \
	$(USER_CHOWN_ELF) \
	$(USER_DATE_ELF) \
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
	$(USER_IDENTITYDEMO_ELF) \
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

# C2: vm.c split into vm_early.c (MMU-off bring-up half, C) + vm.swift
# (per-process address spaces, Swift — listed in SWIFT_SRCS above).
$(VM_OBJ): kernel/mm/vm_early.c $(BRIDGE) Makefile | $(BUILD)/.dir
	$(CLANG) $(C_FLAGS) $< -o $@

$(EL0_OBJ): kernel/user/el0.c $(BRIDGE) Makefile | $(BUILD)/.dir
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

$(BUILD)/user_identitydemo.o: userland/identitydemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/identitydemo.c -o $@

$(BUILD)/user_console-login.o: userland/console-login.swift kernel/crypto/sha256.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/console-login.swift kernel/crypto/sha256.swift -o $@

$(BUILD)/user_ps.o: userland/ps.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ps.swift -o $@

$(BUILD)/user_id.o: userland/id.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/id.swift -o $@

$(BUILD)/user_ls.o: userland/ls.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ls.swift -o $@

$(BUILD)/user_cat.o: userland/cat.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cat.swift -o $@

$(BUILD)/user_echo.o: userland/echo.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/echo.swift -o $@

$(BUILD)/user_pwd.o: userland/pwd.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/pwd.swift -o $@

$(BUILD)/user_mkdir.o: userland/mkdir.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/mkdir.swift -o $@

$(BUILD)/user_rmdir.o: userland/rmdir.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/rmdir.swift -o $@

$(BUILD)/user_rm.o: userland/rm.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/rm.swift -o $@

$(BUILD)/user_mv.o: userland/mv.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/mv.swift -o $@

$(BUILD)/user_chmod.o: userland/chmod.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/chmod.swift -o $@

$(BUILD)/user_chown.o: userland/chown.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/chown.swift -o $@

$(BUILD)/user_date.o: userland/date.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/date.swift -o $@

$(BUILD)/user_calc.o: userland/calc.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/calc.swift -o $@

$(BUILD)/user_kv.o: userland/kv.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/kv.swift -o $@

$(BUILD)/user_head.o: userland/head.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/head.swift -o $@

$(BUILD)/user_touch.o: userland/touch.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/touch.swift -o $@

$(BUILD)/user_tcpecho.o: userland/tcpecho.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/tcpecho.swift -o $@

$(BUILD)/user_threadsdemo.o: userland/threadsdemo.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/threadsdemo.swift -o $@

$(BUILD)/user_mmapdemo.o: userland/mmapdemo.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/mmapdemo.swift -o $@

$(BUILD)/user_tcpget.o: userland/tcpget.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/tcpget.swift -o $@

# /bin/tlsget links the pure-Swift TLS 1.3 client + crypto into one module
# (mirrors the host tls_handshake_test target and the console-login+sha256 rule).
TLS_SWIFT_SRCS := userland/lib/tls13.swift kernel/crypto/sha256.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift
$(BUILD)/user_tlsget.o: userland/tlsget.swift $(TLS_SWIFT_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/tlsget.swift $(TLS_SWIFT_SRCS) -o $@

$(BUILD)/user_httpd.o: userland/httpd.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/httpd.swift -o $@

$(BUILD)/user_nslookup.o: userland/nslookup.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/nslookup.swift -o $@

$(BUILD)/user_udpecho.o: userland/udpecho.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/udpecho.swift -o $@

$(BUILD)/user_wc.o: userland/wc.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/wc.swift -o $@

$(BUILD)/user_top.o: userland/top.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/top.swift -o $@

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

$(USER_IDENTITYDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_identitydemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_identitydemo.o -o $@

$(USER_CONSOLELOGIN_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_console-login.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_console-login.o -o $@

$(USER_PS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o -o $@

$(USER_ID_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_id.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_id.o -o $@

$(USER_LS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ls.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ls.o -o $@

$(USER_CAT_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cat.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cat.o -o $@

$(USER_ECHO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_echo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_echo.o -o $@

$(USER_PWD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_pwd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_pwd.o -o $@

$(USER_MKDIR_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mkdir.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mkdir.o -o $@

$(USER_RMDIR_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_rmdir.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_rmdir.o -o $@

$(USER_RM_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_rm.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_rm.o -o $@

$(USER_MV_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mv.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mv.o -o $@

$(USER_CHMOD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_chmod.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_chmod.o -o $@

$(USER_CHOWN_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_chown.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_chown.o -o $@

$(USER_DATE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_date.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_date.o -o $@

# calc and kv link the Unicode data tables (they use dynamic String compare/hashing).
$(USER_CALC_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_calc.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_calc.o $(SWIFT_UNICODE_DATA) -o $@

$(USER_KV_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_kv.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_kv.o $(SWIFT_UNICODE_DATA) -o $@

$(USER_HEAD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_head.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_head.o -o $@

$(USER_TOUCH_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_touch.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_touch.o -o $@

$(USER_WC_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_wc.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_wc.o -o $@

$(USER_TOP_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_top.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_top.o -o $@

$(USER_UDPECHO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_udpecho.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_udpecho.o -o $@

$(USER_TCPECHO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_tcpecho.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_tcpecho.o -o $@

$(USER_THREADSDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_threadsdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_threadsdemo.o -o $@

$(USER_MMAPDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mmapdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mmapdemo.o -o $@

$(USER_TCPGET_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_tcpget.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_tcpget.o -o $@

$(USER_TLSGET_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_tlsget.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_tlsget.o -o $@

$(USER_HTTPD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_httpd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_httpd.o -o $@

$(USER_NSLOOKUP_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_nslookup.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_nslookup.o -o $@

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
	$(VM_OBJ) $(EL0_OBJ) $(KERNEL_OBJ)

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
	$(HOST_SWIFTC) tests/net_test.swift kernel/net/packet.swift kernel/net/ethernet.swift kernel/net/arp.swift kernel/net/ipv4.swift kernel/net/icmp.swift kernel/net/udp.swift kernel/net/tcp.swift kernel/net/dns.swift kernel/net/stack.swift -o $(BUILD)/net_test
	$(BUILD)/net_test
	$(HOST_SWIFTC) tests/crypto_test.swift kernel/crypto/chacha20poly1305.swift -o $(BUILD)/crypto_test
	$(BUILD)/crypto_test
	$(HOST_SWIFTC) tests/handle_test.swift kernel/vfs/handle.swift -o $(BUILD)/handle_test
	$(BUILD)/handle_test
	$(HOST_SWIFTC) tests/hkdf_test.swift kernel/crypto/sha256.swift -o $(BUILD)/hkdf_test
	$(BUILD)/hkdf_test
	$(HOST_SWIFTC) tests/x25519_test.swift kernel/crypto/x25519.swift -o $(BUILD)/x25519_test
	$(BUILD)/x25519_test
	$(HOST_SWIFTC) tests/tls_handshake_test.swift userland/lib/tls13.swift kernel/crypto/sha256.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift -o $(BUILD)/tls_handshake_test
	$(BUILD)/tls_handshake_test
	./tests/userland_elf_test.sh
	./tests/boot_test.sh
	./tests/tty_test.sh
	./tests/virtio_blk_test.sh
	./tests/virtio_net_test.sh
	./tests/udp_echo_test.sh
	./tests/tcp_echo_test.sh
	./tests/tcp_connect_test.sh
	./tests/tls_test.sh
	./tests/httpd_test.sh
	./tests/dns_test.sh
	./tests/vfs_disk_test.sh
	./tests/disk_exec_test.sh
	./tests/console_login_test.sh
	./tests/cap_enforce_test.sh
	./tests/ls_l_test.sh
	./tests/redirect_test.sh
	./tests/swift_ls_test.sh
	./tests/swift_coreutils_test.sh
	./tests/swift_fileops_test.sh
	./tests/swift_rm_r_test.sh
	./tests/swift_chmodown_test.sh
	./tests/swift_headwc_test.sh
	./tests/swift_date_test.sh
	./tests/calc_test.sh
	./tests/kv_test.sh
	./tests/top_test.sh
	./tests/busybox_test.sh
	./tests/threads_test.sh
	./tests/mmap_test.sh
	./tests/vi_test.sh
	UEFI_BOOT=disk ./tests/uefi_boot_test.sh
	./tests/fb_vi_test.sh

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
	cp $(USER_IDENTITYDEMO_ELF) $(BASE_ROOT)/bin/identitydemo
	cp $(USER_CONSOLELOGIN_ELF) $(BASE_ROOT)/bin/console-login
	cp $(USER_PS_ELF) $(BASE_ROOT)/bin/ps
	cp $(USER_ID_ELF) $(BASE_ROOT)/bin/id
	cp $(USER_LS_ELF) $(BASE_ROOT)/bin/ls
	cp $(USER_CAT_ELF) $(BASE_ROOT)/bin/cat
	cp $(USER_ECHO_ELF) $(BASE_ROOT)/bin/echo
	cp $(USER_PWD_ELF) $(BASE_ROOT)/bin/pwd
	cp $(USER_MKDIR_ELF) $(BASE_ROOT)/bin/mkdir
	cp $(USER_RMDIR_ELF) $(BASE_ROOT)/bin/rmdir
	cp $(USER_RM_ELF) $(BASE_ROOT)/bin/rm
	cp $(USER_MV_ELF) $(BASE_ROOT)/bin/mv
	cp $(USER_CHMOD_ELF) $(BASE_ROOT)/bin/chmod
	cp $(USER_CHOWN_ELF) $(BASE_ROOT)/bin/chown
	cp $(USER_DATE_ELF) $(BASE_ROOT)/bin/date
	cp $(USER_CALC_ELF) $(BASE_ROOT)/bin/calc
	cp $(USER_KV_ELF) $(BASE_ROOT)/bin/kv
	cp $(USER_HEAD_ELF) $(BASE_ROOT)/bin/head
	cp $(USER_TOUCH_ELF) $(BASE_ROOT)/bin/touch
	cp $(USER_WC_ELF) $(BASE_ROOT)/bin/wc
	cp $(USER_TOP_ELF) $(BASE_ROOT)/bin/top
	cp $(USER_UDPECHO_ELF) $(BASE_ROOT)/bin/udpecho
	cp $(USER_TCPECHO_ELF) $(BASE_ROOT)/bin/tcpecho
	cp $(USER_THREADSDEMO_ELF) $(BASE_ROOT)/bin/threadsdemo
	cp $(USER_MMAPDEMO_ELF) $(BASE_ROOT)/bin/mmapdemo
	cp $(USER_TCPGET_ELF) $(BASE_ROOT)/bin/tcpget
	cp $(USER_TLSGET_ELF) $(BASE_ROOT)/bin/tlsget
	cp $(USER_HTTPD_ELF) $(BASE_ROOT)/bin/httpd
	cp $(USER_NSLOOKUP_ELF) $(BASE_ROOT)/bin/nslookup
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
