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

### Toolchain gap analysis

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
- Interrupt controller: **GIC** (version depends on QEMU `-machine` opts).
- Block/etc devices: **virtio-mmio**.
- Boot: `-kernel <image>`, entry at **EL1**.

> These are reference values. Always re-confirm with `qemu-system-aarch64 -M virt,dumpdtb=...` +
> `dtc`, or the QEMU `hw/arm/virt.c` memory map, for the installed QEMU version.

## Build / run commands

To be finalized at M0 once the toolchain is pinned. Targets: `make build|run|debug|clean|test`.

- `run`:   `qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -kernel build/kernel.elf`
- `debug`: same + `-s -S`, then attach GDB/LLDB to `localhost:1234`.

## Open decisions

- [ ] Which Embedded Swift toolchain (swift.org snapshot vs. release vs. full Xcode)?
- [ ] Confirm exact Embedded Swift flags (`-enable-experimental-feature Embedded -wmo ...`) and the
      target triple the chosen toolchain expects for bare-metal aarch64.
- [ ] Linker: `ld.lld` vs `aarch64-elf-ld`.
