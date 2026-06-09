# NOTES

Engineering log: accepted decisions, hardware constants, exact build/run commands, and tool versions.
Newest notes at the top of each section.

## nginx compile probe (2026-06-08)

- Added `scripts/build-nginx.sh` as an out-of-band compile probe. It fetches official nginx source,
  defaults to stable `NGINX_VERSION=1.30.2`, allows env override, extracts under `userland/nginx`,
  logs to `build/nginx-build.log`, and configures a minimal static HTTP build with poll events while
  disabling PCRE/rewrite, gzip/zlib, OpenSSL, cache, proxy/upstream-heavy modules, mail/stream, and
  dynamic-module paths where upstream options allow it. The script builds a local compiler wrapper so
  nginx links with `crt0_newlib.o`, `newlib_syscalls.o`, `compat_stubs.o`, newlib, libm, and libgcc.
- The nginx-local overlay in `userland/nginx/swiftos/` keeps the scaffold out of the shared compat ABI:
  a tiny patch preserves `aarch64` in nginx `--crossbuild=SwiftOS:0:aarch64`, and local headers describe
  source-level shapes for `glob.h`, `sys/uio.h`, and `netinet/tcp.h` so future probes reach link/syscall
  gaps instead of first failing on missing headers.
- Local run result in this worktree: after `make newlib`, `NGINX_CLEAN=1 ./scripts/build-nginx.sh`
  downloads/extracts/configures/builds nginx and emits `build/nginx.elf` (ELF64 AArch64 EXEC,
  entry `0x80000000`, no undefined symbols in `aarch64-elf-nm -u`). The probe forces
  `NGX_HAVE_MAP_ANON` after configure because swift-os has anonymous `SYS_MMAP`, but nginx cannot run
  its mmap feature test while cross-building.
- API gaps closed for the compile probe: vectored I/O (`readv`, `writev`, `pwritev`), IPv4 socket and
  DNS wrappers, minimal IPv6 header helpers, TCP options including `TCP_NODELAY`, low-water socket
  options, `O_NONBLOCK` on TCP accept/read via `fcntl(F_SETFL)`, UTC-only time aliases and
  `_gettimeofday`, `getrlimit`/`setrlimit`, process/signal shape expected by nginx, anonymous
  `mmap`/`munmap`, `chown`, `utimes`, `setitimer`, `gethostname`, `initgroups`, and nginx control-message
  header shapes.
- Runtime caveats: `sendmsg`/`recvmsg` fd passing still returns `ENOSYS`, `setitimer` is a no-op,
  write-side socket nonblocking readiness is not yet modeled, and nginx has not been added to the boot
  image or exercised under QEMU. `sleep`/`usleep`/`nanosleep` now use the timer-backed `SYS_NANOSLEEP`
  path from main. The expected first runtime configuration should still be single-process
  (`daemon off; master_process off;`) until master/worker channel fd passing is real.

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
- busybox vi addition: `33 ftruncate(fd, length)` — resize a writable tmpfs file (busybox vi writes
  with `O_CREAT` without `O_TRUNC`, then `ftruncate`s to the exact length). Growth zero-fills up to
  the node's capacity; shrink updates the length. Read-only/base files and directories are rejected.
- `/bin/top` additions: `46 sysinfo(buffer)` copies a 64-byte system-stats blob (uptime ticks, idle
  ticks, total/free RAM bytes, kernel image/heap bytes, tick rate, process counts); `47 procstat(buffer,
  capacity)` copies richer 56-byte per-process records (`pid`, `ppid`, state, principal, CPU ticks,
  start tick, resident bytes, name[16]). The 32-byte `22 psinfo` record is left unchanged so `/bin/ps`
  is unaffected.

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

## Track B — `mmap`/`munmap`/`mprotect` + W^X

The last "common denominator" in the long-horizon table (`docs/ARCHITECTURE.md`): anonymous
`mmap` with W^X-enforced executable mappings, the substrate JIT runtimes (V8, the JVM) and
large Swift apps need. Built on the `kernel/mm/vm.swift` seams (`walkToL3`, `linkPage`,
`memAttrs`/`protPageDesc`).

### B1 — anonymous `mmap`/`munmap` (DONE, 2026-06-07)

- **`protPageDesc(pa, prot)` in `vm.swift`** builds a 4 KiB leaf from a PROT bitmask
  (READ=1/WRITE=2/EXEC=4) via `memAttrs(userAccess: true, executable: prot&EXEC,
  userReadOnly: !(prot&WRITE))`. W^X (`WRITE|EXEC`) and `PROT_NONE` both return an invalid
  descriptor (0), which callers treat as `EINVAL` — the W^X guard is intrinsic to the
  descriptor builder, not just the syscall.
- **mmap VA arena — chosen base `0x9800_0000`, growing DOWN (floor `0x9000_0000`).**
  The valid user window is `[0x8000_0000, 0xB000_0000)` (`user_access.swift`). Within it:
  the ELF image sits at `0x8000_0000` growing up (busybox ~1.1 MiB, far short of
  `0x8800_0000`); the 4-page user stack is at the top of `[0x8FFF_C000, 0x9000_0000)`; the
  `sbrk` heap is at `0xA000_0000` growing up. That leaves a **256 MiB hole** between the
  stack top (`0x9000_0000`) and the heap base (`0xA000_0000`). The mmap arena is parked at
  the **midpoint** (`0x9800_0000`) and grows down, so it keeps 128 MiB of clearance above
  the stack top and 128 MiB below the heap base — it cannot collide with code, data, stack,
  or heap. The cursor (`pMmapTop`) is per-process: reset on `exec`, copied on `fork` (the
  eager clone duplicates mmap'd pages too), seeded from the creator for a thread.
- **`address_space_mmap`/`munmap` (`vm.swift`)** do the frame work given an aligned base VA
  + page count from `process.swift`: `pmm_alloc_page` each, **zero the frame** (anonymous
  memory reads as 0), `linkPage(protPageDesc(...))`, one bulk `dsb;tlbi`. A mid-map failure
  rolls back every frame already linked, so a failed mmap leaves no partial region. munmap
  clears leaves + frees frames (page tables kept; reclaimed at process exit). The kernel
  policy/accounting half is `processMmap`/`processMunmap` (cursor, `pResPages`, validation).
- **Syscalls:** `mmap` = **54** (returns base VA, or a small negative errno in `[-4095,-1]`
  encoded in the result — bridge maps that to `MAP_FAILED`), `munmap` = **55**.
  Bridges `swiftos_mmap`/`swiftos_munmap` in `swift_user.{h,c}`; POSIX-shaped `mmap`/`munmap`
  inlines + `PROT_*`/`MAP_*` in `syscall.h`.
- **Test:** `userland/mmapdemo.swift` (`/bin/mmapdemo`) maps anonymous RAM, asserts it reads
  as 0, round-trips a write/read pattern across a page boundary, munmaps. `tests/mmap_test.sh`
  (in `make test`). NOTE: syscall numbers 54/55 are next-free at impl time; other concurrent
  sessions may also be adding syscalls to main — renumber at merge if they clash.

### B2 — `mprotect` + W^X (DONE, 2026-06-07)

- **`address_space_mprotect` (`vm.swift`)** changes the PROT bits over a range, preserving
  each page's backing frame: `walkToL3(allocate: false)`, rebuild the leaf from the same PA
  via `protPageDesc`, rewrite it, `dsb;tlbi`. It pre-validates the whole range (every page
  must be mapped) before touching any leaf, so a hole is rejected (ENOMEM) without leaving a
  partially-changed region. `processMprotect` adds the cursor/arena bounds + alignment checks.
- **W^X is enforced at BOTH ends:** at the syscall boundary (`processMmap`/`processMprotect`
  reject `PROT_WRITE|PROT_EXEC` → EINVAL) and defensively inside `protPageDesc` (a W^X or
  PROT_NONE bitmask yields an invalid descriptor, so even a direct `address_space_*` caller
  can never install a writable+executable leaf). So a page is never simultaneously W and X.
- **Syscall `mprotect` = 56**; `mprotect` inline in `syscall.h`, bridge `swiftos_mprotect`.
- **Test — the JIT pattern** (`/bin/mmapdemo`, `tests/mmap_test.sh`): mmap a page RW, write
  `mov w0,#42; ret` (bytes `40 05 80 52  c0 03 5f d6`), `mprotect` RW→RX (must succeed), call
  it through a `@convention(c)` function pointer → returns **42**. Then assert both W^X
  breaches are rejected: `mmap` RWX fails, and `mprotect`→RWX on a live mapping fails.
  Verified in QEMU:
  ```
  mmapdemo: B1-OK anon mmap zero+write+read+munmap
  mmapdemo: B2-OK jit RW->RX call returned 42
  mmapdemo: WX-OK mprotect ->RWX rejected
  mmapdemo: WX-OK mmap RWX rejected
  mmapdemo: ALL-OK
  ```

## Milestone log

- **L0 (2026-06) — kernel log facade.** Introduced `kernel/log/log.swift` with `LogLevel`, `klog(level, source, message)` and `klogInfo`. Renders as `[tick] [L] source: message` to UART (and fb mirror). `timerGetTicks()` published from the timer. The facade is additive: all existing "Mxx OK:" / "panic:" banners were left untouched so every test expectation continues to match. One demo line (`L0 kernel logger active`) was added after `timerInit` and asserted in `boot_test.sh`. `make build` + real QEMU boot verified the line appears on serial. See the full plan, rationale (future central AI log collector), and design in `docs/LOGGING.md`. This is the first slice of the observability work called for in PHILOSOPHY.md and RISK_REMEDIATION_ROADMAP.md.

- **L1 (2026-06) — log ring buffer + dump.** Added fixed 256-entry ring of LogEntry (tick + level + source + StaticString message) with circular overwrite. `logDumpRecent(n)` replays the most recent entries (oldest of the window first). `kpanic` now stores + dumps the tail (~24 entries) after the panic banner. A `logDumpRecent(5)` call was placed late in the kernel demo sequence so the ring is exercised on every test boot; the dump header is asserted in `boot_test.sh`. Ring and dump are allocation-free and safe on panic/IRQ-masked paths. Pre-existing banners unchanged. See docs/LOGGING.md.

- **L2 (2026-06) — runtime min-level filtering.** Added global `minLogLevel` (defaults to .info). `klog` drops sub-minimum messages (both UART and ring storage); `.panic` is never dropped. New `klogSetMinLevel`/`klogGetMinLevel`. Early boot now emits "level filtering active (min INFO)" (asserted in boot_test) plus a .debug example that is suppressed by default. This gives a runtime knob for quieter production images while keeping the ability to open the logs for diagnostics or the future central collector. Filtering decision is made before ringStore. See docs/LOGGING.md.

- **L3 (2026-06) — structured records foundation.** Extended `LogEntry` with `detail: UInt64` (0=none). Updated ring initialiser, ringStore, `klog` (now accepts optional trailing `detail: UInt64 = 0` so 3-arg calls are unaffected) and `logDumpRecent` dump formatting (appends " detail=NNN" when nonzero). Added real example uses (post-heap safe): `klog(..., "timer", "tick rate (Hz)", 100)` after timerInit, `klog(..., "pmm", "free frames", UInt64(count))` in main.swift reclaim demo, and scheduler capacity detail in schedulerInit. `boot_test.sh` now asserts representative `detail=100` and `detail=4` payloads. See `docs/LOGGING.md` L3 entry and phased plan.

- **L3 adoption (2026-06) — klog population for ring value.** Moved or mirrored key boot events into klog(.info, "sched"/"platform"/"boot"/"disk"/"vfs", msg) while keeping message text recognizable. The platform discovery marker remains an early UART line in `platformInit` and is mirrored with klog after `timerInit`, preserving the logger's safe post-runtime startup point. Scheduler online/context-switch, reclaim start/OK, Swift ps launch, M11b disk OK, and M11c VFS base mount now populate the L1 ring (useful for logDumpRecent panic tails and future AI correlation) without touching panics or userland. Updated affected ASSERT strings in tests/boot_test.sh EXPECTS to stable prefixed substrings (e.g. "[I] boot: reclaim OK...") that match the new [tick] [I] source output. See docs/LOGGING.md (L-plan).

- **L4a (2026-06) — ring context enrichment.** Extended `LogEntry` with process/security context captured at emit time: `pid: Int32` (`0` = kernel/no current process) and `principal: UInt32` (`1` = boot/root principal). `klog` now records this context in the ring via the existing `processCurrentPid()` / `processCurrentPrincipal()` accessors after L2 filtering; live UART output stays in the L0 format. `logDumpRecent` appends `pid=N principal=M` only for non-kernel contexts, while preserving L3 `detail=...` payloads. Added a ring-only `psinfo` syscall event via `klogRing`, kept the demo dump window compact while preserving early details, and updated `boot_test.sh` to assert a real EL0 context suffix. See `docs/LOGGING.md`.

- **L4b (2026-06) — per-source runtime filtering.** Added a tiny fixed override table in `kernel/log/log.swift` for exact source-tag minimum levels. `klogSetSourceMinLevel(source, level)` sets/replaces an override, `klogClearSourceMinLevels()` clears all overrides, and filtering now prefers the source override before falling back to the global `minLogLevel`; `.panic` still bypasses filtering. The shared acceptance path is used by both live `klog` and ring-only `klogRing`, so suppressed records do not reach UART or the ring. Boot now demonstrates this on a dedicated `log_filter` source without affecting scheduler/detail acceptance: the `.info` demo is forbidden in `boot_test.sh`, while the `.error` demo must appear. See `docs/LOGGING.md`.

- **L4c (2026-06) — wire-format serialization.** Added allocation-free ring serialization in `kernel/log/log.swift`: `logFormatRecentTail(maxCount, into:capacity:)` writes recent records into a caller-provided byte buffer as newline-separated key=value entries (`tick=N level=I source=tag msg="text"` plus optional `detail=N` and `pid=N principal=N`). The formatter includes the L3 detail and L4a context fields, shares the ring's oldest-first tail semantics, and has no UART side effects. Boot now records a ring-only `log_export` marker, emits a small `LOG-EXPORT-BEGIN` / `LOG-EXPORT-END` sample after `logDumpRecent`, and `boot_test.sh` asserts both a context-rich `psinfo` serialized line and the export marker line. This remains an internal formatter, not a user-visible device or remote protocol. See `docs/LOGGING.md`.

- **L4d (2026-06) — log sink indirection + capability hook.** Live `klog` output now routes through a tiny current-sink dispatch in `kernel/log/log.swift`; the default and only implemented sink remains UART, but `klog` no longer embeds the UART renderer inline. Added reserved `capLogExport` in `kernel/security/security.swift` (not granted to the boot/root context by default) plus `klogCanInstallSink(capabilities:)` / `klogCanExportRing(capabilities:)` hook helpers for the future userland log service/export path. Boot asserts both `sink indirection active` and `sink capability hook active`, while preserving the existing live line spelling and L4c wire-format sample. See `docs/LOGGING.md`.

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
  - NOTE: process teardown now reclaims frames (address space + page tables + kernel stack) on
    exit/exec/reap — see "Process teardown reclaims frames" below. (Originally a documented follow-up.)
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

## Risk remediation arc (post-M13) — planning started 2026-06

A dedicated plan now exists in `docs/RISK_REMEDIATION_ROADMAP.md`. It addresses the structural risks
that became visible once the M8–M13 + N goals were complete:

- SMP (single-core was an explicit hard constraint through M13; it is now required for the server/AI-hosting
  profile and for credible scaling).
- Completion of the capability model (the "flag + ambient" version shipped for M12/M13; the handle-based
  model with spawn-with-handles and IPC is designed in CAPABILITIES.md but not yet implemented beyond
  syscall number reservations and the CellId tag).
- Moving privileged in-kernel drivers and the network stack toward the documented restartable userland
  service model (once IPC exists).
- Making global mutable state (scheduler, PMM, VFS pools, net engine) safe for concurrent execution.
- Other gaps noted in the plan (signal frames, observability, A/B updates, etc.).

The arc follows the project rules exactly: one (sub)milestone at a time, each must build + boot (including
on `-smp N`) + pass tests (with new concurrency stress where relevant) + be committed + reviewed before
the next. C-arc work (explicit handles + IPC) is recommended early because it is both a risk mitigation
in its own right and a prerequisite for a sane multi-core driver/service model.

See the new document for the detailed S0–S5 SMP phases, recommended sequencing, decision forks that
require explicit review ("ask, don't guess"), and acceptance criteria style.

## C-arc checkpoints (post-M13)

### S0a — current CPU id + parked-SMP smoke harness (DONE, 2026-06-08)

- **Current CPU primitive.** Added an AArch64 `read_mpidr_el1()` bridge and a
  small `currentCpuId()` Swift helper that returns MPIDR_EL1 Aff0. For the first
  QEMU `virt` SMP release this records the assumption that Aff0 is the CPU index;
  secondary CPUs still park in `boot.S` and do not execute Swift/kernel work yet.
- **Boot marker.** Early boot now logs
  `[I] smp: S0 OK: foundations ready` on the primary CPU after the timer/logger
  are initialized. The log call carries `currentCpuId()` as its structured detail;
  the current formatter omits zero-valued detail on CPU0, but the call site is
  ready to become visible once nonzero secondary CPU paths exist.
- **SMP smoke harness.** Added `tests/smp_boot_test.sh` plus `make smp-test`
  / `make s0-test`. The harness boots the existing kernel with
  `-smp ${SMP_CPUS:-4}` and the normal DTB/base-image virtio arguments, then
  asserts stable boot markers. Pre-S1, this proves extra QEMU CPUs remain safely
  parked and do not perturb the single-CPU path.
- **Non-goals.** No secondary CPU release, no per-CPU scheduler state, no timer
  PPIs on secondaries, no IPIs, no atomics/locking policy, no TLB shootdown.
  Those remain S0b/S1+ work after review.

### S0b — barrier and atomic primitive shims (DONE, 2026-06-09)

- **C bridge primitives.** Added Swift-callable `dmb ish/ishld/ishst` wrappers
  and a minimal u64 atomic vocabulary (`load`, `store`, `fetch_add`,
  `compare_exchange`) in `io.h`, backed by LLVM/C11 `__atomic` builtins with
  acquire/release or acquire-release ordering. These are the primitives future
  PMM bitmap operations, VFS refcounts, and scheduler cross-CPU state will build
  on; no subsystem is migrated to them in this checkpoint.
- **Swift facade + early self-test.** Added `kernel/smp/atomic.swift` with small
  Embedded Swift wrappers and `smpAtomicSelfTest()`. The boot path runs the
  self-test after timer/log startup and logs
  `[I] smp: S0b OK: atomics and barriers ready` only after load/store,
  fetch-add, successful CAS, failed CAS, and barrier calls all complete.
- **Tests / acceptance.** `make smp-test` asserts the S0b marker while booting
  QEMU with `-smp 4` and parked secondaries. The normal 1-CPU boot path also runs
  the self-test; failures panic before userland.
- **Non-goals.** No locks, no PMM/VFS conversion, no scheduler changes, no
  secondary CPU release, and no performance policy choice for a UP fast path.

### S0c — executable SMP mutable-state audit (DONE, 2026-06-09)

- **Audit manifest.** Added `docs/SMP_STATE_AUDIT.md`, recording the top-level
  mutable kernel storage that must become per-CPU, protected, IRQ/boot-only, or
  driver/service-owned before S1/S2 can safely run kernel work on secondary
  CPUs. This is intentionally a review artifact, not a behavior change.
- **Executable coverage check.** Added `scripts/smp-global-audit.py` and
  `tests/smp_state_audit_test.sh`. The scanner lists top-level Swift stored
  globals plus top-level C mutable definitions; the test fails if the audit doc
  does not cover a scanned `path:symbol` entry. Current coverage is 160 entries,
  including `systemTicks`, process/scheduler globals, VFS tables, virtio state,
  network socket/TCP globals, PMM/heap state, and early MMU tables.
- **Test integration.** `make test` now runs the audit check with the host
  checks, and `make s0-test` runs `smp-state-audit` before the parked SMP smoke.
- **Non-goals.** No locks, no per-CPU conversion, no C4/VFS/process behavior
  changes, no secondary CPU release, and no resolution of the S0 uniprocessor
  fast-path decision.

### S0d — fixed per-CPU state scaffold (DONE, 2026-06-09)

- **Heap-free per-CPU storage.** Added `kernel/smp/percpu.swift` with an
  `InlineArray<8, SMPPerCpuState>` so the first per-CPU state is fixed storage,
  not a Swift heap array. The scaffold records initialization, logical CPU id,
  per-CPU timer ticks, the mirrored kernel-thread id, and a reserved process id
  slot for later S2 work.
- **Primary-CPU init + self-test.** CPU0 now runs `smpEarlyInitCurrentCpu()` and
  `smpPerCpuSelfTest()` during boot, then logs
  `[I] smp: S0d OK: per-CPU state ready`. The self-test validates CPU indexing,
  timer-tick recording, current-thread mirroring, current-process mirroring, and
  barrier calls before interrupts are enabled.
- **Toward S2 without behavior change.** The generic timer mirrors ticks into
  the current CPU's per-CPU slot, and the kernel-thread scheduler mirrors
  `currentThread` after initialization and context-switch selection. The old
  single-CPU scheduler/process tables remain authoritative in S0.
- **Tests / acceptance.** `make s0-test` asserts the S0d marker under `-smp 4`;
  the normal 1-CPU boot path also runs the self-test and panics before userland
  on failure.
- **Non-goals.** No secondary CPU release, no per-CPU run queues, no process
  scheduler conversion, no locking protocol, no VFS/C4 work, and no
  uniprocessor fast-path decision.

### S0e — secondary park mailbox scaffold (DONE, 2026-06-09)

- **Mailbox-aware park loop.** Secondary CPUs now branch to a dedicated
  `boot.S` park loop instead of the generic hang loop. The loop bounds-checks
  `Aff0`, selects a fixed 64-byte per-CPU mailbox slot, acquire-loads a release
  flag, and waits with `wfe`, making it safe for a later S1 release path to wake
  CPUs with a mailbox write plus `sev`.
- **No secondary release yet.** The S0e path deliberately stays parked even if a
  non-zero entry appears: secondary stacks, allocator policy, and shared-state
  locks are still S1/S2 work. The self-test asserts both mailbox words are zero
  and emits `[I] smp: S0e OK: secondary park mailbox ready`.
- **Audit visibility.** The mailbox table lives in `kernel/smp/secondary.c` and
  is forced into `.data.smp_mailbox`, not `.bss`, because secondary CPUs may
  reach the park loop before CPU0 clears BSS. The S0c mutable-state audit now
  records the table.
- **Tests / acceptance.** `make s0-test` asserts the S0e marker under `-smp 4`
  and checks the mailbox table is linked into `.data` with the expected 8-slot
  size and 64-byte alignment. The normal 1-CPU boot path also runs the self-test
  and panics before userland on failure.

### C1 — handle table + fds-as-handles (DONE, 2026-06-08)

- **Typed handle slots.** `kernel/vfs/handle.swift` now owns the dependency-free
  `HandleKind`, `Rights`, `HandleInheritance`, and `HandleEntry` vocabulary. The
  VFS fd table stores `HandleEntry` values keyed by `(process slot, fd)`: each slot
  records the fd-visible object kind, the shared open-description index, per-handle
  rights, and the per-slot `cloexec` flag.
- **Behavior-preserving fd view.** POSIX-visible fd numbering is unchanged:
  top-level stdio is still `0/1/2`, `open()` and `socket()` allocate from fd `3`,
  while `dup`, `dup2`, `F_DUPFD(_CLOEXEC)`, and `pipe` preserve their existing
  lowest-free behavior. Shared offsets, pipe/socket lifetime, close-on-exec,
  fork inheritance, and exec behavior remain backed by the existing reference-counted
  `OpenDescription` pool.
- **Rights without new policy.** `read`/`write` rights stay per handle and are used
  by the same syscall paths as before. C1 does not add enforcement for `.duplicate`,
  `.transfer`, `.getattr`, socket-specific operations, or process capability checks
  beyond the policy that already existed before this checkpoint.
- **Tests / acceptance.** `tests/handle_test.swift` covers stable rights bits,
  attenuation, `rights(read:write:)`, distinct handle kinds, and typed `HandleEntry`
  initialization. The boot path prints `C1 OK: fds-as-handles preserved` only after
  `/bin/fdopsdemo` exits successfully, and `tests/boot_test.sh` asserts that marker.
- **Non-goals left for later C milestones.** No new user-visible generic handle
  syscalls, no spawn-with-explicit-handles default flip (C2), no object-scoped
  authority policy expansion (C3), no new IPC/VMO/device/cell handle semantics
  (C4+), and no SMP work.

### C2 — spawn-with-handles / explicit handle inheritance (DONE, 2026-06-08)

- **Explicit spawn inheritance.** `SYS_SPAWN_HANDLES` adds a synchronous
  `spawn_handles(path, argv, HandleSpec[], count)` ABI. A spawned child starts
  with an empty handle table and receives only the named `(source fd -> target fd)`
  entries, with per-entry rights attenuated by the supplied mask and optional
  child-side close-on-exec.
- **Compatibility preserved.** The existing `SYS_SPAWN` / `spawn()` wrapper still
  inherits stdio only (`0/1/2`). `fork()` still inherits the full handle table,
  including fd numbers, shared open descriptions, offsets, rights, and `cloexec`
  flags. `execve()` still closes only close-on-exec descriptors.
- **Tests / acceptance.** `tests/handle_test.swift` covers the C2 inheritance
  selector and `HandleSpec` ABI constants. `/bin/spawndemo` now proves both that
  legacy spawn drops parent fd `3` and that `spawn_handles` can explicitly pass
  fd `3`; `tests/boot_test.sh` asserts `C2 OK: explicit handle inheritance
  preserved` and rejects leak/failure markers.
- **Non-goals left for later C milestones.** C2 does not add object-scoped
  filesystem authority, subtree grants, resource-limit enforcement, IPC transfer
  policy, service/cell launch semantics, or SMP work.

### C3 — per-handle VFS rights gates (DONE, 2026-06-08)

- **Operation rights now live on the handle.** Existing fd-backed operations now
  check `HandleEntry.rights` before dispatch for duplication, metadata (`fstat`,
  `F_GET*`), fd attributes (`F_SET*`), directory iteration, lseek, socket
  send/receive/control paths, and explicit spawn handle passing (`.transfer`).
  `read`, `write`, `ftruncate`, pipe poll, and endpoint send were already
  rights-aware; C3 closes the obvious fd bypasses without changing fd numbering.
- **Compatibility defaults preserved.** Legacy `open()`, `pipe()`, stdio, and
  `socket()` still mint POSIX-compatible handles with read/write plus the meta
  rights needed by shells, redirects, fork, and `spawn_handles`. Process-global
  caps remain coarse constructor gates for ambient `open()`/`socket()` and tmpfs
  mutation compatibility; once a handle exists, those caps do not widen it.
- **Scoped filesystem authority.** The existing `confine()` subtree root now gates
  path syscalls beyond `open()`: `stat`, `chdir`, namespace mutations, chmod/chown,
  and disk-backed exec image lookup. Confinement is narrow-only and keeps cwd
  inside the subtree.
- **Tests / acceptance.** `tests/handle_test.swift` covers C3 rights bit stability,
  `hasRights`, and attenuation to all/empty masks. `/bin/spawndemo` passes
  deliberately attenuated handles and `/bin/argvdemo` proves missing write,
  duplicate, getattr, and directory-read rights are denied. `/bin/fsdemo` proves
  `/etc` confinement allows inside access but denies open/stat/widen/create outside,
  and the boot test asserts `C3 OK: per-handle rights enforced`.
- **Non-goals left for later C milestones.** C3 does not add C4 IPC expansion,
  endpoint handle policy beyond existing fd rights, VMOs, async rings, userland
  drivers, Cells/resource domains, cap-stripping spawn policy, or SMP work.

### C4a — minimal endpoint handle-passing IPC hardening (DONE, 2026-06-08)

- **Reviewed endpoint slice.** The existing `endpoint_create` / `ipc_send` /
  `ipc_recv` path is now treated as the first C4 sub-milestone: a pollable
  single-slot endpoint can carry bytes plus one moved handle between processes.
  The sender's source fd is cleared without releasing the open description, and
  the receiver installs the same attenuated `HandleEntry` rights into a fresh fd.
- **Rights and lifetime hardening.** `ipc_send` requires endpoint `.write` and
  `.transfer`, and the moved source handle must have `.transfer`. `ipc_recv`
  requires endpoint `.read` and, when a handle is pending, endpoint `.transfer`
  before importing it. Same-endpoint self-transfer is rejected, endpoint creation
  rolls back reserved fd/description/object slots on failure, and receive checks
  fd-space before consuming a pending moved handle.
- **Poll and teardown behavior.** Endpoint poll readiness now mirrors the rights
  `ipc_send`/`ipc_recv` enforce: send readiness needs write+transfer, receive
  readiness for a pending handle needs read+transfer, and peer close still reports
  HUP/ERR-style readiness. Closing the last endpoint references still releases an
  in-flight unreceived handle, and endpoint slots retain their heap-backed message
  buffers for reuse so repeated create/close tests do not burn the bump heap.
- **Tests / acceptance.** `tests/handle_test.swift` covers the C4a endpoint
  vocabulary. `/bin/spawndemo` passes attenuated endpoint handles to
  `/bin/argvdemo`, proving missing endpoint write/read/transfer rights are
  denied. `/bin/forkdemo` proves bytes, received-handle readback, and move-only
  source fd invalidation. The boot acceptance marker is `C4a OK: endpoint IPC
  moved handles safely`.
- **Non-goals left for later C4 milestones.** No VMOs, async rings, batched
  descriptors, `ipc_call`, badges, multi-handle vectors, service supervisor,
  userland drivers, Cells/resource domains, socket-transfer smoke, endpoint
  close-on-exec policy change, or SMP work.

### C4b — socket handle transfer smoke (DONE, 2026-06-09)

- **Socket objects now have endpoint-transfer coverage.** No kernel ABI change
  was needed: C4a already moves a full `HandleEntry`; this slice proves that the
  same move works for `.socket` descriptions and preserves the socket table
  object/lifetime across process ownership transfer.
- **Executable smoke.** Added `/bin/c4b-sockxfer`: the parent binds a UDP socket
  after `fork`, moves that socket handle over an endpoint to the child, verifies
  the source fd is invalidated (`-EBADF`), and waits for the child to receive and
  echo a host datagram through the transferred socket.
- **Tests / acceptance.** `tests/ipc_socket_transfer_test.sh` boots with
  virtio-net + slirp UDP hostfwd, runs `/bin/c4b-sockxfer`, sends a host datagram
  to the bound port, asserts the child received/echoed through the moved socket,
  and is wired into `make test` after the UDP smoke.
- **Still deferred.** VMOs, async rings, batched descriptors, `ipc_call`, badges,
  service supervisor, userland drivers, Cells/resource domains, endpoint
  close-on-exec policy change, and SMP work remain later C/S milestones.

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
- **ESP bring-up:** M10a initially used QEMU virtual FAT from a directory
  (`-drive file=fat:rw:build/esp,format=raw,if=virtio`) so no mount/root privileges were needed. M10c
  adds a real GPT disk image path; virtual FAT remains available as `UEFI_BOOT=fat`.
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
- **Verified:** under QEMU+AAVMF (`-M virt,acpi=off`, `-bios`, real GPT disk image) the kernel runs every
  milestone demo M1→M8 identically to `-kernel`, reaches the busybox shell, and `tests/uefi_boot_test.sh`
  drives `echo`/`ls`/`cat` (`M10-UEFI-OK`, dir listing, `Welcome to swift-os.`). Wired into `make test`
  alongside the `-kernel` path (both green).

### M10c — real GPT disk image for UEFI boot (DONE, 2026-06-04)

- `scripts/make-disk.sh` creates `build/swift-os.img`: a sparse GPT disk with one EFI System Partition
  starting at sector 2048, type `EF00`, formatted/populated with `mtools` via byte-offset access
  (`image@@offset`) so no mount or root privileges are required.
- `make disk` builds `BOOTAA64.EFI`, creates the image, and copies it to `\EFI\BOOT\BOOTAA64.EFI`.
  `make disk-run` boots QEMU+AAVMF from that raw disk image (`-drive file=build/swift-os.img,...`), with
  no `-kernel` and no QEMU virtual FAT.
- `tests/uefi_boot_test.sh` defaults to `UEFI_BOOT=disk` and is wired into `make test`; `UEFI_BOOT=fat`
  remains as a quick fallback for the directory-backed ESP path.
- **Remaining (deferred, not blocking M10):** the loader still embeds the kernel rather than reading it
  from the ESP — fine for now, revisit if the image grows or once M11's on-disk base image exists.

### M10.5 — VirtualBox ARM validation (prep DONE; needs a manual run)

VirtualBox ARM is a developer preview whose machine model differs from QEMU `virt`, and it is a GUI
hypervisor that cannot run in this headless dev environment — so M10.5 needs a manual run on an Apple
Silicon Mac with VirtualBox installed. Prepared for that:

- **Loader diagnostics.** Before handing off, `loader.c` now reports, via the firmware-independent UEFI
  console: device tree present/absent, ACPI 2.0 table present/absent, `CurrentEL` + MMU bit, and the
  largest conventional RAM region (base/size) from `GetMemoryMap`. These print even if the kernel cannot
  drive VirtualBox's UART after handoff, so the first run is informative regardless. (On QEMU+AAVMF with
  `acpi=off`: DTB found, ACPI absent, EL1, RAM region base `0x4800_0000`.)
- **Procedure** is in `docs/VIRTUALBOX.md`: `make disk` → `VBoxManage convertfromraw … --format VDI` →
  create an EFI ARM VM (256 MB, 1 core) → attach the disk → capture serial-to-file and/or a screenshot →
  send the `UEFI:` lines back. Those lines (DTB vs ACPI, RAM base, EL) drive the HAL adaptation.
- **Expected first outcome.** The loader banner should appear (proving VBox launches our EFI app); the
  kernel may stay silent after handoff if VBox's UART base differs from QEMU's PL011 `0x0900_0000`. That
  is the signal to extend `platform.swift` (and, if VBox is ACPI-only with no DTB, add minimal ACPI
  table discovery — likely the SPCR table for the console UART — alongside the M9 device-tree path).

## Disk-backed base filesystem (M11)

### M11a — packed base image format + host packer (DONE, 2026-06-04)

- Added a deterministic packed read-only base image format (`SWOSBASE`, version 1): 64-byte header,
  fixed 40-byte entries, UTF-8 path string table, and concatenated file data. All integer fields are
  little-endian so the kernel reader can stay tiny on AArch64.
- Added `base/` as the host seed tree mirroring today's in-kernel read-only VFS files:
  `/etc/motd`, `/etc/hostname`, `/readme.txt`, `/hello.txt`, and `/bin/ps` placeholder.
- Added `tools/basepack.swift` and `make base-image`, producing `build/base.img`.
- Added `tests/base_image_test.swift`, wired into `make test`, which parses `build/base.img` and verifies
  the expected directories, file contents, and binary layout.
- Remaining M11 work: virtio-blk discovery/driver, attach `build/base.img` (or a partition/file inside
  the GPT image) as the read-only base source, and replace the static Swift VFS literals.

### M11b — virtio-blk driver (DONE, 2026-06-05)

- Extended the M9 HAL: the FDT reader now collects the `virtio,mmio` transport bank (lowest base,
  per-slot stride, slot count) and `platformInit` publishes it as `platform.virtioMmio{Base,Stride,Count}`.
  On QEMU virt that is `0x0A00_0000`, stride `0x200`, 32 slots — verified in `tests/fdt_test.swift`.
  Note: `PlatformInfo`'s new 64-bit fields are grouped with the other pointers (32-bit fields last) so
  the struct stays naturally aligned — the parser runs before the MMU, where a wide unaligned load faults.
- Added `kernel/drivers/virtio_blk.c`: a minimal polled virtio 1.0 (modern, MMIO) block driver. It scans
  the HAL window for device id 2, negotiates `VIRTIO_F_VERSION_1`, brings up one request virtqueue, reads
  the capacity from config space, and reads 512-byte sectors via a 3-descriptor chain (header / data /
  status), polling the used ring. Synchronous and blocking — fine for a read-only base. Cache clean/
  invalidate around every DMA region, mirroring the virtio-input driver.
- `runVirtioBlkProbe` (kernel/main.swift) reads sector 0 at boot and recognises the `SWOSBASE` magic; a
  no-op (just a log line) when no block device is attached, so the `-kernel` test paths are unaffected.
- Test: `tests/virtio_blk_test.sh` attaches `build/base.img` as a virtio-blk disk (modern transport via
  `virtio-mmio.force-legacy=false`) and asserts sector 0 is read with its magic verified. Wired into
  `make test`.
### M11c — serve the read-only base FS from disk (DONE, 2026-06-05)

- `kernel/vfs/vfs.swift` now parses the `SWOSBASE` header/entries off the virtio-blk disk at `vfsInit`
  and backs the read-only vnodes with **extents into the disk image** (a `diskOffset`/`dataLen` pair per
  file); `vfsRead` pulls the requested span via `virtio_blk_read_range`. Directory entries are sorted so
  parents precede children — the builder resolves each path's parent against already-created nodes.
- The metadata block (entries + string table) is read once into a kept heap buffer; vnode names point
  straight into it, so no per-name copies. File data is read lazily from disk on each `read()`.
- Fallback: when no disk / no `SWOSBASE` magic (the `-kernel` test paths and the UEFI GPT boot, whose
  disk is not a packed image), `vfsInit` keeps the compiled-in literals, so every existing path is
  unaffected. `/tmp` tmpfs is added in both cases.
- `runVirtioBlkProbe` now runs before `vfsInit` so the disk is up when the VFS may mount from it.
- Added `virtio_blk_read_range(byte_off, buf, len)` (spans sectors via the bounce buffer).
- Test: `tests/vfs_disk_test.sh` packs a throwaway image whose `/etc/motd` holds a unique marker absent
  from the kernel literals (plus a disk-only file), boots with it attached, and asserts busybox reads the
  marker and the extra file — proving the bytes came off disk, not the fallback. Wired into `make test`.
### M11d — disk-first executable lookup (DONE, 2026-06-05)

- `make base-image` now stages real ELFs into the packed base image under `/bin`: busybox, Swift `ps`,
  and the milestone demo programs. The static seed tree still supplies `/etc` and text files, while the
  staging tree overwrites `/bin/ps` with the executable.
- `exec.swift` now resolves known `/bin/*` programs through the VFS first. When a path is a disk-backed
  file in the mounted `SWOSBASE` image, the kernel reads the ELF into a reusable staging buffer and runs
  it from there; otherwise it falls back to the embedded blob. The fallback keeps the no-disk `-kernel`
  tests and the UEFI GPT boot path working until the boot disk also carries/attaches a base image.
- The final busybox shell launcher uses the same disk-first path, so an attached packed base image makes
  `/bin/busybox` the source of the interactive shell. Busybox applets still re-exec through busybox as
  before, while native `/bin/ps` is served from the packed base image.
- Tests: `tests/base_image_test.swift` verifies that `/bin/busybox` and `/bin/ps` in `build/base.img` are
  real ELF files, and `tests/disk_exec_test.sh` boots with `build/base.img`, asserts the M11d disk-load
  log lines, and runs `ps` from disk. Wired into `make test`.

#### Embedded blob removed (2026-06-05) — M11 complete

- `kernel/user/user_blob.S` and the `*_elf_*` symbols in `io.h` are **gone**; the kernel no longer carries
  any userland code. The image shrank from ~1.4 MiB to ~208 KiB. The packed base image on disk is the sole
  source of busybox, `/bin/ps`, and every demo (loaded into a 2 MiB physically-contiguous PMM buffer, not
  the 256 KiB bump heap).
- `virtio_blk_init` now brings up each block device, reads sector 0, and **selects the disk whose magic is
  `SWOSBASE`** (falling back to the first block device). This lets a medium carry both a boot disk and the
  base image — needed for UEFI/gfx, where the firmware boots a GPT/ESP disk and the base image rides along
  as a second modern virtio-blk device.
- Every QEMU launch attaches `build/base.img` with `-global virtio-mmio.force-legacy=false`: `make run`,
  the `-kernel` tests (`boot`/`tty`/`busybox`), UEFI (`disk-run`, `uefi_boot_test`), and `run-gfx`. The
  `-kernel` test scripts gained a `blk_args` block; `tty_test` timings were relaxed for disk-loaded demos.
- All 11 `make test` suites green; `BOARD=virtualbox` still builds (its boot path parks before `vfsInit`,
  so it does not load programs).

## Capability/principal core (M12)

### M12a — process security context scaffold (DONE, 2026-06-05)

- Added `kernel/security/security.swift` with the first kernel-native `ProcessSecurityContext`:
  `principal`, `session`, and an explicit capability mask. The boot console context is principal `1`,
  session `1`, with initial capabilities for console, spawn, read-only FS, tmpfs writes, and process
  inspection. This is not Unix `uid==0`; it is the capability/principal model chosen in the roadmap.
- Process table entries now carry that security context. Top-level kernel-launched processes receive the
  boot console context; child processes inherit it through `spawn`/`fork`; `execve` preserves it.
- Added `SYS_SECURITY_INFO` (31), returning the current process security record to EL0. It is introspection
  only; M13 will start using capabilities for enforcement.
- Added `/bin/identitydemo`, packed into the base image and run during boot. It validates the boot
  principal/session/capability mask and forks a child to prove context inheritance. `boot_test.sh` asserts
  the M12a lines; `base_image_test.swift` verifies the demo is present as an ELF.
### M12b — identity store + console-login (DONE, 2026-06-05)

- Added the base-image identity store `/etc/swos/passwd`, one principal per line as
  `name:principal:session:caps:password:shell` (caps a decimal capability bitmask; plaintext passwords for
  bring-up). `root` gets all caps (31); `user` gets spawn|fsread|tmpwrite (14), no console/inspect. A
  compat `/etc/passwd` view ships alongside for tools that expect the Unix file (it is not the security
  source).
- Added the privileged `SYS_LOGIN` (32): `login(principal, session, caps)` replaces the calling process's
  security context, but only if the caller holds `capConsole` (the boot/login context), so an ordinary
  program cannot escalate. The new context is inherited across the subsequent `execve` into the shell.
- Added `/bin/console-login`: reads the store, prompts for login name + password on the console, matches a
  store line, calls `login()` to adopt that context, prints the adopted `principal/session/caps`
  (via `security_info`), and `execve`'s the shell from the store's last field.
- Test: `tests/console_login_test.sh` boots with the base image, runs console-login, rejects a wrong
  password, then logs in as `user` and asserts the adopted context (`principal=2 session=2 caps=14`) and
  that the user shell starts. Wired into `make test` (12 suites green).
### M12c — console-login as init (DONE, 2026-06-05)

- `main.swift`'s shell launcher became `runInit`: it starts `/bin/console-login` (re-read from disk each
  iteration, since the session's shell exec overwrites the shared ELF buffer) instead of launching busybox
  directly. console-login authenticates, then `execve`'s the shell with the adopted context; when a session
  exits, init loops back to a fresh login prompt. A raw-busybox fallback remains for a base image with no
  login program.
- Boot-flow tests updated: `busybox_test`, `disk_exec_test`, and `uefi_boot_test` log in (root/swordfish)
  after the M7 Ctrl-C; `console_login_test` logs in at the init prompt directly; `boot_test` TIMEOUT 20→45s
  because every demo now loads from disk.

### M12d — SHA-256 password hashing (DONE, 2026-06-05)

- The identity store no longer holds plaintext passwords. The password field is `salt$sha256hex`, with a
  per-user salt and `hash = SHA-256(salt + password)` in lowercase hex (e.g. `swos-root$2e03ca04…`).
- `console-login` carries a self-contained Swift SHA-256 (FIPS 180-4; constant table + temporary-allocation
  buffers, no heap) and verifies by recomputing `SHA-256(salt + entered password)` and comparing the hex.
  Verified against the host `shasum -a 256` reference values baked into the store.
- A stronger, iterated/memory-hard KDF (and password change tooling) is a later refinement; this milestone
  removes plaintext storage.

## VFS capability enforcement (M13)

### M13a — open-time capability checks (DONE, 2026-06-05)

- `vfsOpen` now consults the running process's capability mask via `processCurrentCaps()`: a read
  (`O_RDONLY`/`O_RDWR`) requires `capFsRead`, and a write/create (`O_WRONLY`/`O_RDWR`/`O_CREAT`, which only
  the tmpfs accepts) requires `capTmpWrite`. Missing the capability returns `EACCES` (-13). The kernel
  itself (no active process) is treated as fully privileged.
- Checking at open time also gates `read`/`getdents`: a file or directory cannot be opened to read or list
  it without `capFsRead`, so `cat`/`ls` fail up front for a capless principal.
- Added a `guest` principal to `/etc/swos/passwd` with only `capSpawn` (caps = 2). `tests/cap_enforce_test.sh`
  logs in as guest and asserts that `echo` (a shell builtin, no FS access) still works while
  `cat /etc/motd` and `ls /` are denied. root/user keep `capFsRead`, so the existing flows and the
  boot demos (which run under the fully-capable boot context) are unaffected.
### M13b — gate tmpfs namespace mutations (DONE, 2026-06-05)

- `vfsUnlink`/`vfsMkdir`/`vfsRmdir`/`vfsRename` are path-based (they don't go through `vfsOpen`), so they
  now require `capTmpWrite` up front (`mayWriteTmp`) — closing the gap where a capless principal could
  still mutate the tmpfs namespace. `ftruncate`/`write` were already covered: they need a writable fd,
  which `vfsOpen` only hands out with `capTmpWrite`.
- Positive path stays green: `fdopsdemo` (mkdir/rename/unlink under the fully-capable boot context) still
  passes in `boot_test`. There is no shell-level negative test because the busybox-min build ships no
  `mkdir`/`touch` applet; the check is the same `mayWriteTmp` used by the open path, which
  `cap_enforce_test` already exercises for `guest`.

### M13c — file ownership + `ls -l` (DONE, 2026-06-05)

- **Per-vnode owner + mode.** `VNode` (kernel/vfs/vfs.swift) gained `owner: UInt32` (principal; 1 =
  root) and `mode: UInt32` (permission bits; 0 = unset → fall back to the old heuristic, so the
  compiled-in literal tree is unchanged). Disk-backed nodes take owner/mode from the image; a tmpfs
  node is stamped with `processCurrentPrincipal()` at creation, so `ls -l /tmp` reflects who wrote the
  file (the live login context, not always root). New `processCurrentPrincipal()` in
  kernel/user/process.swift mirrors `processCurrentCaps()`.
- **Widened kstat (the ABI was never the risk).** The kernel writes a private `kstat` record, not
  newlib's `struct stat`; `userland/lib/newlib_syscalls.c` translates it, so the C compiler computes
  newlib's offsets from the sysroot header. `writeStatMode` grew from 16 to 24 bytes — `u32 mode,
  u32 uid, u64 size, u32 gid, u32 nlink` (first 16 bytes unchanged, so older readers stay valid) —
  and reports `st_uid = st_gid = owner`, `st_nlink = 1` (no group model; gid mirrors the owner
  principal). `_stat`/`_fstat` copy uid/gid/nlink into newlib's struct; `userland/lib/fs.h` mirrors
  the 24-byte layout. The Swift userland tools (`/bin/ps`, `/bin/id`) don't call stat, so widening is
  safe.
- **SWOSBASE format v2.** The 40-byte entry already reserved a `mode` u32 (off 32) and a spare (off
  36); `tools/basepack.swift` now writes the real mode (dir/exec 0o755, text 0o644 — from the host
  execute bit) and `owner = 1` (root) into off 36, and bumps the version 1 → 2. The kernel parser
  (`buildBaseFromDisk`) requires v2 and reads both fields. Base files are all root-owned; non-root
  ownership is demonstrated at runtime via tmpfs. (A host-side manifest for non-root *base* owners is
  recorded as future work.)
- **busybox `ls -l` shows names.** `scripts/build-busybox.sh` enables `FEATURE_LS_USERNAME` (resolve
  uid/gid → name), `FEATURE_LS_SORTFILES` (alphabetical → deterministic tests), and the `MKDIR`
  applet (so a logged-in principal can create a tmpfs node without shell redirection). The compat
  `getpwuid`/`getpwnam`/`getgrgid`/`getgrnam` (userland/compat/stubs.c) — previously hardcoded to
  "root" — now parse `/etc/passwd` and the new `base/etc/group`; an unknown id returns NULL and
  busybox prints the number. New compat stubs: `getpagesize` (libbb/procps + dd reference it) and a
  no-op `chmod`/`fchmod` (mkdir chmod()s the new dir; the kernel already created it 0o755).
  (Timestamps stay off; the date column shows the 1970 epoch since we have no clock — cosmetic.)
- **Open-flag ABI fix (found while testing).** newlib's `<fcntl.h>` uses BSD values (`O_CREAT 0x200`,
  `O_TRUNC 0x400`) but the kernel ABI is Linux-style (`O_CREAT 0x40`). `newlib_syscalls.c::_open` now
  translates the create/truncate/append bits into the kernel ABI (the access-mode bits already match)
  and sets `errno` on a negative return. The kernel honors `O_TRUNC`/`O_APPEND` on writable tmpfs
  files. This fixes a latent bug: busybox file creation via newlib `open(O_CREAT)` never reached the
  create path before — `vi`'s `:wq` only *appeared* to work because `vi_test` greps the on-screen echo
  of the inserted text. With the fix `vi` genuinely saves.
- **Redirection limitation — RESOLVED in the next milestone** (see "Shell redirection + fcntl" below).
  M13c shipped with `echo > file` non-functional (the demo used `mkdir`); the follow-up implements
  `fcntl` and makes redirection work.
- **Tests.** `tests/base_image_test.swift` asserts version 2, owner 1 on every entry, and the
  expected modes (busybox/ps 0o755, motd 0o644, dirs 0o755). New `tests/ls_l_test.sh` (wired into
  `make test`) logs in as root and asserts `ls -l` shows root-owned `drwxr-xr-x` dirs, `-rwxr-xr-x`
  `/bin/*`, and `-rw-r--r--` text files; then logs in as `user`, runs `mkdir /tmp/d`, and asserts
  `ls -l /tmp` shows `d` owned by `user` — proving a tmpfs node is stamped with the creating principal.

- Follow-ups: enforcement on the read/write syscalls (for contexts that change while an fd is open);
  a host-side ownership manifest for non-root base files; real mtimes/clock; `chown`/`chmod`; and
  richer principals.

## Shell redirection + `fcntl` (DONE, 2026-06-05)

Made busybox shell I/O redirection work (`echo > file`, `>>`, pipe-into-redirect), the top M13
follow-up. ash saves/restores descriptors around every redirect with `fcntl(F_DUPFD_CLOEXEC, 10)`;
newlib's `fcntl` is a hard ENOSYS stub, so it never worked.

- **Root cause of the M13c revert, now fixed.** `F_DUPFD_CLOEXEC` is a *distinct* command number
  (newlib value **14**, not `F_DUPFD`=0). The M13c prototype's `switch` only handled `F_DUPFD`; `14`
  fell to `default: return 0`, so ash read **0 as the duplicated fd** and on restore did
  `dup2(0,1); close(0)` — closing stdin → the shell read EOF and exited. The fix handles
  `F_DUPFD_CLOEXEC`, and crucially makes the `default` case return a **negative error** so an
  unhandled command can never be misread as "fd N".
- **Kernel.** `SYS_FCNTL` (34) → `vfsFcntl` (kernel/vfs/vfs.swift): `F_DUPFD`/`F_DUPFD_CLOEXEC`
  duplicate to the lowest free fd ≥ arg (sharing the open description, like `dup`); `F_GETFD`/`F_SETFD`
  read/write a per-fd close-on-exec flag (`FDEntry.cloexec`); `F_GETFL` returns the stored open flags;
  `F_SETFL` updates mutable status flags; anything else is `EINVAL`. A plain `dup`/`dup2` clears cloexec;
  fork copies it.
- **close-on-exec honored.** `vfsCloseCloexec(slot:)` drops cloexec fds, called from `processExec`
  (kernel/user/process.swift) — POSIX exec semantics, so ash's relocated/redirect-saved fds (it uses
  `F_DUPFD_CLOEXEC`) don't leak into exec'd applets. `O_CLOEXEC` (newlib 0x40000 → kernel `oCloexec`
  0x200, translated in `_open`) marks an fd cloexec at open time.
- **Userland.** newlib's `fcntl` (sysfcntl.o) is a hard ENOSYS stub that never calls a syscall stub,
  so a **strong** variadic `fcntl` in `userland/compat/stubs.c` (pulled before `-lc`) routes to
  `SYS_FCNTL`.
- **Tests.** New `tests/redirect_test.sh` (wired into `make test`): asserts `> file` writes content,
  `>>` appends, `cmd | cat > file` works, and a later `echo` still runs — proving the interactive
  shell **survives** the redirects (the exact regression that caused the M13c revert). `tests/vi_test.sh`
  hardened to match the saved content as a clean line (`^hello-from-vi$`) rather than vi's on-screen
  echo, since the M13c `_open` fix made vi genuinely save (previously a false positive).
- **Follow-up (2026-06-08): nonblocking socket fd status.** `O_NONBLOCK` uses newlib's `_FNONBLOCK`
  value (`0x4000`) because compat `fcntl` passes `F_SETFL` flags directly. `F_SETFL` currently records
  only that mutable status bit in the shared open description; `F_GETFL` reports it with the stored flags.
  TCP `accept`/`read` on nonblocking fds return `EAGAIN` when `socketPollReadable` says no child/data is
  ready, and accepted TCP children inherit `O_NONBLOCK` from the listener. TCP write-side readiness is still
  intentionally limited: there is no `socketPollWritable`/send-space helper, so VFS keeps the existing
  `tcpSend` path instead of peeking into TCP internals.
- Out of scope: `dup3`, file locking (`F_GETLK`/`F_SETLK`).

## Native Swift `/bin/ls` (DONE, 2026-06-05)

A pure-Embedded-Swift `/bin/ls` with `-l` (`userland/ls.swift`), advancing the "Swift everywhere"
first principle and the "more Swift userland utilities" roadmap item. It dogfoods the M13c per-file
ownership work entirely in Swift instead of relying on busybox.

- **What it does.** Lists a directory (or a single file). `-l` formats `mode nlink owner group size
  name`: the mode string from the stat type/permission bits, and owner/group resolved by name from
  `/etc/passwd`/`/etc/group` (numeric fallback when unreadable), reusing the colon-table scan pattern
  from `/bin/id`.
- **Bridge.** `userland/lib/swift_user.{h,c}` gained `swiftos_getdents` (over `SYS_GETDENTS`) and
  `swiftos_stat` (over `SYS_STAT`, unpacking the 24-byte kstat into mode/uid/gid/nlink/size). It walks
  the kernel dirent records (`d_reclen`@16, `d_name`@19) and stats each entry by `dir/name`.
- **Applet shadowing.** The busybox standalone shell runs a bare `ls` as its own applet, so `/bin/ls`
  is invoked by **absolute path** to exec our binary (a command with a `/` is exec'd directly, not
  applet-dispatched — verified). `exec.swift` now routes `/bin/ls` to the packed disk ELF (removed
  from the busybox-applet fallback list); bare `ls` is unchanged (still busybox), so `busybox_test`
  and `ls_l_test` are unaffected.
- **Test.** `tests/swift_ls_test.sh` (wired into `make test`): `/bin/ls /etc` lists entries, and
  `/bin/ls -l` shows `drwxr-xr-x … root root … swos`, `-rw-r--r-- … root root 21 motd`, and a
  single-file `-rwxr-xr-x … /bin/busybox`.
- Out of scope: multi-path args, column/wide output, sorting, `-a`/`-h`/time columns.

## Native Swift `cat` / `echo` / `pwd` (DONE, 2026-06-05)

Three more pure-Swift coreutils (`userland/{cat,echo,pwd}.swift`), continuing the move off busybox.

- **cat** copies files (or stdin when given none) to stdout in 4 KiB chunks. **echo** prints its args
  space-separated + newline, with `-n` to suppress the newline. **pwd** prints `getcwd()`.
- **Bridge.** `swift_user.{h,c}` gained `swiftos_write` (over `SYS_WRITE`) and `swiftos_getcwd` (over
  `SYS_GETCWD`).
- **Invocation.** Like `/bin/ls`, they are reached by absolute path (`/bin/cat` …) — `exec.swift`
  routes `/bin/{cat,echo,pwd}` to the packed disk ELFs (removed from the busybox-applet fallback). A
  bare `cat`/`echo`/`pwd` stays the busybox applet/ash builtin, so existing tests are unaffected.
- **Test.** `tests/swift_coreutils_test.sh` (wired into `make test`): `/bin/echo` prints args,
  `/bin/cat /etc/motd` prints the motd, `cd /etc; /bin/pwd` → `/etc` (proves getcwd + cwd inheritance
  across execve), and `/bin/echo -n` suppresses the newline.

## Native Swift `mkdir` / `rmdir` / `rm` / `mv` (DONE, 2026-06-05)

Pure-Swift tmpfs-mutation utilities (`userland/{mkdir,rmdir,rm,mv}.swift`), built directly on the
existing kernel syscalls (no new kernel work).

- **Bridge.** `swift_user.{h,c}` gained `swiftos_mkdir`/`swiftos_rmdir`/`swiftos_unlink`/
  `swiftos_rename` over `SYS_MKDIR`/`SYS_RMDIR`/`SYS_UNLINK`/`SYS_RENAME`. They only affect the
  writable tmpfs; the base FS is read-only, and the calls already require `capTmpWrite` (M13b).
- **Scope.** `rm` is files-only (no `-r`); `rmdir` removes empty dirs; `mv` is a single rename. Reached
  by absolute path; `exec.swift` routes `/bin/{mkdir,rmdir,rm,mv}` to the packed disk ELFs. (busybox
  ships no mkdir/rm/mv applets in our config except `mkdir`, which is only used by `ls_l_test` as a
  bare command — unaffected.)
- **Test.** `tests/swift_fileops_test.sh` (wired into `make test`): `/bin/mkdir /tmp/d`, write a file,
  `/bin/mv` it, `/bin/ls` confirms the rename and `/bin/cat` confirms content survived, then
  `/bin/rm` + `/bin/rmdir` and `/bin/ls /tmp` confirms removal.

The native-Swift userland now covers `ls cat echo pwd ps id mkdir rmdir rm mv` — a usable coreutils
set, all over the `swift_user` bridge.

## Native Swift `chmod` / `chown` (DONE, 2026-06-05)

`/bin/chmod` and `/bin/chown` (`userland/{chmod,chown}.swift`) plus the two kernel syscalls they need,
completing the M13c ownership story: tmpfs file mode/owner can now actually be changed and is reflected
by `ls -l`.

- **Kernel.** `SYS_CHMOD` (35) → `vfsChmod(path, mode)` sets a node's permission bits; `SYS_CHOWN`
  (36) → `vfsChown(path, owner)` sets its owning principal. Both are tmpfs-only (the base FS is
  read-only → `EROFS`) and require `capTmpWrite`, consistent with the other namespace mutations (M13b).
  Cosmetic only, since tmpfs is ephemeral, but it makes ownership/mode first-class and editable.
- **Tools.** `chmod OCTAL FILE...` (octal mode), `chown UID FILE...` (numeric principal id — swift-os
  principals are small numbers, no name lookup). Bridge: `swiftos_chmod`/`swiftos_chown`.
- **Test.** `tests/swift_chmodown_test.sh` (wired into `make test`): `echo > /tmp/f`,
  `chmod 600` → `ls -l` shows `-rw------- … root`, `chown 2` → `ls -l` shows `… user user`.

Native-Swift userland: `ls cat echo pwd ps id mkdir rmdir rm mv chmod chown`.

## Native Swift `head` / `touch` / `wc` (DONE, 2026-06-06)

Three more pure-Swift coreutils over the existing bridge (no new kernel work, no new bridge calls):
`userland/{head,touch,wc}.swift`.

- **head** prints the first N lines (`-n N`, default 10) of each file, or of stdin. **wc** counts
  lines/words/bytes (`L W C name`), stdin when given no file. **touch** creates each missing file in
  the writable tmpfs (swift-os has no `utimes`, so it is "create if missing", not an mtime bump; the
  base FS is read-only).
- All three are byte-oriented (UnsafePointer + `withUnsafeTemporaryAllocation`), so unlike `/bin/calc`
  they pull no Unicode data tables — they link like `ls`/`cat`. Reached by absolute path; `exec.swift`
  routes `/bin/{head,touch,wc}` to the packed disk ELFs; bare names stay busybox/ash.
- **Test.** `tests/swift_headwc_test.sh` (wired into `make test`): builds a 3-line file with the
  shell, asserts `wc` reports `3 3 14`, `head -n 2 … | wc` reports `2 2 8` (proving head stops at the
  limit), and `touch` + `wc` reports an empty `0 0 0` file.

Native-Swift userland: `ls cat echo pwd ps id mkdir rmdir rm mv chmod chown head touch wc calc`.

## Wall clock: PL031 RTC + `/bin/date` (DONE, 2026-06-05)

swift-os had no clock (timestamps showed the 1970 epoch). Added a real wall clock from the QEMU virt
PL031 RTC.

- **Kernel.** `platform.rtcBase` (QEMU virt `0x0901_0000`; 0 on the VBox board → disabled). `rtcNow()`
  (generic_timer.swift) reads the PL031 data register (Unix seconds; QEMU seeds it from the host).
  `SYS_TIME` (37) returns it to EL0.
- **`/bin/date`** (`userland/date.swift`): prints UTC `YYYY-MM-DD HH:MM:SS`. The epoch→calendar
  conversion (Howard Hinnant's civil-from-days) lives in the C bridge as `swiftos_fmt_time` so `ls`
  can reuse it; `swiftos_time` exposes the syscall.
- **Test.** `tests/swift_date_test.sh` asserts a plausible `20xx-..-.. ..:..:.. UTC` line (year in the
  2020s proves the RTC was actually read, not a zero/epoch fallback).
- Out of scope: timezones, `settimeofday`/RTC writes, DTB discovery of the RTC base (QEMU default is
  hardcoded, like the other pre-discovery defaults).

### Per-file mtime + `ls -l` date column (DONE, 2026-06-05)

Files now carry a real modification time, shown by `ls -l`.

- **Kernel.** `VNode.mtime` (Unix seconds). Set from `rtcNow()` on `createTmpNode` and on every tmpfs
  write/`ftruncate`; the base/literal tree (and `/tmp`) is stamped with the boot time at `vfsInit`, so
  read-only files show a real date instead of 1970. The kstat grew 24→32 bytes (mtime u64 at off 24;
  earlier fields keep their offsets).
- **Userland.** `newlib_syscalls.c` fills `st_mtim`/`st_ctim`/`st_atim` (so busybox `ls -l` shows the
  date too); `fs.h` and the `swift_user` kstat mirror the 32-byte layout; `swiftos_stat` gained an
  `mtime` out-param. Native `/bin/ls -l` prints a `YYYY-MM-DD HH:MM` column (reusing the bridge's
  `swiftos_fmt_time`). `swift_ls_test`/`swift_chmodown_test` updated for the new column.

## Userland editors — busybox vi (DONE, 2026-06-05)

A side feature off the M9→M13 critical path: a usable full-screen text editor. We took the cheap path —
busybox already ships a self-contained `vi` applet (no terminfo/ncurses, draws with hardcoded ANSI escapes)
— rather than porting GNU nano (which would need an ncurses/terminfo port + locale/regex; recorded as larger
future work). The same porting pipeline as M8 busybox: cross-build against `./sysroot` (newlib) + the
`userland/compat` shim layer, link with our crt0/syscall stubs, stage into the packed base image.

- **Enable.** `scripts/build-busybox.sh` now sets `CONFIG_VI` + a curated feature set (COLON, YANKMARK,
  SEARCH, DOT_CMD, SET/SETOPTS, UNDO). Three features are deliberately forced OFF because swift-os's headless
  serial tty breaks their assumptions: `FEATURE_VI_USE_SIGNALS` (needs SIGWINCH/SIGINT delivered to a custom
  handler — the kernel records but does not yet deliver custom handlers), `FEATURE_VI_WIN_RESIZE` (SIGWINCH;
  our console is a fixed 80×24, which `ioctl(TIOCGWINSZ)` already reports), and `FEATURE_VI_ASK_TERMINAL`
  (emits `ESC[6n` and blocks reading the cursor-position report, which our tty never sends back — vi would
  hang at startup). Note: the int-valued config symbols `FEATURE_VI_MAX_LEN`/`FEATURE_VI_UNDO_QUEUE_MAX`
  must be preset to a number before `oldconfig` (it errors on a NEW int symbol fed EOF).
- **Compat fix.** `userland/compat/termios.h` was missing the `c_cc` index `VERASE` (and the rest of the
  Linux `c_cc` table); vi's `isbackspace` macro needs it. Added the full Linux `c_cc` index set.
- **New syscall.** `33 ftruncate(fd, length)` (see Syscall ABI) — vi saves by opening `O_CREAT` (no
  `O_TRUNC`), `full_write`, then `ftruncate` to the exact length, so without it a save that shrinks a tmpfs
  file would leave a stale tail. Architectural constraint kept: the base FS is read-only by design, so vi can
  only save into `/tmp` (tmpfs); editing a base file and `:w`-ing it elsewhere works, overwriting the base
  does not. This is the two-tier FS, not a bug.
- **Root-cause kernel fix (the hard part).** Enabling vi exposed a latent kernel bug: vi crashed the kernel
  (intermittent EL1 data abort in `trap_return` with a wild SP near RAM end, or a lower-EL sync with a wild
  PC) right after drawing its screen. A syscall trace pinned the trigger to `poll()` (syscall 26): vi polls
  stdin with a timeout to disambiguate `ESC` sequences. `vfsPoll` blocked by calling `processYieldForIO()`
  (a cooperative scheduler switch) in a loop with IRQs enabled — and that cooperative-yield-from-inside-a-
  blocking-syscall path is not robust under timer preemption (it can corrupt the resumed trap frame). The
  working `ttyRead` path, by contrast, blocks with `enable_irq()` + `wfi()` and never yields. First fix:
  `vfsPoll` waits with `wfi()` for tty/vnode fds (input arrives via the UART RX IRQ; the timer wakes `wfi`
  for the timeout) — exactly ttyRead's proven pattern, and it avoids a busy-spin for a single foreground
  reader. The cooperative-yield path stays only for pipe sets (a pipe becomes ready only when another
  process writes, so the CPU must be yielded).
- **Root-cause yield fix (the underlying bug).** The cooperative yield itself was unsafe, not just for poll:
  `yieldToScheduler()` ran `cpu_switch_context` with the surrounding `currentProc`/`pState` bookkeeping
  **non-atomically with IRQs enabled**. If a timer tick landed mid-switch it ran `processOnTick` →
  `yieldToScheduler` re-entrantly and overwrote the very `CPUContext` being saved/restored (and the single
  shared `schedCtx`), corrupting the resumed trap frame → the wild SP/PC panic. Why poll exposed it: it
  yields in a tight loop for the whole timeout, so a tick lands in the switch window with high probability;
  spawn/fork-wait yield once and rarely hit it, and the wfi paths never switch. Fix (process.swift):
  `yieldToScheduler` brackets the switch with `irq_save()`/`irq_restore()` (mask across the switch, restore
  the caller's prior IRQ state on resume — preemptive callers entered masked, cooperative ones enabled), and
  the `schedule()` loop runs IRQ-masked end to end, unmasking only around its idle `wfi` (safe: `currentProc
  == -1` there, so `processOnTick` is a no-op and no switch is in flight). Added `irq_save`/`irq_restore` to
  `io.h`. Validated by temporarily forcing vi through the yield path: it crashed reliably before, survives
  3/3 after. With the fix the yield path is preemption-safe, so `vfsPoll`'s pipe branch is sound.
- **Tests.** `tests/vi_test.sh` (wired into `make test`) logs in, runs `vi /tmp/vitest`, inserts text, `:wq`,
  then `cat`s the file back — asserting vi's alternate-screen banner, the saved content (proves
  `:wq`/ftruncate), and a trailing shell marker (proves the kernel did not panic). `fdopsdemo` (run on every
  boot, asserted by `boot_test.sh`) gained a **pipe-poll preemption stress**: a CPU-bound child streams a
  0..63 counter through a pipe, busy-burning between writes so the 100 Hz timer preempts it mid-loop, while
  the parent `poll()`s the pipe with a timeout — crossing `cpu_switch_context` dozens of times under active
  preemption (the exact interleaving that used to panic). The byte counter also catches a dropped/reordered
  wakeup, not just a crash. 13 suites green.
- **Framebuffer console VT100 support.** vi worked on the serial console but was garbage on the graphical
  (ramfb/UEFI-GOP) display: `fb.c` was a line printer that drew `\n \r \b \t` and printable bytes but echoed
  ANSI escapes literally, so vi's cursor-positioning/erase sequences became junk glyphs. Added a small
  VT100/ANSI interpreter to `fb_putc` (a CSI state machine): CUP (`H`/`f`), relative moves (`A/B/C/D`, `G`,
  `d`), erase-in-display (`J`) and erase-in-line (`K`), the alternate-screen private modes
  (`?1049`/`1047`/`47` → clear+home, since vi repaints in full), with SGR (`m`) and other sequences consumed
  and ignored so a stray escape never prints. The erase/move helpers update both the pixel framebuffer and
  the shadow cell buffer (and lift the blinking block cursor first). Keyboard input already worked
  (`virtio_input.c` maps arrows/Home/End/Del to the matching escapes). vi now renders correctly on the
  graphical window. Geometry note: `TIOCGWINSZ` still reports a fixed 80×24, so vi uses the top-left 80×24 of
  the (e.g. 100×37 at 800×600) display; reporting the real framebuffer size is a possible enhancement but
  would also affect serial terminals that share the one tty.
- **Tests (fb).** `tests/fb_vi_test.sh` (wired into `make test`) boots the graphical path headless
  (`-device ramfb -display none`), drives vi over the serial console, screendumps the framebuffer via QMP to
  a PPM, and parses the pixels: it asserts a column of `~` down the left over otherwise-blank lines (proving
  CUP/erase were interpreted, not printed), a non-empty status line near the bottom of the 80×24 editor, and
  no kernel panic. 14 suites green.
- **nano:** not done — it needs an ncurses/terminfo port plus locale/regex, a separate multi-step effort.

## First native Swift app: `/bin/calc` + free-capable allocator (DONE, 2026-06-06)

The first *idiomatic* Embedded Swift EL0 program on swift-os. Every prior userland tool
(`ls`/`cat`/`ps`/`console-login`, …) is hand-rolled with `UnsafePointer`/`withUnsafeTemporaryAllocation`
and manual byte loops — none ever used the high-level runtime, so ARC/`String`/`Array`/`Dictionary`/
generics were *asserted* to work but never exercised, and the bridge's allocator had never been
stressed. `/bin/calc` (an interactive Int64 expression REPL) drives all of it end to end:
classes + ARC, an `indirect enum` AST, `Array`/`String`/`Dictionary<String,Int64>`, generics, a
closure, a protocol witness table, and `print()` with String interpolation.

### Runtime-low decision (locked): extend the minimal bridge, not newlib

For "real" Swift apps we keep building Embedded Swift on **our own `svc` ABI + the
`userland/lib/swift_user.*` bridge**, and we grow the bridge as the runtime demands — rather than
relinking Embedded Swift against newlib for malloc/stdio. Why: it keeps the userland Swift-first and
lightweight; the genuinely missing primitive is a **free-capable allocator** (ARC churn), which is a
~80-line addition, not a reason to pull in a second libc; and a working `malloc`/`free` over `sbrk`
is exactly the bottom end the long-horizon Node/JVM targets will need. Newlib stays the third-party
path (busybox, the newlib port). This is the answer to the session's "what runtime-low" fork.

### Gaps that surfaced (verified empirically, all closed)

- **Allocator never freed.** The old `swift_slowAlloc` only bumped `sbrk`; `swift_slowDealloc`/`free`
  were no-ops. A REPL that builds+drops an AST per line would grow the break monotonically until
  `sbrk` failed. Replaced with a classic **K&R free-list allocator with coalescing** (16-byte units
  → 16-aligned payloads, the Embedded Swift heap alignment; grows the arena from `sbrk` in 64 KiB
  chunks). Now `malloc`/`calloc`/`realloc`/`free` are real; `swift_slowAlloc`/`swift_slowDealloc`
  route through it (over-aligned requests stash the base pointer in the preceding word);
  `posix_memalign` likewise. `calc`'s `:mem` prints `sbrk(0)` and the test asserts the break is
  **identical before/after a 24-line churn** (`0xA0010000` = heap base + one 64 KiB chunk) — proof
  the allocator recycles.
- **`print()` needs `putchar`.** Embedded `print`/String output lowers to `putchar`; added a thin one
  to the bridge over `SYS_WRITE`.
- **`String` compare/hashing needs the Unicode data tables.** Dynamic `String ==` (and so
  `Dictionary<String,_>`) references `_swift_stdlib_getNormData`/`nfd_decompositions`/grapheme-break
  accessors. The toolchain ships `libswiftUnicodeDataTables.a` for `aarch64-none-none-elf`; we link
  it into `/bin/calc` only (`SWIFT_UNICODE_DATA` in the Makefile), and `--gc-sections` trims its
  825 KiB to just the referenced tables (final ELF ~160 KiB). `Dictionary`/`Set` also need
  `arc4random_buf` (hash seed) — added a deterministic fill to the bridge (reproducible; the seed
  only randomises hash-table iteration order, and we have no entropy source).
- **FP at EL0 is fine** (not relied upon): `boot.S` sets `CPACR_EL1.FPEN=0b11`, which permits FP/SIMD
  at EL0 too, so scalar FP would not trap. The calculator core stays Int64 anyway so acceptance does
  not hinge on soft-float/compiler-rt; floating point is recorded as available for a future app.

### Files / tests

- `userland/calc.swift` — the REPL (lexer → `indirect enum Expr` → recursive-descent parser →
  `final class Env` with `Dictionary` → recursive evaluator returning an `EvalResult` enum). `:help`
  `:mem` `:vars` `:sum` `:q` commands.
- `userland/lib/swift_user.{c,h}` — the allocator, `putchar`, `arc4random_buf`, `swiftos_heap_break`.
- `kernel/user/exec.swift` — `/bin/calc` routing (disk-backed, like the other Swift tools).
- `Makefile` — `SWIFT_UNICODE_DATA`, `user_calc.o`/`$(USER_CALC_ELF)` rules (calc links the Unicode
  tables), base-image staging.
- `tests/calc_test.sh` (wired into `make test`): precedence/parens/assignment+lookup/modulo/unary/
  division-by-zero/`:sum`, plus the bounded-heap churn assertion, then returns to a working shell.
- Out of scope: floating point, multi-line input, functions/conditionals, REPL history editing.

## Second native Swift app: `/bin/kv` (DONE, 2026-06-06)

An in-memory key-value store REPL — the second idiomatic Embedded Swift EL0 app. Where `calc`
stressed the runtime through a recursive-enum AST + ARC, `kv` leans on the **String/Unicode**
machinery: it stores arbitrary user-supplied keys and values in a `Dictionary<String, String>`
behind a `final class Store`, so every `SET`/`GET`/`DEL` **hashes text the user typed** (calc only
ever hashed `String` keys it minted itself), `KEYS` **sorts** those keys (`String: Comparable`,
Unicode-ordered), the verb dispatch runs through `.uppercased()` (Unicode case mapping), and
`:stats` reduces over `map.values` with a closure (`reduce(0) { $0 + $1.utf8.count }`). No new
kernel work and no new bridge calls — it reuses the calc-era allocator/`putchar`/`arc4random_buf`
and links `libswiftUnicodeDataTables.a` (`SWIFT_UNICODE_DATA`), trimmed by `--gc-sections`.

- Commands: `SET k v…` (value keeps interior spaces — the rest of the line), `GET k`, `DEL k`,
  `KEYS` (sorted), `COUNT`, plus `:stats` / `:mem` / `:help` / `:q`. Line parsing is a small
  `splitFields(line, max:)` over the UTF-8 bytes so the value field preserves spaces.
- Files: `userland/kv.swift`; `kernel/user/exec.swift` routes `/bin/kv` (disk-backed); `Makefile`
  `user_kv.o`/`$(USER_KV_ELF)` rules (links the Unicode tables like calc) + base-image staging.
- `tests/kv_test.sh` (wired into `make test`): SET with a multi-word value, GET/DEL of a missing key
  (`(nil)`), DEL of a present key, COUNT 3→2, KEYS sorted, `:stats`, then a SET/DEL **churn loop**
  with two `:mem` readings asserting the heap break stays identical (the free-capable allocator
  recycles), and a final return to the shell. The QEMU window is 75 s (boot+login+churn under
  emulation lags the scripted feed; the suite is sequential, so this is comfortable in practice).
- Out of scope: persistence (in-memory only, lost on exit by design), value quoting, TTL/expiry.

Native-Swift userland: `ls cat echo pwd ps id mkdir rmdir rm mv chmod chown head touch wc date
calc kv`.

## Open decisions / resolved

- [x] Runtime-low for native Swift apps (2026-06-06): **extend the `swift_user` bridge** (real
  free-capable allocator on our own ABI), not Embedded-Swift-on-newlib. See the calc section above.
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

## Network stack (N-series) — own Swift, sans-IO

The next major arc is our own TCP/IP stack in Embedded Swift, following the sans-IO direction recorded
in `docs/ARCHITECTURE.md` ("Future network stack model"). Decisions locked at net-a:

- **In-kernel for now.** ARCHITECTURE's long-horizon target is a userland driver/stack *service* gated by
  capabilities, but restartable driver services are a non-goal "this stage" and the codebase is
  monolithic. net-a keeps the driver and the protocol core in-kernel. The **sans-IO purity** of the core
  is what preserves the option to lift it into a userland service later without rewriting its logic.
- **Zero-copy data path.** RX buffers are PMM pages the device DMAs into; the sans-IO core reads the
  Ethernet frame straight out of the RX buffer (no bounce copy in), and replies are written directly into
  the TX DMA buffer and handed to the transmit ring by address (no copy out). Only the 12-byte
  `virtio_net_hdr` is added. Honors the ARCHITECTURE N0–N4 zero-copy requirement from the start.
- **sans-IO core in `kernel/net/*.swift`** — pure Swift, no MMIO/heap-per-packet/syscalls — compiled both
  into the kernel (Embedded) and into a host unit test (`tests/net_test.swift`), exactly like `fdt.swift`
  ↔ `tests/fdt_test.swift`. The control-plane ARP cache is the only heap use; the per-packet path does
  not allocate.

### net-a — virtio-net driver + sans-IO Ethernet/ARP/IPv4/ICMP (DONE, 2026-06-06)

- **Driver `kernel/drivers/virtio_net.swift` (Swift).** Mirrors `virtio_blk.c` but in Swift (the project
  default; `uart.swift` is the Swift-MMIO precedent) with **two** virtqueues plus an RX buffer pool. Scans
  the HAL virtio-mmio window for a modern device id 1, negotiates `VIRTIO_F_VERSION_1` (+ `VIRTIO_NET_F_MAC`
  when offered), reads the MAC from config space, sets up the receive (queue 0) and transmit (queue 1)
  rings from PMM pages, pre-fills the RX ring, and polls the used rings (IRQs masked, like the blk driver
  and virtio-input). MMIO + cache maintenance go through the io.h C bridge (new `dc_cvac`/`dc_ivac`/`dsb_sy`
  inlines); everything else is Swift, including `~Copyable`-style buffer ownership via the PMM pool.
- **sans-IO core `kernel/net/`.** `packet.swift` (byte/BE helpers, RFC 1071 internet checksum, `MAC`),
  `ethernet.swift`, `arp.swift` (request/reply + a tiny ARP cache), `ipv4.swift` (no options/frag),
  `icmp.swift` (echo), and `stack.swift` (`NetStack.onFrame` + `buildArpRequest`/`buildEchoRequest`). The
  core consumes one received frame and writes any reply into a caller buffer; it does no I/O. NB: ARP
  `spa` is at offset 14 (after the 6-byte `sha` at 8), not 12 — an early bug caught by the host test.
- **Boot probe `runVirtioNetProbe` (kernel/main.swift)**, run after `vfsInit`: brings up virtio-net, ARPs
  the slirp gateway `10.0.2.2`, then sends an ICMP echo request and waits for the reply, logging
  `net-a OK: ICMP echo reply from 10.0.2.2`. A no-op (one log line) when no NIC is attached, so the other
  boot/test paths are unchanged (mirrors `runVirtioBlkProbe`). Static addressing: guest `10.0.2.15`,
  gateway `10.0.2.2`; no DHCP yet.
- **Tests.** `tests/net_test.swift` (host) feeds crafted frames and asserts ARP request/reply build +
  parse, ARP-cache population, IPv4/ICMP checksum correctness, echo reply recognition, the inbound echo
  responder, and rejection of runt/bad-checksum frames. `tests/virtio_net_test.sh` boots `-kernel` with
  `-netdev user,id=n0 -device virtio-net-device,netdev=n0` and asserts the three `net-a` serial lines.
  Both wired into `make test`.
- **QEMU launch:** the slirp gateway answers ARP for and ICMP echo to `10.0.2.2` while the guest spins —
  the vCPU busy-poll does not starve QEMU's iothread, so the reply arrives. Acceptance is guest-initiated
  because slirp does not reliably originate ICMP to the guest headless.

### net-b — sans-IO UDP + a capability-gated socket syscall surface (DONE, 2026-06-06)

- **sans-IO UDP `kernel/net/udp.swift`** (pure, host-tested): parse/build + the IPv4 pseudo-header
  checksum, reusing a new `sumBytes`/`sumWord`/`foldChecksum` accumulator in `packet.swift` (so a checksum
  can span the pseudo-header + UDP header + payload). `NetStack.onFrame` gained a UDP branch that *reports*
  a received datagram via `RxOutcome` (gotUDP, src IP/port, dst port, payload offset+len) without copying,
  plus `buildUDP`; it also now learns L2 from inbound IPv4 (`arp.insert(ipSrc, ethSrc)`) so replies route
  without an extra ARP.
- **Sockets are VFS fds.** New `fdKindSocket` in `kernel/vfs/vfs.swift`; `OpenDescription.node` indexes a
  kernel socket table. `close`/`poll` work uniformly (poll pumps the NIC when a socket fd is present).
- **Kernel socket layer `kernel/net/socket.swift`** (kernel-only, not in the host test): one shared live
  `NetStack` (`gNet`), brought up once by `netInit()`; a fixed socket table with a small per-socket
  datagram ring backed by a single PMM region. `netPump()` drains the NIC and routes UDP to bound sockets
  (`socketDeliverUDP`, called from `virtioNetPoll`). `socketRecv` pumps until a datagram arrives or a
  bounded timeout. `socketSend` routes via the ARP cache, falling back to the slirp gateway. net-a's probe
  now shares `gNet`/`netInit` instead of a local stack.
- **Syscalls 38–41:** `socket`/`bind`/`sendto`/`recvfrom`. `socket()` requires the new `capNet` (1<<5);
  the boot context and `root` (store caps 31→63) hold it. The 3-arg ABI is kept: `sendto`/`recvfrom` pass
  a small `swiftos_udp_msg` struct by pointer (buf/len/ip/port), validated via `user_access`.
- **Userland:** `swiftos_socket/bind/sendto/recvfrom` in the `swift_user.*` bridge; `userland/udpecho.swift`
  → `/bin/udpecho` binds UDP 5555, echoes the first datagram, prints the size/sender.
- **Tests:** `tests/net_test.swift` gained UDP cases (build/parse + pseudo-header checksum + bad-checksum
  reject). `tests/udp_echo_test.sh` boots with `-netdev user,hostfwd=udp::5555-:5555`, runs `/bin/udpecho`,
  sends a datagram from the host with `nc -u`, and asserts the guest's "got 8 bytes from 10.0.2.2:" line
  **and** that nc received the echo back. Both wired into `make test`. (`busybox_test` updated: root caps
  now `0x3f`.)

### net-c1 — sans-IO TCP connection state machine (DONE, 2026-06-06)

- **`kernel/net/tcp.swift`** (pure, host-tested): TCP segment parse/build + the pseudo-header checksum
  (reusing `sumBytes`/`sumWord`/`foldChecksum`), wraparound-safe sequence comparisons (`seqLT`/`seqLEQ`,
  RFC 1982), and a `TCPConnection` state machine. It consumes parsed inbound segment fields (+ payload +
  a `now` tick) and emits outbound segment *descriptors* (`TCPSegmentOut`: flags/seq/ack/window/payload
  span) into a fixed queue the caller drains — no I/O, no kernel state, identical Swift for kernel and host.
- **Scope:** passive open (LISTEN→SYN_RCVD→ESTABLISHED) and active open (→SYN_SENT→ESTABLISHED); in-order
  data with cumulative ACK (out-of-order/old → drop + re-ACK); an app send buffer with a single-timer RTO
  retransmit of the oldest unacked data; a fixed window; the full close handshake (active
  FIN_WAIT_1→FIN_WAIT_2→TIME_WAIT; passive CLOSE_WAIT→LAST_ACK→CLOSED); RST. The SYN/FIN phantom sequence
  numbers are handled (passive-open completion is an explicit branch since `processAck` only tracks data +
  a queued FIN). **Intentionally deferred to net-c2+:** out-of-order reassembly, delayed ACK, Nagle,
  congestion control beyond the fixed window, SACK, timestamps. ISS is fixed (`0x1000`) for net-c1
  determinism; net-c2 seeds it from the RTC.
- **Not wired into the kernel yet** — the engine is dead code in the image (`--gc-sections` drops it) until
  net-c2 connects it to sockets. It compiles into the kernel (Embedded) to keep it building.
- **Tests:** `tests/net_test.swift` drives the engine with crafted segments — checksum, passive handshake,
  in-order data + cumulative ACK, old-segment re-ACK, app send + ACK drain, RTO retransmit, passive close,
  active open + active close, and RST — plus the sequence-wraparound comparisons. Host gate in `make test`.

### net-c2 — TCP sockets + /bin/tcpecho, in-QEMU (DONE, 2026-06-06)

- **`NetStack` reports TCP** (stays pure): `onFrame`'s IPv4 path validates the TCP checksum and fills
  `RxOutcome` TCP fields (flags/seq/ack/window/payload offset+len); `buildTCP` builds a segment frame
  (payload placed before the header so the checksum covers it). `tcp.swift` gained an ISS parameter on the
  open calls and `copySegmentPayload`.
- **Kernel TCP sockets** (`kernel/net/socket.swift`): the socket table carries a protocol tag; a TCP socket
  is a listener or a connection (owns a `TCPConnection`, keyed by the 4-tuple). `socketDeliverTCP` (called
  from `virtioNetPoll`) demuxes by 4-tuple, spawns a connection on a SYN to a listener, drives `onSegment`,
  and `tcpDrain` transmits the emitted segments via `buildTCP`. `tcpListen`/`tcpAccept`/`tcpRecv`/`tcpSend`
  back the syscalls; `socketClose` sends a FIN first. ISS seeded from `rtcNow()`.
- **Accept latch (bug fixed during bring-up):** a fast client (nc) sends SYN→ACK→data→FIN within one NIC
  pump, so the connection races past `.established` to `.closeWait` before `accept` polls. `accept` now
  matches a one-shot "handshake completed" latch (set on the `established` event) rather than the live
  state — otherwise `accept` never returns for a quick client.
- **Sockets-as-fds:** `vfsSocket` honors `type` (SOCK_STREAM→TCP); new `listen`(42)/`accept`(43) syscalls;
  TCP streams use `read`/`write` on the connection fd (`vfsRead`/`vfsWrite` dispatch `fdKindSocket`+TCP to
  `tcpRecv`/`tcpSend`); `poll` reports a listener readable when a connection awaits accept, a connection
  when it has data or peer-closed. UDP keeps sendto/recvfrom.
- **Userland:** `swiftos_socket_stream`/`listen`/`accept` bridges (stream I/O reuses `swiftos_read`/`write`);
  `userland/tcpecho.swift` → `/bin/tcpecho` (bind 5555, listen, accept one connection, read a chunk, echo,
  close).
- **Acceptance:** `tests/tcp_echo_test.sh` boots with `-netdev user,hostfwd=tcp::5555-:5555`, runs
  `/bin/tcpecho`, connects with `nc`, and asserts the guest's "got N bytes" line + that nc received the echo
  — the full SYN/data/echo/FIN round-trip. Wired into `make test`.
- **Deferred:** accept backlog > 1, graceful TIME_WAIT after close (the slot is freed once the FIN is
  flushed), congestion control. **net-c (a+b+c1+c2) is complete.**

### net-d — TCP connect() (active client) + /bin/tcpget (DONE, 2026-06-06)

- **`socketConnect`** (`kernel/net/socket.swift`): assigns an ephemeral local port, resolves the dest MAC
  (ARP cache → slirp gateway), `activeOpen`s the `TCPConnection` (RTC-seeded ISS), drains the SYN, then
  pumps the NIC until the established latch fires or a timeout — the 4-tuple demux already routes the
  SYN-ACK back. `netPump` now also runs each live TCP connection's `tick` + drain (RTO retransmit), closing
  a net-c2 gap.
- **`connect(fd, ip, port)` = syscall 44** (fits the 3-arg ABI directly — no arg struct). `vfsConnect`
  validates the fd/port; read/write/close on the connected fd reuse the net-c2 stream paths.
- **Userland:** `swiftos_connect` bridge + `userland/tcpget.swift` → `/bin/tcpget [ip] [port]` (dotted-IP
  parser; default `10.0.2.2:5555`): connect, send a request line, read the reply, print it, close.
- **Acceptance:** `tests/tcp_connect_test.sh` runs a host `nc -l 5555` server (QEMU slirp maps `10.0.2.2`
  to the host, so it is reachable with no hostfwd), boots, runs `/bin/tcpget`, and asserts the guest
  received the server's `srv-reply` (host→guest) **and** the guest's request appears on the wire
  (guest→host) via a QEMU `filter-dump` pcap. The pcap is used for the guest→host check because nc's
  file output is block-buffered and its exit timing is unreliable — the guest's TX bytes on the NIC are
  the deterministic signal. (A live debug confirmed the guest correctly transmits data even from
  CLOSE_WAIT when a fast server FINs first.)
- **Deferred:** DNS/name resolution (numeric IP only), a real ephemeral-port allocator (currently
  `40000 + slot`). The TCP stack now does **both** directions: inbound server (`/bin/tcpecho`) and
  outbound client (`/bin/tcpget`).

### net-e — concurrent poll()-driven HTTP server /bin/httpd (DONE, 2026-06-06)

- **A real concurrent server**, the stated purpose of swift-os. `userland/httpd.swift` → `/bin/httpd`:
  `socket`/`bind(8080)`/`listen`, then a single `poll()` event loop multiplexing the listener plus all
  live connections (fixed table, cap 8). On listener-readable it `accept`s and tracks the new fd; on
  connection-readable it reads the request, sends a fixed `HTTP/1.0 200 OK` + `Hello from swift-os`
  (built via `StaticString.withUTF8Buffer` — no String/Array/unicode-table dependency), and closes
  (Connection: close). Concurrency is real: several connections are in flight across poll iterations.
- **Kernel at the time: no change needed.** `vfsPoll` already pumps the NIC and reports socket readiness
  (`socketPollReadable`: a listener is readable when a connection awaits accept, a connection when it has
  data or peer-closed), and `socketDeliverTCP` spawns a connection socket per SYN. The calls are
  *poll-gated*, so the existing blocking `accept`/`read` returned immediately; later nginx work added
  minimal `O_NONBLOCK` handling for direct nonblocking socket calls.
- **Only new plumbing:** a `swiftos_poll(fds, nfds, timeout_ms)` userland bridge over the existing
  `SYS_POLL` (26); the Swift caller builds the 8-byte `pollfd` records (fd@0/events@4/revents@6) in a
  scratch buffer. Reached by absolute path (`/bin/httpd`).
- **Acceptance:** `tests/httpd_test.sh` boots with `hostfwd=tcp::8080-:8080`, runs `/bin/httpd`, fires
  **two concurrent** host `curl`s (falls back to an `nc`-built GET), and asserts both receive the body
  **and** the serial shows ≥2 `httpd: 200` lines — concurrent serving end to end. Wired into `make test`.
- **Deferred:** keep-alive (HTTP/1.0 close only), request parsing/routing (responds to any request),
  `maxSockets`/conn-table caps (8). swift-os now hosts a working concurrent network server.

## Process/resource monitor: native Swift `/bin/top` + CPU/mem accounting (DONE, 2026-06-07)

A live `top` (`userland/top.swift`) — the natural successor to `/bin/ps`. `ps` was a one-shot dump
because the kernel had no CPU/memory accounting ("CPU, memory, tty, and time columns need more kernel
accounting", M8 note). This adds that accounting and renders it as a refreshing top-style screen:
a summary header (uptime, task states, CPU busy/idle, RAM total/used/free, and the kernel's own
footprint) plus a per-process table (PID/PPID/USER/STATE/%CPU/RES/TIME+/COMMAND) sorted by %CPU.

- **Kernel accounting (`kernel/user/process.swift`).** New parallel arrays: `pCpuTicks` (per-process
  CPU ticks), `pStartTick` (systemTicks at creation), `pResPages` (resident user pages), plus an
  `idleTicks` counter. RES is tracked at the obvious map sites: `createProcess` = ELF image pages +
  stack; `fork` copies the parent's count (the eager clone duplicates every page); `execve` resets to
  the new image; `sbrk` adds heap growth. The image page count comes from `elf.c`, which now exports
  `elf_last_load_pages()` (distinct frames the last `elf_load` mapped — counted only on a fresh
  `pmm_alloc_page`, not on a shared-page perm upgrade).
- **EL0-charged CPU time.** `processOnTick` now takes `fromEL0`: it charges a tick as *user* time to
  the running process only when the timer interrupted EL0; EL1 ticks (the scheduler's idle `wfi`, and a
  process parked in a `wfi`-based blocking syscall such as `poll`/`read`) count as idle. `irqHandler`
  reads `SPSR_EL1.M` at entry (still the pre-IRQ PSTATE — no nested EL1 exception is taken before it)
  and passes it down. Effect: an idle system reads ~100% idle and a process sleeping on input reads ~0%
  CPU, while a CPU-bound EL0 loop reads ~100%. The preemption decision is byte-identical to before — only
  which counter increments changed. Limitation (documented in the code): kernel "system" time is
  bucketed into idle, since a real syscall doing work and a syscall parked in `wfi` both look like
  "currentProc at EL1"; a separate sy% would need to tell them apart.
- **Syscalls 45/46.** `sysinfo(buffer)` fills a 64-byte stats blob; `procstat(buffer, capacity)` fills
  56-byte per-process records. Both are additive — the 32-byte `psinfo` (22) record is untouched, so
  `/bin/ps` keeps working. Memory totals come from `platform.ramSize`, `pmm_free_count`/`pmm_total_count`
  (new), the kernel image span (`__image_end − (ramBase + 0x80000)`), and `swiftos_kernel_heap_used_bytes`.
  `generic_timer.swift` now publishes `timerHz` for tick↔second conversion.
- **Userland.** `/bin/top` is a pure byte-oriented Embedded Swift program (no String/Unicode tables, so
  it links ~27 KiB like `/bin/ps`, not ~160 KiB like `calc`). It builds each frame in one 8 KiB buffer
  and writes it once. %CPU is a per-interval rate from the delta in a process's CPU ticks between
  refreshes (the first frame falls back to the since-start average). USER resolves the principal→name
  from `/etc/swos/passwd` (the `id`/`ls` colon-scan pattern), TIME+ is `M:SS.cc` (centiseconds, exact at
  100 Hz), RES is in KiB. The bridge (`swift_user.{c,h}`) gained `swiftos_sysinfo_refresh`/`swiftos_top_refresh`
  + scalar accessors (the proven `ps` pattern, so Swift never touches a C struct field) and `swiftos_set_raw`
  (clear ICANON+ECHO for single-key `q`, keep ISIG).
- **Modes.** `top` interactive (clear+repaint every 2s via an ANSI home, raw tty, `q` to quit — the
  delay is a `poll(stdin, timeout)` that doubles as the quit check); `top -b` batch (no cursor/raw, for
  scripts/logs); `top -d SECS` delay; `top -n N` iterations; `top -h`. Reached by absolute path; routed
  in `exec.swift`. Caveat: interactive mode left raw if killed by Ctrl-C (no custom signal delivery yet) —
  the next shell resets its own termios; `q` is the clean exit.
- **Test.** `tests/top_test.sh` (wired into `make test`): logs in as root, runs `/bin/top -b -n 2 -d 1`,
  and asserts the uptime/Tasks/Cpu/Mem/Kernel header lines, the column header, that **two** frames
  rendered (the refresh/%CPU-delta path), that top lists its own row, and that the shell survives top.

Native-Swift userland: `ls cat echo pwd ps top id mkdir rmdir rm mv chmod chown head touch wc date
calc kv`.

### Kernel memory footprint (measured 2026-06-07, before this feature)

Recorded because `/bin/top`'s `Kernel:` line reports it live. For the QEMU `virt -m 256M` build at the
time `/bin/top` was added (`llvm-size build/kernel.elf` + the linker symbols + the boot log):
- Static: `.text`+`.rodata`+`.got` ≈ 140 KiB, `.data` ≈ 2.3 KiB, `.bss` ≈ 55 KiB → ELF `dec` ≈ 197 KiB;
  `kernel.bin` (flat, loadable) ≈ 142 KiB.
- Resident at boot (`_start` 0x4008_0000 → `__image_end`, = 0x81A50 ≈ **519 KiB**): 144 KiB code/data +
  55 KiB bss + 64 KiB boot stack + 256 KiB early bump heap (of which only ~96 B used at M1, ~50 KiB
  after full boot).
- Dynamic: of 256 MiB RAM the PMM reports **65276 free frames** right after init (~254.98 MiB free), so
  the kernel + the 512 KiB sub-load-base hole + the bitmap consume ~1.02 MiB before any process runs.
  The accounting/syscalls added by this feature grow the image by ~3 KiB (top's `Kernel:` line then
  reads ~522 KiB).

### net-f — DNS resolver: sans-IO codec + resolve syscall + /bin/nslookup (DONE, 2026-06-07)

- **sans-IO codec `kernel/net/dns.swift`** (pure, host-tested): `dnsBuildQuery` (header + length-prefixed
  QNAME labels + QTYPE A/QCLASS IN) and `dnsParseResponse` (validate id/response/rcode, skip the question,
  walk answers, return the first A record). Handles **name-compression pointers** (`0xC0`) when skipping
  names and bounds-checks every read (a malformed/hostile response can't over-read).
- **Kernel resolve `dnsResolve`** (`kernel/net/socket.swift`): a transient UDP socket (reusing
  `socketCreate`/`Bind`/`Send`/`Recv`) sends the query to a DNS server and parses the reply. Query id from
  `rtcNow()`; a dedicated PMM scratch page holds the query/response. `serverIP == 0` defaults to slirp's
  DNS at **10.0.2.3:53**.
- **`resolve(name, server_ip, server_port) = syscall 45`**, gated on `capNet`; returns the IPv4 in x0
  (0 = failure), a value return like `time`. `userland/nslookup.swift` → `/bin/nslookup <name> [server]
  [port]` prints `name -> a.b.c.d`.
- **Tests:** `tests/net_test.swift` gained DNS cases (query encoding; parse an A record reached via a
  compression pointer; CNAME-then-A; NXDOMAIN/wrong-id → 0). `tests/dns_test.sh` runs a tiny host `python3`
  UDP DNS responder (answers any A query with `192.0.2.7`); the guest `/bin/nslookup test.swos 10.0.2.2
  5354` queries it (slirp routes guest→`10.0.2.2` to the host) and prints `test.swos -> 192.0.2.7` — fully
  hermetic. Skips cleanly if `python3` is absent. Wired into `make test`.
- **Deferred:** connect-by-name in `/bin/tcpget` (small follow-up), caching, IPv6/AAAA, a real ephemeral
  port allocator. `/bin/nslookup name` (no server) resolves against slirp's real DNS for interactive use.

### net-g — static-file HTTP server (/bin/httpd serves the VFS) (DONE, 2026-06-07)

- **`/bin/httpd` now serves real files** instead of a canned body. Per connection it parses the request
  line (`GET <path>`), maps the path into a **`/www` docroot** on the VFS (`/` → `/www/index.html`), and
  streams the file with a `stat`-derived `Content-Length` (`open`/`read`→`write` in chunks), 404 on miss.
  The poll() concurrency from net-e is unchanged. Userland-only (`userland/httpd.swift` + the existing
  `open`/`read`/`close`/`stat` bridge); no kernel change.
- **Docroot, not the whole VFS:** only `base/www/` is reachable (seed files `index.html`, `hello.txt`), so
  the server never exposes `/etc/swos/passwd` etc. A path-traversal guard rejects any `..` in the request
  path (and requires a leading `/`) → 404; verified a raw `GET /../etc/swos/passwd` returns 404, no leak.
- **Tests:** `tests/httpd_test.sh` updated — two concurrent `curl`s for `/index.html` both get the page
  (concurrency), `/hello.txt` returns its content (file serving), a missing path returns HTTP 404, and the
  serial shows ≥2 `httpd: 200` lines. `base/www/*` ride along via the existing `BASE_SEED_FILES` glob.
- **Deferred:** keep-alive, MIME types (all served as `text/html`), large-file streaming beyond a chunk
  loop is present but untuned, directory listings. swift-os now serves its filesystem over HTTP.

### net-h2 — HTTP MIME types + directory listing (DONE, 2026-06-07)

- **MIME by extension:** `/bin/httpd` derives `Content-Type` from the request path's final extension
  (`.html`→`text/html`, `.txt`→`text/plain`, `.css`/`.js`/`.json`, else `application/octet-stream`) instead
  of the net-g hardcoded `text/html`. The extension is the last `.` within the final path segment (a `/`
  resets the scan).
- **Directory listing:** when the resolved `/www` path `stat`s as a directory (`S_IFDIR`), httpd reads it
  with `swiftos_getdents` (same dirent layout as `/bin/ls`) and serves a generated HTML index (skipping
  `.`/`..`), buffered so `Content-Length` is accurate. `/` still prefers `/www/index.html`; a dir with no
  index (the new seed `base/www/sub/`) gets the listing. The `..` guard is intact. Userland-only.
- **Test:** `tests/httpd_test.sh` extended — `GET /hello.txt` carries `Content-Type: text/plain` (via
  `curl -D -`), and `GET /sub/` returns a listing containing `note.txt`, alongside the net-g concurrent
  index + 404 assertions.
- **Deferred:** keep-alive, percent-decoding, HTML-escaping dirent names, listing sort/size columns.

### net-rob — TCP/socket robustness (DONE, 2026-06-07)

Hardening pass, no new syscalls. Confined to `kernel/net/tcp.swift`, `kernel/net/socket.swift`,
`tests/net_test.swift`.

- **Ephemeral-port allocator.** A pure rotating allocator `nextEphemeralPort(cursor:inUse:)` over the IANA
  dynamic range **49152–65535** now lives in `tcp.swift` (sans-IO, so the host net_test can unit-check it).
  `socket.swift` keeps a live `ephemeralCursor` and an `inUse` predicate over the bind table; `socketConnect`,
  the UDP `socketSend` (implicit bind on first send), and `dnsResolve` all draw from it, replacing the old
  `40000 + slot` scheme so two concurrent outbound connections (or a slot reused after close) can't collide
  on a stale port. The cursor wraps within the range and skips ports another bound socket already holds.
- **Larger connection tables.** `maxSockets` 16 → **32**. The socket buffer pool scales with it
  (`sockBufBytes = 32·4·1536 = 192 KiB` → `sockBufPages = 48`, one PMM alloc at `netInit`); the DNS scratch
  is a separate single page, unaffected. Memory cost is ~24 KiB extra, allocated once.
- **TCP teardown edge cases (engine).** A **RST** from *any* non-LISTEN state (incl. SYN_SENT, the
  FIN_WAIT/CLOSING/CLOSE_WAIT/LAST_ACK close states, TIME_WAIT) now cleanly tears down: state→CLOSED, RTO
  off, queued output dropped, and both `ev.reset` **and** `ev.closed` flagged. **TIME_WAIT** already decays
  to CLOSED via `tick` after `tcpTimeWaitTicks`; simultaneous-close ordering is correct (FIN before the
  ACK-of-our-FIN → CLOSING → TIME_WAIT once acked; FIN+ACK together → TIME_WAIT directly).
- **Slot reaping (socket layer).** `netPump` now calls `reapConnIfDead` per live connection: a
  listener-spawned connection that reaches CLOSED (TIME_WAIT having decayed) **and was never accepted** is
  freed, so a refused/reset backlog entry or a TIME_WAIT remnant can't leak the (now larger) table.
  Accepted connections stay owned by their fd and are freed only by `socketClose` (which already discards the
  engine state regardless of TIME_WAIT), and active-open sockets (`sockListenerOf == -1`) are never reaped
  out from under the app.
- **Tests (`tests/net_test.swift`):** added RST-from-ESTABLISHED, RST-from-FIN_WAIT_1/FIN_WAIT_2,
  full active+passive close → TIME_WAIT → CLOSED (driving `tick` past the timer), simultaneous-close →
  CLOSING → TIME_WAIT, and an ephemeral-allocator unit check (rotation, skip-in-use, wrap). All prior cases
  still pass; the two in-QEMU acceptance scripts (`tcp_echo_test.sh`, `tcp_connect_test.sh`) still pass.
- **Deferred:** TIME_WAIT FIN re-ACK on a peer retransmit, SO_REUSEADDR semantics, a per-connection RTT
  estimator (RTO is still a fixed 1 s). The wider table is a cap bump, not a dynamic table.
### net-h — ChaCha20-Poly1305 AEAD (RFC 8439), TLS groundwork (DONE, 2026-06-07)

- **Pure crypto module `kernel/crypto/chacha20poly1305.swift`** (no Foundation/MMIO/syscalls/heap, same
  purity as `kernel/net/packet.swift`, so it compiles both for the host test and for the kernel — Embedded):
  - `chacha20Block` (20-round keystream block) and `chacha20Encrypt(key, counter, nonce, in, out, len)`
    (the symmetric stream cipher; `out` may alias `in`). 256-bit key, 96-bit nonce, 32-bit block counter.
  - `poly1305Mac(key, msg, len, tagOut)` — the one-time MAC over GF(2^130 − 5), implemented with a
    schoolbook 5×26-bit-limb multiply-reduce (no 128-bit-int dependency), final reduction + add-s.
  - `aeadSeal(...)`/`aeadOpen(...) -> Bool` — the AEAD construction (§2.8): block-0 keystream derives the
    Poly1305 key, ChaCha20 from counter 1 encrypts, the tag covers `aad ‖ pad16 ‖ ct ‖ pad16 ‖ len64(aad)
    ‖ len64(ct)`. `aeadOpen` verifies the tag in **constant time** (no early-out) and only then decrypts.
    Callers pass a `scratch` buffer for the MAC input (no allocation inside the module).
- **Self-contained byte helpers** (`cb8`/`cb8set`/`le32`, file-private) rather than reusing
  `kernel/net/packet.swift`'s `b8`/`b8set` — under `-wmo` the whole module compiles together, so the net
  helpers would collide; keeping crypto independent also lets `--gc-sections` drop it cleanly while unused.
- **Wired into the kernel `SWIFT_SRCS`** so it keeps building in Embedded mode; it is unused/gc'd for now,
  exactly like `dns.swift` was before net-f wired it up. No kernel paths call it yet.
- **Host test `tests/crypto_test.swift`** asserts the published RFC 8439 vectors: §2.4.2 ChaCha20 of the
  "Ladies and Gentlemen…" plaintext (key 00..1f, nonce …4a…, counter 1) → the published ciphertext (plus a
  symmetric round-trip), §2.5.2 Poly1305 of "Cryptographic Forum Research Group" → `a8061dc1…27a9`, and
  §2.8.2 the full AEAD seal (ciphertext + 16-byte tag) plus `aeadOpen` accepting the valid tag and rejecting
  a corrupted one. Built/run with `$(HOST_SWIFTC)` right after `net_test` in the `test:` target.
- **This is TLS groundwork only.** TLS 1.3 mandates AEAD_CHACHA20_POLY1305; the handshake, key schedule
  (HKDF), and record layer are **deliberately deferred** to a later milestone. No networking or syscalls
  were added here.

### net-ipv6 — IPv6 foundation + NDP + dual-stack sockets + RA/EH/multicast + userland + E2E tests (DONE, net/ipv6 branch 2026-06)

Parallel workers delivered the IPv6 slice on top of the net stack (see git log on net/ipv6 for the subagent
slices: foundation, protocol, userland, tests, integration). This is the concrete realisation of the
"IPv6 later" placeholder in ARCHITECTURE.md "Future network stack model".

- **Foundation (ipv6.swift + early netInit).** `struct IPv6` (two UInt64 for value semantics), byte accessors,
  `ipv6LinkLocalFromMAC` (modified EUI-64 → fe80::/10), `ipv6SolicitedNodeMulticast`, `ipv6FromPrefixAndIID`
  (for RA-derived globals), `ip6WriteHeader`/`ip6*` accessors, IPv6 pseudo-header checksum (`sumIPv6Pseudo` +
  `ipv6UpperChecksum` for UDP6/TCP6/ICMPv6). `netInit` derives link-local from virtio MAC and passes to
  `NetStack(..., ipv6: our6)`; logs "net: IPv6 link-local configured (EUI-64 from MAC)". `gNet` now carries
  the IPv6; `netLocalIPv6` / `netGatewayIPv6` globals for kernel use. (Cross-ref commit "net: IPv6 + NDP +
  dual-stack sockets (foundation...)").
- **NDP (icmp6.swift + stack.swift NeighborCache + onFrame).** Full NS/NA (types 135/136): `icmp6WriteNS`
  (with optional SLLA opt), `icmp6WriteNA` (Solicited|Override flags + TLLA), `icmp6NDTarget`, flag bits.
  `NeighborCache` (fixed Entry table, insert/lookup) in stack; on inbound NA learn target→MAC. On NS for us:
  reply with NA and learn peer from SLLA. `socketSendv6` uses NDP cache (falls back to NS+wait for resolution).
  NDP also learns from any IPv6 src L2 (best-effort). Unsolicited NA (e.g. to all-nodes) also populates.
- **Dual-stack sockets + VFS.** `socket.swift`: AF_INET6 paths (`socketCreateIPv6`, `socketCreateTCPIPv6`),
  parallel tables `sockRemoteIPv6`/`sockRemoteMacv6`/`dgSrcIPv6` etc, `socketDeliverUDPv6`/`socketDeliverTCPv6`,
  `socketSendv6` (NDP resolve + `buildUDPv6`/`buildTCPv6`), `socketRecvFromIPv6`. `stack.swift` adds gotUDPv6/
  gotTCPv6 + v6 fields in RxOutcome, and full IPv6 dispatch in `onFrame`. `vfs.swift` (vfsOpen/vfsConnect etc):
  detects AF_INET6 via family, routes to v6 socket creators, uses 16-byte IPv6 in connect/send/recvfrom
  syscalls (new swiftos_*_ipv6 bridge calls). Sockets remain capNet-gated VFS fds; poll/ close uniform.
- **Protocol enhancements (RA/EH/multicast in kernel/net).**
  - RA (RFC 4861): `icmp6TypeRA`, `icmp6WriteRA` (base + optional Prefix Information option type=3 with L/A
    flags, lifetimes), `icmp6ParseRA` (walks options, extracts hopLimit + first prefix). In `stack.onFrame`
    (IPv6 path): on RA, `ndp.insert(routerLLA)`, set `raReceived`/`raHopLimit`/`raHasPrefix`/`raPrefix`/
    `raFormedGlobal` (via ipv6FromPrefixAndIID). (Added in "net/ipv6: add icmp6WriteRA for full RA
    build/parse roundtrips" + "fuller RA/NA/EH/multicast support").
  - Extension Headers (RFC 8200): IPv6 ingress walks next-header chain (up to 4 skips) and advances over
    Hop-by-Hop (0), Routing (43), Destination Options (60) using HdrExtLen, and fixed 8-byte Fragment (44).
    This ensures L4 (UDP/TCP/ICMPv6) and NDP/RA delivery even when EHs or HBH options are present in test
    frames or on the wire. Skips are bounded; malformed truncate safely.
  - Multicast acceptance: IPv6 path in `onFrame` accepts our unicast, our solicited-node multicast, the
    all-nodes link-local (ff02::1, for RA and unsolicited NA), plus loopback-for-test. Enables RA receipt
    and NDP without a full MLD impl.
  - Also: buildUDPv6/buildTCPv6 (with v6 pseudo checksums), ICMPv6 echo request/reply over v6, full
    checksum validation using base-header src/dst (not L4 addrs).
- **Userland IPv6 support.** `userland/lib/swift_user.{h,c}` bridge gained the AF_INET6 + v6 msg variants:
  `swiftos_socket_ipv6`/`swiftos_socket_stream_ipv6`, `swiftos_bind` (reused), `swiftos_sendto_ipv6`/
  `swiftos_recvfrom_ipv6` (use 16-byte IPv6 layout), stream read/write unchanged. 
  - `udpecho.swift`: argv[1]=="6" → use v6 socket + recvfrom/sendto_ipv6 + printIPv6 (colon-hex groups);
    logs "listening on 5555 (IPv6)" and "got N bytes from <v6>:port". (Commits: "userland: udpecho IPv6
    support", "net/ipv6: userland udpecho/tcpecho/nslookup IPv6 support (AF_INET6 + bridge)").
  - `tcpecho.swift`: analogous "6" path with `swiftos_socket_stream_ipv6`/`listen`/`accept` (logs IPv6
    variant); uses plain read/write for the stream. ( "userland: tcpecho IPv6 support").
  - `nslookup.swift`: AAAA support + IPv6 result printing (tightened in "tests: tighten ipv6_*_echo + dns
    for userland IPv6" + "userland: nslookup IPv6 + AAAA support").
  All reached via absolute /bin/* paths from packed base (exec.swift); bare names stay busybox.
- **Host unit coverage (aggressive).** `tests/net_test.swift` (built+run in `make test` right after page
  allocator) gained a large IPv6 block after the v4 cases: header parse/build + version/nh/payload accessors,
  pseudo-header checksum roundtrips for UDP6/TCP6 (corruption detection), ICMPv6 echo writers + checksums
  (over v6 addrs), full NDP NS wire + on-stack NS→NA reply roundtrip in a dual-stack `NetStack`, NA
  parse/flags, `ipv6LinkLocalFromMAC` EUI-64 U/L bit, `ipv6SolicitedNodeMulticast`, RA parse with prefix-info
  option (hopLimit + formed global), bad-version/truncation guards, and v6 UDP/TCP delivery fields via
  `onFrame`. (Commit "net/ipv6: aggressively extend host net_test with IPv6 cases" + earlier foundation).
  All exercised with dual-stack `NetStack(mac, ip, ipv6: ...)` instances.
- **E2E QEMU tests (dedicated scripts, wired into make test).**
  - `tests/ipv6_smoke_test.sh`: boots with `-netdev user,ipv6=on`, reactive FIFO/await past M7, asserts
    "net: IPv6 link-local configured" + no panic. Early-boot only (foundation + NDP config path).
  - `tests/ipv6_udp_echo_test.sh`: on Darwin, where QEMU rejects IPv6 hostfwd literals, requires the smoke
    test above to pass and reports the AF_INET6 echo path as skipped. On QEMU builds with usable IPv6
    hostfwd this script currently boots with `ipv6=on` and exercises an IPv4 UDP echo roundtrip while the
    NIC is dual-stack, asserting link-local/NDP setup and no-crash behavior. True `/bin/udpecho 6` + `nc -6`
    E2E remains a follow-up once the hostfwd transport is portable.
  - `tests/ipv6_tcp_echo_test.sh`: analogous for TCP: Darwin falls back to the required smoke test; the
    non-Darwin body currently validates TCP echo over IPv4 hostfwd under `ipv6=on` and keeps the AF_INET6
    echo tightening point local to this script.
  All three run early in `make test` (after virtio_net, before v4 net tests). Host `net_test` remains the
  aggressive IPv6 protocol oracle; QEMU coverage proves link-local/NDP setup and dual-stack no-crash behavior
  on this Darwin/QEMU setup.
- **Integration / boot / QEMU.** `netInit` always configures IPv6 (even on v4-only runs the vars are zero
  but harmless); ipv6=on only needed for slirp to emit v6 and answer NDP/RA. All test launches that attach
  virtio-net for net tests now use ipv6=on where the dedicated scripts require it. No new syscalls;
  dual-stack lives behind the existing socket surface + bridge. `build/base.img` stages the IPv6-aware
  udpecho/tcpecho (and nslookup) ELFs.
- **Status / deferred.** Foundation + NDP + RA/EH/multicast ingress + aggressive host IPv6 tests are green;
  QEMU coverage currently verifies link-local/NDP and IPv4 echo under an IPv6-enabled NIC on Darwin. Global
  IPv6 gateway learned via RA (or static); portable AF_INET6 echo hostfwd, SLAAC full, MLD, privacy addrs,
  frag reassembly, larger conn tables for v6, AAAA in more tools, and lifting stack to userland service are
  future (post this slice). All prior net-a..h and non-net tests remain green.
  (See ARCHITECTURE update in same session.)

## Threading runtime groundwork (R-series)

### rt-a — threads + futex (DONE, 2026-06-07)

The kernel primitives a userland threading runtime (and later Swift-concurrency / Node / the JVM) needs:
schedulable EL0 threads that share one address space, plus a futex to block/wake them.

- **`thread_create(entry, arg, stackTop) = syscall 46`** (`processThreadCreate`, `kernel/user/process.swift`):
  allocates a fresh process-table slot whose `TTBR0` is the creator's **shared** (not cloned) address space,
  with its own kernel stack and a crafted context that lands in a new EL0 trampoline `user_thread_launch_arg`
  (`user_entry.S`) — identical to `user_thread_launch` but it also delivers the argument in x0, so the thread
  starts at `entry(arg)` on the caller-supplied user stack. The thread is parented to the *creator's* parent so
  it is a sibling (not a waitpid-reapable child); threads join via futex. Returns a thread id (a pid in the
  shared table). Because the AS is shared and never freed, no teardown races: a thread exiting just frees its
  own slot (`pIsThread` short-circuits `processExit` to self-reap instead of zombify, and drops any futex wait
  record). The shared AS lives on for surviving threads.
- **`futex(uaddr, op, val) = syscall 47`** (`kernel/sched/futex.swift`): `op=0` FUTEX_WAIT blocks the caller iff
  `*uaddr == val`; `op=1` FUTEX_WAKE wakes up to `val` waiters on `uaddr` (returns the count woken). A small
  in-kernel wait queue (slot, watched VA) keyed by the user VA — sufficient for a single multi-threaded
  process, since all its threads share the VA space. The compare-and-block runs under `irq_save`/`irq_restore`
  so the `*uaddr` load and the block transition can't race a concurrent WAKE on a preempted sibling. The user
  word is validated through `userReadableBuffer` before any access.
- **Userland bridge:** `swiftos_thread_create` / `swiftos_futex` / `swiftos_thread_exit` and atomic
  CAS/swap/load/fetch-add helpers (LL/SC the Swift layer can't express directly — justified low-level bridge)
  in `userland/lib/swift_user.{h,c}`; `SYS_THREAD_CREATE`(46)/`SYS_FUTEX`(47) in `userland/lib/syscall.h`.
- **Demo `/bin/threadsdemo`** (`userland/threadsdemo.swift`): spawns 2 EL0 threads that each increment a shared
  counter 2000× under a 3-state futex mutex (Drepper's "Futexes Are Tricky"), joins them via a futex on a
  done-counter, and prints `threadsdemo: counter=4000` (= 2N). Resolved in `exec.swift` and packed into the
  base image. `tests/threads_test.sh` boots `-kernel` + base.img, logs in root/swordfish, runs the demo, and
  asserts `counter=4000`. Wired into `make test`.
- **Caveats / follow-ups:** fd-table sharing is a *snapshot* at thread_create (like fork inherit), enough for
  the demo's shared stdout; true fd-table aliasing across threads is deferred. A thread's own kernel stack and
  the shared AS pages are not reclaimed (same global limitation as processes). `processRunElf` stops when the
  top process exits, so the runtime must join its threads before the main thread returns (the demo does).
  `BOARD=virtualbox` still builds; its boot path parks before the scheduler, so threads don't run there.
### Process teardown reclaims frames — the per-command page leak is closed (DONE, 2026-06-07)

- **The leak.** Process teardown set the slot to `pUnused` but never returned any frames to the PMM, so
  every command leaked its whole footprint: the **address space** (L0/L1 page tables + the L2/L3 tables
  and every user leaf page), the **kernel stack** (2 frames), and — on `execve` — the **replaced** old
  address space (fork clones the shell, the child execs, the clone is dropped). At ~2 MiB per busybox
  command the OS exhausted RAM after ~100 commands. This was the main barrier to long-running use.
- **`address_space_destroy(ttbr0)` (`kernel/mm/vm.swift`).** Walks the user half of the tables (L1 index ≥ 2,
  i.e. VA ≥ `0x8000_0000`) and releases every leaf frame, then frees each L3/L2 table, then the L1 and L0
  frames. The kernel/device identity entries (L1 indices 0,1) are 1 GiB **block** descriptors,
  not tables — the `DESC_TABLE` test skips them, so the shared kernel mapping is never freed. With COW fork,
  user leaf frames may be shared; teardown drops each leaf's PMM refcount and raw-frees only on the last
  owner, while page-table frames remain private to the address space. Safe on a partially built space
  (failed `createProcess`/`buildExecImage` now clean up too). If the doomed space is the **currently
  installed TTBR0** (the case when the kernel scheduler reaps a just-exited top-level process, whose tables
  are still live in the register), it switches to the kernel identity map first so the MMU never walks
  frames being handed back.
- **`process.swift` wiring.** A new `reapProcess(slot)` frees the address space + kernel stack (tracked in
  a new `pKstack` array) and marks the slot unused; it replaces the bare `pState = pUnused` at all four
  reap sites (`processRunElf`, `processRunPair`, `processSpawnChild`, `processWaitpid`). `processExec` frees
  the **old** address space after switching to the new one (kernel stack is reused across exec, so it is
  not freed there). A zombie never runs again, so its space/stack are quiescent at reap time.
- **Test / acceptance.** `runReclaimDemo` (in `main.swift`, on the boot path) records the PMM free-frame
  count, runs **5 rounds** of fork+waitpid (`forkdemo`), exec-replace (`execdemo`), and spawn+reap
  (`spawndemo`) — the exact teardown paths a shell command takes — and asserts the count is **identical**
  before and after. Measured in QEMU: `baseline=64747 after=64747` (zero leak; before the fix it would
  drop by hundreds of frames). `tests/boot_test.sh` greps for `reclaim OK: no frame leak across
  fork/exec/exit/reap`. The host `PageAllocator` `free`/double-free tests already cover the frame allocator.
- **Remaining efficiency holes (still future work, by design for now):** no page cache; the PMM is O(n)
  first-fit (a buddy/free-list refinement is noted in `docs/ARCHITECTURE.md`); single core (no SMP). The
  footprint section above was measured **before** this feature; steady-state RAM is now flat across commands
  rather than monotonically shrinking.

### Track B — COW fork PMM ownership audit (2026-06-08)

Before adding COW write-fault handling, every `pmm_alloc_page` / `pmmAllocPage` /
`pmmAllocZeroedPage` / `pmmAllocPages` caller was audited for frame ownership:
- **User leaf frames** (`elfLoad`, process stacks, `sbrk`, `mmap`) now start with PMM refcount 1 and are
  the only frames shared by COW fork. Address-space teardown and `munmap` drop a reference and raw-free
  only on the last owner. COW write faults allocate a private frame for the writer and drop the old frame's
  reference.
- **Page tables, kernel stacks, driver DMA/ring buffers, network socket buffers, DNS scratch, and the ELF
  staging buffer** are not mapped as COW user leaves. They remain single-owner or permanent kernel/device
  allocations and continue to use raw `pmm_free_page` only where a reclaim path exists.
- **Fixed during the audit:** `address_space_create` now frees a lone L0/L1 allocation if the paired table
  allocation fails; `elfLoad` frees a just-allocated page if mapping it fails; `processSbrk` rolls back any
  partially mapped heap pages when growth fails. `address_space_clone` now destroys a partially built child
  address space on link failure, dropping any shared-frame references it already acquired.
- **Known pre-existing non-COW leak:** EL0 thread kernel stacks are still not reclaimed on thread exit, as
  recorded in the rt-a notes; they are not COW-shared and were not changed in this track.

### Timer-backed `nanosleep`/`sleep` (2026-06-08)

**Why.** `nanosleep`/`sleep` were silent no-op stubs (`userland/compat/stubs.c`), so any ported server or
script that slept returned instantly and busy-spun instead of yielding the CPU — wrong for an OS meant to
host server apps. The kernel already had every primitive (100 Hz `systemTicks`, the `pBlocked` +
`yieldToScheduler` block/wake model, and a per-tick hook that runs even while idle), so a real blocking
sleep was a small, self-contained add.

**Design.** New syscall `SYS_NANOSLEEP = 57`; ABI `x0 = seconds`, `x1 = nanoseconds`, returns 0.
`processNanosleep` parks the caller in `pBlocked` with a wake deadline recorded in `pWakeTick[slot]`
(systemTicks units; 0 = not sleeping) and yields. `processOnTick` wakes any blocked slot whose deadline has
passed — the scan runs first and unconditionally, so it fires even when `currentProc == -1` during the
scheduler's idle `wfi`. A nonzero `pWakeTick` is what distinguishes a sleeper from a futex/waitpid/IO
blocker, so the scan never disturbs those. Resolution is one tick (10 ms); a sub-tick request rounds up to
one tick. Sleep always completes fully — blocked syscalls are not signal-interrupted yet, so there is no
unslept remainder (userland zeroes `*rem`).

**Artifacts / test.** libc `nanosleep`/`sleep` now call the syscall (`stubs.c`); `swiftos_nanosleep` added
to the Swift bridge; native `/bin/sleepprobe` measures an RTC delta around `nanosleep(2s)` and is registered
in `execResolve`; busybox `CONFIG_SLEEP=y` ships a real `/bin/sleep`. `tests/sleep_test.sh` asserts
`SLEEP_DELTA >= 2` (the old stub gave 0) and that `busybox sleep` completes end to end.

**Cron — deliberately deferred.** A real cron/crond is **not** on the roadmap and was not built: it needs
signal delivery to EL0, a supervisor/init daemon, and crontab storage — none on the critical path. Follow-on
timing surface if a scheduler daemon is ever wanted: `SIGALRM`/`alarm`, `setitimer`/POSIX timers,
signal-interruptible sleep (`EINTR` + a real `rem`), then crond/`at`.
