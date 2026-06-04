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
- **Linker:** `ld.lld` (`/opt/homebrew/opt/lld/bin/ld.lld`, `--gc-sections -nostdlib -T kernel.ld`).
  **Switched from GNU `aarch64-elf-ld` at M4.5:** as soon as kernel code uses a Swift `Array`/`String`,
  the compiler emits references to protected-visibility runtime singletons
  (`$es23_swiftEmptyArrayStorage...`). GNU ld rejects these with
  *"copy relocation against non-copyable protected symbol"*; `ld.lld` resolves them directly. lld is
  the linker the Embedded Swift toolchain expects, so this also removes the spurious RWX-segment warning.
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

## Early virtual memory (M3)

- Translation regime: EL1 stage-1, TTBR0 only, 4 KiB granule, 48-bit VA (`T0SZ=16`),
  36-bit PA (`IPS=1`), TTBR1 walks disabled for now.
- MAIR slots:
  - AttrIdx 0: normal write-back/write-allocate cacheable memory (`0xff`).
  - AttrIdx 1: Device-nGnRnE (`0x00`).
- Initial mappings are identity mappings:
  - `0x0000_0000..0x3fff_ffff` as device memory for early MMIO.
  - `0x4000_0000..0x7fff_ffff` as normal memory for RAM/kernel.
- A scratch L3 table under VA `0x8000_0000` is reserved for M3 page map/unmap tests.
- RAM identity mapping is executable during bring-up; device and scratch pages are XN.

## Syscall ABI (M5)

- EL0 syscall entry is `svc #0`.
- `x8` holds the syscall number.
- `x0...x2` hold the first three arguments.
- Return value is written back to `x0`.
- Implemented bring-up calls:
  - `1 open(path, flags)` — supports `/hello.txt`, read-only.
  - `2 read(fd, buffer, count)` — reads from fd 3.
  - `3 write(fd, buffer, count)` — writes fd 1/2 to UART.
  - `4 close(fd)` — closes fd 3.
  - `5 exit(status)` — records M5 success.
  - `6 lseek(fd, offset, whence)` — implemented for fd 3.
- M7 additions: `2 read` from fd 0 is served by the tty; `5 exit` unwinds an active process to the
  kernel; `7 tcgetattr` / `8 tcsetattr`; `9 sigaction`; `10 kill`; `11 getpid`.
- M8d additions include process control plus `22 psinfo(buffer, capacity)`: copies fixed 32-byte
  process records (`pid`, `ppid`, state, short command name) for userland tools such as `/bin/ps`.

## Build / run commands (verified at M9)

- `make build` — assemble `boot.S`, compile Swift (WMO) to one object, link with the script,
  emit `build/kernel.elf` (+ `kernel.bin`).
- `make run`   — `qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -kernel build/kernel.elf`.
  Exit QEMU serial with `Ctrl-A X`.
- `make debug` — same + `-s -S` (paused, gdbstub on `:1234`). Then `make gdb` (or lldb) in another shell.
- `make test`  — host page-allocator unit test, userland ELF sanity check, then QEMU boot asserts
  (M6: `hello from ELF userland` + exit code 7) and a scripted interactive tty test (M7: echo +
  Ctrl-C/SIGINT interruption).
- `make clean` — remove build artifacts.

## Milestone log

- **M9 (2026-06-04) — DONE.** HAL + runtime hardware discovery from a flattened device tree. Added a
  pure Swift FDT reader with host coverage, a global `Platform` populated at boot, and driver/PMM use of
  discovered UART/GIC/RAM values. `make run`/`make test` now dump QEMU's actual `virt` DTB and load it
  into the direct-boot fallback address (`0x4FF0_0000` for `-m 256M`); boot asserts
  `M9 OK: hardware discovered from device tree`. The parser avoids large unaligned value-copy layouts in
  the early boot path because strict alignment checks are active.

- **M8 (2026-06-04) — DONE: toward busybox.** Staged sub-milestones; libc strategy = cross-build newlib.
  - **Swift `/bin/ps` utility — DONE.** Added `SYS_PSINFO` (22), short process names captured from
    `argv[0]`, and an Embedded Swift EL0 utility (`userland/ps.swift`) linked through a tiny C
    syscall/runtime bridge. `/bin/ps` is embedded in the kernel image and asserted in `boot_test.sh`.
    Supported syntax with today's process data: `ps`, `ps -e`, `ps -A`, `ps -ef`, `ps ax`,
    `ps aux`, `ps -aux`, `ps -p pid[,pid...]`, and `ps -o pid,ppid,state,stat,user,uid,cmd` (plus aliases
    `comm`/`command`/`args` for `cmd`). CPU, memory, tty, and time columns need more kernel accounting.
  - **(a1) Full trap frame — DONE.** `exceptions.S` now saves/restores a complete frame (x0..x30 +
    SP_EL0/ELR_EL1/SPSR_EL1) on every lower-EL entry, making exceptions nestable. This resolves the M7
    constraint: `read(0)` is back to a clean `enable_irq` + `wfi` block (validated — it panicked before
    the frame, passes now), and it unblocks preemptive EL0 scheduling. No regressions: M5/M6/M7 green.
  - **(a2-argv) Process arguments — DONE.** `ustack.c` builds the SysV AArch64 entry stack
    (argc/argv/envp/auxv) at the top of the process's user stack; `crt0.S` reads argc from `[sp]`,
    argv from `sp+8`, and computes envp. `processRunElf` takes packed NUL-separated args; `packArgs`
    builds them in Swift. New `argvdemo` prints its argv (`argv[0]=argvdemo argv[1]=alpha argv[2]=beta`,
    exits argc=3). `boot_test.sh` generalized to assert a list of lines (M6 + M8a argv).
  - **(a2-spawn) Nested process launch — DONE.** Process runs are now a depth stack: `process.swift`
    tracks per-level return context, child address space, and exit status, and unwinds the innermost
    level to its launcher on `SYS_exit`/signal, restoring the parent's `TTBR0`. New `spawn(path, argv)`
    syscall (12) resolves an embedded program (`exec.swift` built-in table) and runs it synchronously
    (= fork+exec+wait, since we have no COW), returning the child's exit status; `waitpid` (13) is a
    stub (ECHILD) because spawn is synchronous. Demo: `spawndemo` (EL0) spawns `/bin/argvdemo`
    (own address space), gets status 2, continues — proving the shell-launches-command model.
  - **(b) Real VFS — DONE.** `vfs.swift` rewritten as a fixed vnode table (parent/child/sibling inode
    tree) with a read-only base (`/`, `/bin`, `/etc/{motd,hostname}`, `/readme.txt`, `/hello.txt`) and a
    writable tmpfs at `/tmp`. Implements `open` (incl. `O_CREAT` in tmpfs), `read`, `write` (tmpfs +
    stdout/stderr), `close`, `lseek`, `stat`/`fstat` (14/15), `getdents` (16), `chdir` (17), `getcwd`
    (18); path resolution handles absolute/relative, `.`/`..`. Userland `lib/fs.h` mirrors the
    `stat`/`dirent` layouts. Demo `fsdemo` lists `/`, cats `/etc/motd`, stats, `chdir /etc`+`getcwd`,
    and round-trips a `/tmp/note` file — all asserted in `boot_test.sh`.
  - **(c1) User heap via sbrk — DONE.** Per-process heap region at `0xA000_0000`; `sbrk(incr)` syscall
    (19) grows it on demand, mapping pages from the PMM into the process address space (tracked per
    nesting level in `process.swift`). `brkdemo` writes/reads across a page boundary → OK. This is the
    foundation newlib's malloc/_sbrk will use.
  - **(c2) newlib port — DONE.** Cross-built **newlib 4.6.0.20260123** for `aarch64-elf` with the
    Homebrew `aarch64-elf-gcc` 16.1.0 toolchain (`--disable-newlib-supplied-syscalls`), installed under
    `./sysroot` (gitignored; reproducible via `scripts/build-newlib.sh` / `make newlib`). libgloss is not
    used. Our bottom end: `userland/lib/newlib_syscalls.c` implements `_read/_write/_open/_close/_lseek/`
    `_fstat/_stat/_isatty/_sbrk/_exit/_kill/_getpid` + `environ` over the `svc` ABI; `crt0_newlib.S`
    passes argv and calls newlib `exit()` (flushes stdio); `user_newlib.ld` uses PHDRS for separate
    RX/RW segments (no RWX) so newlib's writable globals work. `newlibtest` (built with `aarch64-elf-gcc`)
    runs `printf`, `malloc`/`free`, and `fopen`/`fgets` of `/etc/motd` on the OS — all pass.
    **Prerequisite:** run `make newlib` once before `make build` (kernel embeds the newlib program).
  - Remaining: (d) process subsystem + cross-build busybox; (e) run `sh`. **Decisions (locked):**
    eager-copy `fork` (no COW) + `execve` + real `waitpid` + preemptive EL0 multitasking; busybox config
    minimal (ash + ls/cat/echo only).

### M8d plan — process subsystem for fork/exec/wait + busybox (the finale)

This is the largest single step: it replaces the current **synchronous nested** process model (all demos
call `processRunElf` and get a return value) with a **real process table + preemptive EL0 scheduler**,
because `fork` needs parent and child alive at once. Staged:

  - **d1 — Unified preemptive process model — DONE.** `process.swift` rewritten as a real process table
    {state, ppid, ttbr0, kernel stack, CPUContext, exit status, wait target, brk}. A dedicated scheduler
  context (the kernel_main stack) switches into a runnable process and regains control when it yields,
  blocks, is preempted, or exits. The timer preempts the current EL0 process (`processOnTick` →
  `yieldToScheduler`, safe thanks to the M8a1 trap frame); tick rate raised to 100 Hz and per-tick
  logging silenced. `processRunElf` launches a top process and runs the scheduler until it exits;
  `spawn` blocks the parent and the same loop runs the child then wakes the parent (foundation for
  fork/waitpid). A new `coproc` demo runs **two** EL0 processes that interleave under preemption
  (`coproc A/B iter 0..2` in alternation) → real preemptive multitasking proven. All prior demos
  (M5–M8c) and the interactive tty/Ctrl-C test still pass.
  - NOTE: process teardown does not yet reclaim frames (AS/stacks/heap) — a follow-up.
  - NOTE: per-process fd table/cwd still global in the VFS — fine while one EL0 process uses fds at a
    time; will move into the process struct when fork needs fd inheritance (d2/d4).
- **Security test hardening — DONE.** Added an embedded `securitydemo` EL0 program to the boot test. It
  sends invalid-but-non-faulting syscall arguments (bad fds, NULL buffers/paths/statbuf, read-only writes,
  too-small `getcwd`, below-base `sbrk`, `waitpid` with no children) and asserts errno-ish returns. The
  first run exposed a real EL1 trap: signed syscall args such as fd `-1` were decoded with trapping
  `Int(UInt.max)` conversions. `syscallDispatch` now decodes signed fd/offset/whence fields with
  `Int(bitPattern:)`. Host PMM tests now also cover reserve idempotence, fragmentation, exhaustion, and
  double-free behavior.
- **User pointer hardening — DONE.** Added `kernel/user/user_access.swift` and moved VFS, TTY, termios,
  and spawn argv/path handling away from direct EL0 pointer dereferences. Syscalls now reject kernel/device
  addresses, unmapped user pages, integer-overflowed ranges, and huge lengths before copying or scanning
  user buffers. `securitydemo` now exercises faulting-class inputs (`0x4000_0000` kernel identity map and
  unmapped user VAs) without panicking the kernel.
- **d2 — `fork()` + first real `waitpid` — DONE.** `SYS_fork` (20) eager-copies the current process
  address space, preserving user page permissions, and clones the saved trap frame onto a fresh child
  kernel stack with child `x0=0`; the parent gets the child pid. `waitpid` can now block on a direct
  child and reap its zombie, writing a minimal status word. `forkdemo` proves parent/child split,
  private copied data (`marker` stays `7` in parent while child writes `42`), child exit status `42`,
  and parent wake/reap.
- **Per-process VFS state — DONE.** `cwd` and fd tables are now keyed by process slot instead of global
  kernel state. New processes start from `/` with empty user fds; forked children inherit a snapshot of
  parent cwd and open fds. `forkdemo` now verifies inherited cwd (`/etc`) and inherited open fd
  (`hostname`) in the child.
- **d3 — `execve(path, argv, envp)` — DONE.** `SYS_execve` (21) resolves an embedded executable path,
  packs argv from the old address space, builds a fresh address space + stack, rewrites the current trap
  frame (`SP_EL0`/`ELR_EL1`/`SPSR_EL1`), switches `TTBR0`, and returns from the syscall directly into the
  new image. `execdemo` replaces itself with `/bin/argvdemo exec-alpha exec-beta`, proving argv survives
  and the old image does not resume.
- **d4 — `waitpid`/`exit`/SIGCHLD** — mostly DONE with d2: `waitpid(pid|-1, *status)` blocks, reaps a
  matching zombie, returns the pid (ECHILD with no children). Remaining: SIGCHLD delivery and
  per-process fd/cwd inheritance across fork (needed once busybox keeps fds open across fork/exec).
- **d5 — busybox — DONE.** fetch busybox.net release, minimal `.config` (ash + ls/cat/echo), cross-build with
  `aarch64-elf-gcc` against `./sysroot` + our stubs; add whatever syscalls it needs (`dup`, `pipe`,
  `ioctl`/`TCGETS`, `wait4`, `getuid`, …); run `sh` and execute ls/cat/echo → M8 acceptance.

- **M7 (2026-06-04) — DONE.** TTY line discipline, termios, signals:
  - **UART RX + IRQ.** PL011 receive path added (`uartRxInit`/`uartHandleRx`/`uartTryReadByte`); routed
    through the GIC as SPI 1 → INTID 33. `gicEnableInterrupt` now programs `GICD_ITARGETSR` for SPIs
    (PPIs are banked, SPIs are not) — without it the line is never delivered.
  - **TTY line discipline** (`kernel/tty/tty.swift`): canonical mode (line buffering, echo, backspace
    editing) and raw mode, selected by termios `c_lflag` (`ICANON`/`ECHO`/`ISIG`). Backing for `read(0)`.
  - **termios** syscalls `tcgetattr`/`tcsetattr` (7/8); userland `lib/termios.h` mirrors the ABI.
  - **Signals** (`kernel/signal/signal.swift`): pending mask + dispositions for the foreground process.
    Ctrl-C (ETX, with `ISIG`) raises SIGINT; delivered from the IRQ handler after the GIC EOI. Default
    action terminates the process (status 128+signo); `SIG_IGN` honored. `sigaction`/`kill`/`getpid`
    (9/10/11) present. **Caveat:** custom (catch) handlers are recorded but not yet *delivered* — that
    needs signal frames/sigreturn (future work); today a custom handler falls back to terminate.
  - **Important constraint discovered:** a blocking syscall must NOT unmask IRQs, because an interrupt
    taken at EL1 overwrites `ELR_EL1`/`SPSR_EL1` (no save/restore in the sync vector yet), corrupting the
    pending return to EL0. `read(0)` therefore *polls* the UART with IRQs masked; the UART IRQ still
    drives Ctrl-C while the program runs at EL0. A full trap-frame (save/restore ELR/SPSR/SP_EL0) is the
    proper fix and is the prerequisite for preemptively scheduling EL0 processes — deferred.
  - Acceptance: typed input is echoed and returned by `read(0)`; Ctrl-C interrupts the running command
    (`M7 OK: foreground interrupted by Ctrl-C (SIGINT), status 130`). `make test` adds `tty_test.sh`
    (scripted serial input) and passes.

- **M6 (2026-06-04) — DONE.** libc subset, ELF64 loader, process spawn:
  - **Userland toolchain.** Hand-written minimal libc (`userland/lib/`): `crt0.S`, syscall wrappers
    (`syscall.h`), `strlen`/`puts_raw` (`libc.c`). `userland/hello.c` cross-built static and linked at
    `0x8000_0000` (`user.ld`) — our userland ABI lives high so it never collides with the kernel/device
    identity blocks. Built with `ld.lld -z max-page-size=4096`.
  - **ELF64 loader** (`kernel/user/elf.c`): validates an `ET_EXEC`/AArch64 image and maps `PT_LOAD`
    segments **page-by-page** (two segments may share a page — ours pack text+rodata into one),
    allocating frames from the PMM, per-page perms = "executable wins". Returns `e_entry`.
  - **Spawn primitive** (`kernel/user/process.swift`): `posix_spawn`-style (fresh address space + load +
    enter EL0), chosen over `fork` because we have no COW and build fresh spaces anyway. Runs
    synchronously — `SYS_exit` switches back (via `cpu_switch_context`) to the kernel context that
    launched it (`user_entry.S` trampoline installs TTBR0/SP_EL0/ELR/SPSR and `eret`s). The exit code
    round-trips to the kernel. Nests naturally for a future shell.
  - The ELF is embedded in the kernel image (`kernel/user/user_blob.S` `.incbin`) until M8's packed FS.
  - Acceptance: a static C `hello` loads, prints `hello from ELF userland` via our libc/syscalls, and
    exits with code 7 — kernel logs `M6 OK: ELF process exited, code 7`. `make test` passes (host PMM
    unit + userland ELF sanity + QEMU asserts).

- **M4.5 (2026-06-04) — DONE.** Foundation hardening before the libc/ELF work of M6:
  - **PMM wired in.** The host-tested `PageAllocator` bitmap now manages all RAM past the kernel
    image (`__image_end .. 0x5000_0000`, ~65k frames) via `kernel/mm/pmm.swift`, exposed to C as
    `pmm_alloc_page` / `pmm_alloc_pages` / `pmm_free_page` / `pmm_free_count`. Page tables, process
    stacks, and user pages now come from the PMM; the bump heap (`heap.c`) is only for small Swift
    objects. Added `kernel/runtime/string.c` (mem* with `-fno-builtin`).
  - **Per-process address spaces.** `vm.c` gained a general 4-level page-table walker
    (`address_space_create/map/switch/translate`) that allocates intermediate tables from the PMM and
    identity-maps the kernel/device 1 GiB blocks into every space. Probe maps one VA to two distinct
    frames in two spaces and reads back distinct values after switching `TTBR0_EL1` → isolation proven.
  - **Real context switch.** `kernel/arch/aarch64/switch.S` `cpu_switch_context` (callee-saved + sp +
    lr, xv6-style) + `thread_trampoline`. `scheduler.swift` rewritten with real TCBs, per-thread
    kernel stacks, cooperative `schedYield` and timer-driven preemption (`schedulerTick` after the GIC
    EOI). Two kernel threads interleave through genuine switches (`thread 1/2 iter 0..2`) and finish.
  - **Linker switched to `ld.lld`** (see above) to support Embedded Swift `Array`/`String`.
  - `make test` passes (host PMM unit test + QEMU asserts the context-switch and M5 lines).

- **M5 (2026-06-04) — DONE.** Syscall entry and VFS skeleton:
  - Lower-EL SVC handling now receives a saved register frame, dispatches by `x8`, and writes
    syscall return values back to saved `x0`.
  - Minimal VFS/file table added with one read-only base file, `/hello.txt`, plus stdout/stderr
    writes to UART.
  - EL0 test program now performs `open/read/write/close/exit` through syscalls; the file content
    is copied into an EL0 buffer and written back out through `write(1, ...)`.
  - `lseek` is present for the read-only file. Wider VFS calls (`stat`, `getdents`, cwd handling)
    remain to be expanded before busybox.
- **M4 (2026-06-04) — DONE.** Minimal processes/scheduler:
  - Timer IRQs now drive a tiny round-robin scheduler model that runs two kernel-thread slots
    and proves A/B interleaving on serial.
  - Lower-EL AArch64 synchronous exceptions dispatch through a separate vector entry; SVC traps
    from EL0 are handled in the kernel.
  - A tiny EL0 program page is installed at `0x8010_0000`, mapped read-only executable for EL0,
    entered via `eret`, executes `mov x0, #42; svc #0`, and traps back into the kernel.
    Its EL0 stack page is mapped read/write and XN.
  - Kernel/device identity mappings remain EL1-only, so EL0 is confined to its mapped user window.
  - Full saved-context thread switching and per-process TTBR switching remain future M4/M5
    refinements; this milestone establishes the tested EL0 trap path.
- **M3 (2026-06-04) — DONE.** Virtual memory and MMU:
  - Early AArch64 stage-1 translation tables added in `kernel/mm/vm.c`.
  - Kernel/devices are identity-mapped, `MAIR_EL1`/`TCR_EL1`/`TTBR0_EL1` are configured,
    and `SCTLR_EL1.M` is enabled.
  - A scratch VA page at `0x8000_0000` maps to a page-aligned heap page; the kernel writes
    through the mapped VA, verifies the physical page contents, unmaps it, and checks software
    translation returns unmapped.
  - Timer interrupts still run after MMU enable; `make test` passes.
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

## Post-M8 roadmap (M9 → M13) — locked 2026-06-04

M8 is complete (busybox `sh` on QEMU virt). The next arc is portability + a real boot + identity.
Three forks were raised and decided with the maintainer (each touched a previously-locked decision):

- **Boot/portability → keep aarch64, add UEFI boot.** "Run in VirtualBox" does NOT mean an amd64
  port (amd64 stays a non-goal). We make the kernel boot from a real disk via UEFI firmware and
  discover hardware at runtime instead of hardcoding the QEMU `virt` map. Reference validation is
  **QEMU + AAVMF (edk2 aarch64 UEFI)**; the end target is VirtualBox ARM on Apple Silicon, treated as
  best-effort because that machine model is experimental and differs from QEMU `virt`.
- **Identity → capability/principal model** (as already described in ARCHITECTURE.md). Kernel
  authorization is capability-based, not `uid==0`. `/etc/passwd`/`/etc/group` are generated compat
  views for busybox/newlib, never the source of policy.
- **Filesystem → virtio-blk + packed read-only base image.** Load `/bin`, `/etc`, busybox from a disk
  image instead of embedding ELFs in the kernel. tmpfs stays; persistent writable storage is NOT
  introduced (data loss on reboot remains by design).

Milestone sequence (one at a time, each builds/boots/tests/commits, then stop for review):

- **M9 — HAL + runtime hardware discovery (DTB).** Replace hardcoded UART/GIC/RAM constants with a
  `Platform` struct populated from a flattened device tree. Prerequisite for both UEFI and any non-QEMU
  host. Low risk: falls back to QEMU `virt` defaults if no valid DTB.
- **M10 — UEFI boot + bootable disk image.** Build the kernel as an EFI-loadable image (or a small
  UEFI loader): get the memory map + ACPI/DTB config table, `ExitBootServices`, hand off. Produce a GPT
  image with an ESP. Acceptance: boots under QEMU+AAVMF from disk (no `-kernel`) to busybox.
- **M10.5 — VirtualBox ARM validation (spike + milestone).** Research VBox ARM device model (UART,
  GICv2/v3, storage backend, ACPI), adapt the HAL/drivers, boot the M10 image in VirtualBox on Apple
  Silicon. If too immature, record findings and keep QEMU+AAVMF as the reference.
- **M11 — virtio-blk + packed base FS from disk.** virtio-blk driver (discovered via HAL); host-side
  image packer; VFS serves the RO base from disk; drop the embedded `user_blob`.
- **M12 — capability/principal core + login.** Typed `Principal`/`Session`/`Capability`; process
  security context; `console-login` authenticates a principal from a base-image identity store, opens a
  session, grants capabilities, spawns the shell. Generated `/etc/passwd` compat view.
- **M13 — permission enforcement on the VFS.** File access checked against capabilities; `ls -l` shows
  ownership/mode from generated views; unprivileged session denied writes to the RO base.

Critical path M9 → M10 → M11 → M12 → M13, with M10.5 a parallel validation after M10. Highest risk is
the UEFI handoff (M10) and VBox ARM immaturity (M10.5); the `-kernel` path stays as a fallback until UEFI
is stable.

## Hardware abstraction (M9)

- The boot stub (`boot.S`) preserves an optional DTB pointer from `x0` and passes it to
  `kernel_main(dtbPhys:)`. QEMU's direct ELF `-kernel` path does **not** reliably provide that pointer,
  so `make run`/`make test` dump QEMU's real `virt` DTB and load it into the last MiB of RAM
  (`0x4FF0_0000` for `-m 256M`) with `-device loader,...,force-raw=on`; `platformInit` tries `x0` first
  and then this direct-boot fallback address.
- `kernel/arch/aarch64/fdt.swift` is a small, pure, host-testable flattened-device-tree reader (no UART,
  no MMIO, no heap). It extracts the `/memory` reg (RAM base/size), the `arm,pl011` UART reg + IRQ
  (SPI/PPI decode), and the `arm,cortex-a15-gic` distributor/CPU-interface regs.
- `kernel/arch/aarch64/platform.swift` holds a global `Platform` struct initialised to QEMU `virt`
  defaults, then overridden by `platformInit(dtbPhys:)`. If neither `x0` nor the direct-boot fallback
  address contains a valid DTB it keeps the defaults and logs a warning, so the kernel never regresses.
- Drivers read their bases/IRQs from `platform`: `uart.swift` (`platform.uartBase`/`uartIrq`),
  `gic.swift` (`platform.gicDist`/`gicCpu`), `pmm.swift` (RAM end = `ramBase + ramSize`). The EL1
  physical timer PPI (INTID 30) stays an architectural constant, not board-specific.
- Tests: a host unit test (`tests/fdt_test.swift`) parses a real QEMU DTB (dumped via
  `-M virt,dumpdtb=...`) and asserts the extracted map; the in-QEMU boot test asserts
  `M9 OK: hardware discovered from device tree`, proving the DTB→`Platform` path end to end.

## UEFI boot (M10)

M10 moves the boot path off QEMU's `-kernel` shortcut to a real firmware booting a disk image.
**M10 is DONE** — the OS boots to busybox under QEMU+AAVMF from an EFI System Partition with no
`-kernel`. Staged as M10a (loader bring-up), M10b-prep (firmware state + load-address reservation), and
M10b (ExitBootServices + kernel handoff); details below.

### M10a — UEFI loader bring-up (DONE, 2026-06-04)

- **Toolchain (verified):** the EFI loader is an AArch64 **PE32+** application. clang targets
  `aarch64-unknown-windows` (COFF) and **`lld-link -subsystem:efi_application -entry:efi_main
  -nodefaultlib`** emits the EFI image. AArch64 UEFI uses ordinary AAPCS64, so firmware function
  pointers are called like normal C — no special calling convention (unlike x86_64 EFIAPI). No gnu-efi
  or EDK2 headers: `boot/efi/efi.h` declares only the structures used, at spec-correct offsets.
- **Firmware:** QEMU's prebuilt **AAVMF/edk2** at `/opt/homebrew/share/qemu/edk2-aarch64-code.fd`,
  loaded with `-bios` (no separate NVRAM vars store needed — AAVMF's default boot order scans removable
  media for `\EFI\BOOT\BOOTAA64.EFI`).
- **ESP without mkfs:** the host has no `mkfs.fat`/`mtools`, so the EFI System Partition is served as
  **virtual FAT** from a directory (`-drive file=fat:rw:build/esp,format=raw,if=virtio`). A real GPT
  image is deferred (needs `mtools`, comes with M10b/M11).
- **Device tree handoff:** AAVMF defaults to **ACPI**, which does NOT publish an FDT table. Booting
  `-M virt,acpi=off` makes the firmware run in device-tree mode and install the FDT configuration table
  (vendor GUID `b1b621d5-f19c-41a5-830b-d9152c69aae0`, EDK2 `gFdtTableGuid`). The loader walks
  `SystemTable->ConfigurationTable` for that GUID and finds the DTB (observed at `0x47EF2000`). This is
  the right mode for swift-os since it is a device-tree OS (M9 HAL). The loader must **not return** —
  returning hands control to the Boot Manager's setup UI — so it halts after reporting.
- Build/run: `make uefi` (build `BOOTAA64.EFI` + stage `build/esp`), `make uefi-run` (boot under AAVMF).
  Test: `tests/uefi_boot_test.sh` asserts the loader banner + `device tree found at 0x…` on serial.

### M10b-prep — firmware state + load-address reservation (DONE, 2026-06-04)

- `boot/efi/efi.h` now types the slice of `EFI_BOOT_SERVICES` needed for the handoff path:
  `AllocatePages`, `GetMemoryMap`, and `ExitBootServices`, keeping unused members as placeholders at
  spec offsets.
- Under QEMU+AAVMF with `-M virt,acpi=off`, the loader observes `CurrentEL == EL1` and reports
  `sctlr_el1` (MMU currently on under firmware). This removes the immediate EL2-drop concern for the
  reference boot path, though other firmware can still differ.
- The loader successfully reserves the direct-boot kernel load address `0x4008_0000` using
  `AllocatePages(AllocateAddress, EfiLoaderData, 16 pages, ...)`. This proves the next step can copy/load
  the Swift kernel at the address it is currently linked for before calling `ExitBootServices`.
- `tests/uefi_boot_test.sh` now asserts the EL1 observation, successful fixed-address reservation, and
  `M10b-prep OK`.

### M10b — ExitBootServices + kernel handoff (DONE, 2026-06-04) — M10 ACCEPTANCE MET

The loader now hands off to the Swift kernel and the OS boots to busybox **from disk under UEFI, with no
`-kernel`** — the M10 acceptance.

- **Embedded kernel.** The loader has no filesystem driver, so it carries the flat kernel image inside
  its own PE: `boot/efi/kernel_blob.S` `.incbin`s `build/kernel.bin` (byte 0 = link base `0x4008_0000`)
  and is linked into `BOOTAA64.EFI`. `make uefi` therefore depends on the built kernel.
- **Handoff sequence** (`efi_main`): locate the DTB; `AllocatePages(AllocateAddress, 0x4008_0000)`;
  copy the kernel there; `dc cvac` clean the region to the point of coherency (the kernel will run with
  the data cache off); `GetMemoryMap` into a static buffer (so no allocation perturbs the map key) →
  `ExitBootServices` (one retry if the key is stale); `msr daifset, #0xf` to mask the firmware's still-
  armed timer; then jump to `0x4008_0000` with the DTB pointer in x0. No firmware calls after exit.
- **Kernel entry hardened** (`boot.S`): the firmware hands us **EL1 with the MMU/caches ON**, so `_start`
  now force-disables MMU + D/I caches + alignment checks in `SCTLR_EL1` and runs `tlbi vmalle1; ic iallu;
  dsb; isb`. This normalizes both entry paths — UEFI (MMU on) and QEMU `-kernel` (MMU off) — to the same
  MMU-off bring-up, so the rest of boot is unchanged. The DTB pointer in x0 flows straight into the M9
  HAL (`platformInit`), which parses it (no scan needed).
- **Verified:** under QEMU+AAVMF (`-M virt,acpi=off`, `-bios`, virtual-FAT ESP) the kernel runs every
  milestone demo M1→M8 identically to `-kernel`, reaches the busybox shell, and `tests/uefi_boot_test.sh`
  drives `echo`/`ls`/`cat` (`M10-UEFI-OK`, dir listing, `Welcome to swift-os.`). Wired into `make test`
  alongside the `-kernel` path (both green).
- **Remaining (deferred, not blocking M10):** a real **GPT disk image** instead of QEMU virtual FAT
  (needs `mtools`); pairs naturally with M11's on-disk base image. Also note the loader embeds the kernel
  rather than reading it from the ESP — fine for now, revisit if the image grows.

Next: **M10.5** — validate this image under VirtualBox ARM on Apple Silicon (research its device model:
UART, GICv2/v3, storage, ACPI vs DT), adapting the HAL where it differs from QEMU `virt`.

## Open decisions / resolved

- [x] Embedded Swift toolchain → swift.org **6.3.2-RELEASE** (user-local xctoolchain).
- [x] Embedded Swift flags & triple → pinned above (`aarch64-none-none-elf`).
- [x] Linker → `aarch64-elf-ld`.
- [x] Post-M8 direction (2026-06-04): keep aarch64 + UEFI boot (no amd64 port), capability/principal
  identity, virtio-blk packed RO base FS (no persistent writable FS). See "Post-M8 roadmap" above.

### d5 — busybox cross-build: feasibility findings (2026-06-04)

Downloaded busybox 1.38.0; configured `allnoconfig` + ash/ls/cat/echo + static; cross-built with
`aarch64-elf-gcc` against `./sysroot` (newlib). busybox is **Linux-oriented**; newlib is bare-metal, so
the bring-up needed a small `userland/compat` header surface for POSIX/Linux-ish declarations that newlib
does not ship.

- Header shims added under `userland/compat/` for the minimal BusyBox build surface: endian/feature
  helpers, directory APIs, termios, sockets/netdb, mount/shadow/utmp placeholders, poll, mmap, statfs,
  sysinfo, sysmacros, utsname, wait/status, stdio/stdlib extensions, and related network headers.
- Repro target added: `make busybox-check` downloads pinned busybox 1.38.0, applies the minimal
  ash/ls/cat/echo/static config, includes `userland/compat`, and passes only if it produces a static
  AArch64 busybox binary. Current log: `build/busybox-check.log`.

Conclusion: busybox-on-newlib is viable for the minimal ash + ls/cat/echo configuration. The binary now
cross-builds statically; the next milestone is launching that image under the OS and filling runtime
syscall gaps (`dup`, `pipe`, `ioctl`/termios variants, uid/gid, process helpers, directory backing, etc.)
over our own syscall surface, not Linux syscall numbers.

### d5 progress — busybox now COMPILES against newlib + compat (2026-06-04)

A `userland/compat/` POSIX/Linux shim layer (≈30 headers, passed via `-isystem` before the newlib
sysroot) now lets busybox 1.38.0 (ash + ls/cat/echo, static) **compile cleanly** with `aarch64-elf-gcc`.
Key gaps filled: `byteswap/endian/features`, full `termios.h` (newlib aarch64 ships none — struct +
flags `ICANON=1/ECHO=2/ISIG=4` matching the kernel ABI + baud table), `dirent.h` (newlib's is
"unsupported"), `sys/{ioctl,mman,statfs,sysinfo,sysmacros,resource,wait,un,termios}.h`,
`netdb/sys/socket/netinet/arpa/net/if` network stubs, `poll/sched/mntent/utmpx/shadow`, and
`include_next` shims for `stdlib.h` (rename newlib's nonstandard itoa/utoa), `stdio.h` (getline),
`signal.h` (SA_RESTART). busybox `.config` saved at `userland/busybox/config-minimal`.

Remaining for d5:
1. **Link-time stub layer** (`userland/compat/*.c`): real `opendir/readdir/closedir` over `getdents`;
   `tcgetattr/tcsetattr` over syscalls 7/8 (+ `tcflush/cf*` stubs); `lstat`→`stat`, `getuid/...`→0,
   `getpwuid/...`→minimal, `ioctl` (TIOCGWINSZ/TCGETS), `fork/execve/waitpid` wrappers, and ENOSYS
   stubs for the networking/mount/utmp surface libbb references.
2. **Custom final link**: busybox's default `gcc` link can't find `-lc`/`crt0.o`; relink the busybox
   objects with our `crt0_newlib.o` + stub lib + `-T user_newlib.ld` + newlib (`--start-group`).
3. **Runtime bring-up**: get the ash prompt, then run ls/cat/echo (likely a few iterations: applet
   re-exec path, tty modes, missing syscalls surfaced at runtime).

### d5 — busybox runs. M8 COMPLETE (2026-06-04)

`scripts/build-busybox.sh` (`make busybox`) cross-builds busybox 1.38.0 (ash standalone shell +
ls/cat/echo/pwd, static) with `aarch64-elf-gcc` against `./sysroot` (newlib) + `userland/compat`, then
links the busybox objects with our `crt0_newlib` + `newlib_syscalls` + `compat/stubs.c` (dirent over
getdents, termios over syscalls 7/8, fork/execve/waitpid, uid/pwd/ioctl/getline/… ) using
`user_newlib.ld` → `build/busybox.elf`, embedded in the kernel (`user_blob.S`).

Standalone applet dispatch: the shell re-execs `bb_busybox_exec_path` (`/proc/self/exe`) with
`argv[0]=<applet>`; `exec.swift` resolves `/proc/self/exe` (and `/bin/{busybox,sh,ls,cat,echo,pwd}`) to
the embedded busybox image, so `execve` reloads busybox and it runs the named applet.

**M8 acceptance MET:** the kernel boots, runs every milestone demo, then launches busybox `sh` as the
init shell; `tests/busybox_test.sh` drives it and asserts:
```
BusyBox v1.38.0 ... built-in shell (ash)
# echo M8-BUSYBOX-OK   -> M8-BUSYBOX-OK
# ls /                 -> bin etc readme.txt hello.txt tmp
# cat /etc/motd        -> Welcome to swift-os.
# exit                 -> code 0
```
Prereqs: `make newlib && make busybox` once, then `make build` / `make test`. The full
**M0 → M8 path is complete**: a static busybox sh runs ls/cat/echo on our read-only base + tmpfs in QEMU.
