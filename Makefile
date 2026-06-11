# swift-os — top-level build.
#
# Targets:
#   make build   Build the kernel image (build/kernel.elf).
#   make run     Boot the kernel in QEMU on the serial console.
#   make run-gfx Boot the UEFI disk in a graphical window (ramfb framebuffer).
#   make debug   Boot under QEMU's gdbstub (paused), for `make gdb` / lldb.
#   make test    Build, then run the boot acceptance test(s).
#   make docs-test Check Markdown links/anchors, API refs, maps, commands, ports.
#   make smp-test Build, then run the pre-S0 SMP boot smoke.
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
MODEL_DIR := models
QEMU_DTB  := $(BUILD)/virt.dtb
QEMU_DTB_SMP4 := $(BUILD)/virt-smp4.dtb
QEMU_DTB_ADDR := 0x4FF00000
BASE_IMG  := $(BUILD)/base.img
BASEPACK  := $(BUILD)/basepack
UPDATESTORE := $(BUILD)/updatestore
KERNELBOOT := $(BUILD)/kernelboot
SWPKG     := $(BUILD)/swpkg
PKGSTORE  := $(BUILD)/pkgstore
PKGREPO   := $(BUILD)/pkgrepo
SWPORT    := $(BUILD)/swport
SWPORT_CATALOG_TEST := $(BUILD)/swport_catalog_test
SWPORT_RECIPE_TEST := $(BUILD)/swport_recipe_test
IMG_SIGNING_SEED := $(MODEL_DIR)/dev-image-signing.seed
IMG_SIGNING_PUB := $(MODEL_DIR)/dev-image-signing.pub
BASE_ROOT := $(BUILD)/base-root
PKGHELLO_ROOT := $(BUILD)/pkghello-root
PKGHELLO_PKG := $(BUILD)/pkghello.swpkg
PKGHELLO_PAYLOAD_IMG := $(BUILD)/pkghello-payload.img
PKGHELLO_STORE_IMG := $(BUILD)/pkgstore-pkghello.img
PKG_EMPTY_STORE_IMG := $(BUILD)/pkgstore-empty.img
PKG_INSTALL_STORE_IMG := $(BUILD)/pkgstore-install.img
PKG_LUA_INSTALL_STORE_IMG := $(BUILD)/pkgstore-lua-install.img
PKG_PORTS_INSTALL_STORE_SIZE := 33554432
PKGREPO_ROOT := $(BUILD)/pkgrepo-root
PKGREPO_PUB := $(BUILD)/pkgrepo-root.pub
PKGREPO_SEED_HEX := 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
PORTS_SEED_REPO_ROOT := $(BUILD)/ports-seed-repo-root
PORTS_SEED_REPO_PUB := $(BUILD)/ports-seed-repo-root.pub
PORTS_STATIC_HOST_ROOT := $(BUILD)/ports-static-host-root
PORTS_STATIC_HOST_BASE_URL ?=
PKG_HOSTED_REPO_URL ?=
PKG_DEFAULT_DNS_SERVER ?=
PKG_DEFAULT_REPO_URL ?=
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
	kernel/arch/aarch64/cpu.swift \
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
	kernel/net/ipv6.swift \
	kernel/net/icmp.swift \
	kernel/net/icmp6.swift \
	kernel/net/udp.swift \
	kernel/net/dns.swift \
	kernel/net/tcp.swift \
	kernel/net/stack.swift \
	kernel/net/socket.swift \
	kernel/crypto/chacha20poly1305.swift \
	kernel/crypto/sha256.swift \
	kernel/crypto/sha512.swift \
	kernel/crypto/ed25519.swift \
	kernel/pkg/store.swift \
	kernel/smp/atomic.swift \
	kernel/smp/percpu.swift \
	kernel/smp/secondary.swift \
	kernel/smp/topology.swift \
	kernel/log/log.swift \
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
	kernel/fs/swosboot.swift \
	kernel/fs/updatestore.swift \
	kernel/fs/esp.swift \
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
NEWLIB_COMPAT_CFLAGS := -ffreestanding -Os -Wall -isystem userland/compat -isystem $(SYSROOT)/include -c
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
# U1g-4: the ESP is on virtio-mmio (if=none + virtio-blk-device), not if=virtio
# (PCI), so the running kernel — which drives only virtio-mmio — can also read it.
UEFI_QEMU_FLAGS := -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
	-bios $(AAVMF_CODE) \
	-drive file=fat:rw:$(ESP_DIR),format=raw,if=none,id=esp \
	-device virtio-blk-device,drive=esp \
	$(UEFI_BASE_DISK)

# ---- Objects ---------------------------------------------------------------
BOOT_OBJ   := $(BUILD)/boot.o
EXC_OBJ    := $(BUILD)/exceptions.o
SWITCH_OBJ := $(BUILD)/switch.o
HEAP_OBJ   := $(BUILD)/heap.o
STRING_OBJ := $(BUILD)/string.o
VM_OBJ     := $(BUILD)/vm.o
EL0_OBJ    := $(BUILD)/el0.o
SMP_SECONDARY_OBJ := $(BUILD)/smp_secondary.o
USER_ENTRY_OBJ := $(BUILD)/user_entry.o
TRUST_ROOT_OBJ := $(BUILD)/trust_root.o
KERNEL_OBJ := $(BUILD)/kernel.o
KERNEL_ELF := $(BUILD)/kernel.elf
KERNEL_BIN := $(BUILD)/kernel.bin

# Userland artifacts (static C programs, embedded into the kernel image).
USER_HELLO_ELF := $(BUILD)/hello.elf
USER_TTYDEMO_ELF := $(BUILD)/ttydemo.elf
USER_ARGVDEMO_ELF := $(BUILD)/argvdemo.elf
USER_SPAWNDEMO_ELF := $(BUILD)/spawndemo.elf
USER_SELFEXECDEMO_ELF := $(BUILD)/selfexecdemo.elf
USER_FSDEMO_ELF := $(BUILD)/fsdemo.elf
USER_BRKDEMO_ELF := $(BUILD)/brkdemo.elf
USER_NEWLIBTEST_ELF := $(BUILD)/newlibtest.elf
USER_CLOCKPROBE_ELF := $(BUILD)/clockprobe.elf
USER_MPROTECTPROBE_ELF := $(BUILD)/mprotectprobe.elf
USER_COPROC_ELF := $(BUILD)/coproc.elf
USER_FORKDEMO_ELF := $(BUILD)/forkdemo.elf
USER_EXECDEMO_ELF := $(BUILD)/execdemo.elf
USER_FDOPSDEMO_ELF := $(BUILD)/fdopsdemo.elf
USER_S4STRESS_ELF := $(BUILD)/s4stress.elf
USER_SECURITYDEMO_ELF := $(BUILD)/securitydemo.elf
USER_IDENTITYDEMO_ELF := $(BUILD)/identitydemo.elf
USER_CONSOLELOGIN_ELF := $(BUILD)/console-login.elf
USER_SLEEPPROBE_ELF := $(BUILD)/sleepprobe.elf
USER_PS_ELF := $(BUILD)/ps.elf
USER_ID_ELF := $(BUILD)/id.elf
USER_SWOSCONFIRM_ELF := $(BUILD)/swos-confirm.elf
USER_SWOSACTIVATE_ELF := $(BUILD)/swos-activate.elf
USER_SWOSUPDATE_ELF := $(BUILD)/swos-update.elf
USER_SWOSKSTAGE_ELF := $(BUILD)/swos-kstage.elf
USER_SWOSKACTIVATE_ELF := $(BUILD)/swos-kactivate.elf
USER_SWOSKCONFIRM_ELF := $(BUILD)/swos-kconfirm.elf
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
USER_C4B_SOCKXFER_ELF := $(BUILD)/c4b-sockxfer.elf
USER_DRVINPUTD_ELF := $(BUILD)/drvinputd.elf
USER_DRVSVCDEMO_ELF := $(BUILD)/drvsvcdemo.elf
USER_PKG_ELF := $(BUILD)/pkg.elf
USER_LLM_ELF := $(BUILD)/llm.elf
USER_LLMD_ELF := $(BUILD)/llmd.elf
USER_PKGHELLO_ELF := $(BUILD)/pkghello.elf
BASE_EXEC_ELFS := \
	$(USER_CALC_ELF) \
	$(USER_LLM_ELF) \
	$(USER_LLMD_ELF) \
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
	$(USER_C4B_SOCKXFER_ELF) \
	$(USER_DRVINPUTD_ELF) \
	$(USER_DRVSVCDEMO_ELF) \
	$(USER_PKG_ELF) \
	$(USER_CONSOLELOGIN_ELF) \
	$(USER_ID_ELF) \
	$(USER_SWOSCONFIRM_ELF) \
	$(USER_SWOSACTIVATE_ELF) \
	$(USER_SWOSUPDATE_ELF) \
	$(USER_SWOSKSTAGE_ELF) \
	$(USER_SWOSKACTIVATE_ELF) \
	$(USER_SWOSKCONFIRM_ELF) \
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
	$(USER_SELFEXECDEMO_ELF) \
	$(USER_FSDEMO_ELF) \
	$(USER_BRKDEMO_ELF) \
	$(USER_NEWLIBTEST_ELF) \
	$(USER_CLOCKPROBE_ELF) \
	$(USER_MPROTECTPROBE_ELF) \
	$(USER_COPROC_ELF) \
	$(USER_FORKDEMO_ELF) \
	$(USER_EXECDEMO_ELF) \
	$(USER_FDOPSDEMO_ELF) \
	$(USER_S4STRESS_ELF) \
	$(USER_SECURITYDEMO_ELF) \
	$(USER_IDENTITYDEMO_ELF) \
	$(USER_PS_ELF) \
	$(USER_SLEEPPROBE_ELF) \
	$(BUILD)/busybox.elf

.PHONY: build run debug gdb test docs-test phase1-roadmap-test api-complete-examples-test examples-verification-test stability-coverage-test page-allocator-refcount-lifecycle-test qemu-virt-hardware-map-test clock-test mprotect-test smp-state-audit smp-mailbox-layout smp-release-guard smp-release-contract smp-s1-preflight smp-test smp-resource-stress-test smp-headroom-test smp-uefi-test s4-resource-stress-test smp-cpu-utilization-test s5-scheduler-placement-test s5-placement-stress-test s5-el0-fanout-test s5-thread-fanout-test s5-run-any-placement-test s5-test c5-test c5-driver-service-test c5-device-handle-test c5-device-discovery-test c5-device-metadata-test c5-device-authority-test c5-device-rights-test s0-test s0c-test s1-test model clean tools-check newlib busybox busybox-check uefi uefi-run disk disk-run base-image swpkg swpkg-header-integrity-test pkgstore pkgrepo swport ports-catalog-test ports-recipe-test ports-lua-repo-fixture ports-zlib-repo-fixture ports-bzip2-repo-fixture ports-zstd-repo-fixture ports-xz-repo-fixture ports-libarchive-repo-fixture ports-ca-certificates-repo-fixture ports-pcre2-repo-fixture ports-tzdata-repo-fixture ports-nginx-repo-fixture ports-sqlite-repo-fixture ports-seed-repo-fixture ports-static-host-publish ports-hosted-url-verify ports-hosted-url-verify-test package-fixture package-store-fixture package-repo-fixture package-overlay-test package-store-test package-local-install-fixture package-lua-install-fixture package-local-install-test package-repo-install-test package-lua-repo-install-test package-ports-seed-repo-install-test package-static-host-repo-install-test package-static-host-dns-repo-install-test package-hosted-url-install-test
build: $(KERNEL_ELF)

$(QEMU_DTB): | $(BUILD)/.dir
	$(QEMU) -M virt,dumpdtb=$@ -cpu cortex-a72 -m 256M -nographic

$(QEMU_DTB_SMP4): | $(BUILD)/.dir
	$(QEMU) -M virt,dumpdtb=$@ -cpu cortex-a72 -smp 4 -m 256M -nographic

$(BUILD)/.dir:
	@mkdir -p $(BUILD)
	@touch $@

# Assemble the boot stub with the LLVM cross clang.
$(BOOT_OBJ): $(ARCH_DIR)/boot.S Makefile | $(BUILD)/.dir
	$(CLANG) $(ASM_FLAGS) $< -o $@

# I8: embed the image-signing trust root (the .S incbins build/image_trust_root.bin).
$(BUILD)/image_trust_root.bin: $(IMG_SIGNING_PUB) | $(BUILD)/.dir
	cp $(IMG_SIGNING_PUB) $@
$(TRUST_ROOT_OBJ): kernel/security/trust_root.S $(BUILD)/image_trust_root.bin Makefile | $(BUILD)/.dir
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

$(SMP_SECONDARY_OBJ): kernel/smp/secondary.c $(BRIDGE) Makefile | $(BUILD)/.dir
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

$(BUILD)/user_selfexecdemo.o: userland/selfexecdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/selfexecdemo.c -o $@

$(BUILD)/user_fsdemo.o: userland/fsdemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/fsdemo.c -o $@

$(BUILD)/user_brkdemo.o: userland/brkdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/brkdemo.c -o $@

$(BUILD)/user_coproc.o: userland/coproc.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/coproc.c -o $@

$(BUILD)/user_forkdemo.o: userland/forkdemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/forkdemo.c -o $@

$(BUILD)/user_c4b_sockxfer.o: userland/c4b_sockxfer.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/c4b_sockxfer.c -o $@

$(BUILD)/user_drvinputd.o: userland/drvinputd.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/drvinputd.c -o $@

$(BUILD)/user_drvsvcdemo.o: userland/drvsvcdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/drvsvcdemo.c -o $@

$(BUILD)/user_execdemo.o: userland/execdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/execdemo.c -o $@

$(BUILD)/user_fdopsdemo.o: userland/fdopsdemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/fdopsdemo.c -o $@

$(BUILD)/user_s4stress.o: userland/s4stress.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/s4stress.c -o $@

$(BUILD)/user_securitydemo.o: userland/securitydemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/securitydemo.c -o $@

$(BUILD)/user_identitydemo.o: userland/identitydemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/identitydemo.c -o $@

$(BUILD)/user_console-login.o: userland/console-login.swift kernel/crypto/sha256.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/console-login.swift kernel/crypto/sha256.swift -o $@

$(BUILD)/user_ps.o: userland/ps.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ps.swift -o $@

$(BUILD)/user_sleepprobe.o: userland/sleepprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/sleepprobe.swift -o $@

$(BUILD)/user_id.o: userland/id.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/id.swift -o $@

$(BUILD)/user_swosconfirm.o: userland/swos-confirm.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-confirm.swift -o $@

$(BUILD)/user_swosactivate.o: userland/swos-activate.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-activate.swift -o $@

$(BUILD)/user_swosupdate.o: userland/swos-update.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-update.swift -o $@

$(BUILD)/user_swoskstage.o: userland/swos-kstage.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-kstage.swift -o $@

$(BUILD)/user_swoskactivate.o: userland/swos-kactivate.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-kactivate.swift -o $@

$(BUILD)/user_swoskconfirm.o: userland/swos-kconfirm.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-kconfirm.swift -o $@

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

# /bin/llm: the app wrapper + the shared engine, compiled together (WMO).
$(BUILD)/user_llm.o: userland/llm.swift userland/lib/llama2.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/llm.swift userland/lib/llama2.swift -o $@

# /bin/llmd: the TCP model-serving daemon + the shared engine + bundle
# verification (manifest parse + sha256), compiled together (WMO).
$(BUILD)/user_llmd.o: userland/llmd.swift userland/lib/llama2.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/llmd.swift userland/lib/llama2.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

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

$(BUILD)/user_pkghello.o: userland/pkghello.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/pkghello.swift -o $@

PKG_SWIFT_SRCS := kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift
$(BUILD)/user_pkg.o: userland/pkg.swift $(PKG_SWIFT_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/pkg.swift $(PKG_SWIFT_SRCS) -o $@

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

$(USER_SELFEXECDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_selfexecdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_selfexecdemo.o -o $@

$(USER_FSDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fsdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fsdemo.o -o $@

$(USER_BRKDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_brkdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_brkdemo.o -o $@

$(USER_COPROC_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_coproc.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_coproc.o -o $@

$(USER_FORKDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_forkdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_forkdemo.o -o $@

$(USER_C4B_SOCKXFER_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_c4b_sockxfer.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_c4b_sockxfer.o -o $@

$(USER_DRVINPUTD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvinputd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvinputd.o -o $@

$(USER_DRVSVCDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvsvcdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvsvcdemo.o -o $@

$(USER_EXECDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_execdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_execdemo.o -o $@

$(USER_FDOPSDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fdopsdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fdopsdemo.o -o $@

$(USER_S4STRESS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_s4stress.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_s4stress.o -o $@

$(USER_SECURITYDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_securitydemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_securitydemo.o -o $@

$(USER_IDENTITYDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_identitydemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_identitydemo.o -o $@

$(USER_CONSOLELOGIN_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_console-login.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_console-login.o -o $@

$(USER_PS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o -o $@

$(USER_SLEEPPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sleepprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sleepprobe.o -o $@

$(USER_ID_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_id.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_id.o -o $@

$(USER_SWOSCONFIRM_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosconfirm.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosconfirm.o -o $@

$(USER_SWOSACTIVATE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosactivate.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosactivate.o -o $@

$(USER_SWOSUPDATE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosupdate.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosupdate.o -o $@

$(USER_SWOSKSTAGE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskstage.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskstage.o -o $@

$(USER_SWOSKACTIVATE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskactivate.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskactivate.o -o $@

$(USER_SWOSKCONFIRM_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskconfirm.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskconfirm.o -o $@

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

# /bin/llm links the Unicode data tables (the BPE tokenizer hashes String keys).
$(USER_LLM_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_llm.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_llm.o $(SWIFT_UNICODE_DATA) -o $@

$(USER_LLMD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_llmd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_llmd.o $(SWIFT_UNICODE_DATA) -o $@

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

$(USER_PKGHELLO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_pkghello.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_pkghello.o -o $@

$(USER_PKG_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_pkg.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_pkg.o $(SWIFT_UNICODE_DATA) -o $@

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

$(BUILD)/n_compat_stubs.o: userland/compat/stubs.c userland/compat/time.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(BUILD)/n_clockprobe.o: userland/clockprobe.c userland/compat/time.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_CLOCKPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_clockprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_clockprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_mprotectprobe.o: userland/mprotectprobe.c userland/compat/sys/mman.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_MPROTECTPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_mprotectprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_mprotectprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

# The userland ELFs are no longer embedded (M11d): they ship in the packed base
# image (see the $(BASE_IMG) rule) and the kernel loads them from disk.

$(KERNEL_OBJ): $(SWIFT_SRCS) $(BRIDGE) Makefile | $(BUILD)/.dir
	$(SWIFTC) $(SWIFT_FLAGS) -c $(SWIFT_SRCS) -o $@

# Link the freestanding image.
KERNEL_OBJS := $(BOOT_OBJ) $(EXC_OBJ) $(SWITCH_OBJ) $(USER_ENTRY_OBJ) $(HEAP_OBJ) $(STRING_OBJ) \
	$(VM_OBJ) $(EL0_OBJ) $(SMP_SECONDARY_OBJ) $(TRUST_ROOT_OBJ) $(KERNEL_OBJ)

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

# ---- Inference test model (I-series) --------------------------------------
# Tiny TinyStories checkpoint (stories260K) + tokenizer (tok512) used by the
# llm engine test and the /bin/llm demo. Fetched on demand (small, permissively
# published llama2.c test artifacts), kept out of git like the newlib sysroot.
MODEL_BIN := $(MODEL_DIR)/stories260K.bin
MODEL_TOK := $(MODEL_DIR)/tok512.bin
MODEL15_BIN := $(MODEL_DIR)/stories15M.bin
MODEL_TOK32 := $(MODEL_DIR)/tokenizer.bin
# I4: int8-quantized checkpoints, produced by the host quantizer (Q8_0,
# llama2.c "version 2" format). The 15M-q8 bundle is what /bin/llmd serves.
MODEL_Q8 := $(MODEL_DIR)/stories260K-q8.bin
MODEL15_Q8 := $(MODEL_DIR)/stories15M-q8.bin
QUANTIZE := $(BUILD)/quantize

$(MODEL_BIN): scripts/fetch-model.sh
	scripts/fetch-model.sh
$(MODEL_TOK) $(MODEL15_BIN) $(MODEL_TOK32): $(MODEL_BIN)

$(QUANTIZE): tools/quantize.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/quantize.swift -o $@

$(MODEL_Q8): $(MODEL_BIN) $(QUANTIZE)
	$(QUANTIZE) $(MODEL_BIN) $@
$(MODEL15_Q8): $(MODEL15_BIN) $(QUANTIZE)
	$(QUANTIZE) $(MODEL15_BIN) $@

# I5: model-bundle manifest generator (sha256 + sizes -> manifest.toml).
MODELMANIFEST := $(BUILD)/modelmanifest
$(MODELMANIFEST): tools/modelmanifest.swift kernel/crypto/sha256.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/modelmanifest.swift kernel/crypto/sha256.swift -o $@

# I7: Ed25519 manifest signing (keygen / sign / verify) + the dev keypair.
# The dev key lives in models/ (gitignored, fetched-or-generated like the
# checkpoints); the PUBLIC key ships in the base image as the trust root.
MODELSIGN := $(BUILD)/modelsign
$(MODELSIGN): tools/modelsign.swift userland/lib/modelbundle.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift kernel/crypto/sha256.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/modelsign.swift userland/lib/modelbundle.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift kernel/crypto/sha256.swift -o $@

SIGNING_SEED := $(MODEL_DIR)/dev-signing.seed
SIGNING_PUB := $(MODEL_DIR)/dev-signing.pub

$(MODEL_DIR):
	mkdir -p $@

# One recipe creates both halves; order-only on the tool so rebuilding it does
# not mint a new key. (make 3.81-compatible — no grouped targets.)
$(SIGNING_PUB): | $(MODELSIGN) $(MODEL_DIR)
	$(MODELSIGN) keygen $(SIGNING_SEED) $@
$(SIGNING_SEED): $(SIGNING_PUB)

# I8: the IMAGE-signing keypair (distinct from the model key — different
# lifecycle: image key = OS vendor, model key = model publisher). The public
# half is compiled into the kernel as the trust root.
$(IMG_SIGNING_PUB): | $(MODELSIGN) $(MODEL_DIR)
	$(MODELSIGN) keygen $(IMG_SIGNING_SEED) $@
$(IMG_SIGNING_SEED): $(IMG_SIGNING_PUB)

model: $(MODEL_BIN) $(MODEL_TOK) $(MODEL15_BIN) $(MODEL_TOK32) $(MODEL_Q8) $(MODEL15_Q8)

docs-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/docs_reference_test.swift -o $(BUILD)/docs_reference_test
	$(BUILD)/docs_reference_test
	$(MAKE) phase1-roadmap-test
	$(MAKE) api-complete-examples-test
	$(MAKE) examples-verification-test
	$(MAKE) stability-coverage-test

phase1-roadmap-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/phase1_roadmap_test.swift -o $(BUILD)/phase1_roadmap_test
	$(BUILD)/phase1_roadmap_test

api-complete-examples-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/api_complete_examples_test.swift -o $(BUILD)/api_complete_examples_test
	$(BUILD)/api_complete_examples_test

examples-verification-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/examples_verification_test.swift -o $(BUILD)/examples_verification_test
	$(BUILD)/examples_verification_test

page-allocator-refcount-lifecycle-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/page_allocator_refcount_lifecycle_test.swift kernel/mm/page_allocator.swift -o $(BUILD)/page_allocator_refcount_lifecycle_test
	$(BUILD)/page_allocator_refcount_lifecycle_test

stability-coverage-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/stability_coverage_test.swift -o $(BUILD)/stability_coverage_test
	$(BUILD)/stability_coverage_test

test: docs-test build $(QEMU_DTB) $(QEMU_DTB_SMP4) disk base-image package-fixture package-local-install-fixture $(SWPKG) $(UPDATESTORE) $(MODEL_BIN) $(MODEL_TOK) $(MODEL_Q8) $(MODEL15_Q8)
	$(HOST_SWIFTC) tests/page_allocator_test.swift kernel/mm/page_allocator.swift -o $(BUILD)/page_allocator_test
	$(BUILD)/page_allocator_test
	$(MAKE) page-allocator-refcount-lifecycle-test
	$(HOST_SWIFTC) tests/base_image_test.swift kernel/crypto/sha256.swift -o $(BUILD)/base_image_test
	$(BUILD)/base_image_test $(BASE_IMG)
	$(HOST_SWIFTC) tests/updatestore_test.swift kernel/fs/swosboot.swift -o $(BUILD)/updatestore_test
	$(BUILD)/updatestore_test
	$(CLANG) -O2 -Wall -Wextra tests/loader_sha256_test.c -o $(BUILD)/loader_sha256_test
	$(BUILD)/loader_sha256_test
	$(CLANG) -O2 -Wall -Wextra tests/loader_ed25519_test.c -o $(BUILD)/loader_ed25519_test
	$(BUILD)/loader_ed25519_test
	$(HOST_SWIFTC) tests/swpkg_tool_test.swift -o $(BUILD)/swpkg_tool_test
	$(BUILD)/swpkg_tool_test
	$(HOST_SWIFTC) tests/swpkg_header_integrity_test.swift -o $(BUILD)/swpkg_header_integrity_test
	$(BUILD)/swpkg_header_integrity_test
	$(HOST_SWIFTC) tests/pkgstore_tool_test.swift -o $(BUILD)/pkgstore_tool_test
	$(BUILD)/pkgstore_tool_test
	$(HOST_SWIFTC) tests/pkgrepo_tool_test.swift -o $(BUILD)/pkgrepo_tool_test
	$(BUILD)/pkgrepo_tool_test
	$(HOST_SWIFTC) tests/fdt_test.swift kernel/arch/aarch64/fdt.swift -o $(BUILD)/fdt_test
	$(BUILD)/fdt_test $(QEMU_DTB) 1
	$(BUILD)/fdt_test $(QEMU_DTB_SMP4) 4
	FDT_TEST=$(BUILD)/fdt_test ./tests/smp_s1_preflight_test.sh
	FDT_TEST=$(BUILD)/fdt_test ./tests/qemu_virt_hardware_map_test.sh
	$(HOST_SWIFTC) tests/net_test.swift kernel/net/packet.swift kernel/net/ethernet.swift kernel/net/arp.swift kernel/net/ipv4.swift kernel/net/ipv6.swift kernel/net/icmp.swift kernel/net/icmp6.swift kernel/net/udp.swift kernel/net/tcp.swift kernel/net/dns.swift kernel/net/stack.swift -o $(BUILD)/net_test
	$(BUILD)/net_test
	$(HOST_SWIFTC) tests/crypto_test.swift kernel/crypto/chacha20poly1305.swift -o $(BUILD)/crypto_test
	$(BUILD)/crypto_test
	$(HOST_SWIFTC) tests/handle_test.swift kernel/vfs/handle.swift -o $(BUILD)/handle_test
	$(BUILD)/handle_test
	./tests/smp_mailbox_layout_test.sh
	./tests/smp_release_guard_test.sh
	./tests/smp_state_audit_test.sh
	$(HOST_SWIFTC) tests/hkdf_test.swift kernel/crypto/sha256.swift -o $(BUILD)/hkdf_test
	$(BUILD)/hkdf_test
	$(HOST_SWIFTC) tests/x25519_test.swift kernel/crypto/x25519.swift -o $(BUILD)/x25519_test
	$(BUILD)/x25519_test
	$(HOST_SWIFTC) tests/tls_handshake_test.swift userland/lib/tls13.swift kernel/crypto/sha256.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift -o $(BUILD)/tls_handshake_test
	$(BUILD)/tls_handshake_test
	$(HOST_SWIFTC) tests/llm_engine_test.swift userland/lib/llama2.swift -o $(BUILD)/llm_engine_test
	$(BUILD)/llm_engine_test
	$(HOST_SWIFTC) -O tests/llm_q8_engine_test.swift userland/lib/llama2.swift -o $(BUILD)/llm_q8_engine_test
	$(BUILD)/llm_q8_engine_test
	$(HOST_SWIFTC) tests/llm_bundle_test.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift -o $(BUILD)/llm_bundle_test
	$(BUILD)/llm_bundle_test
	$(HOST_SWIFTC) -O tests/ed25519_test.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $(BUILD)/ed25519_test
	$(BUILD)/ed25519_test
	./tests/userland_elf_test.sh
	./tests/boot_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/s4_resource_stress_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_resource_stress_test.sh
	./tests/spawn_self_exec_test.sh
	bash ./tests/cow_test.sh
	./tests/tty_test.sh
	./tests/virtio_blk_test.sh
	./tests/virtio_net_test.sh
	# IPv6 (net-ipv6 slice): host net_test covers the protocol core aggressively
	# (NDP, RA, EH chains, DAD, malformed packets). QEMU smoke tests verify
	# link-local/NDP setup; Darwin QEMU currently skips true IPv6 hostfwd echo.
	./tests/ipv6_smoke_test.sh
	./tests/ipv6_udp_echo_test.sh
	./tests/ipv6_tcp_echo_test.sh
	./tests/udp_echo_test.sh
	./tests/ipc_socket_transfer_test.sh
	./tests/tcp_echo_test.sh
	./tests/tcp_connect_test.sh
	./tests/tls_test.sh
	./tests/httpd_test.sh
	bash ./tests/net_zero_copy_throughput_test.sh
	./tests/dns_test.sh
	./tests/vfs_disk_test.sh
	./tests/disk_exec_test.sh
	./tests/package_overlay_test.sh
	./tests/pkg_store_boot_test.sh
	./tests/pkg_local_install_test.sh
	./tests/signed_image_test.sh
	./tests/ab_update_test.sh
	./tests/ab_persist_test.sh
	./tests/ab_confirm_test.sh
	./tests/ab_rollback_test.sh
	./tests/ab_activate_test.sh
	./tests/ab_payload_test.sh
	./tests/multisector_test.sh
	./tests/ab_stage_test.sh
	./tests/ab_flush_test.sh
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
	./tests/clock_test.sh
	./tests/mprotect_test.sh
	./tests/sleep_test.sh
	./tests/calc_test.sh
	./tests/kv_test.sh
	./tests/llm_run_test.sh
	./tests/llm_serve_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/top_test.sh
	$(MAKE) c5-test
	./tests/busybox_test.sh
	./tests/threads_test.sh
	./tests/mmap_test.sh
	./tests/vi_test.sh
	UEFI_BOOT=disk ./tests/uefi_boot_test.sh
	SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh
	./tests/uefi_kernel_ab_test.sh
	./tests/uefi_kstage_test.sh
	./tests/uefi_kactivate_test.sh
	./tests/uefi_kattempt_test.sh
	./tests/uefi_kconfirm_test.sh
	./tests/uefi_krollback_test.sh
	./tests/fb_vi_test.sh

smp-state-audit:
	./tests/smp_state_audit_test.sh

smp-mailbox-layout: build
	./tests/smp_mailbox_layout_test.sh

smp-release-guard: build
	./tests/smp_release_guard_test.sh

smp-release-contract: smp-release-guard

smp-s1-preflight: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/fdt_test.swift kernel/arch/aarch64/fdt.swift -o $(BUILD)/fdt_test
	FDT_TEST=$(BUILD)/fdt_test ./tests/smp_s1_preflight_test.sh

qemu-virt-hardware-map-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/fdt_test.swift kernel/arch/aarch64/fdt.swift -o $(BUILD)/fdt_test
	FDT_TEST=$(BUILD)/fdt_test ./tests/qemu_virt_hardware_map_test.sh

smp-test: build base-image
	./tests/smp_boot_test.sh

clock-test: build $(QEMU_DTB) base-image
	./tests/clock_test.sh

mprotect-test: build $(QEMU_DTB) base-image
	./tests/mprotect_test.sh

smp-resource-stress-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_resource_stress_test.sh

smp-headroom-test: build base-image
	./tests/smp_headroom_test.sh

smp-uefi-test: disk base-image
	SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh

s4-resource-stress-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/s4_resource_stress_test.sh

smp-cpu-utilization-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/top_test.sh

s5-scheduler-placement-test: build $(QEMU_DTB_SMP4) base-image
	TIMEOUT=180 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh

s5-placement-stress-test: build $(QEMU_DTB_SMP4) base-image
	TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh

s5-el0-fanout-test: build $(QEMU_DTB_SMP4) base-image
	TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh

s5-thread-fanout-test: build $(QEMU_DTB_SMP4) base-image
	TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh

s5-run-any-placement-test: build $(QEMU_DTB_SMP4) base-image
	TIMEOUT=240 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh

s5-test: smp-cpu-utilization-test s5-scheduler-placement-test s5-placement-stress-test s5-el0-fanout-test s5-thread-fanout-test s5-run-any-placement-test

c5-driver-service-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/driver_service_test.sh

c5-device-handle-test: c5-driver-service-test

c5-device-discovery-test: c5-driver-service-test

c5-device-metadata-test: build $(QEMU_DTB_SMP4) base-image
	C5_INPUT_DEVICE=1 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/driver_service_test.sh

c5-device-authority-test: build $(QEMU_DTB_SMP4) base-image
	C5_AUTHORITY_TEST=1 C5_INPUT_DEVICE=1 SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/driver_service_test.sh

c5-device-rights-test: $(BUILD)/.dir
	$(HOST_SWIFTC) tests/handle_test.swift kernel/vfs/handle.swift -o $(BUILD)/handle_test
	$(BUILD)/handle_test
	./tests/device_authority_guard_test.sh

c5-test: c5-driver-service-test c5-device-handle-test c5-device-discovery-test c5-device-metadata-test c5-device-authority-test c5-device-rights-test

s0-test: smp-state-audit smp-mailbox-layout smp-s1-preflight smp-test smp-headroom-test smp-uefi-test
s0c-test: smp-state-audit
s1-test: smp-state-audit smp-mailbox-layout smp-release-contract smp-s1-preflight smp-test smp-headroom-test smp-uefi-test

# ---- UEFI loader build + boot ----------------------------------------------
# The loader embeds the flat kernel image (no FS driver) and copies it to the
# kernel load address after ExitBootServices, so rebuild it when kernel.bin
# changes. kernel_blob.S uses `.incbin "build/kernel.bin"`.
$(BUILD)/kernel_blob.obj: boot/efi/kernel_blob.S $(KERNEL_BIN) Makefile | $(BUILD)/.dir
	$(CLANG) --target=aarch64-unknown-windows -c boot/efi/kernel_blob.S -o $@

# U1g-3b: the image-signing public key embedded in the loader (incbins the same
# build/image_trust_root.bin the kernel's trust_root.S uses).
$(BUILD)/efi_pubkey.obj: boot/efi/efi_pubkey.S $(BUILD)/image_trust_root.bin Makefile | $(BUILD)/.dir
	$(CLANG) --target=aarch64-unknown-windows -c boot/efi/efi_pubkey.S -o $@

$(EFI_APP): boot/efi/loader.c boot/efi/efi.h boot/efi/loader_sha256.h boot/efi/loader_ed25519.h $(BUILD)/kernel_blob.obj $(BUILD)/efi_pubkey.obj Makefile | $(BUILD)/.dir
	$(CLANG) $(EFI_CFLAGS) boot/efi/loader.c -o $(BUILD)/loader.obj
	$(LLDLINK) -subsystem:efi_application -entry:efi_main -nodefaultlib -out:$@ \
		$(BUILD)/loader.obj $(BUILD)/kernel_blob.obj $(BUILD)/efi_pubkey.obj
	@echo "Built $(EFI_APP)"

# Stage the EFI System Partition firmware boots from.
$(ESP_DIR)/EFI/BOOT/BOOTAA64.EFI: $(EFI_APP)
	@mkdir -p $(ESP_DIR)/EFI/BOOT
	cp $(EFI_APP) $@

# U1g: stage the kernel A/B slots + signed slot-metadata manifest on the ESP
# under \EFI\swift-os. The loader verifies the manifest for per-slot hashes, then
# uses the writable kernel-state file for mutable active-slot selection. Both
# slots are the same image for now; A/B differentiation comes with staging a new
# kernel into the inactive slot. make-disk.sh copies these into the GPT image.
$(ESP_DIR)/EFI/swift-os/kernelA.bin: $(KERNEL_BIN)
	@mkdir -p $(ESP_DIR)/EFI/swift-os
	cp $(KERNEL_BIN) $@
$(ESP_DIR)/EFI/swift-os/kernelB.bin: $(KERNEL_BIN)
	@mkdir -p $(ESP_DIR)/EFI/swift-os
	cp $(KERNEL_BIN) $@
$(ESP_DIR)/EFI/swift-os/kernel-boot: $(KERNELBOOT) $(KERNEL_BIN) $(IMG_SIGNING_SEED)
	@mkdir -p $(ESP_DIR)/EFI/swift-os
	$(KERNELBOOT) $@ A $(KERNEL_BIN) $(KERNEL_BIN) $(IMG_SIGNING_SEED)

uefi: $(ESP_DIR)/EFI/BOOT/BOOTAA64.EFI \
      $(ESP_DIR)/EFI/swift-os/kernelA.bin \
      $(ESP_DIR)/EFI/swift-os/kernelB.bin \
      $(ESP_DIR)/EFI/swift-os/kernel-boot
	rm -f $(ESP_DIR)/EFI/swift-os/kernel-boot-alt

# Boot the UEFI loader under AAVMF (no `-kernel`). Exit QEMU serial with Ctrl-A X.
uefi-run: uefi base-image
	$(QEMU) $(UEFI_QEMU_FLAGS)

# Build a real bootable GPT disk image (ESP + BOOTAA64.EFI). Bootable under
# QEMU+AAVMF and attachable to VirtualBox / other hypervisors.
DISK_IMG := $(BUILD)/swift-os.img
disk: uefi
	./scripts/make-disk.sh $(DISK_IMG)

# Boot the real disk image under AAVMF (a genuine -drive, not virtual FAT). The
# ESP/GPT disk is on virtio-mmio (U1g-4) so the kernel can read it too.
disk-run: disk base-image
	$(QEMU) -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
		-bios $(AAVMF_CODE) \
		-drive file=$(DISK_IMG),format=raw,if=none,id=esp -device virtio-blk-device,drive=esp \
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
		-bios $(AAVMF_CODE) \
		-drive file=$(DISK_IMG),format=raw,if=none,id=esp -device virtio-blk-device,drive=esp \
		-drive file=$(BASE_IMG),format=raw,if=none,id=swosbase,readonly=on \
		-device virtio-blk-device,drive=swosbase \
		-device ramfb -device virtio-keyboard-device -display cocoa -serial stdio

$(BASEPACK): tools/basepack.swift tools/packfs.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/basepack.swift tools/packfs.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

$(SWPKG): tools/swpkg.swift tools/packfs.swift kernel/crypto/sha256.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/swpkg.swift tools/packfs.swift kernel/crypto/sha256.swift -o $@

swpkg: $(SWPKG)

swpkg-header-integrity-test: $(SWPKG) package-fixture | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/swpkg_header_integrity_test.swift -o $(BUILD)/swpkg_header_integrity_test
	$(BUILD)/swpkg_header_integrity_test

$(PKGSTORE): tools/pkgstore.swift tools/packfs.swift kernel/crypto/sha256.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/pkgstore.swift tools/packfs.swift kernel/crypto/sha256.swift -o $@

pkgstore: $(PKGSTORE)

$(PKGREPO): tools/pkgrepo.swift tools/packfs.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/pkgrepo.swift tools/packfs.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

pkgrepo: $(PKGREPO)

$(SWPORT): tools/swport.swift kernel/crypto/sha256.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -parse-as-library tools/swport.swift kernel/crypto/sha256.swift -o $@

swport: $(SWPORT)

$(SWPORT_CATALOG_TEST): tests/swport_catalog_test.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/swport_catalog_test.swift -o $@

ports-catalog-test: $(SWPORT) $(SWPORT_CATALOG_TEST) ports/catalog.json
	$(SWPORT) catalog validate ports/catalog.json
	$(SWPORT_CATALOG_TEST)

$(SWPORT_RECIPE_TEST): tests/swport_recipe_test.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/swport_recipe_test.swift -o $@

ports-recipe-test: $(SWPORT) $(SWPKG) $(PKGREPO) $(SWPORT_RECIPE_TEST) ports/catalog.json ports/lang/lua/Port.json ports/archivers/zlib/Port.json ports/archivers/bzip2/Port.json ports/archivers/zstd/Port.json ports/archivers/xz/Port.json ports/archivers/libarchive/Port.json ports/security/ca-certificates/Port.json ports/devel/pcre2/Port.json ports/sysutils/tzdata/Port.json ports/www/nginx/Port.json ports/databases/sqlite/Port.json ports/lang/nodejs/Port.json ports/lang/npm/Port.json ports/sysutils/pm2/Port.json
	$(SWPORT_RECIPE_TEST)

ports-lua-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/lang/lua/Port.json scripts/build-lua.sh
	./scripts/build-lua.sh

ports-zlib-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/archivers/zlib/Port.json scripts/build-zlib.sh
	./scripts/build-zlib.sh

ports-bzip2-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/archivers/bzip2/Port.json scripts/build-bzip2.sh
	./scripts/build-bzip2.sh

ports-zstd-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/archivers/zstd/Port.json scripts/build-zstd.sh
	./scripts/build-zstd.sh

ports-xz-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/archivers/xz/Port.json scripts/build-xz.sh
	./scripts/build-xz.sh

ports-libarchive-repo-fixture: ports-zlib-repo-fixture ports-bzip2-repo-fixture ports-zstd-repo-fixture ports-xz-repo-fixture ports/archivers/libarchive/Port.json scripts/build-libarchive.sh
	./scripts/build-libarchive.sh

ports-ca-certificates-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) ports/security/ca-certificates/Port.json scripts/build-ca-certificates.sh
	./scripts/build-ca-certificates.sh

ports-pcre2-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/devel/pcre2/Port.json scripts/build-pcre2.sh
	./scripts/build-pcre2.sh

ports-tzdata-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) ports/sysutils/tzdata/Port.json scripts/build-tzdata.sh
	./scripts/build-tzdata.sh

ports-nginx-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/www/nginx/Port.json scripts/build-nginx.sh
	./scripts/build-nginx.sh

ports-sqlite-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/databases/sqlite/Port.json scripts/build-sqlite.sh
	./scripts/build-sqlite.sh

ports-seed-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/lang/lua/Port.json ports/archivers/zlib/Port.json ports/archivers/bzip2/Port.json ports/archivers/zstd/Port.json ports/archivers/xz/Port.json ports/archivers/libarchive/Port.json ports/security/ca-certificates/Port.json ports/devel/pcre2/Port.json ports/sysutils/tzdata/Port.json ports/www/nginx/Port.json ports/databases/sqlite/Port.json scripts/build-lua.sh scripts/build-zlib.sh scripts/build-bzip2.sh scripts/build-zstd.sh scripts/build-xz.sh scripts/build-libarchive.sh scripts/build-ca-certificates.sh scripts/build-pcre2.sh scripts/build-tzdata.sh scripts/build-nginx.sh scripts/build-sqlite.sh scripts/build-ports-seed-repo.sh
	./scripts/build-ports-seed-repo.sh

ports-static-host-publish: ports-seed-repo-fixture scripts/publish-ports-static-host.sh
	PORTS_STATIC_REPO_SOURCE="$(PORTS_SEED_REPO_ROOT)" \
	PORTS_STATIC_REPO_PUB="$(PORTS_SEED_REPO_PUB)" \
	PORTS_STATIC_HOST_ROOT="$(PORTS_STATIC_HOST_ROOT)" \
	PORTS_STATIC_HOST_BASE_URL="$(PORTS_STATIC_HOST_BASE_URL)" \
	./scripts/publish-ports-static-host.sh

ports-hosted-url-verify: $(PKGREPO) scripts/verify-ports-hosted-url.sh
	@if [ -z "$(PKG_HOSTED_REPO_URL)" ]; then echo "Set PKG_HOSTED_REPO_URL=http://host[/aarch64/current]" >&2; exit 2; fi
	PKGREPO="$(PKGREPO)" ./scripts/verify-ports-hosted-url.sh "$(PKG_HOSTED_REPO_URL)"

ports-hosted-url-verify-test: ports-static-host-publish scripts/verify-ports-hosted-url.sh
	./tests/pkg_hosted_url_verify_test.sh

$(PKGREPO_PUB): $(PKGREPO) Makefile
	$(PKGREPO) pubkey --seed-hex $(PKGREPO_SEED_HEX) --output $@

$(PKGHELLO_ROOT)/usr/bin/pkghello: $(USER_PKGHELLO_ELF) Makefile | $(BUILD)/.dir
	rm -rf $(PKGHELLO_ROOT)
	mkdir -p $(PKGHELLO_ROOT)/usr/bin
	cp $(USER_PKGHELLO_ELF) $@
	chmod 755 $@

$(PKGHELLO_PKG): $(SWPKG) fixtures/pkghello/manifest.json $(PKGHELLO_ROOT)/usr/bin/pkghello Makefile
	$(SWPKG) create --manifest fixtures/pkghello/manifest.json --root $(PKGHELLO_ROOT) --output $@

$(PKGHELLO_PAYLOAD_IMG): $(SWPKG) $(PKGHELLO_PKG) Makefile
	$(SWPKG) extract-payload $(PKGHELLO_PKG) $@

$(PKGHELLO_STORE_IMG): $(PKGSTORE) $(PKGHELLO_PKG) Makefile
	$(PKGSTORE) create --package $(PKGHELLO_PKG) --output $@ --generation 1

$(PKG_EMPTY_STORE_IMG): $(PKGSTORE) Makefile
	$(PKGSTORE) init --output $@ --size 1048576

$(PKG_INSTALL_STORE_IMG): $(PKG_EMPTY_STORE_IMG) Makefile
	cp $(PKG_EMPTY_STORE_IMG) $@

package-fixture: $(PKGHELLO_PKG) $(PKGHELLO_PAYLOAD_IMG) $(PKGHELLO_STORE_IMG)
	$(SWPKG) verify $(PKGHELLO_PKG)

package-store-fixture: $(PKGHELLO_STORE_IMG)
	$(PKGSTORE) inspect $(PKGHELLO_STORE_IMG)

$(PKGREPO_ROOT): $(PKGREPO) $(PKGHELLO_PKG) Makefile
	$(PKGREPO) create --package $(PKGHELLO_PKG) --output $@ --seed-hex $(PKGREPO_SEED_HEX) --generation 1

package-repo-fixture: $(PKGREPO_ROOT) $(PKGREPO_PUB)
	$(PKGREPO) verify --catalog-signed $(PKGREPO_ROOT)/aarch64/current/catalog.signed --pubkey $(PKGREPO_PUB)
	$(PKGREPO) inspect $(PKGREPO_ROOT)/aarch64/current/catalog.signed

package-overlay-test: build $(QEMU_DTB) base-image package-fixture
	./tests/package_overlay_test.sh

package-store-test: build $(QEMU_DTB) base-image package-store-fixture
	./tests/pkg_store_boot_test.sh

package-local-install-fixture: $(PKG_EMPTY_STORE_IMG)
	cp $(PKG_EMPTY_STORE_IMG) $(PKG_INSTALL_STORE_IMG)
	$(PKGSTORE) inspect $(PKG_INSTALL_STORE_IMG)

package-lua-install-fixture: $(PKGSTORE)
	$(PKGSTORE) init --output $(PKG_LUA_INSTALL_STORE_IMG) --size $(PKG_PORTS_INSTALL_STORE_SIZE)
	$(PKGSTORE) inspect $(PKG_LUA_INSTALL_STORE_IMG)

package-local-install-test: build $(QEMU_DTB) base-image package-local-install-fixture
	./tests/pkg_local_install_test.sh

package-repo-install-test: build $(QEMU_DTB) base-image package-local-install-fixture package-repo-fixture
	./tests/pkg_repo_install_test.sh

package-lua-repo-install-test: build $(QEMU_DTB) base-image package-lua-install-fixture ports-lua-repo-fixture
	./tests/pkg_lua_repo_install_test.sh

package-ports-seed-repo-install-test: build $(QEMU_DTB) package-lua-install-fixture ports-seed-repo-fixture
	./tests/pkg_ports_seed_repo_install_test.sh

package-static-host-repo-install-test: build $(QEMU_DTB) package-lua-install-fixture ports-static-host-publish
	./tests/pkg_static_host_repo_install_test.sh

package-static-host-dns-repo-install-test: build $(QEMU_DTB) package-lua-install-fixture ports-static-host-publish
	./tests/pkg_static_host_dns_repo_install_test.sh

package-hosted-url-install-test: build $(QEMU_DTB) package-lua-install-fixture
	@if [ -z "$(PKG_HOSTED_REPO_URL)" ]; then echo "Set PKG_HOSTED_REPO_URL=http://host/aarch64/current" >&2; exit 2; fi
	PKG_HOSTED_REPO_URL="$(PKG_HOSTED_REPO_URL)" ./tests/pkg_hosted_url_install_test.sh

# U1a: host builder for the SWOSBOOT A/B update-store disk. Shares the manifest
# format/CRC with the kernel via kernel/fs/swosboot.swift.
$(UPDATESTORE): tools/updatestore.swift kernel/fs/swosboot.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/updatestore.swift kernel/fs/swosboot.swift -o $@

updatestore: $(UPDATESTORE)

# U1g-2/3a/3b: host builder for the SWOSKERN kernel A/B boot manifest (read by the
# UEFI loader from the ESP). Embeds per-slot SHA-256 (U1g-3a) and signs the body
# with Ed25519 (U1g-3b, image-signing key); the loader parses + verifies in C.
$(KERNELBOOT): tools/kernelboot.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/kernelboot.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

kernelboot: $(KERNELBOOT)

$(BASE_IMG): $(BASEPACK) $(BASE_SEED_FILES) $(BASE_EXEC_ELFS) $(PKGHELLO_PKG) $(PKGREPO_PUB) $(MODEL_BIN) $(MODEL_TOK) $(MODEL15_Q8) $(MODEL_TOK32) $(MODELMANIFEST) $(MODELSIGN) $(SIGNING_SEED) $(SIGNING_PUB) $(IMG_SIGNING_SEED) $(IMG_SIGNING_PUB) Makefile
	rm -rf $(BASE_ROOT)
	mkdir -p $(BASE_ROOT)
	cp -R base/. $(BASE_ROOT)/
	mkdir -p $(BASE_ROOT)/bin
	mkdir -p $(BASE_ROOT)/etc/pkg
	mkdir -p $(BASE_ROOT)/packages
	mkdir -p $(BASE_ROOT)/models
	cp $(PKGHELLO_PKG) $(BASE_ROOT)/packages/pkghello.swpkg
	cp $(PKGREPO_PUB) $(BASE_ROOT)/etc/pkg/repo-root.pub
	if [ -n "$(PKG_DEFAULT_DNS_SERVER)" ]; then printf '%s\n' "$(PKG_DEFAULT_DNS_SERVER)" > $(BASE_ROOT)/etc/pkg/dns-server; fi
	if [ -n "$(PKG_DEFAULT_REPO_URL)" ]; then printf '%s\n' "$(PKG_DEFAULT_REPO_URL)" > $(BASE_ROOT)/etc/pkg/repo-url; fi
	cp $(MODEL_BIN) $(MODEL_TOK) $(BASE_ROOT)/models/
	# I5: verified model bundle /models/stories15M/<gen>/. Generation 1 is the
	# real q8 bundle; generation 2 is DELIBERATELY corrupt (a truncated model
	# with gen-1's manifest hashes) so every boot demonstrates — and the serve
	# test asserts — the verify-and-fall-back path from ARCHITECTURE.md.
	mkdir -p $(BASE_ROOT)/models/stories15M/1 $(BASE_ROOT)/models/stories15M/2
	cp $(MODEL15_Q8) $(BASE_ROOT)/models/stories15M/1/model.bin
	cp $(MODEL_TOK32) $(BASE_ROOT)/models/stories15M/1/tokenizer.bin
	$(MODELMANIFEST) stories15M 1 $(MODEL15_Q8) $(MODEL_TOK32) $(BASE_ROOT)/models/stories15M/1/manifest.toml
	$(MODELMANIFEST) stories15M 2 $(MODEL15_Q8) $(MODEL_TOK32) $(BASE_ROOT)/models/stories15M/2/manifest.toml
	printf 'corrupt-model-payload' > $(BASE_ROOT)/models/stories15M/2/model.bin
	cp $(MODEL_TOK32) $(BASE_ROOT)/models/stories15M/2/tokenizer.bin
	# I7: sign both manifests (gen 2's signature is VALID — its payload hash is
	# what fails, proving the layered checks) and ship the trust root.
	$(MODELSIGN) sign $(BASE_ROOT)/models/stories15M/1/manifest.toml $(SIGNING_SEED)
	$(MODELSIGN) sign $(BASE_ROOT)/models/stories15M/2/manifest.toml $(SIGNING_SEED)
	cp $(SIGNING_PUB) $(BASE_ROOT)/etc/swos/model-signing.pub
	cp $(USER_HELLO_ELF) $(BASE_ROOT)/bin/hello
	cp $(USER_TTYDEMO_ELF) $(BASE_ROOT)/bin/ttydemo
	cp $(USER_ARGVDEMO_ELF) $(BASE_ROOT)/bin/argvdemo
	cp $(USER_SPAWNDEMO_ELF) $(BASE_ROOT)/bin/spawndemo
	cp $(USER_SELFEXECDEMO_ELF) $(BASE_ROOT)/bin/selfexecdemo
	cp $(USER_FSDEMO_ELF) $(BASE_ROOT)/bin/fsdemo
	cp $(USER_BRKDEMO_ELF) $(BASE_ROOT)/bin/brkdemo
	cp $(USER_NEWLIBTEST_ELF) $(BASE_ROOT)/bin/newlibtest
	cp $(USER_CLOCKPROBE_ELF) $(BASE_ROOT)/bin/clockprobe
	cp $(USER_MPROTECTPROBE_ELF) $(BASE_ROOT)/bin/mprotectprobe
	cp $(USER_COPROC_ELF) $(BASE_ROOT)/bin/coproc
	cp $(USER_FORKDEMO_ELF) $(BASE_ROOT)/bin/forkdemo
	cp $(USER_EXECDEMO_ELF) $(BASE_ROOT)/bin/execdemo
	cp $(USER_FDOPSDEMO_ELF) $(BASE_ROOT)/bin/fdopsdemo
	cp $(USER_S4STRESS_ELF) $(BASE_ROOT)/bin/s4stress
	cp $(USER_SECURITYDEMO_ELF) $(BASE_ROOT)/bin/securitydemo
	cp $(USER_IDENTITYDEMO_ELF) $(BASE_ROOT)/bin/identitydemo
	cp $(USER_CONSOLELOGIN_ELF) $(BASE_ROOT)/bin/console-login
	cp $(USER_PS_ELF) $(BASE_ROOT)/bin/ps
	cp $(USER_SLEEPPROBE_ELF) $(BASE_ROOT)/bin/sleepprobe
	cp $(USER_ID_ELF) $(BASE_ROOT)/bin/id
	cp $(USER_SWOSCONFIRM_ELF) $(BASE_ROOT)/bin/swos-confirm
	cp $(USER_SWOSACTIVATE_ELF) $(BASE_ROOT)/bin/swos-activate
	cp $(USER_SWOSUPDATE_ELF) $(BASE_ROOT)/bin/swos-update
	cp $(USER_SWOSKSTAGE_ELF) $(BASE_ROOT)/bin/swos-kstage
	cp $(USER_SWOSKACTIVATE_ELF) $(BASE_ROOT)/bin/swos-kactivate
	cp $(USER_SWOSKCONFIRM_ELF) $(BASE_ROOT)/bin/swos-kconfirm
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
	cp $(USER_LLM_ELF) $(BASE_ROOT)/bin/llm
	cp $(USER_LLMD_ELF) $(BASE_ROOT)/bin/llmd
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
	cp $(USER_C4B_SOCKXFER_ELF) $(BASE_ROOT)/bin/c4b-sockxfer
	cp $(USER_DRVINPUTD_ELF) $(BASE_ROOT)/bin/drvinputd
	cp $(USER_DRVSVCDEMO_ELF) $(BASE_ROOT)/bin/drvsvcdemo
	cp $(USER_PKG_ELF) $(BASE_ROOT)/bin/pkg
	cp $(BUILD)/busybox.elf $(BASE_ROOT)/bin/busybox
	$(BASEPACK) $(BASE_ROOT) $@ $(IMG_SIGNING_SEED)

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
		$(BUILD)/*.swpkg $(BUILD)/*.dtb $(BUILD)/basepack $(BUILD)/swpkg $(BUILD)/pkgstore $(BUILD)/pkgrepo $(BUILD)/base_image_test \
		$(BUILD)/swpkg_tool_test $(BUILD)/pkgstore_tool_test $(BUILD)/pkgrepo_tool_test $(BASE_ROOT) $(PKGHELLO_ROOT) \
		$(PKGREPO_ROOT) $(PKGREPO_PUB) $(PORTS_SEED_REPO_ROOT) $(PORTS_SEED_REPO_PUB) $(PORTS_STATIC_HOST_ROOT) \
		$(BUILD)/lua-port-work $(BUILD)/lua-port-runtime $(BUILD)/lua-root $(BUILD)/lua-repo-root $(BUILD)/lua-repo-root.pub \
		$(BUILD)/zlib-port-work $(BUILD)/zlib-port-runtime $(BUILD)/zlib-root $(BUILD)/zlib-repo-root $(BUILD)/zlib-repo-root.pub \
		$(BUILD)/bzip2-port-work $(BUILD)/bzip2-port-runtime $(BUILD)/bzip2-root $(BUILD)/bzip2-repo-root $(BUILD)/bzip2-repo-root.pub \
		$(BUILD)/zstd-port-work $(BUILD)/zstd-port-runtime $(BUILD)/zstd-root $(BUILD)/zstd-repo-root $(BUILD)/zstd-repo-root.pub \
		$(BUILD)/xz-port-work $(BUILD)/xz-port-runtime $(BUILD)/xz-root $(BUILD)/xz-repo-root $(BUILD)/xz-repo-root.pub \
		$(BUILD)/libarchive-port-work $(BUILD)/libarchive-port-runtime $(BUILD)/libarchive-root $(BUILD)/libarchive-repo-root $(BUILD)/libarchive-repo-root.pub \
		$(BUILD)/ca-certificates-root $(BUILD)/ca-certificates-repo-root $(BUILD)/ca-certificates-repo-root.pub \
		$(BUILD)/pcre2-port-work $(BUILD)/pcre2-port-runtime $(BUILD)/pcre2-root $(BUILD)/pcre2-repo-root $(BUILD)/pcre2-repo-root.pub \
		$(BUILD)/tzdata-port-work $(BUILD)/tzdata-root $(BUILD)/tzdata-repo-root $(BUILD)/tzdata-repo-root.pub \
		$(BUILD)/nginx-port-work $(BUILD)/nginx-root $(BUILD)/nginx-repo-root $(BUILD)/nginx-repo-root.pub $(BUILD)/nginx \
		$(BUILD)/sqlite-port-work $(BUILD)/sqlite-port-runtime $(BUILD)/sqlite-root $(BUILD)/sqlite-repo-root $(BUILD)/sqlite-repo-root.pub \
		$(BUILD)/base-ports-seed-repo.img $(BUILD)/base-ports-static-host.img $(BUILD)/base-ports-static-host-dns.img $(BUILD)/base-hosted-url.img $(ESP_DIR)

# Print the resolved toolchain so failures are easy to diagnose.
tools-check:
	@echo "SWIFTC  = $(SWIFTC)";  $(SWIFTC) --version | head -1
	@echo "HOST_SWIFTC = $(HOST_SWIFTC)"; $(HOST_SWIFTC) --version | head -1
	@echo "CLANG   = $(CLANG)";   $(CLANG) --version | head -1
	@echo "LDBIN   = $(LDBIN)";   $(LDBIN) --version | head -1
	@echo "OBJCOPY = $(OBJCOPY)"; $(OBJCOPY) --version | head -1
	@echo "QEMU    = $(QEMU)";    $(QEMU) --version | head -1
