# ci/toolchain.mk — platform-specific toolchain defaults (included by Makefile).
# Version pin mirrors ci/toolchain.env (Make cannot source shell env files).
SWIFT_VERSION := 6.3.2-RELEASE

ifeq ($(UNAME_S),Linux)
TOOLCHAIN := $(HOME)/.swift/toolchains/swift-$(SWIFT_VERSION)
LLVM      := /usr/bin
CLANG     := /usr/bin/clang
OBJCOPY   := /usr/bin/llvm-objcopy
LDBIN     := /usr/bin/ld.lld
LLDLINK   := /usr/bin/lld-link
# Prefer env (ci-export-env) when set; otherwise pick the first firmware blob
# present (Ubuntu qemu-efi-aarch64 uses AAVMF paths; some builds ship edk2).
ifndef AAVMF_CODE
AAVMF_CODE := $(firstword $(wildcard \
	/usr/share/AAVMF/AAVMF_CODE.fd \
	/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd \
	/usr/share/qemu/edk2-aarch64-code.fd \
	/usr/share/qemu-efi-aarch64/QEMU_EFI.fd))
endif
HOST_SWIFTC := $(TOOLCHAIN)/usr/bin/swiftc
ARM_GNU_BIN := $(HOME)/.local/arm-gnu-toolchain/bin:$(HOME)/.local/bin
export PATH := $(ARM_GNU_BIN):$(PATH)
endif