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
AAVMF_CODE := /usr/share/qemu/edk2-aarch64-code.fd
HOST_SWIFTC := $(TOOLCHAIN)/usr/bin/swiftc
ARM_GNU_BIN := $(HOME)/.local/arm-gnu-toolchain/bin:$(HOME)/.local/bin
export PATH := $(ARM_GNU_BIN):$(PATH)
endif