# NOTES

Engineering log: accepted decisions, hardware constants, exact build/run commands, and tool versions.
Newest notes at the top of each section.

## Environment (host) — captured 2026-06-04

Host: macOS (Darwin 25.5.0), Apple Silicon (arm64, T6050).

| Tool                | Status        | Version / notes                                                            |
|---------------------|---------------|----------------------------------------------------------------------------|
| `swift` / `swiftc`  | present       | Apple Swift 6.3.2 — **Command Line Tools only**                            |
| Embedded Swift      | **missing**   | CLT does not ship the embedded stdlib; `arm64-apple-none-elf` fails to load |
| `clang`             | present       | Apple clang 21 (Darwin target only; no ELF cross out of the box)           |
| `qemu-system-aarch64` | **missing** | available via Homebrew                                                      |
| `lld` / `llvm-objcopy` | **missing** | available via Homebrew (`llvm`, `lld`)                                      |
| `aarch64-elf-binutils` | **missing** | available via Homebrew                                                      |
| `aarch64-elf-gdb`   | **missing**   | available via Homebrew; `lldb` is present and can do remote aarch64        |
| `make`, `git`       | present       | —                                                                          |
| Network             | **up**        | Homebrew (`/opt/workbrew/bin/brew`) usable                                 |

### Resolution (installed 2026-06-04)

- **Brew tools installed:** `qemu` 11.0.1, `llvm` 22.1.6 (clang + `llvm-objcopy`),
  `aarch64-elf-binutils` (`aarch64-elf-ld`), `aarch64-elf-gdb`.
- **Embedded Swift toolchain:** swift.org **6.3.2-RELEASE**, extracted user-locally (no sudo) to
  `~/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain` via
  `pkgutil --expand-full`. It ships `usr/lib/swift/embedded/` including the
  **`aarch64-none-none-elf`** target — exactly what we build for.
- **Pinned target triple:** `aarch64-none-none-elf`.
- **Pinned Embedded Swift flags:**
  `-target aarch64-none-none-elf -enable-experimental-feature Embedded -wmo -parse-as-library -Osize -Xllvm -mattr=+strict-align,-neon -Xfrontend -function-sections -import-objc-header kernel/arch/aarch64/io.h`
  - `+strict-align,-neon` is an early-boot guardrail: with the MMU off, QEMU can fault on
    unaligned SIMD accesses that Swift may otherwise generate for ordinary value copies.
- **Linker:** GNU `aarch64-elf-ld` (`--gc-sections -nostdlib -T kernel.ld`). `ld.lld` is keg-only
  under a separate prefix; binutils `ld` is simpler for a custom script.
- **MMIO:** volatile access via C inlines in `kernel/arch/aarch64/io.h` (bridging header).
  The toolchain also ships a `_Volatile` embedded module — a possible modern refinement later.

### Toolchain gap analysis (historical — resolved above)

- **Embedded Swift stdlib is the blocker.** The Command Line Tools toolchain does not include the
  embedded stdlib for bare-metal ELF targets. Options:
  1. Install a **swift.org open-source toolchain** (`.pkg`) that ships `usr/lib/swift/embedded/` —
     used via `xcrun --toolchain` / `TOOLCHAINS=`.
  2. Install **full Xcode** (ships embedded resources).
  Decision pending — see "Open decisions."
- **C cross-compiler + linker:** use Homebrew `llvm` (clang can target `aarch64-none-elf` with `-ffreestanding`)
  plus `lld` (`ld.lld`) and `llvm-objcopy`. `aarch64-elf-binutils` is a fallback linker/objcopy.
- **Emulator:** Homebrew `qemu` (`qemu-system-aarch64`).
- **Debugger:** Homebrew `aarch64-elf-gdb`, or host `lldb` over the QEMU gdbstub.

### Planned install (pending confirmation)

```sh
brew install qemu llvm lld aarch64-elf-binutils aarch64-elf-gdb
# Swift toolchain with Embedded Swift: install a swift.org toolchain (.pkg) — see ARCHITECTURE/decision.
```

## Hardware constants (QEMU `virt`, aarch64) — verify against QEMU source per version

- RAM base: `0x4000_0000`.
- UART: **PL011** @ `0x0900_0000` (MMIO).
- Interrupt controller: **GICv2** (`arm,cortex-a15-gic`) verified from QEMU 11.0.1 DTB:
  distributor @ `0x0800_0000`, CPU interface @ `0x0801_0000`.
- ARM generic timer: DTB `arm,armv8-timer`; physical timer PPI is interrupt ID **30**
  (`interrupts = <0x01 0x0e ...>`).
- Block/etc devices: **virtio-mmio**.
- Boot: `-kernel <image>`, entry at **EL1**.

> Re-confirm with `qemu-system-aarch64 -M virt,dumpdtb=...` + `dtc`, or the QEMU
> `hw/arm/virt.c` memory map, when QEMU or machine options change.

## Build / run commands (verified at M2)

- `make build` — assemble `boot.S`, compile Swift (WMO) to one object, link with the script,
  emit `build/kernel.elf` (+ `kernel.bin`).
- `make run`   — `qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -kernel build/kernel.elf`.
  Exit QEMU serial with `Ctrl-A X`.
- `make debug` — same + `-s -S` (paused, gdbstub on `:1234`). Then `make gdb` (or lldb) in another shell.
- `make test`  — builds, runs the host page-allocator unit test, then boots QEMU and asserts
  `tick 3` appears on serial within 10 s.
- `make clean` — remove build artifacts.

## Milestone log

- **M2 (2026-06-04) — DONE.** Interrupt and timer bring-up:
  - EL1 vector table now dispatches IRQ entries through an assembly save/restore path and returns
    with `eret`.
  - Minimal GICv2 driver enables the physical timer PPI (ID 30).
  - ARM generic physical timer is configured from `CNTFRQ_EL0`; the kernel logs periodic ticks.
  - `make test` passes and asserts `tick 3` on the QEMU serial console.
- **M1 (2026-06-04) — DONE.** Runtime/memory bring-up:
  - EL1 vector table installed in `boot.S`; unexpected exceptions dump `ESR_EL1`, `ELR_EL1`,
    `FAR_EL1`, `SCTLR_EL1`, and `CPACR_EL1`.
  - Early 256 KiB linker-reserved bump heap, Swift raw allocation hook (`swift_slowAlloc` /
    `swift_slowDealloc`), class allocation support (`posix_memalign` / `free`), and stack
    protector stubs.
  - Physical page allocator added as a Swift bitmap allocator with host unit coverage.
  - Boot probe instantiates and retains a Swift class; `make test` passes.
- **M0 (2026-06-04) — DONE.** Boot skeleton boots on QEMU `virt`; serial prints
  `Hello from Swift kernel`. `make test` passes. Files: `kernel/arch/aarch64/{boot.S,kernel.ld,io.h}`,
  `kernel/drivers/uart.swift`, `kernel/main.swift`, `Makefile`, `tests/boot_test.sh`.

## Open decisions / resolved

- [x] Embedded Swift toolchain → swift.org **6.3.2-RELEASE** (user-local xctoolchain).
- [x] Embedded Swift flags & triple → pinned above (`aarch64-none-none-elf`).
- [x] Linker → `aarch64-elf-ld`.
