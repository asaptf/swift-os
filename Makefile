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
QEMU_DTB_2048 := $(BUILD)/virt-2048.dtb
QEMU_DTB_GICV3 := $(BUILD)/virt-gicv3-smp2.dtb
QEMU_DTB_ADDR := 0x4FF00000
BASE_IMG  := $(BUILD)/base.img
# D0: a writable, persistent virtio-blk "data" disk (the /data tier, datafs from
# D1). Stamped with the "SWDATAFS" sector-0 magic so the kernel scan identifies
# it positively. Persists across `make run` invocations; not rebuilt once created.
DATA_IMG  := $(BUILD)/data.img
DATA_IMG_SIZE_MB ?= 16
# D3: the packaged SQLite shell (static aarch64 ELF), baked into the base image as
# /bin/sqlite3 so durable databases can live on /data. Built by build-sqlite.sh
# (which compiles the current userland/compat stubs, so it picks up real fsync).
SQLITE_BIN := $(BUILD)/sqlite-root/usr/bin/sqlite3
# W1: the static nginx web server (HTTP-only port) + its staged config and web
# root, baked into the base image as /sbin/nginx so we can host a site. Built by
# build-nginx.sh (compiles the current userland/compat stubs).
NGINX_BIN := $(BUILD)/nginx-root/usr/sbin/nginx
# W3: openssl static dev libs (staged by build-openssl.sh) that nginx links for TLS.
OPENSSL_DEV := $(BUILD)/openssl-root/usr/lib/libssl.a
# W3: a build-time self-signed cert baked in for the HTTPS demo (replace with
# acme.sh / Let's Encrypt certs later).
NGINX_CERT := $(BUILD)/nginx-certs/server.crt
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
# SU-B: site-bundle signing key (distinct lifecycle from image/model keys). The
# public half is baked at /etc/swupdate/site-root.pub; /bin/swupdate verifies a
# SWSITE bundle's Ed25519 signature against it before unpacking.
SITEPACK := $(BUILD)/sitepack
# OS-2: host packer for the signed SWSYS system-update bundle (kernel + base
# image, monotonic version), signed with the image-signing key (IMG_SIGNING_SEED).
SYSPACK := $(BUILD)/syspack
SITE_SIGNING_SEED := $(MODEL_DIR)/dev-site-signing.seed
SITE_SIGNING_PUB := $(MODEL_DIR)/dev-site-signing.pub
BASE_ROOT := $(BUILD)/base-root
PKGHELLO_ROOT := $(BUILD)/pkghello-root
PKGHELLO_PKG := $(BUILD)/pkghello.swpkg
PKGHELLO_PAYLOAD_IMG := $(BUILD)/pkghello-payload.img
PKGHELLO_STORE_IMG := $(BUILD)/pkgstore-pkghello.img
PKG_EMPTY_STORE_IMG := $(BUILD)/pkgstore-empty.img
PKG_INSTALL_STORE_IMG := $(BUILD)/pkgstore-install.img
PKG_LUA_INSTALL_STORE_IMG := $(BUILD)/pkgstore-lua-install.img
PKG_PORTS_INSTALL_STORE_SIZE := 134217728
PKGREPO_ROOT := $(BUILD)/pkgrepo-root
PKGREPO_PUB := $(BUILD)/pkgrepo-root.pub
PKGREPO_SEED_HEX := 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
PORTS_SEED_REPO_ROOT := $(BUILD)/ports-seed-repo-root
PORTS_SEED_REPO_PUB := $(BUILD)/ports-seed-repo-root.pub
PORTS_STATIC_HOST_ROOT := $(BUILD)/ports-static-host-root
PORT_RECIPE_FILES := $(shell find ports -name Port.json | sort)
PORT_BUILD_SCRIPTS := $(shell find scripts -name 'build-*.sh' | sort)
PORTS_STATIC_HOST_BASE_URL ?=
PKG_HOSTED_REPO_URL ?=
PKG_DEFAULT_DNS_SERVER ?=
PKG_DEFAULT_REPO_URL ?=
SSHD_HOST_SEED_FILE ?=
SSHD_KEX_SEED_FILE ?=
SSHD_AUTHORIZED_KEYS_FILE ?=
NET_IPV6_CONFIG_FILE ?=
SWOS_SERVICES_FILE ?=
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
	kernel/errno.swift \
	kernel/arch/aarch64/platform.swift \
	kernel/arch/aarch64/cpu.swift \
	kernel/arch/aarch64/fdt.swift \
	kernel/arch/aarch64/acpi.swift \
	kernel/drivers/uart.swift \
	kernel/drivers/fb.swift \
	kernel/drivers/gic.swift \
	kernel/drivers/pci.swift \
	kernel/drivers/virtio_transport_ops.swift \
	kernel/drivers/virtio_transport.swift \
	kernel/drivers/virtio_net.swift \
	kernel/drivers/virtio_blk.swift \
	kernel/drivers/virtio_rng.swift \
	kernel/drivers/virtio_gpu.swift \
	kernel/drivers/virtio_input.swift \
	kernel/drivers/usb_xhci.swift \
	kernel/net/packet.swift \
	kernel/net/ethernet.swift \
	kernel/net/arp.swift \
	kernel/net/ipv4.swift \
	kernel/net/ipv6.swift \
	kernel/net/icmp.swift \
	kernel/net/icmp6.swift \
	kernel/net/udp.swift \
	kernel/net/dhcp.swift \
	kernel/net/dns.swift \
	kernel/net/tcp.swift \
	kernel/net/stack.swift \
	kernel/net/socket.swift \
	kernel/ipc/shmring.swift \
	kernel/ipc/shmring_chan.swift \
	kernel/crypto/chacha20poly1305.swift \
	kernel/crypto/sha256.swift \
	kernel/crypto/sysrng.swift \
	kernel/crypto/sha512.swift \
	kernel/crypto/ed25519.swift \
	kernel/pkg/store.swift \
	kernel/smp/atomic.swift \
	kernel/smp/percpu.swift \
	kernel/smp/secondary.swift \
	kernel/smp/topology.swift \
	kernel/log/log.swift \
	kernel/timer/generic_timer.swift \
	kernel/power/power.swift \
	kernel/sched/scheduler.swift \
	kernel/sched/futex.swift \
	kernel/syscall/syscall.swift \
	kernel/tty/tty.swift \
	kernel/tty/pty.swift \
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
	kernel/fs/ramdisk.swift \
	kernel/fs/swosboot.swift \
	kernel/fs/updatestore.swift \
	kernel/fs/esp.swift \
	kernel/fs/datafs.swift \
	kernel/mm/page_allocator.swift \
	kernel/mm/pmm.swift \
	kernel/mm/vm.swift

# ---- Flags -----------------------------------------------------------------
# Embedded Swift: freestanding, no Foundation/stdlib, whole-module.
# -function-sections lets the linker drop unused runtime code.
# Extra Swift compilation conditions, empty by default. Overridden on the command
# line for test-only kernel variants (e.g. EXTRA_SWIFT_DEFS="-D PANIC_LOOP_INJECT").
EXTRA_SWIFT_DEFS :=
SWIFT_FLAGS := \
	-target $(TRIPLE) \
	-enable-experimental-feature Embedded \
	-wmo -parse-as-library -Osize \
	-Xllvm -mattr=+strict-align,-neon \
	-Xfrontend -function-sections \
	$(BOARD_SWDEF) \
	$(EXTRA_SWIFT_DEFS) \
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
# LM1: NEON-enabled variant for the SIMD-vectorized inference engine. The kernel
# saves the full FP/SIMD register file (q0..q31 + FPCR/FPSR) on EL0 exception
# entry (kernel/arch/aarch64/exceptions.S), so vector code is safe under
# preemption in userland. strict-align is kept; only -neon is flipped to +neon.
USER_SWIFT_FLAGS_NEON := \
	-target $(TRIPLE) \
	-enable-experimental-feature Embedded \
	-wmo -parse-as-library -Osize \
	-Xllvm -mattr=+strict-align,+neon \
	-Xfrontend -function-sections \
	-import-objc-header userland/lib/swift_user.h
# Newlib-linked userland: aarch64-elf GNU toolchain + ./sysroot (run `make newlib`).
SYSROOT        := sysroot/aarch64-elf
NEWLIB_GCC     := aarch64-elf-gcc
NEWLIB_CFLAGS  := -ffreestanding -Os -Wall -isystem $(SYSROOT)/include -c
NEWLIB_COMPAT_CFLAGS := -ffreestanding -Os -Wall -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 -D_POSIX_BARRIERS=1 -isystem userland/compat -isystem $(SYSROOT)/include -c
# Node.js/libuv masquerade compat: node-compat shims ahead of compat, with the
# Linux + newlib feature-test macros the masquerade needs (see scripts/build-node.sh).
NODE_COMPAT_CFLAGS := -ffreestanding -Os -Wall -D_GNU_SOURCE -D__linux__ -D_POSIX_READER_WRITER_LOCKS=1 -D_POSIX_SEMAPHORES=1 -D_POSIX_BARRIERS=1 -D_UNIX98_THREAD_MUTEX_ATTRIBUTES=1 -isystem userland/node-compat -isystem userland/compat -isystem $(SYSROOT)/include -c
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
	-drive file=$(DATA_IMG),format=raw,if=none,id=swosdata \
	-device virtio-blk-device,drive=swosdata \
	-kernel $(BUILD)/kernel.elf

# D0: create the blank, stamped data disk if it does not yet exist. Order-only on
# the build dir so an existing image is preserved (persistence across runs).
$(DATA_IMG): | $(BUILD)/.dir
	dd if=/dev/zero of=$@ bs=1048576 count=$(DATA_IMG_SIZE_MB) 2>/dev/null
	printf 'SWDATAFS' | dd of=$@ bs=1 seek=0 conv=notrunc 2>/dev/null

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
USER_SWOSINIT_ELF := $(BUILD)/swos-init.elf
USER_TTYDEMO_ELF := $(BUILD)/ttydemo.elf
USER_ARGVDEMO_ELF := $(BUILD)/argvdemo.elf
USER_SPAWNDEMO_ELF := $(BUILD)/spawndemo.elf
USER_SELFEXECDEMO_ELF := $(BUILD)/selfexecdemo.elf
USER_FSDEMO_ELF := $(BUILD)/fsdemo.elf
USER_BRKDEMO_ELF := $(BUILD)/brkdemo.elf
USER_NEWLIBTEST_ELF := $(BUILD)/newlibtest.elf
USER_CLOCKPROBE_ELF := $(BUILD)/clockprobe.elf
USER_MPROTECTPROBE_ELF := $(BUILD)/mprotectprobe.elf
USER_LARGEMMAPPROBE_ELF := $(BUILD)/largemmapprobe.elf
USER_MMAPRESERVEPROBE_ELF := $(BUILD)/mmapreserveprobe.elf
USER_MAPFIXEDPROBE_ELF := $(BUILD)/mapfixedprobe.elf
USER_PTHREADPROBE_ELF := $(BUILD)/pthreadprobe.elf
USER_FUTEXPROBE_ELF := $(BUILD)/futexprobe.elf
USER_THREADSYNCPROBE_ELF := $(BUILD)/threadsyncprobe.elf
USER_SELECTPROBE_ELF := $(BUILD)/selectprobe.elf
USER_EVENTFDPROBE_ELF := $(BUILD)/eventfdprobe.elf
USER_EPOLLPROBE_ELF := $(BUILD)/epollprobe.elf
USER_UVWAKEPROBE_ELF := $(BUILD)/uvwakeprobe.elf
USER_UVSEMPROBE_ELF := $(BUILD)/uvsemprobe.elf
USER_UVRWLOCKPROBE_ELF := $(BUILD)/uvrwlockprobe.elf
USER_UVMUTEXPROBE_ELF := $(BUILD)/uvmutexprobe.elf
USER_UVTHREADNAMEPROBE_ELF := $(BUILD)/uvthreadnameprobe.elf
USER_UVTHREADSTACKPROBE_ELF := $(BUILD)/uvthreadstackprobe.elf
USER_UVKEYONCEPROBE_ELF := $(BUILD)/uvkeyonceprobe.elf
USER_UVENVPROBE_ELF := $(BUILD)/uvenvprobe.elf
USER_ENVCHILD_ELF := $(BUILD)/envchild.elf
# Node.js 24.16 cross-built for SwiftOS in Docker (scripts/build-node-docker.sh
# compiles all objects; scripts/link-node.sh does the freestanding final link).
# The heavy build runs out-of-band; `make` only stages the resulting binary.
USER_NODE_ELF := $(BUILD)/node.elf
# Packing the ~57 MB node.elf into base.img bloats every image build/sign and the
# disk every QEMU test loads, for a binary only the node/npm tests use. So it is
# OPT-IN: `make base-image INCLUDE_NODE=1` (or `make node-test`) stages /bin/node;
# default builds skip it. Future: ship node as an installable package instead.
INCLUDE_NODE ?= 0
ifeq ($(INCLUDE_NODE),1)
NODE_BASE_ELFS := $(USER_NODE_ELF)
NODE_PACK_CMD := cp $(USER_NODE_ELF) $(BASE_ROOT)/bin/node
else
NODE_BASE_ELFS :=
NODE_PACK_CMD := echo "  (node.elf NOT packed — build with INCLUDE_NODE=1 for /bin/node)"
endif

# Optional heavy userland app/shell ports: bash (SH1), zsh (SH2), ncurses+ncdemo
# (NC1), GLib+glibdemo (GL1), Midnight Commander (MC1). Each is a slow from-source
# cross-build (newlib + zlib + ncurses + glib + network). ALL default OFF so
# kernel/base/disk iteration ships only busybox and never pulls the app toolchain;
# turn one on with INCLUDE_<X>=1 (the matching test targets do). Build the port
# first: `make ncurses`/`glib`/`mc`/`bash`/`zsh`.
INCLUDE_BASH ?= 0
ifeq ($(INCLUDE_BASH),1)
BASH_BASE_ELF := $(BUILD)/bash.elf
BASH_PACK_CMD := cp $(BUILD)/bash.elf $(BASE_ROOT)/bin/bash
else
BASH_BASE_ELF :=
BASH_PACK_CMD := echo "  (bash.elf NOT packed — build with INCLUDE_BASH=1 for /bin/bash)"
endif

INCLUDE_ZSH ?= 0
ifeq ($(INCLUDE_ZSH),1)
ZSH_BASE_ELF := $(BUILD)/zsh.elf
ZSH_PACK_CMD := cp $(BUILD)/zsh.elf $(BASE_ROOT)/bin/zsh
else
ZSH_BASE_ELF :=
ZSH_PACK_CMD := echo "  (zsh.elf NOT packed — build with INCLUDE_ZSH=1 for /bin/zsh)"
endif

INCLUDE_NCURSES ?= 0
ifeq ($(INCLUDE_NCURSES),1)
NCURSES_BASE_ELF := $(BUILD)/ncdemo.elf
NCURSES_PACK_CMD := cp $(BUILD)/ncdemo.elf $(BASE_ROOT)/bin/ncdemo
else
NCURSES_BASE_ELF :=
NCURSES_PACK_CMD := echo "  (ncdemo.elf NOT packed — build with INCLUDE_NCURSES=1)"
endif

INCLUDE_GLIB ?= 0
ifeq ($(INCLUDE_GLIB),1)
GLIBDEMO_BASE_ELF := $(BUILD)/glibdemo.elf
GLIBDEMO_PACK_CMD := cp $(BUILD)/glibdemo.elf $(BASE_ROOT)/bin/glibdemo
else
GLIBDEMO_BASE_ELF :=
GLIBDEMO_PACK_CMD := echo "  (glibdemo.elf NOT packed — build with INCLUDE_GLIB=1)"
endif

INCLUDE_MC ?= 0
ifeq ($(INCLUDE_MC),1)
MC_BASE_ELF := $(BUILD)/mc.elf
MC_PACK_CMD := cp $(BUILD)/mc.elf $(BASE_ROOT)/bin/mc; mkdir -p $(BASE_ROOT)/usr/share/mc/skins; cp $(BUILD)/mc-skins/default.ini $(BASE_ROOT)/usr/share/mc/skins/default.ini
else
MC_BASE_ELF :=
MC_PACK_CMD := echo "  (mc.elf NOT packed — build with INCLUDE_MC=1)"
endif

# root's login shell in the staged base. SH3 ships /bin/zsh in base/etc/swos/passwd;
# when zsh is NOT baked (default), rewrite it to /bin/sh (busybox ash, always
# present) so login still reaches a shell. Overridable on the command line.
ROOT_LOGIN_SHELL ?= $(if $(filter 1,$(INCLUDE_ZSH)),,/bin/sh)

# SU-B: a signed test SWSITE bundle (+ a tampered copy) for site-bundle-test.
# OPT-IN via INCLUDE_SITE_TEST=1 so production images carry no test fixtures.
# The site-signing PUBLIC key is baked unconditionally (production `swupdate
# site` needs it to verify bundles).
SITE_TEST_BUNDLE := $(BUILD)/site-test.swsite
SITE_TEST_BAD_BUNDLE := $(BUILD)/site-test-bad.swsite
INCLUDE_SITE_TEST ?= 0
ifeq ($(INCLUDE_SITE_TEST),1)
SITE_TEST_DEPS := $(SITE_TEST_BUNDLE) $(SITE_TEST_BAD_BUNDLE)
SITE_TEST_PACK_CMD := mkdir -p $(BASE_ROOT)/usr/share/swupdate-test; cp $(SITE_TEST_BUNDLE) $(BASE_ROOT)/usr/share/swupdate-test/site.swsite; cp $(SITE_TEST_BAD_BUNDLE) $(BASE_ROOT)/usr/share/swupdate-test/site-bad.swsite
else
SITE_TEST_DEPS :=
SITE_TEST_PACK_CMD := true
endif

# OS-3b: a tiny signed SWOSBASE image baked under /usr/share/swupdate-test so
# os-stage-test has a valid image to stream into the inactive A/B slot. OS-1b: a
# tiny signed SWSYS bundle (kernel stub + that base) for os-coordinate-activate-test
# (swupdate os-apply-local, no network). Opt-in via INCLUDE_OS_STAGE_TEST=1 so
# production images carry no test fixtures.
TEST_BASE_IMG := $(BUILD)/test-base.img
TEST_OS_BUNDLE := $(BUILD)/test-os.swsys
INCLUDE_OS_STAGE_TEST ?= 0
ifeq ($(INCLUDE_OS_STAGE_TEST),1)
OS_STAGE_DEPS := $(TEST_BASE_IMG) $(TEST_OS_BUNDLE)
OS_STAGE_PACK_CMD := mkdir -p $(BASE_ROOT)/usr/share/swupdate-test; cp $(TEST_BASE_IMG) $(BASE_ROOT)/usr/share/swupdate-test/test-base.img; cp $(TEST_OS_BUNDLE) $(BASE_ROOT)/usr/share/swupdate-test/os.swsys
else
OS_STAGE_DEPS :=
OS_STAGE_PACK_CMD := true
endif

# OS-1c-2b: fixtures for uefi-kinstall-test — a genuinely NEW kernel image (the
# padded slot with one trailing pad byte flipped, so it has a DISTINCT sha256 but
# still boots; the flipped byte is in the zero-pad past the real kernel) plus its
# host-signed 104-byte manifest entries, sliced out of a kernelboot-built v4
# manifest: entryB (slot index 1, valid for install into the inactive B slot),
# entryA (slot index 0 over the same image — replayed into B it must be rejected
# by the per-slot index binding), and entry-badsig (entryB with the signature
# zeroed — must be rejected). Opt-in via INCLUDE_OS_KINSTALL_TEST=1 so production
# images carry no test fixtures. The rules that build these live next to the
# kernel-slot.bin rule (KERNEL_SLOT_BYTES is defined there).
KINSTALL_TEST_NEWKERNEL := $(BUILD)/kinstall-newkernel.bin
KINSTALL_TEST_ENTRY_B := $(BUILD)/kinstall-entryB.bin
KINSTALL_TEST_ENTRY_A := $(BUILD)/kinstall-entryA.bin
KINSTALL_TEST_ENTRY_BADSIG := $(BUILD)/kinstall-entry-badsig.bin
# OS-1c-3b: a signed SWSYS v2 bundle whose kernel half is the distinct new kernel
# (+ the tiny test base), so `swupdate os` install-then-flips a genuinely new kernel.
KINSTALL_TEST_BUNDLE := $(BUILD)/kinstall-os.swsys
INCLUDE_OS_KINSTALL_TEST ?= 0
ifeq ($(INCLUDE_OS_KINSTALL_TEST),1)
KINSTALL_TEST_DEPS := $(KINSTALL_TEST_NEWKERNEL) $(KINSTALL_TEST_ENTRY_B) $(KINSTALL_TEST_ENTRY_A) $(KINSTALL_TEST_ENTRY_BADSIG) $(KINSTALL_TEST_BUNDLE)
KINSTALL_TEST_PACK_CMD := mkdir -p $(BASE_ROOT)/usr/share/swos-kinstall-test; cp $(KINSTALL_TEST_NEWKERNEL) $(BASE_ROOT)/usr/share/swos-kinstall-test/newkernel.bin; cp $(KINSTALL_TEST_ENTRY_B) $(BASE_ROOT)/usr/share/swos-kinstall-test/entryB.bin; cp $(KINSTALL_TEST_ENTRY_A) $(BASE_ROOT)/usr/share/swos-kinstall-test/entryA.bin; cp $(KINSTALL_TEST_ENTRY_BADSIG) $(BASE_ROOT)/usr/share/swos-kinstall-test/entry-badsig.bin; cp $(KINSTALL_TEST_BUNDLE) $(BASE_ROOT)/usr/share/swos-kinstall-test/os.swsys
else
KINSTALL_TEST_DEPS :=
KINSTALL_TEST_PACK_CMD := true
endif

USER_UVBARRIERPROBE_ELF := $(BUILD)/uvbarrierprobe.elf
USER_UVCONDPROBE_ELF := $(BUILD)/uvcondprobe.elf
USER_UVSOCKETPAIRPROBE_ELF := $(BUILD)/uvsocketpairprobe.elf
USER_UVSIGNALPROBE_ELF := $(BUILD)/uvsignalprobe.elf
USER_UVATFORKPROBE_ELF := $(BUILD)/uvatforkprobe.elf
USER_UVSPAWNPROBE_ELF := $(BUILD)/uvspawnprobe.elf
USER_SIGNALPROBE_ELF := $(BUILD)/signalprobe.elf
USER_PTYSIGPROBE_ELF := $(BUILD)/ptysigprobe.elf
USER_SOCKETPROBE_ELF := $(BUILD)/socketprobe.elf
USER_COPROC_ELF := $(BUILD)/coproc.elf
USER_FORKDEMO_ELF := $(BUILD)/forkdemo.elf
USER_EXECDEMO_ELF := $(BUILD)/execdemo.elf
USER_ORPHANDEMO_ELF := $(BUILD)/orphandemo.elf
USER_QW2IPC_ELF := $(BUILD)/qw2-ipc.elf
USER_IPCCALL_ELF := $(BUILD)/ipc-call-test.elf
USER_FDOPSDEMO_ELF := $(BUILD)/fdopsdemo.elf
USER_S4STRESS_ELF := $(BUILD)/s4stress.elf
USER_SATSTRESS_ELF := $(BUILD)/satstress.elf
USER_SMPRACE_ELF := $(BUILD)/smprace.elf
USER_EDGESTRESS_ELF := $(BUILD)/edgestress.elf
USER_SECURITYDEMO_ELF := $(BUILD)/securitydemo.elf
USER_DEVICEAUTHDEMO_ELF := $(BUILD)/deviceauthdemo.elf
USER_DEVICEMMAPPROBE_ELF := $(BUILD)/devicemmapprobe.elf
USER_NETMMAPPROBE_ELF := $(BUILD)/netmmapprobe.elf
USER_NETDRIVERPROBE_ELF := $(BUILD)/netdriverprobe.elf
USER_NETSVC_ELF := $(BUILD)/netsvc.elf
USER_NETSVCDEMO_ELF := $(BUILD)/netsvc-demo.elf
USER_IDENTITYDEMO_ELF := $(BUILD)/identitydemo.elf
USER_CONSOLELOGIN_ELF := $(BUILD)/console-login.elf
USER_PASSWD_ELF := $(BUILD)/passwd.elf
USER_SLEEPPROBE_ELF := $(BUILD)/sleepprobe.elf
USER_SIMDPROBE_ELF := $(BUILD)/simdprobe.elf
USER_PTYPROBE_ELF := $(BUILD)/ptyprobe.elf
USER_CELLSTATPROBE_ELF := $(BUILD)/cellstatprobe.elf
USER_PROCMAXPROBE_ELF := $(BUILD)/procmaxprobe.elf
USER_CELLCHILD_ELF := $(BUILD)/cellchild.elf
USER_CELLCREATEPROBE_ELF := $(BUILD)/cellcreateprobe.elf
USER_CELLNSCHILD_ELF := $(BUILD)/cellnschild.elf
USER_CELLNSPROBE_ELF := $(BUILD)/cellnsprobe.elf
USER_CELLCAPPROBE_ELF := $(BUILD)/cellcapprobe.elf
USER_CELLHELLO_ELF := $(BUILD)/cellhello.elf
USER_CELLSVCPROBE_ELF := $(BUILD)/cellsvcprobe.elf
USER_CELLGROWER_ELF := $(BUILD)/cellgrower.elf
USER_CELLGROWPROBE_ELF := $(BUILD)/cellgrowprobe.elf
USER_CELLOPENER_ELF := $(BUILD)/cellopener.elf
USER_CELLHANDLEPROBE_ELF := $(BUILD)/cellhandleprobe.elf
USER_CELLSVC_ELF := $(BUILD)/cell-svc.elf
USER_CELLSUPERVISOR_ELF := $(BUILD)/cell-supervisor.elf
USER_CELLKVSUPERVISOR_ELF := $(BUILD)/cell-kv-supervisor.elf
USER_PTYRUN_ELF := $(BUILD)/ptyrun.elf
USER_PS_ELF := $(BUILD)/ps.elf
USER_ID_ELF := $(BUILD)/id.elf
USER_SUDO_ELF := $(BUILD)/sudo.elf
USER_REBOOT_ELF := $(BUILD)/reboot.elf
USER_SHUTDOWN_ELF := $(BUILD)/shutdown.elf
USER_LOGTAIL_ELF := $(BUILD)/logtail.elf
USER_LOGTAILPROBE_ELF := $(BUILD)/logtail-probe.elf
USER_SWOSCONFIRM_ELF := $(BUILD)/swos-confirm.elf
USER_SWOSACTIVATE_ELF := $(BUILD)/swos-activate.elf
USER_SWOSUPDATE_ELF := $(BUILD)/swos-update.elf
USER_SWOSKSTAGE_ELF := $(BUILD)/swos-kstage.elf
USER_SWOSKACTIVATE_ELF := $(BUILD)/swos-kactivate.elf
USER_SWOSKCONFIRM_ELF := $(BUILD)/swos-kconfirm.elf
USER_SWOSKINSTALL_ELF := $(BUILD)/swos-kinstall.elf
USER_SWOSSTAGEBASE_ELF := $(BUILD)/swos-stagebase.elf
USER_LS_ELF := $(BUILD)/ls.elf
USER_SWUPDATE_ELF := $(BUILD)/swupdate.elf
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
USER_CROND_ELF := $(BUILD)/crond.elf
USER_CALC_ELF := $(BUILD)/calc.elf
USER_KV_ELF := $(BUILD)/kv.elf
USER_HEAD_ELF := $(BUILD)/head.elf
USER_TOUCH_ELF := $(BUILD)/touch.elf
USER_WC_ELF := $(BUILD)/wc.elf
USER_TOP_ELF := $(BUILD)/top.elf
USER_NETINFO_ELF := $(BUILD)/netinfo.elf
USER_UDPECHO_ELF := $(BUILD)/udpecho.elf
USER_TCPECHO_ELF := $(BUILD)/tcpecho.elf
USER_THREADSDEMO_ELF := $(BUILD)/threadsdemo.elf
USER_MMAPDEMO_ELF := $(BUILD)/mmapdemo.elf
USER_TCPGET_ELF := $(BUILD)/tcpget.elf
USER_TLSGET_ELF := $(BUILD)/tlsget.elf
USER_HTTPD_ELF := $(BUILD)/httpd.elf
USER_SSH_ELF := $(BUILD)/ssh.elf
USER_SSHD_ELF := $(BUILD)/sshd.elf
USER_NSLOOKUP_ELF := $(BUILD)/nslookup.elf
USER_C4B_SOCKXFER_ELF := $(BUILD)/c4b-sockxfer.elf
USER_QW4_BADGE_ELF := $(BUILD)/qw4-badge.elf
USER_QW5_RIGHTSXFER_ELF := $(BUILD)/qw5-rightsxfer.elf
USER_DRVINPUTD_ELF := $(BUILD)/drvinputd.elf
USER_DRVSVCDEMO_ELF := $(BUILD)/drvsvcdemo.elf
USER_SVC_INPUT_ELF := $(BUILD)/svc-input.elf
USER_INPUTD_ELF := $(BUILD)/inputd.elf
USER_SHMRINGPROBE_ELF := $(BUILD)/shmringprobe.elf
USER_SVC_SUPERVISOR_ELF := $(BUILD)/svc-supervisor.elf
USER_PKG_ELF := $(BUILD)/pkg.elf
USER_LLM_ELF := $(BUILD)/llm.elf
USER_LLMD_ELF := $(BUILD)/llmd.elf
USER_PKGHELLO_ELF := $(BUILD)/pkghello.elf
USER_ACME_ELF := $(BUILD)/acme.elf
# SC2: SwiftCube control-plane daemon + node agent (swiftcube/).
USER_SCTLD_ELF := $(BUILD)/sctld.elf
USER_SLET_ELF := $(BUILD)/slet.elf
BASE_EXEC_ELFS := \
	$(USER_ACME_ELF) \
	$(USER_SCTLD_ELF) \
	$(USER_SLET_ELF) \
	$(NODE_BASE_ELFS) \
	$(USER_CALC_ELF) \
	$(USER_LLM_ELF) \
	$(USER_LLMD_ELF) \
	$(USER_KV_ELF) \
	$(USER_HEAD_ELF) \
	$(USER_TOUCH_ELF) \
	$(USER_WC_ELF) \
	$(USER_TOP_ELF) \
	$(USER_NETINFO_ELF) \
	$(USER_UDPECHO_ELF) \
	$(USER_TCPECHO_ELF) \
	$(USER_THREADSDEMO_ELF) \
	$(USER_MMAPDEMO_ELF) \
	$(USER_TCPGET_ELF) \
	$(USER_TLSGET_ELF) \
	$(USER_HTTPD_ELF) \
	$(USER_SSH_ELF) \
	$(USER_SSHD_ELF) \
	$(USER_NSLOOKUP_ELF) \
	$(USER_C4B_SOCKXFER_ELF) \
	$(USER_SHMRINGPROBE_ELF) \
	$(USER_QW4_BADGE_ELF) \
	$(USER_QW5_RIGHTSXFER_ELF) \
	$(USER_DRVINPUTD_ELF) \
	$(USER_DRVSVCDEMO_ELF) \
	$(USER_SVC_INPUT_ELF) \
	$(USER_INPUTD_ELF) \
	$(USER_SVC_SUPERVISOR_ELF) \
	$(USER_PKG_ELF) \
	$(USER_CONSOLELOGIN_ELF) \
	$(USER_PASSWD_ELF) \
	$(USER_ID_ELF) \
	$(USER_SUDO_ELF) \
	$(USER_REBOOT_ELF) \
	$(USER_SHUTDOWN_ELF) \
	$(USER_LOGTAIL_ELF) \
	$(USER_LOGTAILPROBE_ELF) \
	$(USER_SWOSCONFIRM_ELF) \
	$(USER_SWOSACTIVATE_ELF) \
	$(USER_SWOSUPDATE_ELF) \
	$(USER_SWOSKSTAGE_ELF) \
	$(USER_SWOSKACTIVATE_ELF) \
	$(USER_SWOSKCONFIRM_ELF) \
	$(USER_SWOSKINSTALL_ELF) \
	$(USER_SWOSSTAGEBASE_ELF) \
	$(USER_LS_ELF) \
	$(USER_SWUPDATE_ELF) \
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
	$(USER_CROND_ELF) \
	$(USER_HELLO_ELF) \
	$(USER_SWOSINIT_ELF) \
	$(USER_TTYDEMO_ELF) \
	$(USER_ARGVDEMO_ELF) \
	$(USER_SPAWNDEMO_ELF) \
	$(USER_SELFEXECDEMO_ELF) \
	$(USER_FSDEMO_ELF) \
	$(USER_BRKDEMO_ELF) \
	$(USER_NEWLIBTEST_ELF) \
	$(USER_CLOCKPROBE_ELF) \
	$(USER_MPROTECTPROBE_ELF) \
	$(USER_LARGEMMAPPROBE_ELF) \
	$(USER_MMAPRESERVEPROBE_ELF) \
	$(USER_MAPFIXEDPROBE_ELF) \
	$(USER_PTHREADPROBE_ELF) \
	$(USER_FUTEXPROBE_ELF) \
	$(USER_THREADSYNCPROBE_ELF) \
	$(USER_SELECTPROBE_ELF) \
	$(USER_EVENTFDPROBE_ELF) \
	$(USER_EPOLLPROBE_ELF) \
	$(USER_UVWAKEPROBE_ELF) \
	$(USER_UVSEMPROBE_ELF) \
	$(USER_UVRWLOCKPROBE_ELF) \
	$(USER_UVMUTEXPROBE_ELF) \
	$(USER_UVTHREADNAMEPROBE_ELF) \
	$(USER_UVTHREADSTACKPROBE_ELF) \
	$(USER_UVKEYONCEPROBE_ELF) \
	$(USER_UVENVPROBE_ELF) \
	$(USER_ENVCHILD_ELF) \
	$(USER_UVBARRIERPROBE_ELF) \
	$(USER_UVCONDPROBE_ELF) \
	$(USER_UVSOCKETPAIRPROBE_ELF) \
	$(USER_UVSIGNALPROBE_ELF) \
	$(USER_UVATFORKPROBE_ELF) \
	$(USER_UVSPAWNPROBE_ELF) \
	$(USER_SIGNALPROBE_ELF) \
	$(USER_PTYSIGPROBE_ELF) \
	$(USER_SOCKETPROBE_ELF) \
	$(USER_COPROC_ELF) \
	$(USER_FORKDEMO_ELF) \
	$(USER_EXECDEMO_ELF) \
	$(USER_ORPHANDEMO_ELF) \
	$(USER_QW2IPC_ELF) \
	$(USER_IPCCALL_ELF) \
	$(USER_FDOPSDEMO_ELF) \
	$(USER_S4STRESS_ELF) \
	$(USER_SATSTRESS_ELF) \
	$(USER_SMPRACE_ELF) \
	$(USER_EDGESTRESS_ELF) \
	$(USER_SECURITYDEMO_ELF) \
	$(USER_DEVICEAUTHDEMO_ELF) \
	$(USER_DEVICEMMAPPROBE_ELF) \
	$(USER_NETMMAPPROBE_ELF) \
	$(USER_NETDRIVERPROBE_ELF) \
	$(USER_NETSVC_ELF) \
	$(USER_NETSVCDEMO_ELF) \
	$(USER_IDENTITYDEMO_ELF) \
	$(USER_PS_ELF) \
	$(USER_SLEEPPROBE_ELF) \
	$(USER_SIMDPROBE_ELF) \
	$(USER_PTYPROBE_ELF) \
	$(USER_CELLSTATPROBE_ELF) \
	$(USER_PROCMAXPROBE_ELF) \
	$(USER_CELLCHILD_ELF) \
	$(USER_CELLCREATEPROBE_ELF) \
	$(USER_CELLNSCHILD_ELF) \
	$(USER_CELLNSPROBE_ELF) \
	$(USER_CELLCAPPROBE_ELF) \
	$(USER_CELLHELLO_ELF) \
	$(USER_CELLSVCPROBE_ELF) \
	$(USER_CELLGROWER_ELF) \
	$(USER_CELLGROWPROBE_ELF) \
	$(USER_CELLOPENER_ELF) \
	$(USER_CELLHANDLEPROBE_ELF) \
	$(USER_CELLSVC_ELF) \
	$(USER_CELLSUPERVISOR_ELF) \
	$(USER_CELLKVSUPERVISOR_ELF) \
	$(USER_PTYRUN_ELF) \
	$(BUILD)/busybox.elf \
	$(NCURSES_BASE_ELF) \
	$(GLIBDEMO_BASE_ELF) \
	$(MC_BASE_ELF) \
	$(BASH_BASE_ELF) \
	$(ZSH_BASE_ELF)

.PHONY: ncurses ncurses-test glib glib-test mc mc-test bash bash-test zsh zsh-test
.PHONY: build run debug gdb test docs-test errno-test cubestore-test swiftcube-test phase1-roadmap-test api-complete-examples-test examples-verification-test stability-coverage-test page-allocator-refcount-lifecycle-test elf-loader-test user-access-test signed-image-test panic-loop-test qemu-virt-hardware-map-test log-export-test clock-test gicv3-test virtio-pci-test h3-ramdisk-test h4-ssh-pci-test h5-acpi-test hetzner-deploy-test data-persist-test crond-test reboot-test os-stage-test os-update-test os-confirm-test os-coordinate-test os-coordinate-activate-test uefi-kinstall-test uefi-os-install-test datafs-test datafs-fsync-test datafs-sqlite-test v1-volume-test v2-label-test v2-manifest-test v2-anchor-test nginx-test nginx-data-test nginx-tls-test site-seed-test site-bundle-test site-update-test acme-mock-test acme-persist-test acme-verify-test tls-verify-test tls-truststore-test mprotect-test largemmap-test mmapreserve-test mapfixed-test pthread-test futex-test threadsync-test select-test eventfd-test qw4-badge-test pty-test ptysig-test epoll-test uvwake-test uvsem-test uvmutex-test uvthreadname-test uvthreadstack-test uvbarrier-test uvcond-test uvsocketpair-test uvsignal-test uvatfork-test signal-test socket-test usb-xhci-test smp-state-audit smp-mailbox-layout smp-release-guard smp-release-contract smp-s1-preflight smp-test orphan-reap-test smp-resource-stress-test smp-headroom-test smp-uefi-test s4-resource-stress-test saturation-test saturation-smp-test smp-race-stress-test edge-stress-test httpd-load-test smp-cpu-utilization-test s5-scheduler-placement-test s5-placement-stress-test s5-el0-fanout-test s5-thread-fanout-test s5-run-any-placement-test s5-test c5-test c5-mmio-grant-test c5-userland-driver-test c5-tty-inject-test ns1-net-grant-test ns2-net-driver-test ns3-net-service-test c5-driver-service-test la1-service-test c5-device-handle-test c5-device-discovery-test c5-device-metadata-test c5-device-authority-test c5-device-rights-test device-authority-cap-test s0-test s0c-test s1-test sshkey ssh-transport-test sshd-transport-test sshd-usr-bin-exec-test sshd-sftp-test sshd-sftp-write-test sshd-interactive-test sshd-host-key-rotation-test sshd-kex-seed-test sshd-authorized-keys-test sshd-supervision-test sshd-runtime-entropy-test net-static-ipv6-test model clean tools-check newlib busybox busybox-check uefi uefi-run disk disk-run hetzner-run base-image syspack syspack-test swpkg swpkg-header-integrity-test sitepack sitepack-test swsite-test pkgstore pkgrepo swport ports-catalog-test ports-recipe-test ports-lua-repo-fixture ports-zlib-repo-fixture ports-bzip2-repo-fixture ports-zstd-repo-fixture ports-xz-repo-fixture ports-libarchive-repo-fixture ports-ca-certificates-repo-fixture ports-openssl-repo-fixture ports-pcre2-repo-fixture ports-tzdata-repo-fixture ports-curl-repo-fixture ports-rsync-repo-fixture rsync-test ports-nginx-repo-fixture ports-sqlite-repo-fixture node-configure-probe ports-seed-repo-fixture ports-static-host-publish ports-hosted-url-verify ports-hosted-url-verify-test package-fixture package-store-fixture package-repo-fixture package-overlay-test package-store-test package-local-install-fixture package-lua-install-fixture package-local-install-test package-remove-test package-repo-install-test package-lua-repo-install-test package-ports-seed-repo-install-test package-static-host-repo-install-test package-static-host-dns-repo-install-test package-hosted-url-install-test
.PHONY: build run debug gdb test docs-test errno-test cubestore-test swiftcube-test phase1-roadmap-test api-complete-examples-test examples-verification-test stability-coverage-test page-allocator-refcount-lifecycle-test elf-loader-test user-access-test signed-image-test panic-loop-test qemu-virt-hardware-map-test log-export-test clock-test gicv3-test virtio-pci-test h3-ramdisk-test h4-ssh-pci-test h5-acpi-test hetzner-deploy-test data-persist-test crond-test reboot-test os-stage-test os-update-test os-confirm-test os-coordinate-test os-coordinate-activate-test datafs-test datafs-fsync-test datafs-sqlite-test v1-volume-test v2-label-test v2-manifest-test v2-anchor-test nginx-test nginx-data-test nginx-tls-test site-seed-test site-bundle-test site-update-test acme-mock-test acme-persist-test acme-verify-test tls-verify-test tls-truststore-test mprotect-test largemmap-test mmapreserve-test mapfixed-test pthread-test futex-test threadsync-test select-test eventfd-test qw4-badge-test pty-test ptysig-test epoll-test uvwake-test uvsem-test uvmutex-test uvthreadname-test uvthreadstack-test uvbarrier-test uvcond-test uvsocketpair-test uvsignal-test uvatfork-test signal-test socket-test usb-xhci-test smp-state-audit smp-mailbox-layout smp-release-guard smp-release-contract smp-s1-preflight smp-test orphan-reap-test smp-resource-stress-test smp-headroom-test smp-uefi-test s4-resource-stress-test saturation-test saturation-smp-test smp-race-stress-test edge-stress-test httpd-load-test smp-cpu-utilization-test s5-scheduler-placement-test s5-placement-stress-test s5-el0-fanout-test s5-thread-fanout-test s5-run-any-placement-test s5-test c5-test c5-mmio-grant-test c5-userland-driver-test c5-tty-inject-test c6-cell-accounting-test c6-cell-create-test c6-cell-namespace-test c6-cell-lifecycle-test c6-cell-service-test c7-cell-pagecap-test c7-cell-handlecap-test c7-cell-supervisor-test c7-cell-realservice-test ns1-net-grant-test ns2-net-driver-test ns3-net-service-test c5-driver-service-test la1-service-test c5-device-handle-test c5-device-discovery-test c5-device-metadata-test c5-device-authority-test c5-device-rights-test device-authority-cap-test s0-test s0c-test s1-test sshkey ssh-transport-test sshd-transport-test sshd-usr-bin-exec-test sshd-sftp-test sshd-sftp-write-test sshd-interactive-test sshd-host-key-rotation-test sshd-kex-seed-test sshd-authorized-keys-test sshd-supervision-test sshd-runtime-entropy-test net-static-ipv6-test model clean tools-check newlib busybox busybox-check uefi uefi-run disk disk-run hetzner-run base-image syspack syspack-test swpkg swpkg-header-integrity-test sitepack sitepack-test swsite-test pkgstore pkgrepo swport ports-catalog-test ports-recipe-test ports-lua-repo-fixture ports-zlib-repo-fixture ports-bzip2-repo-fixture ports-zstd-repo-fixture ports-xz-repo-fixture ports-libarchive-repo-fixture ports-ca-certificates-repo-fixture ports-openssl-repo-fixture ports-pcre2-repo-fixture ports-tzdata-repo-fixture ports-curl-repo-fixture ports-rsync-repo-fixture rsync-test ports-nginx-repo-fixture ports-sqlite-repo-fixture node-configure-probe ports-seed-repo-fixture ports-static-host-publish ports-hosted-url-verify ports-hosted-url-verify-test package-fixture package-store-fixture package-repo-fixture package-overlay-test package-store-test package-local-install-fixture package-lua-install-fixture package-local-install-test package-remove-test package-repo-install-test package-lua-repo-install-test package-ports-seed-repo-install-test package-static-host-repo-install-test package-static-host-dns-repo-install-test package-hosted-url-install-test
.PHONY: build run debug gdb test docs-test errno-test cubestore-test swiftcube-test phase1-roadmap-test api-complete-examples-test examples-verification-test stability-coverage-test page-allocator-refcount-lifecycle-test elf-loader-test user-access-test signed-image-test panic-loop-test qemu-virt-hardware-map-test log-export-test clock-test gicv3-test virtio-pci-test h3-ramdisk-test h4-ssh-pci-test h5-acpi-test hetzner-deploy-test data-persist-test crond-test reboot-test os-stage-test os-update-test os-confirm-test os-coordinate-test os-coordinate-activate-test uefi-kinstall-test uefi-os-install-test datafs-test datafs-fsync-test datafs-sqlite-test nginx-test nginx-data-test nginx-tls-test site-seed-test site-bundle-test site-update-test acme-mock-test acme-persist-test acme-verify-test tls-verify-test tls-truststore-test mprotect-test largemmap-test mmapreserve-test mapfixed-test pthread-test futex-test threadsync-test select-test eventfd-test qw4-badge-test pty-test ptysig-test epoll-test uvwake-test uvsem-test uvmutex-test uvthreadname-test uvthreadstack-test uvbarrier-test uvcond-test uvsocketpair-test uvsignal-test uvatfork-test signal-test socket-test usb-xhci-test smp-state-audit smp-mailbox-layout smp-release-guard smp-release-contract smp-s1-preflight smp-test orphan-reap-test procmax-test smp-resource-stress-test smp-headroom-test smp-uefi-test s4-resource-stress-test saturation-test saturation-smp-test smp-race-stress-test edge-stress-test httpd-load-test smp-cpu-utilization-test s5-scheduler-placement-test s5-placement-stress-test s5-el0-fanout-test s5-thread-fanout-test s5-run-any-placement-test s5-test c5-test c5-mmio-grant-test c5-userland-driver-test c5-tty-inject-test ns1-net-grant-test ns2-net-driver-test ns3-net-service-test c5-driver-service-test la1-service-test c5-device-handle-test c5-device-discovery-test c5-device-metadata-test c5-device-authority-test c5-device-rights-test device-authority-cap-test s0-test s0c-test s1-test sshkey ssh-transport-test sshd-transport-test sshd-usr-bin-exec-test sshd-sftp-test sshd-sftp-write-test sshd-interactive-test sshd-host-key-rotation-test sshd-kex-seed-test sshd-authorized-keys-test sshd-supervision-test sshd-runtime-entropy-test net-static-ipv6-test model clean tools-check newlib busybox busybox-check uefi uefi-run disk disk-run hetzner-run base-image syspack syspack-test swpkg swpkg-header-integrity-test sitepack sitepack-test swsite-test pkgstore pkgrepo swport ports-catalog-test ports-recipe-test ports-lua-repo-fixture ports-zlib-repo-fixture ports-bzip2-repo-fixture ports-zstd-repo-fixture ports-xz-repo-fixture ports-libarchive-repo-fixture ports-ca-certificates-repo-fixture ports-openssl-repo-fixture ports-pcre2-repo-fixture ports-tzdata-repo-fixture ports-curl-repo-fixture ports-rsync-repo-fixture rsync-test ports-nginx-repo-fixture ports-sqlite-repo-fixture node-configure-probe ports-seed-repo-fixture ports-static-host-publish ports-hosted-url-verify ports-hosted-url-verify-test package-fixture package-store-fixture package-repo-fixture package-overlay-test package-store-test package-local-install-fixture package-lua-install-fixture package-local-install-test package-remove-test package-repo-install-test package-lua-repo-install-test package-ports-seed-repo-install-test package-static-host-repo-install-test package-static-host-dns-repo-install-test package-hosted-url-install-test
.PHONY: build run debug gdb test docs-test errno-test cubestore-test swiftcube-test phase1-roadmap-test api-complete-examples-test examples-verification-test stability-coverage-test page-allocator-refcount-lifecycle-test elf-loader-test user-access-test signed-image-test panic-loop-test qemu-virt-hardware-map-test log-export-test clock-test gicv3-test virtio-pci-test h3-ramdisk-test h4-ssh-pci-test h5-acpi-test hetzner-deploy-test data-persist-test crond-test reboot-test os-stage-test os-update-test os-confirm-test os-coordinate-test os-coordinate-activate-test datafs-test datafs-fsync-test datafs-sqlite-test nginx-test nginx-data-test nginx-tls-test site-seed-test site-bundle-test site-update-test acme-mock-test acme-persist-test acme-verify-test tls-verify-test tls-truststore-test mprotect-test largemmap-test mmapreserve-test mapfixed-test pthread-test futex-test threadsync-test select-test eventfd-test qw4-badge-test pty-test ptysig-test epoll-test uvwake-test uvsem-test uvmutex-test uvthreadname-test uvthreadstack-test uvbarrier-test uvcond-test uvsocketpair-test uvsignal-test uvatfork-test signal-test socket-test usb-xhci-test smp-state-audit smp-mailbox-layout smp-release-guard smp-release-contract smp-s1-preflight smp-test orphan-reap-test procmax-test smp-resource-stress-test smp-headroom-test smp-uefi-test s4-resource-stress-test saturation-test saturation-smp-test smp-race-stress-test edge-stress-test httpd-load-test smp-cpu-utilization-test s5-scheduler-placement-test s5-placement-stress-test s5-el0-fanout-test s5-thread-fanout-test s5-run-any-placement-test s5-test c5-test c5-mmio-grant-test c5-userland-driver-test c5-tty-inject-test c6-cell-accounting-test c6-cell-create-test c6-cell-namespace-test c6-cell-lifecycle-test c6-cell-service-test c7-cell-pagecap-test c7-cell-handlecap-test c7-cell-supervisor-test c7-cell-realservice-test ns1-net-grant-test ns2-net-driver-test ns3-net-service-test c5-driver-service-test la1-service-test c5-device-handle-test c5-device-discovery-test c5-device-metadata-test c5-device-authority-test c5-device-rights-test device-authority-cap-test s0-test s0c-test s1-test sshkey ssh-transport-test sshd-transport-test sshd-usr-bin-exec-test sshd-sftp-test sshd-sftp-write-test sshd-interactive-test sshd-host-key-rotation-test sshd-kex-seed-test sshd-authorized-keys-test sshd-supervision-test sshd-runtime-entropy-test net-static-ipv6-test model clean tools-check newlib busybox busybox-check uefi uefi-run disk disk-run hetzner-run base-image syspack syspack-test swpkg swpkg-header-integrity-test sitepack sitepack-test swsite-test pkgstore pkgrepo swport ports-catalog-test ports-recipe-test ports-lua-repo-fixture ports-zlib-repo-fixture ports-bzip2-repo-fixture ports-zstd-repo-fixture ports-xz-repo-fixture ports-libarchive-repo-fixture ports-ca-certificates-repo-fixture ports-openssl-repo-fixture ports-pcre2-repo-fixture ports-tzdata-repo-fixture ports-curl-repo-fixture ports-rsync-repo-fixture rsync-test ports-nginx-repo-fixture ports-sqlite-repo-fixture node-configure-probe ports-seed-repo-fixture ports-static-host-publish ports-hosted-url-verify ports-hosted-url-verify-test package-fixture package-store-fixture package-repo-fixture package-overlay-test package-store-test package-local-install-fixture package-lua-install-fixture package-local-install-test package-remove-test package-repo-install-test package-lua-repo-install-test package-ports-seed-repo-install-test package-static-host-repo-install-test package-static-host-dns-repo-install-test package-hosted-url-install-test
.PHONY: uvrwlock-test qw2-blocking-ipc-test ipc-call-test qw5-rights-intersection-test
.PHONY: uvspawn-test
.PHONY: virtio-transport-test
.PHONY: uvkeyonce-test
.PHONY: uvenv-test
build: $(KERNEL_ELF)
.PHONY: ssh-runtime-entropy-test
.PHONY: sshd-ipv6-listener-test
.PHONY: sshd-ipv6-supervision-test
.PHONY: sshd-deploy-preflight-test
.PHONY: hetzner-deploy-bundle-test
.PHONY: netinfo-test
.PHONY: device-mmio-map-test

$(QEMU_DTB): | $(BUILD)/.dir
	$(QEMU) -M virt,dumpdtb=$@ -cpu cortex-a72 -m 256M -nographic

$(QEMU_DTB_SMP4): | $(BUILD)/.dir
	$(QEMU) -M virt,dumpdtb=$@ -cpu cortex-a72 -smp 4 -m 256M -nographic

# 2 GiB device tree for the node/npm harness — V8 wants the larger RAM window
# advertised so its heap reservations have headroom.
$(QEMU_DTB_2048): | $(BUILD)/.dir
	$(QEMU) -M virt,dumpdtb=$@ -cpu cortex-a72 -m 2048M -nographic

# H1: a GICv3, -smp 2 device tree for the direct-boot harness — the interrupt
# controller the Hetzner ARM VM presents (and what `-M virt,gic-version=3` emits).
$(QEMU_DTB_GICV3): | $(BUILD)/.dir
	$(QEMU) -M virt,gic-version=3,dumpdtb=$@ -cpu cortex-a72 -smp 2 -m 256M -nographic

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

$(BUILD)/user_swos_init.o: userland/swos-init.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/swos-init.c -o $@

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

$(BUILD)/user_qw5_rightsxfer.o: userland/qw5_rightsxfer.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/qw5_rightsxfer.c -o $@

$(BUILD)/user_qw4_badge.o: userland/qw4_badge.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/qw4_badge.c -o $@

$(BUILD)/user_drvinputd.o: userland/drvinputd.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/drvinputd.c -o $@

$(BUILD)/user_drvsvcdemo.o: userland/drvsvcdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/drvsvcdemo.c -o $@

$(BUILD)/user_execdemo.o: userland/execdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/execdemo.c -o $@

$(BUILD)/user_orphandemo.o: userland/orphandemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/orphandemo.c -o $@

$(BUILD)/user_qw2_ipc.o: userland/qw2_ipc.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/qw2_ipc.c -o $@

$(BUILD)/user_ipc_call_test.o: userland/ipc_call_test.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/ipc_call_test.c -o $@

$(BUILD)/user_fdopsdemo.o: userland/fdopsdemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/fdopsdemo.c -o $@

$(BUILD)/user_s4stress.o: userland/s4stress.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/s4stress.c -o $@

$(BUILD)/user_satstress.o: userland/satstress.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/satstress.c -o $@

$(BUILD)/user_smprace.o: userland/smprace.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/smprace.c -o $@

$(BUILD)/user_edgestress.o: userland/edgestress.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/edgestress.c -o $@

$(BUILD)/user_securitydemo.o: userland/securitydemo.c userland/lib/syscall.h userland/lib/fs.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/securitydemo.c -o $@

$(BUILD)/user_deviceauthdemo.o: userland/deviceauthdemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/deviceauthdemo.c -o $@

$(BUILD)/user_devicemmapprobe.o: userland/devicemmapprobe.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/devicemmapprobe.c -o $@

$(BUILD)/user_identitydemo.o: userland/identitydemo.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/identitydemo.c -o $@

$(BUILD)/user_console-login.o: userland/console-login.swift userland/lib/swos_identity.swift kernel/crypto/sha256.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/console-login.swift userland/lib/swos_identity.swift kernel/crypto/sha256.swift -o $@

$(BUILD)/user_passwd.o: userland/passwd.swift userland/lib/swos_identity.swift kernel/crypto/sha256.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/passwd.swift userland/lib/swos_identity.swift kernel/crypto/sha256.swift -o $@

# LA1/C5i: svc-input compiles with the reusable UserlandService template plus the
# shared userland virtio-input driver core; the supervisor is a standalone program
# (it is the service's client, not a service).
$(BUILD)/user_svc-input.o: userland/svc-input.swift userland/lib/userland_service.swift userland/lib/virtio_input_user.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/svc-input.swift userland/lib/userland_service.swift userland/lib/virtio_input_user.swift -o $@

$(BUILD)/user_svc-supervisor.o: userland/svc-supervisor.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/svc-supervisor.swift -o $@

# C5j: persistent userland virtio-input driver, sharing the driver core with svc-input.
$(BUILD)/user_inputd.o: userland/inputd.swift userland/lib/virtio_input_user.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/inputd.swift userland/lib/virtio_input_user.swift -o $@

# LA3: the shmring probe reuses the kernel's sans-IO ring core (the same file the
# kernel and host unit test compile), built -D SHMRING_USER so its cursor
# accessors use the SEQ_CST userland atomics for cross-process ordering.
$(BUILD)/user_shmringprobe.o: userland/shmringprobe.swift kernel/ipc/shmring.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -D SHMRING_USER -c userland/shmringprobe.swift kernel/ipc/shmring.swift -o $@

$(BUILD)/user_ps.o: userland/ps.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ps.swift -o $@

$(BUILD)/user_sleepprobe.o: userland/sleepprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/sleepprobe.swift -o $@

# LM1b: built with +neon to exercise the int8 SIMD path under NEON codegen.
$(BUILD)/user_simdprobe.o: userland/simdprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS_NEON) -c userland/simdprobe.swift -o $@

# C6a: per-cell resource-accounting probe (forks children, reads SYS_cell_stat).
$(BUILD)/user_cellstatprobe.o: userland/cellstatprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellstatprobe.swift -o $@

# Process-table capacity probe (forks until the table refuses, asserts > 16 live).
$(BUILD)/user_procmaxprobe.o: userland/procmaxprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/procmaxprobe.swift -o $@

# C6b: the cell-creation supervisor probe + the tiny workload it launches.
$(BUILD)/user_cellchild.o: userland/cellchild.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellchild.swift -o $@

$(BUILD)/user_cellcreateprobe.o: userland/cellcreateprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellcreateprobe.swift -o $@

# C6c: the namespace-root supervisor probe + the workload it confines.
$(BUILD)/user_cellnschild.o: userland/cellnschild.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellnschild.swift -o $@

$(BUILD)/user_cellnsprobe.o: userland/cellnsprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellnsprobe.swift -o $@

# C6d: the cell-lifecycle supervisor probe (cap + enumerate + teardown).
$(BUILD)/user_cellcapprobe.o: userland/cellcapprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellcapprobe.swift -o $@

# C6e: the end-to-end one-service-per-cell supervisor probe + the service it hosts.
$(BUILD)/user_cellhello.o: userland/cellhello.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellhello.swift -o $@

$(BUILD)/user_cellsvcprobe.o: userland/cellsvcprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellsvcprobe.swift -o $@

# C7a: the intra-member resident-page cap supervisor probe + the grower it launches.
$(BUILD)/user_cellgrower.o: userland/cellgrower.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellgrower.swift -o $@

$(BUILD)/user_cellgrowprobe.o: userland/cellgrowprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellgrowprobe.swift -o $@

# C7b: the per-cell handle cap supervisor probe + the opener it launches.
$(BUILD)/user_cellopener.o: userland/cellopener.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellopener.swift -o $@

$(BUILD)/user_cellhandleprobe.o: userland/cellhandleprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cellhandleprobe.swift -o $@

# C7c: the persistent restart/FDIR cell supervisor + the demo service it hosts.
$(BUILD)/user_cell-svc.o: userland/cell-svc.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cell-svc.swift -o $@

$(BUILD)/user_cell-supervisor.o: userland/cell-supervisor.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cell-supervisor.swift -o $@

# C7d: the real-service-in-a-cell supervisor (hosts the existing /bin/kv over pipes).
$(BUILD)/user_cell-kv-supervisor.o: userland/cell-kv-supervisor.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/cell-kv-supervisor.swift -o $@

# NS1: standalone Swift virtio-net MMIO grant probe.
$(BUILD)/user_netmmapprobe.o: userland/netmmapprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/netmmapprobe.swift -o $@

# NS2: userland virtio-net driver probe, over the shared NS userland net core.
$(BUILD)/user_netdriverprobe.o: userland/netdriverprobe.swift userland/lib/virtio_net_user.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/netdriverprobe.swift userland/lib/virtio_net_user.swift -o $@

# NS3: restartable userland net service + its supervisor/client, over the shared net
# core AND the shmring data-plane ring (kernel/ipc/shmring.swift, -D SHMRING_USER).
$(BUILD)/user_netsvc.o: userland/netsvc.swift userland/lib/virtio_net_user.swift kernel/ipc/shmring.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -D SHMRING_USER -c userland/netsvc.swift userland/lib/virtio_net_user.swift kernel/ipc/shmring.swift -o $@

$(BUILD)/user_netsvc-demo.o: userland/netsvc-demo.swift userland/lib/virtio_net_user.swift kernel/ipc/shmring.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -D SHMRING_USER -c userland/netsvc-demo.swift userland/lib/virtio_net_user.swift kernel/ipc/shmring.swift -o $@

$(BUILD)/user_ptyprobe.o: userland/ptyprobe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ptyprobe.swift -o $@

$(BUILD)/user_ptyrun.o: userland/ptyrun.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ptyrun.swift -o $@

$(BUILD)/user_id.o: userland/id.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/id.swift -o $@

$(BUILD)/user_sudo.o: userland/sudo.swift kernel/crypto/sha256.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/sudo.swift kernel/crypto/sha256.swift -o $@

$(BUILD)/user_logtail.o: userland/logtail.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/logtail.swift -o $@

$(BUILD)/user_logtail_probe.o: userland/logtail-probe.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/logtail-probe.swift -o $@

$(BUILD)/user_reboot.o: userland/reboot.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/reboot.swift -o $@

$(BUILD)/user_shutdown.o: userland/shutdown.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/shutdown.swift -o $@

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

$(BUILD)/user_swoskinstall.o: userland/swos-kinstall.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-kinstall.swift -o $@

$(BUILD)/user_swosstagebase.o: userland/swos-stagebase.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swos-stagebase.swift -o $@

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

$(BUILD)/user_crond.o: userland/crond.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/crond.swift -o $@

$(BUILD)/user_calc.o: userland/calc.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/calc.swift -o $@

$(BUILD)/user_kv.o: userland/kv.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/kv.swift -o $@

# /bin/llm: the app wrapper + the shared engine, compiled together (WMO).
$(BUILD)/user_llm.o: userland/llm.swift userland/lib/llama2.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS_NEON) -c userland/llm.swift userland/lib/llama2.swift -o $@

# /bin/llmd: the TCP model-serving daemon + the shared engine + bundle
# verification (manifest parse + sha256), compiled together (WMO).
$(BUILD)/user_llmd.o: userland/llmd.swift userland/lib/llama2.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS_NEON) -c userland/llmd.swift userland/lib/llama2.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

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
TLS_SWIFT_SRCS := userland/lib/tls13.swift userland/lib/x509.swift userland/lib/x509_verify.swift userland/lib/rsa.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift
$(BUILD)/user_tlsget.o: userland/tlsget.swift $(TLS_SWIFT_SRCS) userland/lib/asn1.swift userland/lib/truststore.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/tlsget.swift $(TLS_SWIFT_SRCS) userland/lib/asn1.swift userland/lib/truststore.swift -o $@

# SC2: /bin/sctld + /bin/slet — the SwiftCube control plane compiled into Embedded
# Swift userland. One source set (cubestore core + control plane + the swift-os TLS
# 1.3 record/key-schedule + crypto modules) feeds both ELFs; --gc-sections trims
# each to what its main references. The control plane is Foundation-free; the host
# control-test (make control-test) links the SAME control sources under host Swift.
SC2_CONTROL_SRCS := \
	swiftcube/cubestore/Crc32.swift swiftcube/cubestore/Model.swift swiftcube/cubestore/ByteIO.swift \
	swiftcube/cubestore/MVCCIndex.swift swiftcube/cubestore/StorageSink.swift swiftcube/cubestore/WALCodec.swift \
	swiftcube/cubestore/SnapshotCodec.swift swiftcube/cubestore/Watch.swift swiftcube/cubestore/CubeStore.swift \
	swiftcube/control/Identity.swift swiftcube/control/Schema.swift swiftcube/control/Node.swift \
	swiftcube/control/Token.swift swiftcube/control/Lease.swift swiftcube/control/RamStore.swift \
	swiftcube/control/Wire.swift swiftcube/control/Rpc.swift swiftcube/control/MutualTLS.swift \
	swiftcube/control/Channel.swift swiftcube/control/Controller.swift swiftcube/control/Agent.swift \
	swiftcube/control/SC2Boot.swift \
	userland/lib/tls13.swift userland/lib/asn1.swift userland/lib/x509.swift \
	userland/lib/x509_verify.swift userland/lib/rsa.swift \
	kernel/crypto/p256.swift kernel/crypto/sha256.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift
# SC3: the Cell-supervisor seam + slet reconcile loop. These compile into the on-device
# `slet` ELF (proving the whole reconcile loop is Embedded-Swift-clean); the host
# FakeCellSupervisor is test-only and is NOT listed here. Image verification reuses the
# existing Ed25519 (+ SHA-512) image-trust primitives — no new signature scheme.
SC3_SLET_SRCS := \
	swiftcube/cell/CellSpec.swift swiftcube/cell/CellSupervisor.swift \
	swiftcube/cell/ImageResolver.swift swiftcube/cell/C6Adapter.swift \
	swiftcube/slet/Assignment.swift swiftcube/slet/StoreClient.swift swiftcube/slet/Reconciler.swift \
	kernel/crypto/ed25519.swift kernel/crypto/sha512.swift
# SC5: the probe runner (state machine + spec) and the on-device http/tcp prober. These
# compile into the `slet` ELF too (proving the probe loop is Embedded-Swift-clean); the host
# FakeProber is test-only and is NOT listed here. NetProbe is the real prober over the SC2
# socket bridge — exercised on-device once C6 yields real Cells (gate deferred, like SC3).
SC5_SLET_SRCS := \
	swiftcube/slet/probes/Probe.swift swiftcube/slet/probes/ProbeRunner.swift \
	swiftcube/slet/probes/NetProbe.swift
# SC7: the east-west service registry object + the userspace node-proxy (target manager + L4
# forwarder + load balancer) + the node-local resolver + the on-device real transport. These
# compile into the `slet` ELF too (proving the whole node-proxy is Embedded-Swift-clean); the
# host FakeTransport is test-only and is NOT listed here. NetProxyTransport is the real L4
# transport over the SC2 socket bridge — exercised on-device once C6 yields real Cells (the
# QEMU east-west gate is deferred, like SC3/SC5). Endpoint.swift is the SC5 endpoints object
# the proxy reads from /endpoints, so it is listed here (it is not otherwise in the slet ELF).
SC7_SLET_SRCS := \
	swiftcube/sctld/endpoints/Endpoint.swift \
	swiftcube/sctld/services/Service.swift \
	swiftcube/slet/proxy/ProxyTransport.swift \
	swiftcube/slet/proxy/Balancer.swift \
	swiftcube/slet/proxy/NodeProxy.swift \
	swiftcube/slet/proxy/NetProxyTransport.swift \
	swiftcube/slet/resolver/Resolver.swift
# SC8: the persistent-volume object + datafs PV provisioning/binding/fencing + the on-device
# datafs binding. These compile into the `slet` ELF too (proving the volume path is Embedded-
# Swift-clean); the host HostDirVolumeStore is test-only and is NOT listed here. The
# VolumeManager conforms to the VolumeFence/VolumeMounter seams the reconciler drives. The live
# datafs path (real /data over virtio-blk) is exercised once datafs + C6 yield a real stateful
# Cell — the QEMU gate is deferred, like SC3/SC5/SC7.
SC8_SLET_SRCS := \
	swiftcube/slet/volume/Volume.swift \
	swiftcube/slet/volume/VolumeStore.swift \
	swiftcube/slet/volume/VolumeManager.swift \
	swiftcube/slet/volume/DatafsVolumeStore.swift

$(BUILD)/user_sctld.o: swiftcube/sctld/sctld.swift $(SC2_CONTROL_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c swiftcube/sctld/sctld.swift $(SC2_CONTROL_SRCS) -o $@
$(BUILD)/user_slet.o: swiftcube/slet/slet.swift $(SC2_CONTROL_SRCS) $(SC3_SLET_SRCS) $(SC5_SLET_SRCS) $(SC7_SLET_SRCS) $(SC8_SLET_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c swiftcube/slet/slet.swift $(SC2_CONTROL_SRCS) $(SC3_SLET_SRCS) $(SC5_SLET_SRCS) $(SC7_SLET_SRCS) $(SC8_SLET_SRCS) -o $@

# SU-B/SU-C: swupdate links the Ed25519 crypto to verify SWSITE bundles, plus the
# TLS 1.3 stack (shared with /bin/tlsget) to fetch them over HTTPS. The TLS set
# already includes sha256, so add only ed25519+sha512 on top of it. (Defined here,
# after TLS_SWIFT_SRCS, so the prerequisite list expands non-empty.)
SWUPDATE_SWIFT_SRCS := $(TLS_SWIFT_SRCS) kernel/crypto/ed25519.swift kernel/crypto/sha512.swift userland/lib/swsite.swift userland/lib/sysbundle.swift userland/lib/asn1.swift userland/lib/truststore.swift
$(BUILD)/user_swupdate.o: userland/swupdate.swift $(SWUPDATE_SWIFT_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/swupdate.swift $(SWUPDATE_SWIFT_SRCS) -o $@

# /bin/acme links the ACME message layer + JOSE/ASN.1 + P-256 over the same
# TLS 1.3 client as tlsget, all into one Embedded module.
ACME_SWIFT_SRCS := userland/lib/acme.swift userland/lib/jose.swift userland/lib/asn1.swift \
  userland/lib/tls13.swift userland/lib/x509.swift userland/lib/x509_verify.swift userland/lib/rsa.swift \
  kernel/crypto/p256.swift kernel/crypto/sha256.swift \
  kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift
$(BUILD)/user_acme.o: userland/acme_client.swift $(ACME_SWIFT_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/acme_client.swift $(ACME_SWIFT_SRCS) -o $@

$(BUILD)/user_httpd.o: userland/httpd.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/httpd.swift -o $@

SSH_SWIFT_SRCS := kernel/crypto/sha256.swift kernel/crypto/sha512.swift kernel/crypto/ed25519.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift
$(BUILD)/user_ssh.o: userland/ssh.swift $(SSH_SWIFT_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/ssh.swift $(SSH_SWIFT_SRCS) -o $@

SSHD_SWIFT_SRCS := kernel/crypto/sha256.swift kernel/crypto/sha512.swift kernel/crypto/ed25519.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift
$(BUILD)/user_sshd.o: userland/sshd.swift $(SSHD_SWIFT_SRCS) userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/sshd.swift $(SSHD_SWIFT_SRCS) -o $@

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

$(BUILD)/user_netinfo.o: userland/netinfo.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/netinfo.swift -o $@

$(USER_HELLO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_hello.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_hello.o -o $@

$(USER_SWOSINIT_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_swos_init.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_swos_init.o -o $@

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

$(USER_QW5_RIGHTSXFER_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_qw5_rightsxfer.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_qw5_rightsxfer.o -o $@

$(USER_QW4_BADGE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_qw4_badge.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_qw4_badge.o -o $@

$(USER_DRVINPUTD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvinputd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvinputd.o -o $@

$(USER_DRVSVCDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvsvcdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_drvsvcdemo.o -o $@

$(USER_EXECDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_execdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_execdemo.o -o $@

$(USER_ORPHANDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_orphandemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_orphandemo.o -o $@

$(USER_QW2IPC_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_qw2_ipc.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_qw2_ipc.o -o $@

$(USER_IPCCALL_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_ipc_call_test.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_ipc_call_test.o -o $@

$(USER_FDOPSDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fdopsdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_fdopsdemo.o -o $@

$(USER_S4STRESS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_s4stress.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_s4stress.o -o $@

$(USER_SATSTRESS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_satstress.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_satstress.o -o $@

$(USER_SMPRACE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_smprace.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_smprace.o -o $@

$(USER_EDGESTRESS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_edgestress.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_edgestress.o -o $@

$(USER_SECURITYDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_securitydemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_securitydemo.o -o $@

$(USER_DEVICEAUTHDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_deviceauthdemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_deviceauthdemo.o -o $@

$(USER_DEVICEMMAPPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_devicemmapprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_devicemmapprobe.o -o $@

$(USER_IDENTITYDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_identitydemo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_libc.o $(BUILD)/user_identitydemo.o -o $@

$(USER_CONSOLELOGIN_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_console-login.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_console-login.o -o $@

$(USER_PASSWD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_passwd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_passwd.o -o $@

$(USER_SVC_INPUT_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_svc-input.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_svc-input.o -o $@

$(USER_SVC_SUPERVISOR_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_svc-supervisor.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_svc-supervisor.o -o $@

$(USER_INPUTD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_inputd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_inputd.o -o $@

$(USER_SHMRINGPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_shmringprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_shmringprobe.o -o $@

$(USER_PS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ps.o -o $@

$(USER_SLEEPPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sleepprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sleepprobe.o -o $@

$(USER_SIMDPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_simdprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_simdprobe.o $(SWIFT_UNICODE_DATA) -o $@

$(USER_CELLSTATPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellstatprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellstatprobe.o -o $@

$(USER_PROCMAXPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_procmaxprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_procmaxprobe.o -o $@

$(USER_CELLCHILD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellchild.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellchild.o -o $@

$(USER_CELLCREATEPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellcreateprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellcreateprobe.o -o $@

$(USER_CELLNSCHILD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellnschild.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellnschild.o -o $@

$(USER_CELLNSPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellnsprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellnsprobe.o -o $@

$(USER_CELLCAPPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellcapprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellcapprobe.o -o $@

$(USER_CELLHELLO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellhello.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellhello.o -o $@

$(USER_CELLSVCPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellsvcprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellsvcprobe.o -o $@

$(USER_CELLGROWER_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellgrower.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellgrower.o -o $@

$(USER_CELLGROWPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellgrowprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellgrowprobe.o -o $@

$(USER_CELLOPENER_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellopener.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellopener.o -o $@

$(USER_CELLHANDLEPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellhandleprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cellhandleprobe.o -o $@

$(USER_CELLSVC_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cell-svc.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cell-svc.o -o $@

$(USER_CELLSUPERVISOR_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cell-supervisor.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cell-supervisor.o -o $@

$(USER_CELLKVSUPERVISOR_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cell-kv-supervisor.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_cell-kv-supervisor.o -o $@

$(USER_NETMMAPPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netmmapprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netmmapprobe.o -o $@

$(USER_NETDRIVERPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netdriverprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netdriverprobe.o -o $@

$(USER_NETSVC_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netsvc.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netsvc.o -o $@

$(USER_NETSVCDEMO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netsvc-demo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netsvc-demo.o -o $@

$(USER_PTYPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ptyprobe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ptyprobe.o -o $@

$(USER_PTYRUN_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ptyrun.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ptyrun.o -o $@

$(USER_ID_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_id.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_id.o -o $@

$(USER_SUDO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sudo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sudo.o -o $@

$(USER_LOGTAIL_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_logtail.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_logtail.o -o $@

$(USER_LOGTAILPROBE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_logtail_probe.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_logtail_probe.o -o $@

$(USER_REBOOT_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_reboot.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_reboot.o -o $@

$(USER_SHUTDOWN_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_shutdown.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_shutdown.o -o $@

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

$(USER_SWOSKINSTALL_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskinstall.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swoskinstall.o -o $@

$(USER_SWOSSTAGEBASE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosstagebase.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swosstagebase.o -o $@

$(USER_LS_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ls.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ls.o -o $@

$(USER_SWUPDATE_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swupdate.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_swupdate.o -o $@

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

$(USER_CROND_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_crond.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_crond.o -o $@

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

$(USER_NETINFO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netinfo.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_netinfo.o -o $@

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

# SC2 daemons. Link the Embedded Unicode tables (String comparison/decoding), like
# /bin/calc; --gc-sections trims them to the referenced data.
$(USER_SCTLD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sctld.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sctld.o $(SWIFT_UNICODE_DATA) -o $@
$(USER_SLET_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_slet.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_slet.o $(SWIFT_UNICODE_DATA) -o $@

$(USER_ACME_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_acme.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_acme.o -o $@

$(USER_HTTPD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_httpd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_httpd.o -o $@

$(USER_SSH_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ssh.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_ssh.o -o $@

$(USER_SSHD_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sshd.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_sshd.o -o $@

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

$(BUILD)/n_compat_stubs.o: userland/compat/stubs.c userland/compat/pthread.h userland/compat/semaphore.h userland/compat/signal.h userland/compat/sys/eventfd.h userland/compat/sys/mman.h userland/compat/sys/resource.h userland/compat/sys/socket.h userland/compat/time.h userland/compat/unistd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(BUILD)/n_clockprobe.o: userland/clockprobe.c userland/compat/time.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_CLOCKPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_clockprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_clockprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_mprotectprobe.o: userland/mprotectprobe.c userland/compat/sys/mman.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_MPROTECTPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_mprotectprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_mprotectprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_largemmapprobe.o: userland/largemmapprobe.c userland/compat/sys/mman.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_LARGEMMAPPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_largemmapprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_largemmapprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_mmapreserveprobe.o: userland/mmapreserveprobe.c userland/compat/sys/mman.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_MMAPRESERVEPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_mmapreserveprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_mmapreserveprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_mapfixedprobe.o: userland/mapfixedprobe.c userland/compat/sys/mman.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_MAPFIXEDPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_mapfixedprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_mapfixedprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_pthreadprobe.o: userland/pthreadprobe.c userland/compat/pthread.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_PTHREADPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_pthreadprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_pthreadprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_futexprobe.o: userland/futexprobe.c userland/compat/pthread.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_FUTEXPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_futexprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_futexprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_threadsyncprobe.o: userland/threadsyncprobe.c userland/compat/pthread.h userland/compat/semaphore.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_THREADSYNCPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_threadsyncprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_threadsyncprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_selectprobe.o: userland/selectprobe.c Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_SELECTPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_selectprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_selectprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_eventfdprobe.o: userland/eventfdprobe.c userland/compat/sys/eventfd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_EVENTFDPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_eventfdprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_eventfdprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvwakeprobe.o: userland/uvwakeprobe.c userland/compat/pthread.h userland/compat/sys/eventfd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVWAKEPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvwakeprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvwakeprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

# epollprobe links the node-compat epoll-over-poll emulation (node_compat.o),
# the same translation unit Node's libuv masquerade uses (NPM30).
$(BUILD)/n_node_compat.o: userland/node-compat/node_compat.c userland/node-compat/sys/epoll.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NODE_COMPAT_CFLAGS) $< -o $@

$(BUILD)/n_epollprobe.o: userland/epollprobe.c userland/node-compat/sys/epoll.h userland/compat/sys/eventfd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NODE_COMPAT_CFLAGS) $< -o $@

$(USER_EPOLLPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_epollprobe.o $(BUILD)/n_node_compat.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_epollprobe.o $(BUILD)/n_node_compat.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

# Node.js is cross-built out-of-band in Docker (it can't build in this Makefile's
# macOS host toolchain). This guard only fires when build/node.elf is absent: it
# never triggers the multi-hour Docker build implicitly, it just explains how.
$(USER_NODE_ELF):
	@test -f $@ || { echo "ERROR: $@ missing. Build Node for SwiftOS with:"; \
	  echo "  ./scripts/build-node-docker.sh   # build image + compile all objects"; \
	  echo "  docker run --rm -e NODE_VERSION=24.16.0 -v \$$(pwd):/src -w /src swiftos-nodebuild bash /src/scripts/link-node.sh"; \
	  echo "  cp build/node-docker-work/node-v24.16.0/out/Release/node.elf $@"; \
	  exit 1; }

$(BUILD)/n_uvsemprobe.o: userland/uvsemprobe.c userland/compat/pthread.h userland/compat/semaphore.h userland/compat/time.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVSEMPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvsemprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvsemprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvrwlockprobe.o: userland/uvrwlockprobe.c userland/compat/pthread.h userland/compat/semaphore.h userland/compat/time.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVRWLOCKPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvrwlockprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvrwlockprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvmutexprobe.o: userland/uvmutexprobe.c userland/compat/pthread.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVMUTEXPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvmutexprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvmutexprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvthreadnameprobe.o: userland/uvthreadnameprobe.c userland/compat/pthread.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVTHREADNAMEPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvthreadnameprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvthreadnameprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvthreadstackprobe.o: userland/uvthreadstackprobe.c userland/compat/pthread.h userland/compat/sys/resource.h userland/compat/unistd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVTHREADSTACKPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvthreadstackprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvthreadstackprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvkeyonceprobe.o: userland/uvkeyonceprobe.c userland/compat/pthread.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVKEYONCEPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvkeyonceprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvkeyonceprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvenvprobe.o: userland/uvenvprobe.c userland/compat/unistd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVENVPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvenvprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvenvprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_envchild.o: userland/envchild.c Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_ENVCHILD_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_envchild.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_envchild.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvbarrierprobe.o: userland/uvbarrierprobe.c userland/compat/pthread.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVBARRIERPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvbarrierprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvbarrierprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvcondprobe.o: userland/uvcondprobe.c userland/compat/pthread.h userland/compat/time.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVCONDPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvcondprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvcondprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvsocketpairprobe.o: userland/uvsocketpairprobe.c userland/compat/sys/socket.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVSOCKETPAIRPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvsocketpairprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvsocketpairprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvsignalprobe.o: userland/uvsignalprobe.c userland/compat/pthread.h userland/compat/signal.h userland/compat/unistd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVSIGNALPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvsignalprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvsignalprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvatforkprobe.o: userland/uvatforkprobe.c userland/compat/pthread.h userland/compat/unistd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVATFORKPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvatforkprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvatforkprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_uvspawnprobe.o: userland/uvspawnprobe.c userland/compat/pthread.h userland/compat/signal.h userland/compat/unistd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_UVSPAWNPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_uvspawnprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_uvspawnprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_signalprobe.o: userland/signalprobe.c userland/compat/signal.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_SIGNALPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_signalprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_signalprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_ptysigprobe.o: userland/ptysigprobe.c userland/compat/signal.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_PTYSIGPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_ptysigprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_ptysigprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

$(BUILD)/n_socketprobe.o: userland/socketprobe.c userland/compat/sys/socket.h userland/compat/unistd.h Makefile | $(BUILD)/.dir
	$(NEWLIB_GCC) $(NEWLIB_COMPAT_CFLAGS) $< -o $@

$(USER_SOCKETPROBE_ELF): $(BUILD)/n_crt0.o $(BUILD)/n_socketprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o userland/user_newlib.ld $(SYSROOT)/lib/libc.a Makefile
	$(NEWLIB_GCC) $(NEWLIB_LDFLAGS) $(BUILD)/n_crt0.o $(BUILD)/n_socketprobe.o $(BUILD)/n_syscalls.o $(BUILD)/n_compat_stubs.o $(NEWLIB_LIBS) -o $@

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

run: build $(QEMU_DTB) base-image $(DATA_IMG)
	$(QEMU) $(QEMU_FLAGS)

# Paused under the gdbstub on tcp::1234. Attach with `make gdb` in another shell.
debug: build $(QEMU_DTB) base-image $(DATA_IMG)
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

SSHKEY := $(BUILD)/sshkey
$(SSHKEY): tools/sshkey.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/sshkey.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

sshkey: $(SSHKEY)

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

# SU-B: the site-signing keypair (used by sitepack to sign SWSITE bundles; pub
# half baked into the image for /bin/swupdate to verify against).
$(SITE_SIGNING_PUB): | $(MODELSIGN) $(MODEL_DIR)
	$(MODELSIGN) keygen $(SITE_SIGNING_SEED) $@
$(SITE_SIGNING_SEED): $(SITE_SIGNING_PUB)

model: $(MODEL_BIN) $(MODEL_TOK) $(MODEL15_BIN) $(MODEL_TOK32) $(MODEL_Q8) $(MODEL15_Q8)

docs-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/docs_reference_test.swift -o $(BUILD)/docs_reference_test
	$(BUILD)/docs_reference_test
	$(MAKE) phase1-roadmap-test
	$(MAKE) api-complete-examples-test
	$(MAKE) examples-verification-test
	$(MAKE) stability-coverage-test

# QW6: pin the shared Errno table's exact raw values (they are syscall ABI).
errno-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/errno_test.swift kernel/errno.swift -o $(BUILD)/errno_test
	$(BUILD)/errno_test

# SC0: cubestore single-node MVCC KV store (watch + WAL/snapshot). Host test of
# the Foundation-free core plus the POSIX-file sink (cases 1-11). The core files
# stay Foundation-free; only the sink adapter and the test harness use Foundation.
CUBESTORE_CORE = \
	swiftcube/cubestore/Crc32.swift \
	swiftcube/cubestore/Model.swift \
	swiftcube/cubestore/ByteIO.swift \
	swiftcube/cubestore/MVCCIndex.swift \
	swiftcube/cubestore/StorageSink.swift \
	swiftcube/cubestore/WALCodec.swift \
	swiftcube/cubestore/SnapshotCodec.swift \
	swiftcube/cubestore/Watch.swift \
	swiftcube/cubestore/CubeStore.swift

# SwiftCube (SC0–SC9b) host-test aggregate. Every SC milestone ships a deterministic,
# Foundation-only-in-the-harness host acceptance test; this rolls all of them up so the
# whole orchestration layer is covered by one target and is part of `make test` (below),
# guarding the shared cubestore/control/scheduler cores against regressions.
.PHONY: swiftcube-test
swiftcube-test:
	$(MAKE) cubestore-test
	$(MAKE) raft-test
	$(MAKE) store-test
	$(MAKE) control-test
	$(MAKE) slet-test
	$(MAKE) scheduler-test
	$(MAKE) probe-test
	$(MAKE) endpoints-test
	$(MAKE) lb-test
	$(MAKE) proxy-test
	$(MAKE) volume-test
	$(MAKE) manifest-test
	$(MAKE) sctl-test
	$(MAKE) rollout-test
	@echo "swiftcube-test: all SC0–SC9b host acceptance suites passed"

cubestore-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) $(CUBESTORE_CORE) \
		swiftcube/cubestore/host/PosixFileSink.swift \
		swiftcube/cubestore/tests/cubestore_test.swift \
		-o $(BUILD)/cubestore_test
	$(BUILD)/cubestore_test

# SC1a: Raft consensus core (transport-agnostic, deterministic) over a simulated
# message bus, driving a trivial replicated state machine. The Raft core reuses
# cubestore's Foundation-free seams (Bytes/ByteIO/Crc32, AppendLog/SnapshotStore);
# only the simulator + test harness use Foundation. Covers cases 1,4-8,11.
.PHONY: raft-test store-test control-test slet-test scheduler-test probe-test endpoints-test lb-test proxy-test volume-test sc2-join-test
# Seams shared with cubestore (compiled once per test target to avoid duplicate
# symbols when both cores are linked together).
CUBESTORE_SEAMS = \
	swiftcube/cubestore/Crc32.swift \
	swiftcube/cubestore/Model.swift \
	swiftcube/cubestore/ByteIO.swift \
	swiftcube/cubestore/StorageSink.swift
RAFT_ONLY = \
	swiftcube/raft/RaftTypes.swift \
	swiftcube/raft/Random.swift \
	swiftcube/raft/StateMachine.swift \
	swiftcube/raft/RaftStorage.swift \
	swiftcube/raft/RaftNode.swift
RAFT_CORE = $(CUBESTORE_SEAMS) $(RAFT_ONLY)
raft-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) $(RAFT_CORE) \
		swiftcube/raft/tests/Simulator.swift \
		swiftcube/raft/tests/raft_test.swift \
		-o $(BUILD)/raft_test
	$(BUILD)/raft_test

# SC1b: cubestore wired in as the Raft replicated state machine — writes go
# through Raft (propose → commit → apply), compare-and-apply evaluated at apply,
# ReadIndex linearizable reads, talk-to-any forwarding. The committed Raft log is
# the durability log (cubestore's SC0 WAL retired; cubestore runs over a discard
# log here). Reuses the full cubestore core + the raft core + the simulator.
# Covers cases 2,3,9,10.
store-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) $(CUBESTORE_CORE) $(RAFT_ONLY) \
		swiftcube/store/WriteRequest.swift \
		swiftcube/store/CubeStateMachine.swift \
		swiftcube/raft/tests/Simulator.swift \
		swiftcube/store/tests/store_test.swift \
		-o $(BUILD)/store_test
	$(BUILD)/store_test

# SC2: node join over mTLS — bootstrap tokens, CA-signed identity, TTL leases, the
# leader-gated reaper, and the framed/resumable watch wire. Host acceptance (cases
# 1-7) runs the full control plane over a loopback transport carrying a REAL
# mutual-TLS handshake with an injected clock — no network, no wall clock. Reuses
# the cubestore core + the swift-os TLS 1.3 record/key-schedule primitives + the
# crypto modules (P-256/X25519/SHA-256/ChaCha20-Poly1305); the control plane is
# Foundation-free, only the harness uses Foundation.
CONTROL_CORE = \
	swiftcube/control/Identity.swift \
	swiftcube/control/Schema.swift \
	swiftcube/control/Node.swift \
	swiftcube/control/Token.swift \
	swiftcube/control/Lease.swift \
	swiftcube/control/RamStore.swift \
	swiftcube/control/Wire.swift \
	swiftcube/control/Rpc.swift \
	swiftcube/control/MutualTLS.swift \
	swiftcube/control/Channel.swift \
	swiftcube/control/Controller.swift \
	swiftcube/control/Agent.swift
CONTROL_TLS_DEPS = \
	userland/lib/tls13.swift userland/lib/asn1.swift userland/lib/x509.swift \
	userland/lib/x509_verify.swift userland/lib/rsa.swift \
	kernel/crypto/p256.swift kernel/crypto/sha256.swift \
	kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift
control-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) $(CONTROL_CORE) $(CONTROL_TLS_DEPS) \
		swiftcube/control/tests/control_test.swift \
		-o $(BUILD)/control_test
	$(BUILD)/control_test

# SC3: slet reconcile-loop host acceptance (cases 1–8). Links the cubestore core + the
# SC2 control plane (the reconciler watches/CAS-writes over the same Agent/Controller
# mTLS path used in case 8) + the SC3 Cell seam (interface + host fake + C6 stub) + the
# Ed25519/SHA-256/SHA-512 image-trust primitives. The reconcile loop is Foundation-free;
# only the harness uses Foundation. The on-device gate (case 9) is deferred — C6 is not
# implemented; see swiftcube/cell/C6Adapter.swift.
SC3_CELL_SRCS = \
	swiftcube/slet/probes/Probe.swift \
	swiftcube/slet/probes/ProbeRunner.swift \
	swiftcube/cell/CellSpec.swift \
	swiftcube/cell/CellSupervisor.swift \
	swiftcube/cell/ImageResolver.swift \
	swiftcube/cell/C6Adapter.swift \
	swiftcube/cell/FakeSupervisor.swift \
	swiftcube/slet/Assignment.swift \
	swiftcube/slet/StoreClient.swift \
	swiftcube/slet/Reconciler.swift
slet-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) $(CONTROL_CORE) $(CONTROL_TLS_DEPS) \
		kernel/crypto/ed25519.swift kernel/crypto/sha512.swift \
		$(SC3_CELL_SRCS) \
		swiftcube/slet/tests/slet_test.swift \
		-o $(BUILD)/slet_test
	$(BUILD)/slet_test

# SC4: the spread+fit scheduler — the pure schedule() function (filter → score/spread →
# fit → deterministic cellIds) plus the leader-gated reconcile loop that diffs its result
# against /assignments and applies the delta via CAS. Pure control-plane logic, no kernel:
# the host acceptance (cases 1–10) runs the loop against an in-process cubestore with an
# injected clock. Reuses the cubestore core + the SC2 node/lease schema (for healthy-node
# liveness) + the SC3 Cell spec/Assignment objects it produces. Foundation-free except the
# harness; only kernel/crypto/sha256.swift is linked to satisfy the Schema seam.
SC4_SCHED_SRCS = \
	swiftcube/control/Schema.swift \
	swiftcube/control/Node.swift \
	swiftcube/control/Lease.swift \
	swiftcube/control/RamStore.swift \
	swiftcube/slet/probes/Probe.swift \
	swiftcube/cell/CellSpec.swift \
	swiftcube/cell/CellSupervisor.swift \
	swiftcube/slet/Assignment.swift \
	swiftcube/slet/volume/Volume.swift \
	swiftcube/sctld/scheduler/Deployment.swift \
	swiftcube/sctld/scheduler/Schedule.swift \
	swiftcube/sctld/scheduler/SchedulerLoop.swift
scheduler-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) kernel/crypto/sha256.swift \
		$(SC4_SCHED_SRCS) \
		swiftcube/sctld/scheduler/tests/scheduler_test.swift \
		-o $(BUILD)/scheduler_test
	$(BUILD)/scheduler_test

# SC5a: the probe runner — readiness/liveness state machine (thresholds, initialDelay,
# timeout-as-failure) wired into the reconcile loop (readiness→status.ready, liveness→
# restart). Host acceptance (cases 1–6, 9) drives the reconciler with a FakeProber + the
# SC3 FakeCellSupervisor and an injected clock — no kernel, no network, no wall clock.
# Reuses the cubestore core + the SC2 control plane (store client/CAS) + the SC3 Cell seam
# + the SC5 probe sources + the Ed25519/SHA-256/SHA-512 image-trust primitives. The probe
# loop is Foundation-free; only the harness uses Foundation. The on-device gate (a Cell
# becoming ready via an http probe over virtio-net) is deferred — C6 is not implemented.
# Probe.swift + ProbeRunner.swift come in via $(SC3_CELL_SRCS) (CellSpec references ProbeSpec;
# Reconciler holds a ProbeRunner), so only the test-only FakeProber is added here — listing
# the others twice would duplicate symbols.
SC5_PROBE_SRCS = \
	swiftcube/slet/probes/FakeProber.swift
probe-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) $(CONTROL_CORE) $(CONTROL_TLS_DEPS) \
		kernel/crypto/ed25519.swift kernel/crypto/sha512.swift \
		$(SC3_CELL_SRCS) $(SC5_PROBE_SRCS) \
		swiftcube/slet/probes/tests/probe_test.swift \
		-o $(BUILD)/probe_test
	$(BUILD)/probe_test

# SC5b: the endpoints loop — leader-gated, level-triggered, ready-only. Host acceptance
# (cases 1/2, 7, 8, 10) drives the loop against an in-process cubestore with synthetic Cell
# statuses (as slet reports them) and checks the deterministic sorted /endpoints/<service>
# output, leader-only writes, no-churn convergence, and ready→endpoint add/remove. Reuses
# the cubestore core + the RAM store + the SC3 status/Cell objects + the SC5 probe spec
# (CellSpec decode references it) + the SC5 endpoints sources. Only kernel/crypto/sha256 is
# linked to satisfy the Schema seam transitively. Foundation only in the harness.
SC5_ENDPOINTS_SRCS = \
	swiftcube/control/RamStore.swift \
	swiftcube/slet/probes/Probe.swift \
	swiftcube/cell/CellSpec.swift \
	swiftcube/cell/CellSupervisor.swift \
	swiftcube/slet/Assignment.swift \
	swiftcube/sctld/endpoints/Endpoint.swift \
	swiftcube/sctld/endpoints/EndpointsLoop.swift
endpoints-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) \
		$(SC5_ENDPOINTS_SRCS) \
		swiftcube/sctld/endpoints/tests/endpoints_test.swift \
		-o $(BUILD)/endpoints_test
	$(BUILD)/endpoints_test

# SC6: the LB provider interface + the nginx provider (pure renderer + validate→swap→reload
# applier) + the leader-gated, debounced, level-triggered LB programmer loop. Host acceptance
# (cases 1–10) drives the loop and the provider against an in-process cubestore with an injected
# clock: a FakeApplier models validate-before-swap + atomic-swap (so the provider is tested with
# no real nginx in CI), a FakeProvider counts reconciles (so the loop's leader gate / debounce /
# backoff are tested independent of rendering). Reuses the cubestore core + the SC2 clock seam +
# the SC5 endpoints object (the backend pool). The renderer/provider/loop are Foundation-free;
# only the NginxApplier seam (shells out to a local nginx) and the harness use Foundation. The
# on-device gate (program a real nginx, curl through the listener to a Cell) is conditional on a
# ported nginx + real Cells (C6) — deferred, not claimed. Only kernel/crypto/sha256.swift is
# linked to satisfy the Schema clock seam transitively.
SC6_LB_SRCS = \
	swiftcube/control/Schema.swift \
	swiftcube/control/RamStore.swift \
	swiftcube/sctld/endpoints/Endpoint.swift \
	swiftcube/sctld/lb/LBProvider.swift \
	swiftcube/sctld/lb/ExposeConfig.swift \
	swiftcube/sctld/lb/LBLoop.swift \
	swiftcube/sctld/lb/nginx/NginxRenderer.swift \
	swiftcube/sctld/lb/nginx/ConfigApplier.swift \
	swiftcube/sctld/lb/nginx/NginxProvider.swift \
	swiftcube/sctld/lb/nginx/NginxApplier.swift
lb-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) kernel/crypto/sha256.swift \
		$(SC6_LB_SRCS) \
		swiftcube/sctld/lb/tests/lb_test.swift \
		-o $(BUILD)/lb_test
	$(BUILD)/lb_test

# SC7: the east-west service registry + userspace node-proxy. Host acceptance (cases 1–9) drives
# the real SC7 control logic against an in-process cubestore: the SC5 endpoints loop + the SC7
# service reconciler populate /endpoints + /services, a Resolver turns a name into the node-local
# proxy address, and a NodeProxy load-balances accepted connections across the ready endpoints over
# an in-memory ProxyTransport (FakeTransport + fake backend servers — so bytes flow end-to-end with
# no kernel and no real sockets, the FakeProber/FakeApplier pattern). Reuses the cubestore core +
# the SC2 control plane (the StoreClient/LocalStoreClient read seam pulls AgentStoreClient, so the
# TLS/crypto deps are linked as in slet-test) + the SC3 Cell status object + the SC5 endpoints
# object/loop + the SC7 service/proxy/resolver sources. The proxy/reconciler/resolver are
# Foundation-free; only the harness uses Foundation. The on-device gate (two real Cells, A connects
# to B by service name over virtio-net) is conditional on C6 + real Cells — deferred, not claimed;
# the real transport (NetProxyTransport over swiftos sockets) compiles into the slet ELF.
SC7_SVC_SRCS = \
	swiftcube/sctld/endpoints/Endpoint.swift \
	swiftcube/sctld/endpoints/EndpointsLoop.swift \
	swiftcube/sctld/services/Service.swift \
	swiftcube/sctld/services/ServiceReconciler.swift \
	swiftcube/slet/proxy/ProxyTransport.swift \
	swiftcube/slet/proxy/Balancer.swift \
	swiftcube/slet/proxy/NodeProxy.swift \
	swiftcube/slet/resolver/Resolver.swift
proxy-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) $(CONTROL_CORE) $(CONTROL_TLS_DEPS) \
		kernel/crypto/ed25519.swift kernel/crypto/sha512.swift \
		$(SC3_CELL_SRCS) $(SC7_SVC_SRCS) \
		swiftcube/slet/proxy/tests/proxy_test.swift \
		-o $(BUILD)/proxy_test
	$(BUILD)/proxy_test

# SC8: node-local sticky persistent volumes on datafs + single-writer fencing. Host
# acceptance (cases 1–8) drives the REAL SC8 logic against an in-process cubestore with a
# HostDirVolumeStore (a host directory standing in for datafs, honest POSIX fsync) and an
# injected clock: the VolumeManager provisions/binds/mounts/fences PVs and bumps the fencing
# token, the leader-gated scheduler PINS each stateful ordinal to its bound node (Pending when
# that node is down), and the SC3 reconcile loop + FakeCellSupervisor exercise the single-mount
# gate end to end. Reuses the cubestore core + the SC2 control plane (the StoreClient read seam
# pulls AgentStoreClient, so the TLS/crypto deps are linked as in slet-test) + the SC3 Cell seam
# + the SC4 scheduler + the SC8 volume sources. The volume logic is Foundation-free; only the
# HostDirVolumeStore (host datafs fake) and the harness use Foundation. The on-device datafs
# binding (DatafsVolumeStore) compiles into the slet ELF; the QEMU gate (a real stateful Cell
# writes /data, restarts, data survives, stays pinned) is conditional on datafs + C6 — deferred.
# SC4 scheduler sources are listed here (NOT via a shared var) joined with the SC3 Cell seam,
# de-duplicated against the cubestore/control cores; DatafsVolumeStore is on-device only.
SC8_VOLUME_SRCS = \
	swiftcube/slet/volume/Volume.swift \
	swiftcube/slet/volume/VolumeStore.swift \
	swiftcube/slet/volume/VolumeManager.swift \
	swiftcube/slet/volume/host/HostDirVolumeStore.swift
# Scheduler core only — Node/Lease/Schema/RamStore come from CONTROL_CORE and the Cell
# objects (CellSpec/Assignment/Probe) from SC3_CELL_SRCS, so listing them again would
# duplicate symbols. Volume.swift comes from SC8_VOLUME_SRCS.
SC8_SCHED_SRCS = \
	swiftcube/sctld/scheduler/Deployment.swift \
	swiftcube/sctld/scheduler/Schedule.swift \
	swiftcube/sctld/scheduler/SchedulerLoop.swift
volume-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) $(CONTROL_CORE) $(CONTROL_TLS_DEPS) \
		kernel/crypto/ed25519.swift kernel/crypto/sha512.swift \
		$(SC3_CELL_SRCS) $(SC8_SCHED_SRCS) $(SC8_VOLUME_SRCS) \
		swiftcube/slet/volume/tests/volume_test.swift \
		-o $(BUILD)/volume_test
	$(BUILD)/volume_test

# SC9a: the manifest parser/validator + its mapping onto cubestore objects. Host acceptance
# (case 1) golden-parses a §10 manifest into the typed `Manifest`, checks the mapping onto
# DeploymentSpec/ServiceExpose/ServiceSpec, and rejects malformed manifests with clear errors.
# The parser/validator (Yaml/Manifest/ManifestParser) is Foundation-free — `sctld` links the
# same sources to re-validate a submitted manifest — and depends only on the cubestore ByteIO
# core plus the typed objects it produces (Probe/CellSpec/Assignment/Volume/Deployment/Endpoint/
# LBProvider/ExposeConfig/Service). Only the harness uses Foundation.
.PHONY: manifest-test sctl-test sctl
MANIFEST_SRCS = \
	swiftcube/slet/probes/Probe.swift \
	swiftcube/cell/CellSpec.swift \
	swiftcube/cell/CellSupervisor.swift \
	swiftcube/slet/Assignment.swift \
	swiftcube/slet/volume/Volume.swift \
	swiftcube/sctld/scheduler/Deployment.swift \
	swiftcube/sctld/endpoints/Endpoint.swift \
	swiftcube/sctld/lb/LBProvider.swift \
	swiftcube/sctld/lb/ExposeConfig.swift \
	swiftcube/sctld/services/Service.swift \
	swiftcube/manifest/Yaml.swift \
	swiftcube/manifest/Manifest.swift \
	swiftcube/manifest/ManifestParser.swift
manifest-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) \
		$(MANIFEST_SRCS) \
		swiftcube/manifest/tests/manifest_test.swift \
		-o $(BUILD)/manifest_test
	$(BUILD)/manifest_test

# SC9a: the `sctl` CLI command layer + the control-client transport seam. Host acceptance
# (case 2) drives apply/get/describe/scale/delete + `rollout status` through the dispatcher over
# a StoreControlClient backed by an in-process cubestore (the milestone's "fake control client"),
# proving the round-trip: apply upserts objects and bumps the revision on a template change,
# keeps it on a pure scale; get/scale/delete behave. The command layer + manifest are
# Foundation-free; only the harness (and the host `sctl` main) use Foundation. The real
# over-the-wire mTLS transport (WireControlClient) lands with the SC9b multi-node QEMU harness.
SCTL_SRCS = \
	$(MANIFEST_SRCS) \
	swiftcube/control/Schema.swift \
	swiftcube/control/Node.swift \
	swiftcube/control/RamStore.swift \
	swiftcube/sctld/rollout/Rollout.swift \
	swiftcube/sctl/ControlClient.swift \
	swiftcube/sctl/StoreControlClient.swift \
	swiftcube/sctl/Config.swift \
	swiftcube/sctl/Command.swift
sctl-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) kernel/crypto/sha256.swift \
		$(SCTL_SRCS) \
		swiftcube/sctl/tests/sctl_test.swift \
		-o $(BUILD)/sctl_test
	$(BUILD)/sctl_test

# SC9b: the leader-gated rollout state machine — the pure stepper (rolling/blue-green/canary +
# automatic rollback) and the level-triggered controller that drives per-revision desired counts
# (/schedrev, placed by the reused SC4 scheduler), traffic weights (/traffic), and status/history
# (/rollouts). Host acceptance (cases 3–9 + a real-scheduler integration check) drives the
# controller against an in-process cubestore with an injected clock and a simulated cluster (the
# /status/cells readiness signal). Reuses the cubestore core + the SC2 node/lease schema + the SC3
# Cell objects + the SC4 scheduler. The rollout logic is Foundation-free; only the harness uses
# Foundation; only kernel/crypto/sha256.swift is linked to satisfy the Schema seam.
.PHONY: rollout-test
ROLLOUT_SRCS = \
	swiftcube/control/Schema.swift \
	swiftcube/control/Node.swift \
	swiftcube/control/Lease.swift \
	swiftcube/control/RamStore.swift \
	swiftcube/slet/probes/Probe.swift \
	swiftcube/cell/CellSpec.swift \
	swiftcube/cell/CellSupervisor.swift \
	swiftcube/slet/Assignment.swift \
	swiftcube/slet/volume/Volume.swift \
	swiftcube/sctld/scheduler/Deployment.swift \
	swiftcube/sctld/scheduler/Schedule.swift \
	swiftcube/sctld/scheduler/SchedulerLoop.swift \
	swiftcube/sctld/rollout/Rollout.swift \
	swiftcube/sctld/rollout/RolloutPlan.swift \
	swiftcube/sctld/rollout/RolloutController.swift
rollout-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) kernel/crypto/sha256.swift \
		$(ROLLOUT_SRCS) \
		swiftcube/sctld/rollout/tests/rollout_test.swift \
		-o $(BUILD)/rollout_test
	$(BUILD)/rollout_test

# SC9a: build the host `sctl` binary (Mac/Linux). The command layer + manifest parser are the
# Foundation-free SCTL_SRCS; main.swift + Config.swift + the POSIX cubestore sink are the host
# shell. Single-node today via `sctl --local <statedir> <command>`; the remote mTLS transport is
# the SC9b seam.
sctl: | $(BUILD)/.dir
	$(HOST_SWIFTC) -O $(CUBESTORE_CORE) kernel/crypto/sha256.swift \
		swiftcube/cubestore/host/PosixFileSink.swift \
		$(SCTL_SRCS) \
		swiftcube/sctl/main.swift \
		-o $(BUILD)/sctl
	@echo "built $(BUILD)/sctl"

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

# Aggressive host unit tests for the EL0 trust boundary: the ELF loader's reject
# paths (malformed/hostile binaries, integer-overflow phoff/offset/memsz) and the
# copyin/copyout guards (kernel/unmapped/overflow/straddling user ranges). Both
# link the real kernel source against fake address-space/PMM bridges, no QEMU.
elf-loader-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/elf_loader_test.swift kernel/user/elf.swift -o $(BUILD)/elf_loader_test
	$(BUILD)/elf_loader_test

user-access-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/user_access_test.swift kernel/user/user_access.swift -o $(BUILD)/user_access_test
	$(BUILD)/user_access_test

# QW7: host unit test for the VirtioTransportOps abstraction. Compiles only the
# protocol + extension (which reference no mmio_*/PCI), drives an in-memory fake
# transport through a generic bring-up — proving the host-test double the protocol
# now enables. No QEMU.
virtio-transport-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/virtio_transport_test.swift kernel/drivers/virtio_transport_ops.swift -o $(BUILD)/virtio_transport_test
	$(BUILD)/virtio_transport_test

stability-coverage-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/stability_coverage_test.swift -o $(BUILD)/stability_coverage_test
	$(BUILD)/stability_coverage_test

# LA3 shared-memory ring: the host unit test for the sans-IO core, then the
# in-QEMU full-duplex round-trip at -smp 4 (parent/child over mapped pages).
shmring-test: build $(QEMU_DTB_SMP4) disk base-image | $(BUILD)/.dir
	$(HOST_SWIFTC) -D SHMRING_HOST tests/shmring_test.swift kernel/ipc/shmring.swift -o $(BUILD)/shmring_test
	$(BUILD)/shmring_test
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/shmring_test.sh

test: docs-test build $(QEMU_DTB) $(QEMU_DTB_SMP4) disk base-image package-fixture package-local-install-fixture $(SWPKG) $(UPDATESTORE) $(MODEL_BIN) $(MODEL_TOK) $(MODEL_Q8) $(MODEL15_Q8)
	$(HOST_SWIFTC) tests/page_allocator_test.swift kernel/mm/page_allocator.swift -o $(BUILD)/page_allocator_test
	$(BUILD)/page_allocator_test
	$(MAKE) page-allocator-refcount-lifecycle-test
	$(HOST_SWIFTC) tests/base_image_test.swift kernel/crypto/sha256.swift -o $(BUILD)/base_image_test
	$(BUILD)/base_image_test $(BASE_IMG)
	$(HOST_SWIFTC) tests/updatestore_test.swift kernel/fs/swosboot.swift -o $(BUILD)/updatestore_test
	$(BUILD)/updatestore_test
	$(MAKE) syspack-test
	$(CLANG) -O2 -Wall -Wextra tests/loader_sha256_test.c -o $(BUILD)/loader_sha256_test
	$(BUILD)/loader_sha256_test
	$(CLANG) -O2 -Wall -Wextra tests/loader_ed25519_test.c -o $(BUILD)/loader_ed25519_test
	$(BUILD)/loader_ed25519_test
	$(HOST_SWIFTC) tests/swpkg_tool_test.swift -o $(BUILD)/swpkg_tool_test
	$(BUILD)/swpkg_tool_test
	$(HOST_SWIFTC) tests/swpkg_header_integrity_test.swift -o $(BUILD)/swpkg_header_integrity_test
	$(BUILD)/swpkg_header_integrity_test
	$(MAKE) sitepack-test
	$(HOST_SWIFTC) tests/swsite_test.swift userland/lib/swsite.swift -o $(BUILD)/swsite_test
	$(BUILD)/swsite_test
	$(HOST_SWIFTC) tests/pkgstore_tool_test.swift -o $(BUILD)/pkgstore_tool_test
	$(BUILD)/pkgstore_tool_test
	$(HOST_SWIFTC) tests/pkgrepo_tool_test.swift -o $(BUILD)/pkgrepo_tool_test
	$(BUILD)/pkgrepo_tool_test
	$(HOST_SWIFTC) tests/fdt_test.swift kernel/arch/aarch64/fdt.swift -o $(BUILD)/fdt_test
	$(BUILD)/fdt_test $(QEMU_DTB) 1
	$(BUILD)/fdt_test $(QEMU_DTB_SMP4) 4
	FDT_TEST=$(BUILD)/fdt_test ./tests/smp_s1_preflight_test.sh
	FDT_TEST=$(BUILD)/fdt_test ./tests/qemu_virt_hardware_map_test.sh
	$(HOST_SWIFTC) tests/net_test.swift kernel/net/packet.swift kernel/net/ethernet.swift kernel/net/arp.swift kernel/net/ipv4.swift kernel/net/ipv6.swift kernel/net/icmp.swift kernel/net/icmp6.swift kernel/net/udp.swift kernel/net/dhcp.swift kernel/net/tcp.swift kernel/net/dns.swift kernel/net/stack.swift -o $(BUILD)/net_test
	$(BUILD)/net_test
	$(HOST_SWIFTC) -D SHMRING_HOST tests/shmring_test.swift kernel/ipc/shmring.swift -o $(BUILD)/shmring_test
	$(BUILD)/shmring_test
	$(HOST_SWIFTC) tests/crypto_test.swift kernel/crypto/chacha20poly1305.swift -o $(BUILD)/crypto_test
	$(BUILD)/crypto_test
	$(HOST_SWIFTC) tests/handle_test.swift kernel/vfs/handle.swift -o $(BUILD)/handle_test
	$(BUILD)/handle_test
	$(MAKE) virtio-transport-test
	$(MAKE) swiftcube-test
	$(HOST_SWIFTC) tests/elf_loader_test.swift kernel/user/elf.swift -o $(BUILD)/elf_loader_test
	$(BUILD)/elf_loader_test
	$(HOST_SWIFTC) tests/user_access_test.swift kernel/user/user_access.swift -o $(BUILD)/user_access_test
	$(BUILD)/user_access_test
	$(HOST_SWIFTC) tests/errno_test.swift kernel/errno.swift -o $(BUILD)/errno_test
	$(BUILD)/errno_test
	./tests/smp_mailbox_layout_test.sh
	./tests/smp_release_guard_test.sh
	./tests/smp_state_audit_test.sh
	$(HOST_SWIFTC) tests/hkdf_test.swift kernel/crypto/sha256.swift -o $(BUILD)/hkdf_test
	$(BUILD)/hkdf_test
	$(HOST_SWIFTC) tests/identity_test.swift userland/lib/swos_identity.swift kernel/crypto/sha256.swift -o $(BUILD)/identity_test
	$(BUILD)/identity_test
	$(HOST_SWIFTC) tests/x25519_test.swift kernel/crypto/x25519.swift -o $(BUILD)/x25519_test
	$(BUILD)/x25519_test
	$(HOST_SWIFTC) tests/tls_handshake_test.swift userland/lib/tls13.swift userland/lib/x509.swift userland/lib/x509_verify.swift userland/lib/rsa.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift -o $(BUILD)/tls_handshake_test
	$(BUILD)/tls_handshake_test
	$(HOST_SWIFTC) tests/llm_engine_test.swift userland/lib/llama2.swift -o $(BUILD)/llm_engine_test
	$(BUILD)/llm_engine_test
	$(HOST_SWIFTC) -O tests/llm_q8_engine_test.swift userland/lib/llama2.swift -o $(BUILD)/llm_q8_engine_test
	$(BUILD)/llm_q8_engine_test
	$(HOST_SWIFTC) tests/llm_bundle_test.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift -o $(BUILD)/llm_bundle_test
	$(BUILD)/llm_bundle_test
	$(HOST_SWIFTC) -O tests/ed25519_test.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $(BUILD)/ed25519_test
	$(BUILD)/ed25519_test
	$(HOST_SWIFTC) -O tests/p256_test.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift -o $(BUILD)/p256_test
	$(BUILD)/p256_test
	$(HOST_SWIFTC) -O tests/jose_test.swift userland/lib/jose.swift userland/lib/asn1.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift -o $(BUILD)/jose_test
	$(BUILD)/jose_test
	$(HOST_SWIFTC) -O tests/acme_test.swift userland/lib/acme.swift userland/lib/jose.swift userland/lib/asn1.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift -o $(BUILD)/acme_test
	$(BUILD)/acme_test
	$(HOST_SWIFTC) -O tests/x509_test.swift userland/lib/x509.swift -o $(BUILD)/x509_test
	$(BUILD)/x509_test
	$(HOST_SWIFTC) -O tests/rsa_test.swift userland/lib/rsa.swift kernel/crypto/sha256.swift -o $(BUILD)/rsa_test
	$(BUILD)/rsa_test
	$(HOST_SWIFTC) -O tests/x509_verify_test.swift userland/lib/x509.swift userland/lib/x509_verify.swift userland/lib/rsa.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift -o $(BUILD)/x509_verify_test
	$(BUILD)/x509_verify_test
	$(HOST_SWIFTC) -O tests/x509_chain_test.swift userland/lib/x509.swift userland/lib/x509_verify.swift userland/lib/rsa.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift -o $(BUILD)/x509_chain_test
	$(BUILD)/x509_chain_test
	./tests/tls_verify_test.sh
	./tests/tls_truststore_test.sh
	./tests/userland_elf_test.sh
	./tests/boot_test.sh
	./tests/log_export_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_boot_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/s4_resource_stress_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_resource_stress_test.sh
	SMP_CPUS=1 SMP_DTB=$(QEMU_DTB) ./tests/saturation_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_race_stress_test.sh
	SMP_CPUS=1 SMP_DTB=$(QEMU_DTB) ./tests/edge_stress_test.sh
	./tests/spawn_self_exec_test.sh
	bash ./tests/cow_test.sh
	./tests/tty_test.sh
	./tests/virtio_blk_test.sh
	./tests/virtio_net_test.sh
	./tests/netinfo_test.sh
	# IPv6 (net-ipv6 slice): host net_test covers the protocol core aggressively
	# (NDP, RA, EH chains, DAD, malformed packets). QEMU smoke tests verify
	# link-local/NDP setup; Darwin QEMU currently skips true IPv6 hostfwd echo.
	./tests/ipv6_smoke_test.sh
	./tests/net_static_ipv6_test.sh
	./tests/ipv6_udp_echo_test.sh
	./tests/ipv6_tcp_echo_test.sh
	./tests/udp_echo_test.sh
	./tests/ipc_socket_transfer_test.sh
	./tests/qw5_rights_intersection_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/ipc_call_test.sh
	./tests/qw4_badge_test.sh
	./tests/tcp_echo_test.sh
	./tests/tcp_connect_test.sh
	./tests/tls_test.sh
	./tests/httpd_test.sh
	./tests/httpd_load_test.sh
	./tests/ssh_transport_test.sh
	./tests/ssh_runtime_entropy_test.sh
	./tests/sshd_transport_test.sh
	./tests/sshd_sftp_test.sh
	./tests/sshd_sftp_write_test.sh
	./tests/sshd_runtime_entropy_test.sh
	./tests/sshd_ipv6_listener_test.sh
	./tests/sshd_ipv6_supervision_test.sh
	./tests/sshd_deploy_preflight_test.sh
	./tests/hetzner_deploy_bundle_test.sh
	bash ./tests/net_zero_copy_throughput_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/shmring_test.sh
	./tests/dns_test.sh
	./tests/vfs_disk_test.sh
	./tests/disk_exec_test.sh
	./tests/gicv3_test.sh
	./tests/virtio_pci_test.sh
	./tests/h3_ramdisk_test.sh
	./tests/h4_ssh_pci_test.sh
	./tests/h5_acpi_test.sh
	./tests/data_persist_test.sh
	./tests/datafs_test.sh
	./tests/datafs_fsync_test.sh
	./tests/datafs_sqlite_test.sh
	./tests/nginx_test.sh
	./tests/nginx_data_test.sh
	./tests/nginx_tls_test.sh
	rm -f $(BASE_IMG); $(MAKE) base-image INCLUDE_NCURSES=1 INCLUDE_GLIB=1 INCLUDE_MC=1 INCLUDE_BASH=1 INCLUDE_ZSH=1
	./tests/ncurses_test.sh
	./tests/glib_test.sh
	./tests/mc_test.sh
	./tests/bash_test.sh
	./tests/zsh_test.sh
	rm -f $(BASE_IMG); $(MAKE) base-image
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
	$(MAKE) os-stage-test
	$(MAKE) os-update-test
	$(MAKE) os-confirm-test
	./tests/ab_flush_test.sh
	./tests/console_login_test.sh
	./tests/cap_enforce_test.sh
	./tests/sudo_test.sh
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
	./tests/largemmap_test.sh
	./tests/mmapreserve_test.sh
	./tests/sleep_test.sh
	./tests/crond_test.sh
	./tests/calc_test.sh
	./tests/kv_test.sh
	./tests/llm_run_test.sh
	./tests/llm_serve_test.sh
	./tests/simdprobe_test.sh
	$(MAKE) model-image-test
	$(MAKE) model-mount-test
	$(MAKE) llm-serve-disk-test
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/top_test.sh
	$(MAKE) c5-test
	$(MAKE) device-mmio-map-test
	$(MAKE) c5-mmio-grant-test
	$(MAKE) c5-userland-driver-test
	$(MAKE) c5-tty-inject-test
	$(MAKE) ns1-net-grant-test
	$(MAKE) ns2-net-driver-test
	$(MAKE) ns3-net-service-test
	$(MAKE) procmax-test
	$(MAKE) c6-cell-accounting-test
	$(MAKE) c6-cell-create-test
	$(MAKE) c6-cell-namespace-test
	$(MAKE) c6-cell-lifecycle-test
	$(MAKE) c6-cell-service-test
	$(MAKE) c7-cell-pagecap-test
	$(MAKE) c7-cell-handlecap-test
	$(MAKE) c7-cell-supervisor-test
	$(MAKE) c7-cell-realservice-test
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
	$(MAKE) os-coordinate-test
	$(MAKE) os-coordinate-activate-test
	$(MAKE) uefi-kinstall-test
	$(MAKE) uefi-os-install-test
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

log-export-test: build $(QEMU_DTB) base-image
	./tests/log_export_test.sh

smp-test: build base-image
	./tests/smp_boot_test.sh

# QW3: orphan-zombie reaper acceptance. Boots the kernel and waits for the
# in-kernel orphan-reap self-test's OK marker; runs at -smp 1 and -smp 4 because
# reparent/reap is SMP-sensitive shared-table state.
orphan-reap-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	SINGLE_DTB=$(QEMU_DTB) SMP_DTB=$(QEMU_DTB_SMP4) ./tests/orphan_reap_test.sh

# QW2: blocking IPC park/wake acceptance. The receiver calls ipc_recv on an
# empty endpoint and must park (not busy-spin) until ipc_send wakes it. The
# EOF wake (last sender closes) is also tested. Runs at -smp 4 so a lost
# cross-CPU wakeup causes the child to hang and the await to time out.
qw2-blocking-ipc-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/qw2_blocking_ipc_test.sh

# QW1: synchronous request/reply IPC over a transient kernel reply port
# (ipc_call / ipc_reply_recv). A server child runs the one-syscall-per-request hot
# loop; the parent issues several ipc_calls and asserts each reply correlates to
# its request, that a handle round-trips both ways, and that bogus tokens / dead
# servers fail (EINVAL/EPIPE) instead of hanging. Runs at -smp 4 so a lost
# cross-CPU wakeup (caller parked on a reply port) times out.
ipc-call-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/ipc_call_test.sh

# QW5: rights = held ∩ requested on IPC handle transfer. A parent moves a
# /dev/zero handle (READ|WRITE|TRANSFER) over an endpoint requesting only
# READ|TRANSFER; the child proves read still works, write is denied (WRITE was
# attenuated away), and the parent's source fd was invalidated (move semantics).
qw5-rights-intersection-test: build $(QEMU_DTB) base-image
	./tests/qw5_rights_intersection_test.sh

clock-test: build $(QEMU_DTB) base-image
	./tests/clock_test.sh

# H1: GICv3 driver — detect GICv2 vs v3 and drive the GICv3 redistributor +
# ICC_* system-register CPU interface. Boots on `-M virt,gic-version=3` (the
# interrupt controller the Hetzner ARM VM presents) and proves interrupts are
# live multi-core: CPU0 + secondary timer IRQs and SGI/IPI delivery. The QEMU
# `virt` GICv2 profile is unchanged (the driver detects, it does not replace).
# No base image needed — the markers are emitted during SMP bring-up.
gicv3-test: build $(QEMU_DTB_GICV3)
	./tests/gicv3_test.sh

# H2: PCIe ECAM enumeration + virtio-PCI transport. Boots on `-M virt,gic-version=3`
# with a virtio-rng attached over PCIe (the transport the Hetzner VM uses) and
# proves the kernel enumerates the ECAM, assigns BARs, resolves the modern virtio
# capabilities, and exchanges a virtqueue (entropy round trip). No base image
# needed — the marker is emitted during early driver bring-up.
virtio-pci-test: build $(QEMU_DTB_GICV3)
	./tests/virtio_pci_test.sh

# H3: boot to login from a RAM base image with NO block driver bound. Boots the
# GPT disk under UEFI on the Hetzner profile (GICv3, boot disk on virtio-scsi-pci
# which the kernel does not drive); the loader reads base.img from the ESP into
# RAM and the kernel mounts the read-only base FS from RAM. Needs the full base
# image, so it depends on `disk` (which builds base-image + the GPT).
h3-ramdisk-test: disk
	./tests/h3_ramdisk_test.sh

# H4: a bounded SSH command succeeds end-to-end over virtio-net on the PCI
# transport. Boots GICv3 with the NIC + RNG on PCIe (the Hetzner network/IRQ
# model), the guest gets a DHCP lease over virtio-net-pci, autostarts /bin/sshd,
# and a host OpenSSH client runs /bin/id over the network (QEMU hostfwd).
h4-ssh-pci-test: build base-image $(SSHKEY)
	./tests/h4_ssh_pci_test.sh

# H5: the kernel derives its platform map (GIC/ECAM/UART/CPU/PSCI) from ACPI with
# no device tree. Boots the GPT disk under UEFI on the Hetzner device model (ACPI
# firmware, GICv3, virtio-PCI); the loader forwards the RSDP and the kernel walks
# RSDP->XSDT->MADT/MCFG/SPCR/FADT, then the whole stack comes up on those values.
h5-acpi-test: disk
	./tests/h5_acpi_test.sh

# H6: bare-metal cloud-deploy regression (Hetzner Cloud bring-up). Boots the
# UEFI/GPT disk on the real device model — virtio devices BEHIND PCIe root ports
# (only the GPU on bus 0), a virtio-gpu scanout console, GICv3, -smp 2, and
# serial OUTPUT-ONLY (no serial input) — and proves a headless server reaches a
# PERSISTENT SSH login. Builds the disk with supervised sshd first. Guards the
# four bring-up bugs: per-AS PCI MMU map, PCIe bridge recursion, virtio-gpu
# console, and headless boot to swos-init/sshd.
hetzner-deploy-test: build $(SSHKEY)
	rm -f $(BASE_IMG) $(DISK_IMG)
	$(MAKE) disk SWOS_SERVICES_FILE=fixtures/swos/services-supervised
	./tests/hetzner_deploy_test.sh
	rm -f $(BASE_IMG) $(DISK_IMG)   # restore: the supervised base.img is deploy-specific, not the default

# D0: persistent /data disk survives reboot. Base-image optional (the D0 marker
# is emitted before vfsInit), so this focused gate runs without the full image.
data-persist-test: build $(QEMU_DTB)
	./tests/data_persist_test.sh

# CR1: native Swift /bin/crond. Boots with the base image + a writable /data
# disk, then drives a test crontab to prove @reboot fires once, @every fires
# repeatedly, and jobs run via /bin/sh -c (durable append to /data).
crond-test: build $(QEMU_DTB) base-image
	./tests/crond_test.sh

# OS-3b: streamed staging of a base image into the inactive A/B slot via the
# capability-gated kernel syscalls (begin/write/commit), with monotonic
# anti-rollback. Forces a base rebuild carrying the signed SWOSBASE fixture.
os-stage-test: build $(QEMU_DTB) updatestore $(TEST_BASE_IMG)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_OS_STAGE_TEST=1
	./tests/os_stage_test.sh

# OS-4: reflash-free OS update over HTTPS. swupdate fetches a signed SWSYS bundle
# from a host TLS server (slirp 10.0.2.2), verifies it, and stages the base image
# into the inactive slot + activates it; anti-rollback + bad-signature rejected.
# Needs python3 + openssl (SKIPs without them). base-image carries os-root.pub.
os-update-test: build $(QEMU_DTB) base-image updatestore $(SYSPACK) $(TEST_BASE_IMG) $(BUILD)/kernel-slot.bin
	./tests/os_update_test.sh

# OS-5: health-confirm + anti-rollback floor bump. swupdate confirm marks the
# booted slot healthy and raises the floor to its version; --auto gates on
# sshd+nginx being up. Needs the SWOSBASE fixture baked (INCLUDE_OS_STAGE_TEST=1).
os-confirm-test: build $(QEMU_DTB) updatestore $(TEST_BASE_IMG)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_OS_STAGE_TEST=1
	./tests/os_confirm_test.sh

# OS-1: the single coordinated A/B selector — the only topology where BOTH A/B
# mechanisms coexist (UEFI kernel A/B on the ESP + a SWOSBOOT store as the base
# disk). The kernel puts the base on the slot the loader booted (ESP
# kernel-state.lastBooted), so kernel + base never drift. Boots under AAVMF; SKIPs
# without the firmware. Needs the ESP staging (uefi), base image, store + kernelboot.
os-coordinate-test: build uefi base-image updatestore kernelboot
	./tests/os_coordinate_test.sh

# OS-1b: `swupdate os` flips the single ESP selector (kernel-state) so kernel +
# base activate together. Boots a UEFI/ESP disk + SWOSBOOT store under AAVMF,
# reaches a shell, and runs `swupdate os-apply-local` on a baked tiny SWSYS bundle
# (no network). Needs the fixtures (INCLUDE_OS_STAGE_TEST=1). SKIPs without AAVMF.
os-coordinate-activate-test: build uefi updatestore $(TEST_BASE_IMG) $(TEST_OS_BUNDLE)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_OS_STAGE_TEST=1
	./tests/os_coordinate_activate_test.sh

# OS-1c-2b: install a genuinely NEW kernel into the inactive ESP slot. Boots a
# UEFI/ESP disk under AAVMF, corrupts slot B, then /bin/swos-kinstall streams a
# distinct host-signed kernel image into slot B and commits its per-slot manifest
# entry — with the kernel verifying the on-disk re-hash + the per-slot Ed25519
# signature. Index-mismatched and bad-signature entries are rejected. Then flips
# the ESP selector (swos-kactivate) and reboots to prove the loader boots the
# freshly installed slot B. Needs the baked fixtures (INCLUDE_OS_KINSTALL_TEST=1);
# rebuilds the base to carry them. SKIPs without AAVMF.
uefi-kinstall-test: build uefi updatestore kernelboot $(KINSTALL_TEST_DEPS)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_OS_KINSTALL_TEST=1
	./tests/uefi_kinstall_test.sh

# OS-1c-3b: one SWSYS bundle moves kernel + base. Boots the coordinated topology
# (UEFI kernel A/B on the ESP + a SWOSBOOT store) under AAVMF, reaches a shell, and
# runs `swupdate os-apply-local` on a baked v2 bundle whose kernel half is a
# DISTINCT kernel. swupdate streams the base into the inactive store slot AND the
# kernel into the inactive ESP slot (committing the per-slot entry sliced from the
# bundle's manifest), then flips the single ESP selector. Asserts both halves
# staged + the flip, and (host) that the ESP slot now holds the new kernel while
# the active slot is untouched. Needs the fixtures (INCLUDE_OS_KINSTALL_TEST=1).
uefi-os-install-test: build uefi updatestore kernelboot $(KINSTALL_TEST_DEPS)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_OS_KINSTALL_TEST=1
	./tests/uefi_os_install_test.sh

# Power control: /bin/reboot issues PSCI SYSTEM_RESET (machine resets), /bin/shutdown
# issues PSCI SYSTEM_OFF (QEMU exits), and both are capConsole-gated. The reset path
# is shared by the kernel panic auto-reboot. Needs the base image for the commands.
reboot-test: build $(QEMU_DTB) base-image
	./tests/reboot_test.sh

# D1: datafs files created via the VFS syscall path survive reboot. Needs the
# base image (drives the busybox shell to create/read files under /data).
datafs-test: build $(QEMU_DTB) base-image
	./tests/datafs_test.sh

# D2: fsync/fdatasync/sync issue a real /data cache flush. Boots with a data disk
# and confirms the durable-sync self-test. Base-image optional.
datafs-fsync-test: build $(QEMU_DTB)
	./tests/datafs_fsync_test.sh

# D3: a SQLite database stored on /data survives reboot (headline acceptance).
# Needs the base image (which bakes in /bin/sqlite3).
datafs-sqlite-test: build $(QEMU_DTB) base-image
	./tests/datafs_sqlite_test.sh

# V1: a second SWDATAFS disk mounts at /mnt/data1 as a distinct datafs volume,
# isolated from /data, and both survive reboot. Boots with TWO data disks (the
# test stamps them); the kernel mounts volume 0 = /data, volume 1 = /mnt/data1.
v1-volume-test: build $(QEMU_DTB) base-image
	./tests/v1_volume_test.sh

# V2a: a datafs volume carries a stable on-disk identity (128-bit UUID + label).
# The second disk is provisioned with the label "media"; the kernel mounts it by
# LABEL at /mnt/media (not by scan order) and the UUID is stable across reboot.
v2-label-test: build $(QEMU_DTB) base-image
	./tests/v2_label_test.sh

# V2b: the declarative mount manifest /data/.system/mounts drives where labeled
# volumes mount (by label), with the /mnt-only + empty-dir + no-format-non-magic
# guardrails. Three boots: auto-mount, manifest remap, guardrail refusal.
v2-manifest-test: build $(QEMU_DTB) base-image
	./tests/v2_manifest_test.sh

# V2c: the root /data volume is anchored by a UUID pinned in the kernel cmdline
# (FDT /chosen/bootargs datafs.root=<hex>) — /data follows that disk regardless of
# scan order; a blank disk is formatted as root stamping the pin on first boot.
# Needs dtc to bake the cmdline UUID into a DTB.
v2-anchor-test: build $(QEMU_DTB) base-image
	./tests/v2_anchor_test.sh

# W1: nginx runs and serves a static page over HTTP on SwiftOS. Needs the base
# image (bakes /sbin/nginx + config) and host curl.
nginx-test: build $(QEMU_DTB) base-image
	./tests/nginx_test.sh

# NC1: boot the base image and run /bin/ncdemo — links static ncurses, resolves
# terminfo from compiled-in fallbacks (no DB on disk), draws a box on the serial
# console, reads a key, and exits. Asserts the post-endwin plain-text markers.
ncurses-test: build $(QEMU_DTB)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_NCURSES=1
	./tests/ncurses_test.sh

# GL1: boot the base image and run /bin/glibdemo — links static libglib-2.0.a
# and exercises GString/GList/GHashTable/GArray/g_get_monotonic_time. Asserts
# the GLIBDEMO-OK marker.
glib-test: build $(QEMU_DTB)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_GLIB=1
	./tests/glib_test.sh

# MC1: boot the base image and run /bin/mc — the Midnight Commander TUI on the
# ncurses backend. Asserts the panels/menu draw and that it quits cleanly.
mc-test: build $(QEMU_DTB)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_NCURSES=1 INCLUDE_GLIB=1 INCLUDE_MC=1
	./tests/mc_test.sh

# W2: nginx serves a web root + logs from the persistent /data tier; content
# survives reboot. Needs the base image and host curl.
nginx-data-test: build $(QEMU_DTB) base-image
	./tests/nginx_data_test.sh

# W3: nginx serves HTTPS/TLS (self-signed) — static openssl, /dev/urandom entropy,
# TCP MSG_PEEK for TLS detection. Needs the base image and host curl.
nginx-tls-test: build $(QEMU_DTB) base-image
	./tests/nginx_tls_test.sh

# M-A: reflash-free site updates, seed/recovery. swos-init runs `swupdate seed`
# at boot: a fresh /data is seeded from the baked default (nginx then serves it
# from /data/www/current), and a crash-interrupted atomic swap is recovered on
# the next boot — proving content lives on /data and survives reboot without a
# base-image reflash. Needs the base image and host curl.
site-seed-test: build $(QEMU_DTB) base-image
	./tests/site_seed_test.sh

# SU-B: signed-bundle apply. Forces a repack with INCLUDE_SITE_TEST=1 so the
# signed test bundle (+ tampered copy) is baked under /usr/share/swupdate-test.
site-bundle-test: build $(QEMU_DTB)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_SITE_TEST=1
	./tests/site_bundle_test.sh

# SU-C: full operator path — `/bin/swupdate site <https-url>` over bounded-sshd
# fetches a signed bundle from a host HTTPS server, verifies + atomically swaps
# it, nginx serves the new content; survives reboot; tampered bundle rejected.
# Uses the test bundles built by the SITE_TEST_* rules (served from the host).
site-update-test: build $(QEMU_DTB) base-image $(SSHKEY) $(SITE_TEST_BUNDLE) $(SITE_TEST_BAD_BUNDLE)
	./tests/site_update_test.sh

acme-mock-test: build $(QEMU_DTB) base-image
	./tests/acme_mock_test.sh

acme-persist-test: build $(QEMU_DTB) base-image
	./tests/acme_persist_test.sh

acme-verify-test: build $(QEMU_DTB) base-image
	./tests/acme_verify_test.sh

tls-verify-test:
	./tests/tls_verify_test.sh

# V-TS1: /bin/tlsget verifies by default against the system trust store
# (/etc/ssl/cert.pem, shipped in the base image). Needs base-image + a NIC + host openssl.
tls-truststore-test: build $(QEMU_DTB) base-image
	./tests/tls_truststore_test.sh

# SC2: on-device node-join + lease-expiry acceptance (case 8). Boots /bin/sctld +
# /bin/slet under Embedded Swift in QEMU and asserts the join → register →
# heartbeat → reaper-expiry → watch lifecycle markers on the serial console.
sc2-join-test: build $(QEMU_DTB) base-image
	./tests/sc2_join_test.sh

mprotect-test: build $(QEMU_DTB) base-image
	./tests/mprotect_test.sh

largemmap-test: build $(QEMU_DTB) base-image
	./tests/largemmap_test.sh

mmapreserve-test: build $(QEMU_DTB) base-image
	./tests/mmapreserve_test.sh

mapfixed-test: build $(QEMU_DTB) base-image
	./tests/mapfixed_test.sh

pthread-test: build $(QEMU_DTB) base-image
	./tests/pthread_test.sh

# TH8: direct-futex boundary probe (val-mismatch fast path, wake-empty, and the
# 16-slot wait table full -> EAGAIN). Runs at -smp 4 so the slot-table races matter.
futex-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/futex_test.sh

threadsync-test: build $(QEMU_DTB) base-image
	./tests/threadsync_test.sh

select-test: build $(QEMU_DTB) base-image
	./tests/select_test.sh

eventfd-test: build $(QEMU_DTB) base-image
	./tests/eventfd_test.sh

# QW4: endpoint-badge acceptance. /bin/qw4-badge stamps a distinct badge into two
# clients' send handles on otherwise-identical endpoints, sends on each, and
# proves ipc_recv_badged reports the right badge per client — and 0 for an
# unbadged send. No network needed.
qw4-badge-test: build $(QEMU_DTB) base-image
	./tests/qw4_badge_test.sh

# I8 signed-base negative acceptance: tampered metadata + tampered payload +
# (TH5) a valid signature by the WRONG key — all refused. base-image provides the
# basepack tool + build/base-root the test re-signs with an attacker seed.
signed-image-test: build $(QEMU_DTB) base-image
	./tests/signed_image_test.sh

# TH6 panic-loop guard: build a test-only kernel whose `#if PANIC_LOOP_INJECT`
# hook faults on every boot, BEFORE the healthy-boot marker. The guard must bound
# the consecutive panic auto-reboots and halt instead of cycling forever. The
# variant kernel is a recursive build with the define + its own object/elf names so
# the production kernel.elf is untouched and carries no injector.
PANIC_LOOP_KERNEL := $(BUILD)/kernel-paniclooptest.elf
panic-loop-test: build $(QEMU_DTB) base-image
	$(MAKE) $(PANIC_LOOP_KERNEL) \
	  KERNEL_OBJ=$(BUILD)/kernel-paniclooptest.o KERNEL_ELF=$(PANIC_LOOP_KERNEL) \
	  EXTRA_SWIFT_DEFS="-D PANIC_LOOP_INJECT"
	PANIC_LOOP_KERNEL=$(PANIC_LOOP_KERNEL) ./tests/panic_loop_test.sh

pty-test: build $(QEMU_DTB) base-image
	./tests/pty_test.sh

ptysig-test: build $(QEMU_DTB) base-image
	./tests/ptysig_test.sh

epoll-test: build $(QEMU_DTB) base-image
	./tests/epoll_test.sh

uvwake-test: build $(QEMU_DTB) base-image
	./tests/uvwake_test.sh

uvsem-test: build $(QEMU_DTB) base-image
	./tests/uvsem_test.sh

uvrwlock-test: build $(QEMU_DTB) base-image
	./tests/uvrwlock_test.sh

uvmutex-test: build $(QEMU_DTB) base-image
	./tests/uvmutex_test.sh

uvthreadname-test: build $(QEMU_DTB) base-image
	./tests/uvthreadname_test.sh

uvthreadstack-test: build $(QEMU_DTB) base-image
	./tests/uvthreadstack_test.sh

uvkeyonce-test: build $(QEMU_DTB) base-image
	./tests/uvkeyonce_test.sh

uvenv-test: build $(QEMU_DTB) base-image
	./tests/uvenv_test.sh

uvbarrier-test: build $(QEMU_DTB) base-image
	./tests/uvbarrier_test.sh

uvcond-test: build $(QEMU_DTB) base-image
	./tests/uvcond_test.sh

uvsocketpair-test: build $(QEMU_DTB) base-image
	./tests/uvsocketpair_test.sh

uvsignal-test: build $(QEMU_DTB) base-image
	./tests/uvsignal_test.sh

uvatfork-test: build $(QEMU_DTB) base-image
	./tests/uvatfork_test.sh

uvspawn-test: build $(QEMU_DTB) base-image
	./tests/uvspawn_test.sh

signal-test: build $(QEMU_DTB) base-image
	./tests/signal_test.sh

socket-test: build $(QEMU_DTB) base-image
	./tests/socket_test.sh

# USB M1: xHCI controller bring-up over PCIe + USB-keyboard detection. Runs
# early in boot (before any disk use), so it needs only the kernel + dtb.
usb-xhci-test: build $(QEMU_DTB)
	./tests/usb_xhci_test.sh

smp-resource-stress-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_resource_stress_test.sh

smp-headroom-test: build base-image
	./tests/smp_headroom_test.sh

smp-uefi-test: disk base-image
	SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh

s4-resource-stress-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/s4_resource_stress_test.sh

# Fixed-size kernel-pool saturation: every bounded pool must refuse gracefully
# at its ceiling (clean errno, no panic) and recover afterwards (no slot leak).
# Single-core by default (cap logic is not SMP-specific); the SMP variant also
# stresses the S4 pool locks while secondaries tick.
saturation-test: build $(QEMU_DTB) base-image
	SMP_CPUS=1 SMP_DTB=$(QEMU_DTB) ./tests/saturation_test.sh

saturation-smp-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/saturation_test.sh

# Concurrent cross-CPU resource-churn race: N+2 copies of /bin/smprace run in
# parallel on different CPUs (via the S5f run-any primitive) and hammer the
# S4-locked pools at once. Validates the locks under genuine multi-CPU
# contention - frame-leak-free and balanced - which a CPU0-only stress cannot.
smp-race-stress-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/smp_race_stress_test.sh

# Coarse memory edge cases: sparse page-table pressure (touch per 2 MiB then
# unmap) + graceful refusal of an absurd reservation, and COW fork lifecycle.
# Asserts graceful behaviour + leak balance (free frames return to baseline).
edge-stress-test: build $(QEMU_DTB) base-image
	SMP_CPUS=1 SMP_DTB=$(QEMU_DTB) ./tests/edge_stress_test.sh

# Network overload + recovery: drive /bin/httpd past maxConns from the host over
# slirp (20-way burst + a slow reader), asserting graceful degradation and that
# the server recovers (200) afterwards. The netsvc kill+restart-under-traffic
# recovery angle is covered by ns3-net-service-test.
httpd-load-test: build $(QEMU_DTB) base-image
	./tests/httpd_load_test.sh

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

# LA1: persistent Swift supervisor + UserlandService over the name-registry grant,
# under -smp 4 with the virtio-input device present (like c5-device-metadata-test).
la1-service-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/userland_service_test.sh

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

device-authority-cap-test: build $(QEMU_DTB) base-image
	./tests/device_authority_cap_test.sh

c5-test: c5-driver-service-test c5-device-handle-test c5-device-discovery-test c5-device-metadata-test c5-device-authority-test c5-device-rights-test device-authority-cap-test

# LA2: device-MMIO-map authority. Boots the base image with a virtio-input window
# present and asserts the capConsole probe maps it and reads its registers, plus
# the EACCES refusals. Runs single-core and under -smp 4.
device-mmio-map-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/device_mmio_map_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/device_mmio_map_test.sh

# C5h: real MMIO authority reaches the supervised userland driver service. The LA1
# supervisor claims the now-mappable virtio-input.0 grant and transfers it over IPC
# to /bin/svc-input, which sys_device_mmap's the window and verifies the virtio magic
# through the userland mapping. Runs under -smp 4 with the virtio-input device.
c5-mmio-grant-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c5_mmio_grant_test.sh

# C5i: the virtio-input driver runs entirely in userland. The kernel skips its
# in-kernel polled driver; /bin/svc-input maps the MMIO window, resolves the
# virtqueue's physical address via virt_to_phys, brings the queue up, and recovers
# across a supervisor-driven kill+restart. Runs under -smp 4.
c5-userland-driver-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c5_userland_driver_test.sh

# NS1: virtio-net MMIO grant reaches userland alongside the live in-kernel net
# stack. Boots with a virtio-net (slirp) device; the capConsole probe maps the NIC
# window, reads the identity + config MAC, and the kernel net stack stays up
# (ICMP echo reply). Runs under -smp 4.
ns1-net-grant-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/ns1_net_grant_test.sh

# NS2: a userland virtio-net driver does real TX/RX on a SECONDARY NIC (two
# virtio-net devices; the kernel keeps the first) via an ARP round-trip against
# slirp, without disturbing the primary kernel NIC. Runs under -smp 4.
ns2-net-driver-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/ns2_net_driver_test.sh

# NS3: a restartable userland net service relays frames over an shmring data plane,
# driving a secondary NIC from EL0; kill+restart recovery across two generations.
ns3-net-service-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/ns3_net_service_test.sh

# C5j: the persistent userland driver (/bin/inputd, launched by swos-init) injects
# decoded virtio-input keystrokes into the kernel tty (SYS_tty_inject), restoring
# interactive keyboard. The test QMP send-key's a character into the virtio device
# and asserts it reaches the login prompt via the userland driver. Runs under -smp 4.
c5-tty-inject-test: build $(QEMU_DTB_SMP4) base-image
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c5_tty_inject_test.sh

# Process-table capacity. The boot probe (/bin/procmaxprobe) forks children in
# globalCell, each parked on a pipe barrier, until the table refuses; it asserts
# more than the historical 16 were live at once (the cap is raised), that the
# boundary returned a clean EAGAIN, and that saturate-and-reap leaks no slot. This
# guards the unified kMaxProcesses cap. Runs single-core and under -smp 4.
procmax-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/procmax_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/procmax_test.sh

# C6a: per-cell resource accounting. The boot probe (/bin/cellstatprobe) forks
# children in globalCell, reads SYS_cell_stat, and asserts the aggregate
# {processes, residentPages, handles} grows with the live children and that a
# reaped process's charge is reclaimed. Runs single-core and under -smp 4.
c6-cell-accounting-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c6_cell_accounting_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c6_cell_accounting_test.sh

# C6b: cell creation + spawn-into-cell. The boot probe (/bin/cellcreateprobe)
# creates a cell, refuses a spawn without the cell handle, launches /bin/cellchild
# into the cell, and asserts the child is charged to the new cell (not globalCell)
# and reclaimed on reap. Runs single-core and under -smp 4.
c6-cell-create-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c6_cell_create_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c6_cell_create_test.sh

# C6c: per-cell namespace root. The boot probe (/bin/cellnsprobe) creates a cell
# rooted at /www and launches /bin/cellnschild into it; the child must resolve a
# file inside the root but be refused /etc and the global root, while the default
# cell stays unconfined. Runs single-core and under -smp 4.
c6-cell-namespace-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c6_cell_namespace_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c6_cell_namespace_test.sh

# C6d: cell lifecycle — resident-page cap, enumerate-by-cell, and teardown. The boot
# probe (/bin/cellcapprobe) caps a cell, spawns members until the cap refuses, walks
# the members via cell_pids, proves destroy is refused while live, then reaps + frees
# the CellId and reuses it. Runs single-core and under -smp 4.
c6-cell-lifecycle-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c6_cell_lifecycle_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c6_cell_lifecycle_test.sh

# C6e: end-to-end one-service-per-cell. The boot probe (/bin/cellsvcprobe) assembles
# a cell { /www root + restricted handles + page cap }, launches /bin/cellhello
# inside it, drives a ping/pong round-trip, confirms isolation + accounting, then
# tears it down. Runs single-core and under -smp 4.
c6-cell-service-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c6_cell_service_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c6_cell_service_test.sh

# C7a: intra-member resident-page cap. The boot probe (/bin/cellgrowprobe) launches
# /bin/cellgrower into a capped cell; the grower cannot grow its own heap (sbrk/mmap)
# past the cap (the aggregate never exceeds it), while an uncapped global member is
# unaffected. Runs single-core and under -smp 4.
c7-cell-pagecap-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c7_cell_pagecap_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c7_cell_pagecap_test.sh

# C7b: per-cell handle cap (folded into cell_create). The boot probe
# (/bin/cellhandleprobe) launches /bin/cellopener into a handle-capped cell; the opener
# cannot open() fds past the cap (refused EMFILE, aggregate never exceeds it), while an
# uncapped global member is unaffected. Runs single-core and under -smp 4.
c7-cell-handlecap-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c7_cell_handlecap_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c7_cell_handlecap_test.sh

# C7c: persistent restart/FDIR cell supervisor. The boot probe (/bin/cell-supervisor)
# hosts /bin/cell-svc in a cell, detects its exit/crash, restarts it in a FRESH cell
# (new CellId) with accounting reclaimed across generations, and bounds restarts so a
# crash loop halts instead of fork-storming. Runs single-core and under -smp 4.
c7-cell-supervisor-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c7_cell_supervisor_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c7_cell_supervisor_test.sh

# C7d: a REAL in-tree service (/bin/kv) lifted into a supervised cell. The boot probe
# (/bin/cell-kv-supervisor) runs the real key-value store inside a cell with a restricted
# handle set + caps, drives a live SET/GET round-trip over pipes, faults + restarts it in
# a fresh cell (fresh state), and tears down cleanly. Runs single-core and under -smp 4.
c7-cell-realservice-test: build $(QEMU_DTB) $(QEMU_DTB_SMP4) base-image
	./tests/c7_cell_realservice_test.sh
	SMP_CPUS=4 SMP_DTB=$(QEMU_DTB_SMP4) ./tests/c7_cell_realservice_test.sh

ssh-transport-test: build $(QEMU_DTB) base-image
	./tests/ssh_transport_test.sh

ssh-runtime-entropy-test: build $(QEMU_DTB) base-image
	./tests/ssh_runtime_entropy_test.sh

sshd-transport-test: build $(QEMU_DTB) base-image $(SSHKEY)
	./tests/sshd_transport_test.sh

sshd-usr-bin-exec-test: build $(QEMU_DTB) base-image package-fixture $(SSHKEY)
	./tests/sshd_usr_bin_exec_test.sh

sshd-sftp-test: build $(QEMU_DTB) base-image $(SSHKEY)
	./tests/sshd_sftp_test.sh

sshd-sftp-write-test: build $(QEMU_DTB) base-image $(SSHKEY)
	./tests/sshd_sftp_write_test.sh

sshd-interactive-test: build $(QEMU_DTB) base-image $(SSHKEY)
	./tests/sshd_interactive_test.sh

sshd-host-key-rotation-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/sshd_host_key_rotation_test.sh

sshd-kex-seed-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/sshd_kex_seed_test.sh

sshd-authorized-keys-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/sshd_authorized_keys_test.sh

sshd-supervision-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/sshd_supervision_test.sh

sshd-ipv6-listener-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/sshd_ipv6_listener_test.sh

sshd-ipv6-supervision-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/sshd_ipv6_supervision_test.sh

sshd-runtime-entropy-test: build $(QEMU_DTB) base-image $(SSHKEY)
	./tests/sshd_runtime_entropy_test.sh

sshd-deploy-preflight-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/sshd_deploy_preflight_test.sh

hetzner-deploy-bundle-test: build $(QEMU_DTB) $(SSHKEY)
	./tests/hetzner_deploy_bundle_test.sh

netinfo-test: build $(QEMU_DTB) base-image
	./tests/netinfo_test.sh

net-static-ipv6-test: build $(QEMU_DTB)
	./tests/net_static_ipv6_test.sh

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
# OS-1c: fixed-size (padded) ESP kernel slots. A slot file is the kernel image
# zero-padded to KERNEL_SLOT_BYTES so the box can later overwrite it IN PLACE with
# a different-size new kernel (the FAT writer does same-size-in-place only), and so
# the per-slot signed manifest entry covers a fixed-length region. The loader loads
# the whole padded file; trailing zeros are harmless (the kernel zeroes its own BSS
# and the base ramdisk is allocated elsewhere). Host (here) and the on-box installer
# pad identically so the SHA-256 over the padded slot matches.
KERNEL_SLOT_BYTES := 4194304   # 4 MiB
$(BUILD)/kernel-slot.bin: $(KERNEL_BIN) Makefile | $(BUILD)/.dir
	@ksz=$$(wc -c < $(KERNEL_BIN)); if [ $$ksz -gt $(KERNEL_SLOT_BYTES) ]; then \
	  echo "kernel.bin $$ksz B exceeds the $(KERNEL_SLOT_BYTES) B slot" >&2; exit 1; fi
	dd if=/dev/zero of=$@ bs=1 count=0 seek=$(KERNEL_SLOT_BYTES) 2>/dev/null
	dd if=$(KERNEL_BIN) of=$@ conv=notrunc 2>/dev/null

# OS-1c-2b test fixtures (built only when referenced via INCLUDE_OS_KINSTALL_TEST=1):
# a DISTINCT-but-bootable kernel image + its host-signed per-slot manifest entries.
# The flipped byte is the last byte of the padded slot — in the zero-pad well past
# the real kernel — so the sha256 differs while the kernel still boots identically.
$(KINSTALL_TEST_NEWKERNEL): $(BUILD)/kernel-slot.bin
	cp $< $@
	printf '\xA5' | dd of=$@ bs=1 seek=$$(( $(KERNEL_SLOT_BYTES) - 1 )) count=1 conv=notrunc 2>/dev/null
# Slot-B entry (index 1) over the new image: valid for install into the inactive B.
$(BUILD)/kinstall-manifest-b: $(KERNELBOOT) $(BUILD)/kernel-slot.bin $(KINSTALL_TEST_NEWKERNEL) $(IMG_SIGNING_SEED)
	$(KERNELBOOT) $@ A $(BUILD)/kernel-slot.bin $(KINSTALL_TEST_NEWKERNEL) $(IMG_SIGNING_SEED)
$(KINSTALL_TEST_ENTRY_B): $(BUILD)/kinstall-manifest-b
	dd if=$< of=$@ bs=1 skip=128 count=104 2>/dev/null
# Slot-A entry (index 0) over the SAME new image: a correctly-signed entry for the
# WRONG slot index — commit into slot B must reject it (per-slot index binding).
$(BUILD)/kinstall-manifest-a: $(KERNELBOOT) $(KINSTALL_TEST_NEWKERNEL) $(IMG_SIGNING_SEED)
	$(KERNELBOOT) $@ A $(KINSTALL_TEST_NEWKERNEL) $(KINSTALL_TEST_NEWKERNEL) $(IMG_SIGNING_SEED)
$(KINSTALL_TEST_ENTRY_A): $(BUILD)/kinstall-manifest-a
	dd if=$< of=$@ bs=1 skip=24 count=104 2>/dev/null
# entryB with the 64-byte signature zeroed: a broken/unsigned entry, must be rejected.
$(KINSTALL_TEST_ENTRY_BADSIG): $(KINSTALL_TEST_ENTRY_B)
	cp $< $@
	dd if=/dev/zero of=$@ bs=1 seek=40 count=64 conv=notrunc 2>/dev/null
# OS-1c-3b: a SWSYS v2 bundle carrying the distinct new kernel + the tiny test base.
$(KINSTALL_TEST_BUNDLE): $(SYSPACK) $(KINSTALL_TEST_NEWKERNEL) $(TEST_BASE_IMG) $(IMG_SIGNING_SEED)
	$(SYSPACK) create $(KINSTALL_TEST_NEWKERNEL) $(TEST_BASE_IMG) $@ --version 2 --seed $(IMG_SIGNING_SEED) --slot-bytes $(KERNEL_SLOT_BYTES)

$(ESP_DIR)/EFI/swift-os/kernelA.bin: $(BUILD)/kernel-slot.bin
	@mkdir -p $(ESP_DIR)/EFI/swift-os
	cp $< $@
$(ESP_DIR)/EFI/swift-os/kernelB.bin: $(BUILD)/kernel-slot.bin
	@mkdir -p $(ESP_DIR)/EFI/swift-os
	cp $< $@
$(ESP_DIR)/EFI/swift-os/kernel-boot: $(KERNELBOOT) $(BUILD)/kernel-slot.bin $(IMG_SIGNING_SEED)
	@mkdir -p $(ESP_DIR)/EFI/swift-os
	$(KERNELBOOT) $@ A $(BUILD)/kernel-slot.bin $(BUILD)/kernel-slot.bin $(IMG_SIGNING_SEED)

# H3: stage the packed read-only base image on the ESP so the loader can read it
# into RAM and hand the kernel a ramdisk (the path for boards whose boot disk —
# e.g. the Hetzner VM's virtio-scsi — the kernel does not drive). When a
# virtio-blk base disk is also attached (the QEMU UEFI tests), the kernel still
# prefers it; the ramdisk base is used when no block base disk is present.
$(ESP_DIR)/EFI/swift-os/base.img: base-image
	@mkdir -p $(ESP_DIR)/EFI/swift-os
	cp $(BASE_IMG) $@

uefi: $(ESP_DIR)/EFI/BOOT/BOOTAA64.EFI \
      $(ESP_DIR)/EFI/swift-os/kernelA.bin \
      $(ESP_DIR)/EFI/swift-os/kernelB.bin \
      $(ESP_DIR)/EFI/swift-os/kernel-boot \
      $(ESP_DIR)/EFI/swift-os/base.img
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
		-drive file=$(DISK_IMG),format=raw,if=none,id=gfxesp -device virtio-blk-device,drive=gfxesp \
		-drive file=$(BASE_IMG),format=raw,if=none,id=gfxbase,readonly=on \
		-device virtio-blk-device,drive=gfxbase \
		-device ramfb -device virtio-keyboard-device -display cocoa -serial stdio

# ---- Hetzner-faithful local profile (H-series bare-metal bring-up) ---------
# Reproduces the Hetzner ARM cloud VM device model in local QEMU so the
# bare-metal drivers (docs/RISK_REMEDIATION_ROADMAP.md, H-series) can be
# developed WITHOUT the server. It differs from the QEMU `virt` profile the
# kernel boots on today in the four ways the live VM does:
#   * ACPI firmware (NO `acpi=off`) — edk2 boots in ACPI mode and, as H0 found,
#     publishes NO FDT configuration table (only ACPI). The kernel's DT path
#     therefore finds nothing here; ACPI parsing is H5.
#   * virtio over PCIe (virtio-scsi-pci boot disk, virtio-net-pci, virtio-rng-pci)
#     instead of virtio-mmio — H2/H3/H4.
#   * GICv3 (`gic-version=3`, sysreg CPU interface) instead of GICv2 MMIO — H1.
#   * `-cpu max -smp 2 -m 4G`, matching the 2-vCPU / ~4 GiB VM.
# The bootable GPT disk rides on virtio-scsi-pci (like `/dev/sda` on the VM);
# the EFI loader reads the kernel from its ESP via the firmware (transport-
# agnostic), which already works here. The kernel then panics at GICv2 init
# (expected until H1) — this target is for driver bring-up, not a clean boot yet.
HETZNER_QEMU_FLAGS := -M virt,gic-version=3 -cpu max -m 4G -smp 2 -no-reboot \
	-bios $(AAVMF_CODE) \
	-drive file=$(DISK_IMG),format=raw,if=none,id=hdd \
	-device virtio-scsi-pci -device scsi-hd,drive=hdd \
	-device virtio-net-pci,netdev=hn0 -netdev user,id=hn0 \
	-device virtio-rng-pci \
	-nographic

hetzner-run: disk
	$(QEMU) $(HETZNER_QEMU_FLAGS)

$(BASEPACK): tools/basepack.swift tools/packfs.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) -O tools/basepack.swift tools/packfs.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

# OS-3b: a tiny signed SWOSBASE image (from a one-file fixture dir) that
# os-stage-test streams into the inactive A/B slot. Signed with the image key.
$(TEST_BASE_IMG): $(BASEPACK) $(IMG_SIGNING_SEED) tests/fixtures/test-base/README.txt Makefile | $(BUILD)/.dir
	$(BASEPACK) tests/fixtures/test-base $@ $(IMG_SIGNING_SEED)

# LM3a: a dedicated, signed packed read-only "model disk" — a SECOND SWOSBASE
# image carrying the model bundle, separate from the base. A real (multi-GB)
# model cannot live in the RAM-loaded base image, and datafs caps files at
# ~4 MiB (single-indirect), so neither tier can hold a real model. A packed
# image has no such cap and reuses the base reader + file-backed mmap. LM3b
# mounts it read-only at /srv/models; LM3c serves from there. Signed with the
# image key so the kernel's compiled-in trust root verifies it like the base.
MODEL_PACK_ROOT := $(BUILD)/model-pack-root
MODEL_PACK_IMG  := $(BUILD)/model.img
MODEL_DISK_ID   := SWOS-MODEL-DISK-v1

$(MODEL_PACK_IMG): $(BASEPACK) $(MODELSIGN) $(MODEL15_Q8) $(MODEL_TOK32) $(MODELMANIFEST) $(SIGNING_SEED) $(IMG_SIGNING_SEED) Makefile | $(BUILD)/.dir
	rm -rf $(MODEL_PACK_ROOT)
	mkdir -p $(MODEL_PACK_ROOT)/stories15M/1
	cp $(MODEL15_Q8) $(MODEL_PACK_ROOT)/stories15M/1/model.bin
	cp $(MODEL_TOK32) $(MODEL_PACK_ROOT)/stories15M/1/tokenizer.bin
	$(MODELMANIFEST) stories15M 1 $(MODEL15_Q8) $(MODEL_TOK32) $(MODEL_PACK_ROOT)/stories15M/1/manifest.toml
	$(MODELSIGN) sign $(MODEL_PACK_ROOT)/stories15M/1/manifest.toml $(SIGNING_SEED)
	printf '%s\n' '$(MODEL_DISK_ID)' > $(MODEL_PACK_ROOT)/MODEL-DISK-ID
	$(BASEPACK) $(MODEL_PACK_ROOT) $@ $(IMG_SIGNING_SEED)

.PHONY: model-image
model-image: $(MODEL_PACK_IMG)

# LM3a host acceptance: the model image builds, is a valid signed SWOSBASE
# packed FS, and carries the model bundle + the provenance sentinel.
model-image-test: $(MODEL_PACK_IMG)
	./tests/model_image_test.sh

# LM3b acceptance: boot with the model disk attached and prove the kernel mounts
# it read-only at /srv/models (sentinel readable, bundle visible).
model-mount-test: build $(QEMU_DTB) base-image $(MODEL_PACK_IMG)
	./tests/model_mount_test.sh

# LM3c acceptance: /bin/llmd serves the disk-delivered model from /srv/models
# under a larger-RAM inference profile (model disk attached, -m 1024M).
llm-serve-disk-test: build $(QEMU_DTB) base-image $(MODEL_PACK_IMG)
	./tests/llm_serve_disk_test.sh

# OS-1b/OS-1c-3: a signed SWSYS v2 bundle (the real padded kernel slot + a v4
# SWOSKERN manifest over it, plus the tiny test base, version 2) for the no-network
# coordinated-activate test. The base half is applied by os-coordinate-activate-test;
# the kernel half + manifest are what OS-1c-3b's `swupdate os` installs.
$(TEST_OS_BUNDLE): $(SYSPACK) $(BUILD)/kernel-slot.bin $(TEST_BASE_IMG) $(IMG_SIGNING_SEED) Makefile | $(BUILD)/.dir
	$(SYSPACK) create $(BUILD)/kernel-slot.bin $(TEST_BASE_IMG) $@ --version 2 --seed $(IMG_SIGNING_SEED) --slot-bytes $(KERNEL_SLOT_BYTES)

$(SWPKG): tools/swpkg.swift tools/packfs.swift kernel/crypto/sha256.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/swpkg.swift tools/packfs.swift kernel/crypto/sha256.swift -o $@

swpkg: $(SWPKG)

swpkg-header-integrity-test: $(SWPKG) package-fixture | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/swpkg_header_integrity_test.swift -o $(BUILD)/swpkg_header_integrity_test
	$(BUILD)/swpkg_header_integrity_test

$(PKGSTORE): tools/pkgstore.swift tools/packfs.swift kernel/crypto/sha256.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/pkgstore.swift tools/packfs.swift kernel/crypto/sha256.swift -o $@

pkgstore: $(PKGSTORE)

# SU-B: host tool that packs a static site into a signed SWSITE bundle.
$(SITEPACK): tools/sitepack.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/sitepack.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

sitepack: $(SITEPACK)

# OS-2: host tool that packs a kernel + signed base image into a signed SWSYS
# system-update bundle. Shares the format/verifier with the on-box updater via
# userland/lib/sysbundle.swift, and the Ed25519/SHA-256 crypto with the kernel.
$(SYSPACK): tools/syspack.swift userland/lib/sysbundle.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift Makefile | $(BUILD)/.dir
	$(HOST_SWIFTC) tools/syspack.swift userland/lib/sysbundle.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $@

syspack: $(SYSPACK)

# OS-2: host unit test for the shared SWSYS verifier (sign/verify, anti-rollback
# floor, all rejection paths). Pure host-side; no QEMU.
syspack-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/syspack_test.swift userland/lib/sysbundle.swift kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift -o $(BUILD)/syspack_test
	$(BUILD)/syspack_test

# SU-B/SU-C: fast host proof of the signed SWSITE bundle format. An independent
# unpacker reconstructs the fixture tree from a freshly packed bundle (catching
# any drift from the layout /bin/swupdate reads), and `sitepack verify` is driven
# against signature/payload/key/length tampering. Host-only — no QEMU boot.
sitepack-test: $(SITEPACK) $(SITE_SIGNING_SEED) $(SITE_SIGNING_PUB) | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/sitepack_test.swift -o $(BUILD)/sitepack_test
	$(BUILD)/sitepack_test $(SITEPACK) $(SITE_SIGNING_SEED) $(SITE_SIGNING_PUB) tests/fixtures/site-update

# SU-B/SU-C: host unit tests for the pure SWSITE parsers /bin/swupdate trusts
# (userland/lib/swsite.swift) — layout/inode-budget bounds, path-traversal
# rejection, and URL/HTTP-response parsing — hit with hostile input, no QEMU.
swsite-test: | $(BUILD)/.dir
	$(HOST_SWIFTC) tests/swsite_test.swift userland/lib/swsite.swift -o $(BUILD)/swsite_test
	$(BUILD)/swsite_test

# Pack+sign the fixture site into a test bundle; the "bad" copy corrupts a
# payload byte (past the 64B sig + 64B header) so both the signature and the
# payload sha256 fail to verify.
SITE_TEST_FIXTURES := $(shell find tests/fixtures/site-update -type f 2>/dev/null | sort)
$(SITE_TEST_BUNDLE): $(SITEPACK) $(SITE_SIGNING_SEED) $(SITE_TEST_FIXTURES) Makefile | $(BUILD)/.dir
	$(SITEPACK) create tests/fixtures/site-update $@ --seed $(SITE_SIGNING_SEED)
$(SITE_TEST_BAD_BUNDLE): $(SITE_TEST_BUNDLE)
	cp $< $@
	printf '\377' | dd of=$@ bs=1 seek=200 conv=notrunc 2>/dev/null

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

ports-recipe-test: $(SWPORT) $(SWPKG) $(PKGREPO) $(SWPORT_RECIPE_TEST) ports/catalog.json $(PORT_RECIPE_FILES)
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

ports-openssl-repo-fixture: ports-ca-certificates-repo-fixture $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/security/openssl/Port.json scripts/build-openssl.sh
	./scripts/build-openssl.sh

ports-pcre2-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/devel/pcre2/Port.json scripts/build-pcre2.sh
	./scripts/build-pcre2.sh

ports-tzdata-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) ports/sysutils/tzdata/Port.json scripts/build-tzdata.sh
	./scripts/build-tzdata.sh

ports-curl-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/net/curl/Port.json scripts/build-curl.sh
	./scripts/build-curl.sh

ports-rsync-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/net/rsync/Port.json scripts/build-rsync.sh userland/rsync/swiftos/at_compat.c
	./scripts/build-rsync.sh

ports-nginx-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/www/nginx/Port.json scripts/build-nginx.sh
	./scripts/build-nginx.sh

ports-sqlite-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/databases/sqlite/Port.json scripts/build-sqlite.sh
	./scripts/build-sqlite.sh

# D3: build the SQLite shell binary (and package) so it can be baked into base.img.
# Depends on the userland runtime sources so a stubs.c change (e.g. real fsync)
# rebuilds the shell.
$(SQLITE_BIN): $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/databases/sqlite/Port.json scripts/build-sqlite.sh userland/compat/stubs.c userland/lib/newlib_syscalls.c userland/lib/crt0_newlib.S
	./scripts/build-sqlite.sh

# W1: build the nginx server binary (+ staged config and index.html) for baking
# into base.img. Depends on the userland runtime sources so stub changes rebuild.
# W3: build the openssl static dev libs (and headers) for nginx TLS linking.
# Tool prereqs are order-only so rebuilding swport/swpkg/pkgrepo does not force a
# (slow) openssl recompile; only the recipe/script/libc actually trigger it.
$(OPENSSL_DEV): scripts/build-openssl.sh ports/security/openssl/Port.json $(SYSROOT)/lib/libc.a | $(SWPORT) $(SWPKG) $(PKGREPO)
	./scripts/build-openssl.sh

# W3: a build-time self-signed cert for the HTTPS demo (CN=swift-os, 10y).
$(NGINX_CERT): | $(BUILD)/.dir
	mkdir -p $(BUILD)/nginx-certs
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=swift-os -keyout $(BUILD)/nginx-certs/server.key -out $(NGINX_CERT) >/dev/null 2>&1

$(NGINX_BIN): $(OPENSSL_DEV) $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/www/nginx/Port.json scripts/build-nginx.sh userland/compat/stubs.c userland/lib/newlib_syscalls.c userland/lib/crt0_newlib.S
	./scripts/build-nginx.sh

# NPM26: assert the current Node.js cross-build frontier. Vanilla Node
# configure.py rejects --dest-os=swiftos; this probe fetches+verifies the
# pinned source and confirms the build stops exactly at that documented wall.
node-configure-probe: $(SYSROOT)/lib/libc.a ports/lang/nodejs/Port.json scripts/build-node.sh
	./scripts/build-node.sh

# node-test / npm-test: opt-in runtime checks for the cross-built Node binary.
# They are deliberately NOT part of `make test` and NOT default `base-image`
# prerequisites — node.elf is ~57 MB and packing it bloats every image build/sign
# and the disk QEMU loads. These targets force a node-inclusive repack
# (INCLUDE_NODE=1) and use the 2 GiB DTB for V8 heap headroom. node.elf must
# already exist (built out-of-band in Docker; see the $(USER_NODE_ELF) guard).
# `rm -f $(BASE_IMG)` guarantees the repack happens even when a default
# (node-less) image is newer than node.elf, which make's mtime check would
# otherwise treat as up-to-date.
.PHONY: node-test npm-test
node-test: build $(QEMU_DTB_2048) $(USER_NODE_ELF)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_NODE=1
	NODE_DTB=$(QEMU_DTB_2048) bash tests/node_test.sh

npm-test: build $(QEMU_DTB_2048) $(USER_NODE_ELF)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_NODE=1
	NODE_DTB=$(QEMU_DTB_2048) bash tests/npm_test.sh

ports-seed-repo-fixture: $(SWPORT) $(SWPKG) $(PKGREPO) $(SYSROOT)/lib/libc.a ports/catalog.json $(PORT_RECIPE_FILES) $(PORT_BUILD_SCRIPTS)
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

package-remove-test: build $(QEMU_DTB) base-image package-fixture $(PKG_EMPTY_STORE_IMG)
	./tests/pkg_remove_test.sh

package-repo-install-test: build $(QEMU_DTB) base-image package-local-install-fixture package-repo-fixture
	./tests/pkg_repo_install_test.sh

package-lua-repo-install-test: build $(QEMU_DTB) base-image package-lua-install-fixture ports-lua-repo-fixture
	./tests/pkg_lua_repo_install_test.sh

package-ports-seed-repo-install-test: build $(QEMU_DTB) package-lua-install-fixture ports-seed-repo-fixture
	./tests/pkg_ports_seed_repo_install_test.sh

# R1: install the rsync port from a signed repo over the network and run
# `rsync --version` in QEMU. Builds rsync.swpkg + a one-package trusted repo.
rsync-test: build busybox $(QEMU_DTB) package-lua-install-fixture ports-rsync-repo-fixture
	./tests/rsync_test.sh

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

$(BASE_IMG): $(BASEPACK) $(BASE_SEED_FILES) $(BASE_EXEC_ELFS) $(PKGHELLO_PKG) $(PKGREPO_PUB) $(MODEL_BIN) $(MODEL_TOK) $(MODEL15_Q8) $(MODEL_TOK32) $(MODELMANIFEST) $(MODELSIGN) $(SIGNING_SEED) $(SIGNING_PUB) $(IMG_SIGNING_SEED) $(IMG_SIGNING_PUB) $(SSHD_HOST_SEED_FILE) $(SSHD_KEX_SEED_FILE) $(SSHD_AUTHORIZED_KEYS_FILE) $(NET_IPV6_CONFIG_FILE) $(SWOS_SERVICES_FILE) $(SQLITE_BIN) $(NGINX_BIN) $(NGINX_CERT) $(SITE_SIGNING_PUB) $(SITE_TEST_DEPS) $(OS_STAGE_DEPS) $(KINSTALL_TEST_DEPS) Makefile
	rm -rf $(BASE_ROOT)
	mkdir -p $(BASE_ROOT)
	cp -R base/. $(BASE_ROOT)/
	if [ -n "$(ROOT_LOGIN_SHELL)" ]; then perl -i -pe 's{^(root(?::[^:]*){4}:).*$$}{$${1}$(ROOT_LOGIN_SHELL)}' $(BASE_ROOT)/etc/swos/passwd; fi
	if [ -n "$(SSHD_HOST_SEED_FILE)" ]; then cp "$(SSHD_HOST_SEED_FILE)" $(BASE_ROOT)/etc/ssh/ssh_host_ed25519_seed; fi
	if [ -n "$(SSHD_KEX_SEED_FILE)" ]; then cp "$(SSHD_KEX_SEED_FILE)" $(BASE_ROOT)/etc/ssh/ssh_kex_seed; fi
	if [ -n "$(SSHD_AUTHORIZED_KEYS_FILE)" ]; then cp "$(SSHD_AUTHORIZED_KEYS_FILE)" $(BASE_ROOT)/etc/ssh/authorized_keys; fi
	if [ -n "$(NET_IPV6_CONFIG_FILE)" ]; then cp "$(NET_IPV6_CONFIG_FILE)" $(BASE_ROOT)/etc/swos/net-ipv6; fi
	if [ -n "$(SWOS_SERVICES_FILE)" ]; then cp "$(SWOS_SERVICES_FILE)" $(BASE_ROOT)/etc/swos/services; fi
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
	cp $(SQLITE_BIN) $(BASE_ROOT)/bin/sqlite3
	mkdir -p $(BASE_ROOT)/sbin $(BASE_ROOT)/usr/etc/nginx $(BASE_ROOT)/usr/share/nginx/html
	cp $(NGINX_BIN) $(BASE_ROOT)/sbin/nginx
	if [ -n "$(NGINX_SITE_DIR)" ]; then cp -R "$(NGINX_SITE_DIR)/." $(BASE_ROOT)/usr/share/nginx/html/; else cp $(BUILD)/nginx-root/usr/share/nginx/html/index.html $(BASE_ROOT)/usr/share/nginx/html/index.html; fi
	mkdir -p $(BASE_ROOT)/usr/etc/nginx/certs
	cp $(BUILD)/nginx-certs/server.crt $(BUILD)/nginx-certs/server.key $(BASE_ROOT)/usr/etc/nginx/certs/
	mkdir -p $(BASE_ROOT)/etc/swupdate
	cp $(SITE_SIGNING_PUB) $(BASE_ROOT)/etc/swupdate/site-root.pub
	cp $(IMG_SIGNING_PUB) $(BASE_ROOT)/etc/swupdate/os-root.pub
	$(SITE_TEST_PACK_CMD)
	$(OS_STAGE_PACK_CMD)
	$(KINSTALL_TEST_PACK_CMD)
	cp $(USER_SWOSINIT_ELF) $(BASE_ROOT)/bin/swos-init
	cp $(USER_TTYDEMO_ELF) $(BASE_ROOT)/bin/ttydemo
	cp $(USER_ARGVDEMO_ELF) $(BASE_ROOT)/bin/argvdemo
	cp $(USER_SPAWNDEMO_ELF) $(BASE_ROOT)/bin/spawndemo
	cp $(USER_SELFEXECDEMO_ELF) $(BASE_ROOT)/bin/selfexecdemo
	cp $(USER_FSDEMO_ELF) $(BASE_ROOT)/bin/fsdemo
	cp $(USER_BRKDEMO_ELF) $(BASE_ROOT)/bin/brkdemo
	cp $(USER_NEWLIBTEST_ELF) $(BASE_ROOT)/bin/newlibtest
	cp $(USER_CLOCKPROBE_ELF) $(BASE_ROOT)/bin/clockprobe
	cp $(USER_MPROTECTPROBE_ELF) $(BASE_ROOT)/bin/mprotectprobe
	cp $(USER_LARGEMMAPPROBE_ELF) $(BASE_ROOT)/bin/largemmapprobe
	cp $(USER_MMAPRESERVEPROBE_ELF) $(BASE_ROOT)/bin/mmapreserveprobe
	cp $(USER_MAPFIXEDPROBE_ELF) $(BASE_ROOT)/bin/mapfixedprobe
	cp $(USER_PTHREADPROBE_ELF) $(BASE_ROOT)/bin/pthreadprobe
	cp $(USER_FUTEXPROBE_ELF) $(BASE_ROOT)/bin/futexprobe
	cp $(USER_THREADSYNCPROBE_ELF) $(BASE_ROOT)/bin/threadsyncprobe
	cp $(USER_SELECTPROBE_ELF) $(BASE_ROOT)/bin/selectprobe
	cp $(USER_EVENTFDPROBE_ELF) $(BASE_ROOT)/bin/eventfdprobe
	cp $(USER_EPOLLPROBE_ELF) $(BASE_ROOT)/bin/epollprobe
	$(NODE_PACK_CMD)
	cp $(USER_UVWAKEPROBE_ELF) $(BASE_ROOT)/bin/uvwakeprobe
	cp $(USER_UVSEMPROBE_ELF) $(BASE_ROOT)/bin/uvsemprobe
	cp $(USER_UVRWLOCKPROBE_ELF) $(BASE_ROOT)/bin/uvrwlockprobe
	cp $(USER_UVMUTEXPROBE_ELF) $(BASE_ROOT)/bin/uvmutexprobe
	cp $(USER_UVTHREADNAMEPROBE_ELF) $(BASE_ROOT)/bin/uvthreadnameprobe
	cp $(USER_UVTHREADSTACKPROBE_ELF) $(BASE_ROOT)/bin/uvthreadstackprobe
	cp $(USER_UVKEYONCEPROBE_ELF) $(BASE_ROOT)/bin/uvkeyonceprobe
	cp $(USER_UVENVPROBE_ELF) $(BASE_ROOT)/bin/uvenvprobe
	cp $(USER_ENVCHILD_ELF) $(BASE_ROOT)/bin/envchild
	cp $(USER_UVBARRIERPROBE_ELF) $(BASE_ROOT)/bin/uvbarrierprobe
	cp $(USER_UVCONDPROBE_ELF) $(BASE_ROOT)/bin/uvcondprobe
	cp $(USER_UVSOCKETPAIRPROBE_ELF) $(BASE_ROOT)/bin/uvsocketpairprobe
	cp $(USER_UVSIGNALPROBE_ELF) $(BASE_ROOT)/bin/uvsignalprobe
	cp $(USER_UVATFORKPROBE_ELF) $(BASE_ROOT)/bin/uvatforkprobe
	cp $(USER_UVSPAWNPROBE_ELF) $(BASE_ROOT)/bin/uvspawnprobe
	cp $(USER_SIGNALPROBE_ELF) $(BASE_ROOT)/bin/signalprobe
	cp $(USER_PTYSIGPROBE_ELF) $(BASE_ROOT)/bin/ptysigprobe
	cp $(USER_SOCKETPROBE_ELF) $(BASE_ROOT)/bin/socketprobe
	cp $(USER_COPROC_ELF) $(BASE_ROOT)/bin/coproc
	cp $(USER_FORKDEMO_ELF) $(BASE_ROOT)/bin/forkdemo
	cp $(USER_EXECDEMO_ELF) $(BASE_ROOT)/bin/execdemo
	cp $(USER_ORPHANDEMO_ELF) $(BASE_ROOT)/bin/orphandemo
	cp $(USER_QW2IPC_ELF) $(BASE_ROOT)/bin/qw2-ipc
	cp $(USER_IPCCALL_ELF) $(BASE_ROOT)/bin/ipc-call-test
	cp $(USER_FDOPSDEMO_ELF) $(BASE_ROOT)/bin/fdopsdemo
	cp $(USER_S4STRESS_ELF) $(BASE_ROOT)/bin/s4stress
	cp $(USER_SATSTRESS_ELF) $(BASE_ROOT)/bin/satstress
	cp $(USER_SMPRACE_ELF) $(BASE_ROOT)/bin/smprace
	cp $(USER_EDGESTRESS_ELF) $(BASE_ROOT)/bin/edgestress
	cp $(USER_SECURITYDEMO_ELF) $(BASE_ROOT)/bin/securitydemo
	cp $(USER_DEVICEAUTHDEMO_ELF) $(BASE_ROOT)/bin/deviceauthdemo
	cp $(USER_DEVICEMMAPPROBE_ELF) $(BASE_ROOT)/bin/devicemmapprobe
	cp $(USER_NETMMAPPROBE_ELF) $(BASE_ROOT)/bin/netmmapprobe
	cp $(USER_NETDRIVERPROBE_ELF) $(BASE_ROOT)/bin/netdriverprobe
	cp $(USER_NETSVC_ELF) $(BASE_ROOT)/bin/netsvc
	cp $(USER_NETSVCDEMO_ELF) $(BASE_ROOT)/bin/netsvc-demo
	cp $(USER_IDENTITYDEMO_ELF) $(BASE_ROOT)/bin/identitydemo
	cp $(USER_CONSOLELOGIN_ELF) $(BASE_ROOT)/bin/console-login
	cp $(USER_PASSWD_ELF) $(BASE_ROOT)/bin/passwd
	cp $(USER_PS_ELF) $(BASE_ROOT)/bin/ps
	cp $(USER_SLEEPPROBE_ELF) $(BASE_ROOT)/bin/sleepprobe
	cp $(USER_SIMDPROBE_ELF) $(BASE_ROOT)/bin/simdprobe
	cp $(USER_CELLSTATPROBE_ELF) $(BASE_ROOT)/bin/cellstatprobe
	cp $(USER_PROCMAXPROBE_ELF) $(BASE_ROOT)/bin/procmaxprobe
	cp $(USER_CELLCHILD_ELF) $(BASE_ROOT)/bin/cellchild
	cp $(USER_CELLCREATEPROBE_ELF) $(BASE_ROOT)/bin/cellcreateprobe
	cp $(USER_CELLNSCHILD_ELF) $(BASE_ROOT)/bin/cellnschild
	cp $(USER_CELLNSPROBE_ELF) $(BASE_ROOT)/bin/cellnsprobe
	cp $(USER_CELLCAPPROBE_ELF) $(BASE_ROOT)/bin/cellcapprobe
	cp $(USER_CELLHELLO_ELF) $(BASE_ROOT)/bin/cellhello
	cp $(USER_CELLSVCPROBE_ELF) $(BASE_ROOT)/bin/cellsvcprobe
	cp $(USER_CELLGROWER_ELF) $(BASE_ROOT)/bin/cellgrower
	cp $(USER_CELLGROWPROBE_ELF) $(BASE_ROOT)/bin/cellgrowprobe
	cp $(USER_CELLOPENER_ELF) $(BASE_ROOT)/bin/cellopener
	cp $(USER_CELLHANDLEPROBE_ELF) $(BASE_ROOT)/bin/cellhandleprobe
	cp $(USER_CELLSVC_ELF) $(BASE_ROOT)/bin/cell-svc
	cp $(USER_CELLSUPERVISOR_ELF) $(BASE_ROOT)/bin/cell-supervisor
	cp $(USER_CELLKVSUPERVISOR_ELF) $(BASE_ROOT)/bin/cell-kv-supervisor
	cp $(USER_PTYPROBE_ELF) $(BASE_ROOT)/bin/ptyprobe
	cp $(USER_PTYRUN_ELF) $(BASE_ROOT)/bin/ptyrun
	cp $(USER_ID_ELF) $(BASE_ROOT)/bin/id
	cp $(USER_SUDO_ELF) $(BASE_ROOT)/bin/sudo
	cp $(USER_REBOOT_ELF) $(BASE_ROOT)/bin/reboot
	cp $(USER_SHUTDOWN_ELF) $(BASE_ROOT)/bin/shutdown
	cp $(USER_LOGTAIL_ELF) $(BASE_ROOT)/bin/logtail
	cp $(USER_LOGTAILPROBE_ELF) $(BASE_ROOT)/bin/logtail-probe
	cp $(USER_SWOSCONFIRM_ELF) $(BASE_ROOT)/bin/swos-confirm
	cp $(USER_SWOSACTIVATE_ELF) $(BASE_ROOT)/bin/swos-activate
	cp $(USER_SWOSUPDATE_ELF) $(BASE_ROOT)/bin/swos-update
	cp $(USER_SWOSKSTAGE_ELF) $(BASE_ROOT)/bin/swos-kstage
	cp $(USER_SWOSKACTIVATE_ELF) $(BASE_ROOT)/bin/swos-kactivate
	cp $(USER_SWOSKCONFIRM_ELF) $(BASE_ROOT)/bin/swos-kconfirm
	cp $(USER_SWOSKINSTALL_ELF) $(BASE_ROOT)/bin/swos-kinstall
	cp $(USER_SWOSSTAGEBASE_ELF) $(BASE_ROOT)/bin/swos-stagebase
	cp $(USER_LS_ELF) $(BASE_ROOT)/bin/ls
	cp $(USER_SWUPDATE_ELF) $(BASE_ROOT)/bin/swupdate
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
	cp $(USER_CROND_ELF) $(BASE_ROOT)/bin/crond
	cp $(USER_CALC_ELF) $(BASE_ROOT)/bin/calc
	cp $(USER_LLM_ELF) $(BASE_ROOT)/bin/llm
	cp $(USER_LLMD_ELF) $(BASE_ROOT)/bin/llmd
	cp $(USER_KV_ELF) $(BASE_ROOT)/bin/kv
	cp $(USER_HEAD_ELF) $(BASE_ROOT)/bin/head
	cp $(USER_TOUCH_ELF) $(BASE_ROOT)/bin/touch
	cp $(USER_WC_ELF) $(BASE_ROOT)/bin/wc
	cp $(USER_TOP_ELF) $(BASE_ROOT)/bin/top
	cp $(USER_NETINFO_ELF) $(BASE_ROOT)/bin/netinfo
	cp $(USER_UDPECHO_ELF) $(BASE_ROOT)/bin/udpecho
	cp $(USER_TCPECHO_ELF) $(BASE_ROOT)/bin/tcpecho
	cp $(USER_THREADSDEMO_ELF) $(BASE_ROOT)/bin/threadsdemo
	cp $(USER_MMAPDEMO_ELF) $(BASE_ROOT)/bin/mmapdemo
	cp $(USER_TCPGET_ELF) $(BASE_ROOT)/bin/tcpget
	cp $(USER_TLSGET_ELF) $(BASE_ROOT)/bin/tlsget
	cp $(USER_ACME_ELF) $(BASE_ROOT)/bin/acme
	cp $(USER_SCTLD_ELF) $(BASE_ROOT)/bin/sctld
	cp $(USER_SLET_ELF) $(BASE_ROOT)/bin/slet
	cp $(USER_HTTPD_ELF) $(BASE_ROOT)/bin/httpd
	cp $(USER_SSH_ELF) $(BASE_ROOT)/bin/ssh
	cp $(USER_SSHD_ELF) $(BASE_ROOT)/bin/sshd
	cp $(USER_NSLOOKUP_ELF) $(BASE_ROOT)/bin/nslookup
	cp $(USER_C4B_SOCKXFER_ELF) $(BASE_ROOT)/bin/c4b-sockxfer
	cp $(USER_SHMRINGPROBE_ELF) $(BASE_ROOT)/bin/shmringprobe
	cp $(USER_QW4_BADGE_ELF) $(BASE_ROOT)/bin/qw4-badge
	cp $(USER_QW5_RIGHTSXFER_ELF) $(BASE_ROOT)/bin/qw5-rightsxfer
	cp $(USER_DRVINPUTD_ELF) $(BASE_ROOT)/bin/drvinputd
	cp $(USER_DRVSVCDEMO_ELF) $(BASE_ROOT)/bin/drvsvcdemo
	cp $(USER_SVC_INPUT_ELF) $(BASE_ROOT)/bin/svc-input
	cp $(USER_INPUTD_ELF) $(BASE_ROOT)/bin/inputd
	cp $(USER_SVC_SUPERVISOR_ELF) $(BASE_ROOT)/bin/svc-supervisor
	cp $(USER_PKG_ELF) $(BASE_ROOT)/bin/pkg
	cp $(BUILD)/busybox.elf $(BASE_ROOT)/bin/busybox
	$(NCURSES_PACK_CMD)
	$(GLIBDEMO_PACK_CMD)
	$(MC_PACK_CMD)
	$(BASH_PACK_CMD)
	$(ZSH_PACK_CMD)
	$(BASEPACK) $(BASE_ROOT) $@ $(IMG_SIGNING_SEED)

base-image: $(BASE_IMG)

newlib:
	./scripts/build-newlib.sh

busybox:
	./scripts/build-busybox.sh

# busybox.elf is produced by `make busybox` (slow; needs newlib + network).
$(BUILD)/busybox.elf:
	@echo "busybox not built. Run: make busybox" >&2; exit 1

# NC1: cross-build static ncurses + the ncdemo proof binary.
ncurses:
	./scripts/build-ncurses.sh

# ncdemo.elf is produced by `make ncurses` (slow; needs newlib + network + host
# tic/infocmp). Like busybox it must run before `make base-image`.
$(BUILD)/ncdemo.elf:
	@echo "ncurses demo not built. Run: make ncurses" >&2; exit 1

# GL1: cross-build static GLib 2.56 core + the glibdemo proof binary.
glib:
	./scripts/build-glib.sh

# glibdemo.elf is produced by `make glib` (slow; needs newlib + zlib + network).
# Like busybox it must run before `make base-image`.
$(BUILD)/glibdemo.elf:
	@echo "glib demo not built. Run: make glib" >&2; exit 1

# MC1: cross-build Midnight Commander (needs `make ncurses` + `make glib` first).
mc:
	./scripts/build-mc.sh

# mc.elf is produced by `make mc` (slow; needs newlib + ncurses + glib + zlib).
# Like busybox it must run before `make base-image`.
$(BUILD)/mc.elf:
	@echo "Midnight Commander not built. Run: make mc" >&2; exit 1

# SH1: cross-build GNU bash (needs `make ncurses` first for readline + curses).
bash:
	./scripts/build-bash.sh

# bash-test: boot the base image and verify bash starts, runs compound commands,
# and exits cleanly. Requires `make bash` + `make base-image` first.
bash-test: build $(QEMU_DTB)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_BASH=1
	./tests/bash_test.sh

# bash.elf is produced by `make bash` (needs newlib + ncurses + network).
# Must run before `make base-image`.
$(BUILD)/bash.elf:
	@echo "bash not built. Run: make bash" >&2; exit 1

# SH2: cross-build zsh (needs `make ncurses` first for ZLE + terminal library).
zsh:
	./scripts/build-zsh.sh

# zsh-test: boot the base image and verify zsh starts, runs arrays/functions,
# and exits cleanly. Requires `make zsh` + `make base-image` first.
zsh-test: build $(QEMU_DTB)
	rm -f $(BASE_IMG)
	$(MAKE) base-image INCLUDE_ZSH=1
	./tests/zsh_test.sh

# zsh.elf is produced by `make zsh` (needs newlib + ncurses + network).
# Must run before `make base-image`.
$(BUILD)/zsh.elf:
	@echo "zsh not built. Run: make zsh" >&2; exit 1

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
		$(BUILD)/openssl-port-work $(BUILD)/openssl-port-runtime $(BUILD)/openssl-root $(BUILD)/openssl-repo-root $(BUILD)/openssl-repo-root.pub \
		$(BUILD)/pcre2-port-work $(BUILD)/pcre2-port-runtime $(BUILD)/pcre2-root $(BUILD)/pcre2-repo-root $(BUILD)/pcre2-repo-root.pub \
		$(BUILD)/tzdata-port-work $(BUILD)/tzdata-root $(BUILD)/tzdata-repo-root $(BUILD)/tzdata-repo-root.pub \
		$(BUILD)/nginx-port-work $(BUILD)/nginx-root $(BUILD)/nginx-repo-root $(BUILD)/nginx-repo-root.pub $(BUILD)/nginx \
		$(BUILD)/sqlite-port-work $(BUILD)/sqlite-port-runtime $(BUILD)/sqlite-root $(BUILD)/sqlite-repo-root $(BUILD)/sqlite-repo-root.pub \
		$(BUILD)/rsync-port-work $(BUILD)/rsync-port-runtime $(BUILD)/rsync-root $(BUILD)/rsync-repo-root $(BUILD)/rsync-repo-root.pub $(BUILD)/rsync-test-repo $(BUILD)/base-rsync-repo.img \
		$(BUILD)/base-ports-seed-repo.img $(BUILD)/base-ports-static-host.img $(BUILD)/base-ports-static-host-dns.img $(BUILD)/base-hosted-url.img $(ESP_DIR)

# Print the resolved toolchain so failures are easy to diagnose.
tools-check:
	@echo "SWIFTC  = $(SWIFTC)";  $(SWIFTC) --version | head -1
	@echo "HOST_SWIFTC = $(HOST_SWIFTC)"; $(HOST_SWIFTC) --version | head -1
	@echo "CLANG   = $(CLANG)";   $(CLANG) --version | head -1
	@echo "LDBIN   = $(LDBIN)";   $(LDBIN) --version | head -1
	@echo "OBJCOPY = $(OBJCOPY)"; $(OBJCOPY) --version | head -1
	@echo "QEMU    = $(QEMU)";    $(QEMU) --version | head -1
