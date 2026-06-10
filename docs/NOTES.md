# NOTES

Engineering log: accepted decisions, hardware constants, exact build/run commands, and tool versions.
Newest notes at the top of each section.

## P15 bzip2 seed package (2026-06-10)

- Added `ports/archivers/bzip2/Port.json` for Sourceware bzip2 1.0.8 as the
  next checked archive-format package after zlib. It packages static
  `bzip2`/`bunzip2`/`bzcat`/`bzip2recover`, `libbz2.a`, `bzlib.h`, pkgconf
  metadata, and a marker file.
- Added `scripts/build-bzip2.sh`. The script performs a manual static AArch64
  object build against the local newlib sysroot because the upstream makefile's
  link ordering is not suitable for the current freestanding runtime shape. A
  tiny generated compat shim supplies metadata calls bzip2 expects but SwiftOS
  does not implement yet.
- The ports seed repository now publishes Lua, zlib, bzip2, ca-certificates,
  pcre2, tzdata, nginx, and sqlite. Package seed, static-host, hosted URL, and
  recipe tests were extended to install bzip2 and run a compression round trip.

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
  `0x8800_0000`); the 16-page user stack is at the top of `[0x8FFF_0000, 0x9000_0000)`; the
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
- **User pointer hardening follow-up (2026-06-09) — DONE.** Tightened the range checks so wraparound user
  pointers such as `(char *)-1` are rejected before forming `va + count` on both readable and writable
  copy paths. `packUserArgv` now validates each argv pointer slot before reading it, so an argv array
  without a NULL terminator before an unmapped page cannot fault EL1. Added `/bin/selfexecdemo` plus
  `tests/spawn_self_exec_test.sh`, which opens and spawns the same disk-backed file and feeds malformed
  argv shapes, then proves the shell survives. `securitydemo` also covers wraparound open/stat/getcwd/read/write.
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
  - Early linker-reserved bump heap, Swift raw allocation hook (`swift_slowAlloc` /
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

### S0f — DTB CPU topology scaffold (DONE, 2026-06-09)

- **CPU topology parsing.** The pure FDT reader now records `/cpus/cpu@N`
  topology from QEMU `virt` DTBs into fixed 8-slot Aff0 storage. No heap-backed
  arrays are introduced, and secondary CPUs still remain parked below kernel
  Swift code.
- **Platform handoff + self-test.** After the MMU is enabled, the platform layer
  compares the bootloader-provided DTB with the direct-boot injected DTB address
  (`0x4FF0_0000`) and copies the richest discovered CPU count/Aff0 map into the
  global platform record. The boot path validates the count against the S0
  per-CPU/mailbox limit and logs
  `[I] smp: S0f OK: CPU topology ready` with the discovered CPU count.
- **DTB-consistent SMP smoke.** `tests/smp_boot_test.sh` now dumps a QEMU DTB
  with the same `-smp ${SMP_CPUS}` value it boots, then asserts the S0f count
  marker. The host FDT test covers both 1-CPU and `-smp 4` DTBs.
- **Non-goals.** No PSCI/spin-table choice, no secondary release, no scheduler
  conversion, no GIC/timer work on secondaries, no C4/VFS/process changes.

### S0g — PSCI discovery scaffold (DONE, 2026-06-09)

- **QEMU DTB evidence.** Verified locally with QEMU 11.0.1 by dumping/decompiling
  `virt` DTBs for `-smp 1`, `-smp 4`, and `-smp 8`. QEMU advertises a `/psci`
  node with `compatible = "arm,psci-1.0", "arm,psci-0.2", "arm,psci"`,
  `method = "hvc"`, and `cpu_on = <0xc4000003>`. Per-CPU
  `enable-method = "psci"` appears when there are secondary CPUs (`-smp > 1`);
  the single-CPU DTB omits it because there is no secondary to release.
- **Fixed discovery fields.** The pure FDT reader now records PSCI presence,
  call method, CPU_ON function ID, and a fixed 8-bit Aff0 mask of CPU nodes that
  advertise `enable-method = "psci"`. This is heap-free and uses the existing
  post-MMU platform handoff so early Device-typed RAM parsing still avoids wide
  struct copies.
- **Boot self-test + tests.** The S0 boot path validates PSCI discovery and logs
  `[I] smp: S0g OK: PSCI discovery ready` with the PSCI enable mask. The host
  FDT test checks the PSCI node and CPU enable-method behavior for both 1-CPU
  and `-smp 4` DTBs; the SMP smoke test checks the S0g marker for arbitrary
  `SMP_CPUS` up to the current 8-slot scaffold.
- **Non-goals.** No S1 release mechanism is chosen here, no HVC/SMC call is
  issued, no secondary stacks are allocated, no secondary enters Swift/kernel
  code, and no scheduler/GIC/timer/C4/VFS/process state changes are made.

### S0h — full-test parked SMP gate (DONE, 2026-06-09)

- **Default gate coverage.** The normal `make test` suite now runs
  `SMP_CPUS=4 SMP_DTB=build/virt-smp4.dtb tests/smp_boot_test.sh` after the
  classic single-core boot smoke. This makes the roadmap's S-series rule
  executable: the default gate covers both the 1-CPU path and QEMU
  `virt -smp 4` parked-SMP path.
- **Reuse existing smoke.** The integrated smoke is the same S0 harness used by
  `make smp-test` / `make s0-test`: it asserts the S0/S0b/S0d/S0e/S0f/S0g
  markers and fails on missing/incomplete DTB discovery. The full suite reuses
  the already-dumped `-smp 4` DTB; explicit `SMP_CPUS=1` and `SMP_CPUS=8`
  remain useful focused checks.
- **Non-goals.** No secondary release, no new scheduler/GIC/timer behavior, and
  no C4/VFS/process changes. This is test-gate hardening only.

### S0i — pre-S1 release guard and SMP headroom (DONE, 2026-06-09)

- **Executable no-release guard.** `tests/smp_release_guard_test.sh` now
  disassembles the built kernel/boot object and fails if pre-S1 code contains
  `hvc`/`smc` PSCI calls, an indirect secondary-entry branch from `boot.S`, or
  writes to the parked secondary mailbox release fields. The full `make test`
  suite runs this cheap guard before the mutable-state audit.
- **Parked headroom smoke.** `tests/smp_headroom_test.sh` reuses the existing
  parked-SMP boot harness for `-smp 1` and `-smp 8`; `make s0-test` now covers
  the audit, mailbox layout, release guard, default `-smp 4`, and headroom
  boots. This keeps the S0/S1 handoff executable without lengthening the full
  product gate beyond the S0h `-smp 4` check.
- **Verifier stability.** During S0i validation, the network smoke drivers were
  moved toward fail-fast FIFO marker waits and dynamic host ports, and the Swift
  `ls` smoke now drives the serial console by markers instead of fixed sleeps.
  This keeps full-gate failures diagnosable and avoids parallel-worktree port
  conflicts without changing kernel or network behavior.
- **Non-goals.** No S1 protocol choice, no CPU_ON/HVC/SMC call, no secondary
  stacks, no GIC/timer initialization on secondaries, and no C4/VFS/process
  changes. This milestone preserves the review boundary before S1.

### S0j — S1 preflight gates (DONE, 2026-06-09)

- **Fresh QEMU topology evidence.** `tests/smp_s1_preflight_test.sh` dumps
  current QEMU `virt` DTBs for `-smp 1`, `2`, `4`, and `8`, then runs the same
  host `fdt_test` parser the kernel shares. This validates the DTB-visible S1
  inputs: CPU Aff0 slots, `enable-method = "psci"` for secondary-capable
  topologies, PSCI method/function ID, the existing GICv2/UART/virtio map, and
  the ARM generic timer's non-secure physical PPI (INTID 30) with the expected
  per-CPU PPI target mask.
- **UEFI parked-SMP smoke.** `tests/uefi_boot_test.sh` now accepts
  `SMP_CPUS`, boots the real GPT disk through AAVMF with `-smp 4` in the new
  `smp-uefi-test` target, and asserts the S0 markers, CPU topology count, and
  PSCI enable mask before reaching busybox. This covers the S0 parked-SMP path
  for both direct `-kernel` and UEFI/disk boot.
- **Gate integration.** `make test` runs the preflight next to the existing FDT
  checks and adds the UEFI `-smp 4` smoke after the single-CPU UEFI boot.
  `make s0-test` includes the preflight and UEFI SMP smoke around the direct
  parked boot smokes. This keeps the S0/S1 handoff executable.
- **Non-goals.** No C4/VFS/process behavior changes.

### S0l — full-gate mailbox ABI guard (DONE, 2026-06-09)

- **Full gate coverage.** The normal `make test` suite now runs
  `tests/smp_mailbox_layout_test.sh` before the release guard, so the secondary
  mailbox ABI (`.data`, 512 bytes, 64-byte alignment) is checked in the same
  overnight/product gate that would catch accidental release-path regressions.
- **Verifier hardening.** The mailbox layout script now fails clearly when the
  expected `llvm-objdump` tool is unavailable.
- **Non-goals.** No mailbox layout change, no kernel/C4/VFS/process behavior
  changes.

### S0m — legacy QEMU smoke harness hardening (DONE, 2026-06-09)

- **Prompt-driven legacy drivers.** Older QEMU smoke tests that still drove
  serial input with fixed sleeps now use FIFO stdin plus bounded waits for the
  relevant prompts or acceptance markers. This covers the tty, disk exec,
  console-login, cap enforcement, and throwaway disk VFS tests.
- **Early-probe waits.** The virtio-blk and virtio-net smoke tests now wait for
  their boot-time success markers before cleanup instead of killing QEMU after a
  fixed delay.
- **Non-goals.** No kernel, filesystem, process, capability, or userland
  behavior is changed.

### S0n — native Swift file-tool harness hardening (DONE, 2026-06-09)

- **Prompt-driven Swift tool tests.** The native Swift coreutils, fileops, and
  chmod/chown smoke tests now drive QEMU through FIFO stdin and wait for login
  prompts plus existing output markers instead of relying on fixed serial
  sleeps.
- **Assertions unchanged.** The tests still verify the same `/bin/echo`,
  `/bin/cat`, `/bin/pwd`, tmpfs mutation, chmod, and chown behavior.
- **Non-goals.** No Swift userland behavior, kernel behavior, C4/VFS/process
  behavior, or S1 release behavior is changed.

### S0o — timed Swift tool harness hardening (DONE, 2026-06-09)

- **Prompt-driven timed tool tests.** The native Swift recursive `rm`,
  `head`/`wc`/`touch`, `date`, and sleep smoke tests now drive QEMU through FIFO
  stdin and wait for login prompts plus existing output markers instead of
  relying on fixed serial sleeps.
- **Assertions unchanged.** The tests still verify recursive removal semantics,
  head/wc/touch output, RTC-backed `/bin/date`, and timer-backed
  nanosleep/busybox sleep behavior.
- **Non-goals.** No Swift userland behavior, kernel behavior, C4/VFS/process
  behavior, or S1 release behavior is changed.

### S0p — runtime demo harness hardening (DONE, 2026-06-09)

- **Prompt-driven runtime demos.** The userland threads/futex and
  mmap/munmap/mprotect/W^X smoke tests now drive QEMU through FIFO stdin and
  wait for login prompts plus their existing `threadsdemo` / `mmapdemo` success
  markers instead of relying on fixed serial sleeps.
- **Assertions unchanged.** The tests still verify `counter=4000` for the futex
  thread demo and the same B1/B2/W^X mmap markers.
- **Non-goals.** No runtime behavior, kernel behavior, C4/VFS/process behavior,
  or S1 release behavior is changed.

### S0q — calc REPL harness hardening (DONE, 2026-06-09)

- **Prompt-driven calc REPL.** `tests/calc_test.sh` now drives QEMU through FIFO
  stdin, waits for the login shell and `/bin/calc` banner, then feeds the same
  REPL session without fixed serial sleeps.
- **Assertions unchanged.** The test still verifies precedence, parentheses,
  assignment, lookup, modulo, unary minus, division-by-zero reporting, `:sum`,
  and bounded heap break across churn.
- **Non-goals.** No calc behavior, Swift runtime behavior, kernel behavior,
  C4/VFS/process behavior, or S1 release behavior is changed.

### S0r — HTTP server harness hardening (DONE, 2026-06-09)

- **Prompt-driven httpd launch.** `tests/httpd_test.sh` now drives QEMU through
  FIFO stdin, waits for the tty demo, login shell, and `httpd: listening on
  8080` marker, then runs the existing curl acceptance checks without fixed
  serial input sleeps.
- **Assertions unchanged.** The test still verifies concurrent index requests,
  `/hello.txt` serving plus `text/plain`, generated `/sub/` directory listings,
  404 on missing paths, and multiple `httpd: 200` serial markers.
- **Non-goals.** No HTTP server behavior, networking behavior, filesystem
  behavior, kernel behavior, C4/VFS/process behavior, or S1 release behavior is
  changed.

### S0s — serial vi harness hardening (DONE, 2026-06-09)

- **Prompt-driven vi session.** `tests/vi_test.sh` now drives QEMU through FIFO
  stdin, waits for the tty demo, login shell, vi alternate-screen entry,
  inserted text echo, saved-file readback, and trailing shell marker instead of
  relying on fixed serial input sleeps.
- **Assertions unchanged.** The test still verifies busybox vi enters the
  alternate screen, saves `/tmp/vitest`, returns a clean `hello-from-vi` line via
  `cat`, keeps the shell alive, and avoids kernel panics.
- **Non-goals.** No vi behavior, terminal behavior, filesystem behavior, kernel
  behavior, C4/VFS/process behavior, or S1 release behavior is changed.

### S0t — UDP echo harness hardening (DONE, 2026-06-09)

- **Prompt-driven UDP smoke.** `tests/udp_echo_test.sh` now writes serial input
  immediately after awaited tty/login markers, waits for `udpecho: listening on
  5555`, sends the host datagram, and waits for the guest receive marker instead
  of relying on short fixed guard sleeps.
- **Assertions unchanged.** The test still verifies that `/bin/udpecho` binds,
  receives eight bytes from the slirp host, and echoes `swos-udp` back to host
  `nc`.
- **Non-goals.** No UDP behavior, socket behavior, networking behavior, kernel
  behavior, C4/VFS/process behavior, or S1 release behavior is changed.

### S0u — TCP connect harness hardening (DONE, 2026-06-09)

- **Prompt-driven TCP client smoke.** `tests/tcp_connect_test.sh` now writes
  serial input immediately after awaited tty/login markers and waits for the
  `srv-reply` client output instead of sleeping after launching `/bin/tcpget`.
- **Assertions unchanged.** The test still verifies that `/bin/tcpget` connects
  to the slirp host, receives `srv-reply`, and transmits `GET swos` on the
  captured pcap path.
- **Non-goals.** No TCP behavior, socket behavior, networking behavior, kernel
  behavior, C4/VFS/process behavior, or S1 release behavior is changed.

### S0v — Swift ls harness hardening (DONE, 2026-06-09)

- **Prompt-driven native ls smoke.** `tests/swift_ls_test.sh` now writes serial
  input immediately after awaited tty/login and command-output markers instead
  of using short fixed guard sleeps before `/bin/ls` invocations.
- **Assertions unchanged.** The test still verifies plain `/etc` listing,
  long-format `/etc/motd`, `/etc/swos`, and single-file `/bin/busybox` owner,
  group, mode, size, and timestamp formatting.
- **Non-goals.** No `/bin/ls` behavior, VFS behavior, filesystem behavior,
  kernel behavior, C4/VFS/process behavior, or S1 release behavior is changed.

### S0w — TCP echo harness hardening (DONE, 2026-06-09)

- **Prompt-driven TCP server smoke.** `tests/tcp_echo_test.sh` now writes serial
  input immediately after awaited tty/login markers, waits for
  `tcpecho: listening on 5555`, and uses a bounded regex wait for the guest's
  receive marker instead of serial guard sleeps and hand-written polling loops.
- **Assertions unchanged.** The test still preserves the one-shot TCP retry
  model, verifies guest receive logging, and verifies that host `nc` receives
  the echoed `swos-tcp` payload.
- **Non-goals.** No TCP behavior, socket behavior, networking behavior, kernel
  behavior, C4/VFS/process behavior, or S1 release behavior is changed.

### S0x — SMP audit freshness guard (DONE, 2026-06-09)

- **Bidirectional manifest check.** `tests/smp_state_audit_test.sh` now records
  the scanner output once, verifies every scanned mutable global is documented,
  and also rejects stale backticked `kernel/...:symbol` entries that no longer
  appear in `scripts/smp-global-audit.py` output.
- **Audit contract clarified.** `docs/SMP_STATE_AUDIT.md` now states that the
  executable check covers both missing and stale manifest entries.
- **Non-goals.** No SMP release behavior, locking policy, kernel behavior,
  C4/VFS/process behavior, or S1 design decision is changed.

### S0y — hermetic S1 preflight target (DONE, 2026-06-09)

- **Direct target hygiene.** `make smp-s1-preflight` now has an order-only
  dependency on `$(BUILD)/.dir` before writing `build/fdt_test`, so the focused
  preflight target is hermetic from a clean checkout/build directory.
- **Assertions unchanged.** The target still builds the host FDT parser and runs
  the same QEMU virt DTB PSCI/GIC/timer/topology preflight.
- **Non-goals.** No preflight semantics, SMP release behavior, kernel behavior,
  C4/VFS/process behavior, or S1 design decision is changed.

### S1 — secondary CPU bring-up and per-CPU early init (DONE, 2026-06-09)

- **Policy decision.** S1 records the S0 decision point as "always use the
  general SMP path." There is no compile-time or boot-time uniprocessor fast
  path; the simpler single path is preferred until measured cost justifies a
  later optimization.
- **Release protocol.** CPU0 now publishes each secondary's mailbox slot
  (`entry`, `stack_top`, `argument`, then a release-store flag), sends `sev`,
  and issues the DTB-selected PSCI `CPU_ON` call (`hvc` or `smc`, `cpu_on =
  0xc4000003` on the QEMU 11.0.1 `virt` DTB). This deliberately supports both
  powered-off PSCI secondaries and eager `-kernel` secondaries that reached the
  mailbox park loop first.
- **Secondary entry.** `smp_secondary_entry` derives the real CPU id from
  `MPIDR_EL1`, loads the fixed per-CPU stack from the mailbox table, installs
  the EL1 vector table, enables FP/SIMD and the kernel identity MMU regime, then
  enters `smp_secondary_main`. Secondary stacks are static, 32 KiB each, and
  covered by `docs/SMP_STATE_AUDIT.md`.
- **Early online + timer PPI only.** A secondary CPU initializes only its
  per-CPU state, its GIC CPU interface, and its banked physical timer PPI. Its
  IRQ path records per-CPU timer ticks and EOIs the interrupt; scheduler,
  process, VFS, PMM allocation, drivers, and EL0 work remain CPU0/S2+ concerns.
- **Tests / acceptance.** `tests/smp_release_guard_test.sh` is now an S1 release
  contract guard instead of an S0 no-release guard. `tests/smp_boot_test.sh`
  asserts `S1 CPU online` markers for every discovered CPU plus
  `[I] smp: S1 OK: secondary CPUs online detail=N`; `make s1-test` covers the
  mutable-state audit, mailbox layout, release contract, `-smp 4`, and headroom
  `-smp 1` / `-smp 8` boots.
- **Non-goals.** No EL0 process runs on a secondary, no per-CPU run queues, no
  PMM/VFS/driver locking policy, no IPIs, and no cross-CPU TLB work. Those are
  S2/S3+ work.

### S2a — secondary timer / scheduler-boundary readiness gate (DONE, 2026-06-09)

- **Timer evidence is now explicit.** S1 already required each discovered CPU to
  record at least one banked physical-timer tick before declaring bring-up
  complete. S2a logs one `S2a OK: per-CPU timer heartbeat ready` marker per CPU
  after that condition is true, using `detail = cpu_id + 1` so CPU0 also has an
  explicit payload.
- **Scheduler boundary guard.** Before logging `S1 OK`, the bring-up path now
  verifies that every secondary per-CPU scheduler slot still has no current
  thread, no current process, no run queue, and no scheduler context pointer.
  This preserves the S1/S2 boundary: secondary CPUs can take timer PPIs, but
  scheduler, process, VFS, PMM, drivers, and EL0 work remain CPU0-only until S2
  deliberately changes that contract.
- **CPU0 ownership seam.** After `schedulerInit` and `processInit`, boot runs an
  S2a self-test that requires the primary CPU to be online, to own a scheduler
  thread slot in the per-CPU scaffold, and to have no active EL0 process yet.
  The EL0 scheduler loop now mirrors `currentProc` into the current CPU's
  per-CPU state while a process is switched in, then clears it on return to the
  scheduler. Today that only records CPU0 state; S2 will use the same seam when
  scheduler ownership becomes per-CPU.
- **Tests / acceptance.** `tests/smp_boot_test.sh` now asserts the S2a heartbeat
  markers for every `-smp N` CPU plus `S2a OK: scheduler boundary held` and
  `S2a OK: scheduler owner ready`. `make s1-test` exercises those checks for
  the default `-smp 4`, headroom `-smp 1` / `-smp 8`, and UEFI `-smp 4` paths
  through the existing S1 gate.
- **Harness / guard hardening.** A follow-up tightened the cheap release guard
  so it also verifies the S2a accessors, boot ordering
  (`schedulerInit` -> `processInit` -> `smpS2ReadinessSelfTest`), and EL0
  `currentProc` mirroring into per-CPU state. `tests/smp_boot_test.sh` now
  escalates QEMU cleanup from TERM to KILL after a bounded grace period, so a
  failed expectation cannot strand the expensive `make s1-test` gate in `wait`.
- **Non-goals.** No EL0 work moves to secondary CPUs, no run queues are added,
  and no scheduler/process/VFS/PMM locking policy changes in this checkpoint.

### S2b — per-CPU EL0 scheduler-context scaffold (DONE, 2026-06-09)

- **Process scheduler context storage.** The EL0 process scheduler context is no
  longer a singleton `schedCtx[1]`. `processInit` now allocates one fixed
  `CPUContext` per supported SMP CPU (`smpMaxCpuCount()`), initializes every
  slot, and all process scheduler switches select the slot for `currentCpuId()`.
  Today only CPU0 reaches those switch paths, so this is a storage/readiness
  scaffold rather than a scheduling policy change.
- **Runtime readiness marker.** Boot runs `processSchedulerContextSelfTest`
  immediately after the S2a scheduler-owner check. The self-test verifies the
  context array size, `CPUContext` stride, alignment, primary CPU index
  validity, CPU0's published per-CPU process scheduler context, and zeroed
  initial contexts before the first EL0 process switch, then logs
  `S2b OK: process scheduler context scaffold ready`.
- **Secondary EL0 guard.** Each EL0 process switch increments the current CPU's
  per-CPU EL0 switch counter. After the Swift `ps` demo has run, boot verifies
  that CPU0 recorded EL0 switches and every secondary CPU still has zero EL0
  switches, then logs `S2b OK: no secondary EL0 execution`.
- **Owner guard.** Until S2 proper deliberately moves EL0 scheduling off CPU0,
  the process scheduler context helper and `processOnTick` panic if entered on
  any non-owner CPU. This keeps the per-CPU storage scaffold from hiding an
  accidental secondary scheduler entry.
- **Static guard.** `tests/smp_release_guard_test.sh` now rejects a return to
  singleton process scheduler context usage, verifies the S2b helper/self-test
  hooks, checks the CPU0 owner guard, verifies that `irqHandler` still gates
  `processOnTick` to CPU0, and checks that S2b runs after S2a in the boot order.
- **Non-goals.** No EL0 work moves to secondary CPUs, no per-CPU run queues are
  active yet, no cross-CPU wake/IPI path is added, and scheduler/process/VFS/PMM
  locking policy remains S2+ work.

### S2c — kernel-thread scheduler ownership guard (DONE, 2026-06-09)

- **Kernel scheduler owner guard.** The M4.5 kernel-thread scheduler now has an
  explicit CPU0 owner check at its public and internal scheduler boundaries.
  `schedulerInit`, `threadCreate`, `schedule`, `schedYield`, `schedulerTick`,
  `schedAllThreadsDone`, and `thread_exit` panic if they are reached from any
  non-owner CPU, so the existing global `currentThread` / `states` scheduler
  cannot silently appear per-CPU-safe before S2 proper.
- **Per-CPU ownership evidence.** The fixed per-CPU state keeps its 64-byte
  stride: the former reserved 32-bit slot is now
  `kernelSchedulerActivityCount`, while the S2b EL0 switch counter remains a
  full 64-bit counter. CPU0 marks the kernel scheduler ready in per-CPU flags,
  and real kernel-thread context switches increment the current CPU's kernel
  scheduler activity counter.
- **Runtime acceptance.** Boot runs `kernelSchedulerOwnershipSelfTest` and
  `smpS2cKernelSchedulerReadinessSelfTest` after `schedulerInit`, then logs
  `S2c OK: kernel scheduler owner ready`. After the M4.5 scheduler demo and
  before any EL0 demos, boot verifies CPU0 recorded kernel scheduler activity
  and every secondary still has zero kernel scheduler activity, then logs
  `S2c OK: no secondary kernel scheduler execution`.
- **Static guard.** `tests/smp_release_guard_test.sh` now checks the kernel
  scheduler owner helper, per-CPU kernel scheduler ready/activity state, CPU0
  timer IRQ gating for `schedulerTick`, and the S2c boot-order contract.
- **Non-goals.** No per-CPU run queues are active yet, no kernel thread can run
  on a secondary CPU, no cross-CPU wake/IPI path is added, and PMM/VFS/process
  locking policy remains S2+ work.

### S2d — EL0 process run queue scaffold (DONE, 2026-06-09)

- **Queue-backed EL0 scheduling.** The EL0 process scheduler no longer picks
  runnable slots by scanning `pState` with a global round-robin cursor. Every
  `pReady` transition now goes through `markProcessReady`, which records a
  home CPU, links the slot into that CPU's FIFO run queue, and mirrors the
  queue head/tail into the fixed per-CPU state. `pickReady` dequeues from the
  current CPU's queue and verifies the slot still belongs to that CPU.
- **CPU0 placement, deliberately.** `processHomeCpuForNewReadySlot` is the new
  placement hook, but S2d intentionally returns CPU0 for every runnable process
  and panics if a process is enqueued to any secondary CPU. This makes the S2
  policy boundary explicit without enabling secondary EL0 execution early.
- **Runtime acceptance.** Boot runs `processRunQueueScaffoldSelfTest` after the
  S2b process scheduler context check and logs
  `S2d OK: process run queue scaffold ready`. After the Swift `ps` userland
  demo, boot verifies CPU0 observed run queue enqueue/dispatch activity and
  every secondary CPU still has an empty process run queue, then logs
  `S2d OK: process run queue stayed CPU0-owned`.
- **Static guard.** `tests/smp_release_guard_test.sh` now checks the per-CPU
  process run queue mirror helpers, the process scheduler run queue arrays,
  rejects the old `rrCursor`/linear-scan scheduler path, and verifies that
  `pReady` transitions are centralized through `markProcessReady`.
- **Non-goals.** No EL0 work moves to secondary CPUs, no cross-CPU wake/IPI
  path is added, and PMM/VFS/process locking policy remains S2+ work.

### S2e — dormant per-CPU EL0 scheduler publication (DONE, 2026-06-10)

- **Dormant scheduler contexts for every CPU.** `processInit` now publishes the
  exact `schedCtx[cpu]` address and an empty process run queue mirror into every
  fixed per-CPU state slot. CPU0 performs this publication during boot; it does
  not require secondary CPUs to enter process scheduler code.
- **Idle means no execution, not no resources.** `smpPerCpuSchedulerIdle` now
  treats a nonzero dormant process scheduler context as allowed idle state. The
  idle invariant remains strict about current thread/process ownership, run
  queue emptiness, kernel scheduler activity, EL0 switch count, and the kernel
  scheduler-ready flag.
- **Runtime acceptance.** Boot runs `processDormantSchedulerCpusSelfTest` after
  the S2d run queue scaffold check and logs
  `S2e OK: dormant process scheduler CPUs published`. After the Swift `ps`
  userland demo, boot verifies secondary scheduler contexts still point at
  their dormant slots, secondary run queues remain empty, and secondary EL0
  switch counts remain zero, then logs
  `S2e OK: secondary process scheduler contexts stayed dormant`.
- **Static guard.** `tests/smp_release_guard_test.sh` now checks the addressable
  per-CPU scheduler context/runqueue publication helpers, rejects a CPU0-only
  context publication regression, and verifies the S2e boot-order contract.
- **Non-goals.** No secondary CPU dispatches EL0 work, no cross-CPU wake/IPI path
  is added, and PMM/VFS/process locking policy remains S2+ work.

### S2f — EL0 process dispatch CPU telemetry (DONE, 2026-06-10)

- **Actual-dispatch telemetry.** The process scheduler now records the CPU that
  actually dispatches each EL0 process slot (`pLastDispatchCpu`), a per-slot
  dispatch count, and a small CPU bitmask of CPUs that have dispatched the slot.
  A per-CPU aggregate telemetry counter is incremented at the same switch-in
  site and is cross-checked against the existing per-CPU EL0 switch counter.
  This is the cheap "last CPU" and history evidence needed by the later S2
  acceptance test, without changing placement policy yet.
- **CPU0 owner guard remains strict.** `recordProcessDispatch` still panics if
  an EL0 process is dispatched on a secondary CPU or if the process home CPU and
  dispatch CPU diverge. S2f is observability/readiness work, not the point where
  secondary EL0 execution starts.
- **Runtime acceptance.** Boot runs `processDispatchTelemetrySelfTest` after the
  S2e dormant scheduler publication check and logs
  `S2f OK: process dispatch telemetry ready`. After the Swift `ps` userland
  demo, boot verifies the dispatch telemetry aggregate matches CPU0's EL0
  switch count and every secondary CPU remains at zero, then logs
  `S2f OK: process dispatch telemetry stayed CPU0-owned`.
- **Static guard.** `tests/smp_release_guard_test.sh` now checks the dispatch
  telemetry fields/helper/self-tests, verifies the telemetry write is on the
  actual EL0 switch path before `smpRecordEl0SwitchForCurrentCpu`, and enforces
  the S2f boot-order contract.
- **Non-goals.** No process migrates between CPUs, no secondary CPU dispatches
  EL0 work, no cross-CPU wake/IPI path is added, and no procstat/userland ABI is
  widened in this checkpoint.

### S2g — coproc pair dispatch telemetry harness (DONE, 2026-06-10)

- **Coproc pair evidence before reap.** `processRunPair` now captures each
  process slot's dispatch count, last dispatch CPU, and dispatch CPU mask after
  the pair has exited but before either slot is reaped. This preserves the exact
  evidence the later S2 acceptance needs from the existing `coproc` demo, where
  the target will become "the two processes ran on different CPUs".
- **Current invariant remains CPU0-only.** The S2g guard requires both `coproc`
  processes to have dispatched at least once and to have CPU0-only dispatch
  masks. It does not migrate work, change the placement hook, add cross-CPU
  wakeups, or enable secondary EL0 execution.
- **Runtime acceptance.** After `runConcurrentDemo` prints
  `M8d OK: two EL0 processes ran concurrently`, boot runs
  `processCoprocPairDispatchTelemetrySelfTest` before later demos can reuse the
  slots. S2h now owns the runtime dispatch marker and logs either
  `S2h OK: coproc pair dispatched across scheduler CPUs` or the explicit CPU0
  fallback marker.
- **Static guard.** `tests/smp_release_guard_test.sh` checks the last-pair
  telemetry fields, verifies `processRunPair` captures telemetry before
  `reapProcess(a)`, and enforces that the S2g guard runs immediately after the
  concurrent EL0 demo.
- **Non-goals.** No secondary CPU dispatches EL0 work, no scheduler placement
  policy changes, no IPI/cross-CPU wake path is added, and no userland ABI is
  widened in this checkpoint.

### S2h — restricted coproc multi-CPU EL0 dispatch (DONE, 2026-06-10)

- **Secondary EL0 scheduler gate.** The S1 secondary loop now polls a process
  scheduler service hook before returning to IRQ-enabled `wfi`. CPU0 can set a
  run mask for one secondary CPU, wait for that CPU to enter its per-CPU process
  scheduler context, and later set a stop mask so the secondary returns to its
  idle loop. The hook is only enabled by the `processRunPair` acceptance path;
  general secondary process scheduling remains off.
- **Per-CPU current process state.** The old singleton `currentProc` is now a
  per-CPU slot mirror, so syscalls, user access, VFS capability checks, logging,
  timer accounting, and signal paths read the process running on the current
  CPU. The kernel scheduler remains CPU0-owned; only the EL0 process scheduler
  uses the restricted secondary hook.
- **Safe cross-CPU reap boundary.** A process is not reapable until it has
  returned to its scheduler stack. After every process context switch back to a
  scheduler context, the scheduler switches TTBR0 back to the kernel address
  space and marks the slot quiesced before another CPU may free the process
  kernel stack or page tables.
- **Runtime acceptance.** On `-smp 4`, the existing `coproc` pair runs with one
  process on CPU0 and one on a secondary scheduler CPU, then logs
  `S2h OK: coproc pair dispatched across scheduler CPUs`,
  `S2h OK: process scheduler quiesced after multi-CPU dispatch`, and
  `S2h OK: secondary EL0 gate closed after restricted dispatch`. On `-smp 1`,
  the same path logs an explicit CPU0 fallback marker. `tests/smp_boot_test.sh`
  covers both forms; `tests/uefi_boot_test.sh` checks the markers on firmware
  boots.
- **Harness hardening.** `tests/boot_test.sh` now builds a QEMU virt DTB when a
  clean worktree lacks `build/virt.dtb`, assembles QEMU argv through a non-empty
  array under `set -u`, and uses the same escalating QEMU cleanup style as the
  SMP harness. Interactive Swift/userland smoke drivers send shell input with
  short per-character pacing and explicit completion markers to avoid FIFO
  overrun flakes under long full-suite runs.
- **Non-goals.** No process migration, reschedule IPI, TLB shootdown protocol,
  shared-address-space thread execution on secondary CPUs, or broad VFS/PMM
  concurrency is enabled here. The remaining S2 work is the general stress path:
  N runnable EL0 processes, cross-CPU wakeups, and no scheduler corruption under
  sustained timer preemption.

### S3a — address-space active CPU mask preflight (DONE, 2026-06-10)

- **Active-address-space evidence.** The EL0 scheduler now records
  `pAddressSpaceCpuMask[slot]` and a per-CPU
  `processAddressSpaceActivationCount` after installing a process TTBR0 with
  `address_space_switch(pTtbr0[s])` and before accounting the EL0 switch. This
  is the cheap active-CPU evidence S3 needs before real TLB shootdown targeting
  can be implemented.
- **Restricted-secondary invariant.** The recorder is still protected by the
  S2h scheduler run mask and cross-checks against dispatch telemetry, so only
  CPU0 and the explicitly started S2h secondary scheduler CPU may activate a
  process address space in this checkpoint.
- **Runtime acceptance.** Boot runs `processAddressSpaceCpuMaskSelfTest` after
  S2h readiness and logs `S3a OK: address-space CPU mask scaffold ready`. After
  the userland demos, boot runs `processAddressSpaceCpuMaskPostRunSelfTest`
  after the S2h gate-closed guard and logs
  `S3a OK: address-space CPU masks matched dispatch CPUs`.
- **Static guard.** `tests/smp_release_guard_test.sh` requires the S3a fields,
  recorder, self-tests, marker ordering, and the exact switch-path order:
  `address_space_switch(pTtbr0[s])` -> `recordProcessAddressSpaceActivation`
  -> `smpRecordEl0SwitchForCurrentCpu`.
- **Non-goals.** No TLB invalidation behavior changes, no process migration, no
  shared-address-space cross-CPU execution, and no broad scheduler placement is
  enabled in this checkpoint.

### S3b — GIC SGI / IPI substrate preflight (DONE, 2026-06-10)

- **GICv2 SGI sender.** `kernel/drivers/gic.swift` now reserves SGI ID 1 for
  SMP IPIs, enables SGIs per CPU interface, and writes GICD_SGIR at offset
  `0xF00` in target-list mode (`SGIINTID[3:0]`,
  `CPUTargetList[23:16]`, `TargetListFilter[25:24] = 0b00`). The encoding was
  checked against QEMU 11.0.1 `hw/intc/arm_gic.c`, whose `gic_dist_writel`
  handles offset `0xf00` by setting `sgi_pending[irq][target_cpu]`.
- **Parked secondaries can receive IPIs.** After their early timer heartbeat,
  secondary CPUs poll the restricted S2h scheduler hook and then sleep in an
  IRQ-enabled `wfi` loop. Their IRQ path still does no scheduler/VFS/driver
  work: timer PPIs only rearm the local timer or drive an already-active S2h
  process scheduler CPU, and SGI ID 1 only records atomic per-CPU IPI counters
  and source CPU.
- **Runtime acceptance.** Boot runs `smpIpiSubstrateSelfTest` after S3a
  readiness. On SMP boots CPU0 sends SGI ID 1 to every discovered secondary,
  waits for the delivered mask, verifies the source CPU, and logs
  `S3b OK: GIC SGI IPI substrate ready`. After userland demos, boot verifies the
  IPI delivery mask stayed complete and secondary kernel scheduler state stayed
  idle, then logs `S3b OK: IPI delivery stayed scheduler-safe`.
- **Static guard.** `tests/smp_release_guard_test.sh` requires the SGIR offset,
  SGI sender/source helpers, IPI counters, IRQ handler hook, restricted S2h
  service loop, and the boot-order contract (`S3a readiness -> S3b readiness ->
  demos`, then `S2h quiesced -> S2h gate closed -> S3a matched -> S3b
  scheduler-safe`).
- **Non-goals.** No TLB shootdown protocol is implemented yet, no reschedule
  IPI is consumed by the scheduler, and no PMM/VFS/process locking policy
  changes in this checkpoint.

### S3c — TLB shootdown IPI scaffold (DONE, 2026-06-10)

- **Fixed request/ack protocol.** `kernel/smp/percpu.swift` now has separate
  fixed atomic TLB shootdown generations, ack generations, received counters,
  and probe masks. These stay outside `SMPPerCpuState`, preserving the 64-byte
  scheduler slot while giving S3 a concrete per-CPU protocol to wire into
  future address-space active masks.
- **IPI handler consumption.** SGI ID 1 still records the generic S3b IPI
  counters, then consumes any pending TLB shootdown generation for the current
  CPU. The S3c path performs only a local `tlbi_all()` plus atomic ack/counter
  updates; it does not log, schedule, touch process state, allocate pages, or
  call VFS/driver code from a parked secondary CPU.
- **Runtime acceptance.** Boot runs `smpTlbShootdownSelfTest` after S3b
  readiness. On SMP boots CPU0 publishes a generation to every discovered
  secondary, sends the reserved SGI, waits for the ack mask, verifies each
  target's ack generation and received count, and logs
  `S3c OK: TLB shootdown IPI scaffold ready`. After userland demos, boot
  verifies the ack mask stayed complete and secondary scheduler state stayed
  idle, then logs `S3c OK: TLB shootdown path stayed scheduler-safe`.
- **Static guard.** `tests/smp_release_guard_test.sh` now checks the S3c
  request/ack globals and helpers, boot-order placement, and the narrow TLB
  handler contract. The generic S3b handler still cannot inline logging,
  scheduler/process work, VFS/driver/PMM calls, or raw TLB instructions.
- **Non-goals.** Existing VM page-table mutation sites still perform local
  invalidation because secondary EL0/address-space activation remains gated.
  The next S3 slice can connect this protocol to per-address-space active CPU
  masks once multi-CPU process execution is intentionally opened.

### S3d — active-mask VM TLB flush facade (DONE, 2026-06-10)

- **VM facade.** `kernel/mm/vm.swift` now routes TLB invalidation through
  `addressSpaceFlushTlbForActiveCpuMask`. The facade performs the page-table
  write barrier, invalidates the current CPU locally (`tlbi vae1` or
  `tlbi vmalle1`), and forwards any remote CPU bits to the S3c request/ack
  shootdown path. The exported C ABI entry points remain as current-CPU wrappers
  for inactive construction paths.
- **Process-owned active masks.** `kernel/user/process.swift` exposes
  `processCurrentAddressSpaceActiveCpuMask` and uses S3a's
  `pAddressSpaceCpuMask` for process-owned page-table mutations: heap growth
  rollback, anonymous mmap, demand-paged file mmap, munmap, mprotect, COW
  prepare/fault handling, and fork's parent COW rewrite. The current gate keeps
  the active mask CPU0-only, but the future multi-CPU path now has one explicit
  hook instead of scattered raw `tlbi_*` calls.
- **Runtime acceptance.** Boot runs `processAddressSpaceTlbFlushFacadeSelfTest`
  after S3c readiness and logs
  `S3d OK: address-space TLB flush facade ready`. After userland demos, boot
  runs `processAddressSpaceTlbFlushNoSecondarySelfTest`, verifies active masks
  stayed CPU0-owned, and logs
  `S3d OK: address-space TLB flush stayed CPU0-owned`.
- **Static guard.** `tests/smp_release_guard_test.sh` requires the VM facade,
  active-mask variants, process active-mask helpers, COW/copyout routing, and
  the S3d boot-order contract. Generic IPI/TLB handlers remain constrained to
  no logging, scheduler, process, VFS, virtio, or PMM work from secondary IRQ
  context.
- **Non-goals.** This checkpoint does not enable secondary EL0 execution, does
  not prove stale translation eviction across user threads on different CPUs,
  and does not change PMM/VFS/package-store concurrency policy.

### S4a — PMM lock boundary and concurrent PageAllocator stress (DONE, 2026-06-10)

- **Coarse PMM lock.** `kernel/mm/pmm.swift` now wraps the shared
  `PageAllocator` owner in an IRQ-save spinlock built from the S0b atomic CAS
  primitive. The exported PMM entry points (`pmm_alloc_page`,
  `pmm_alloc_pages`, `pmm_free_page`, COW ref/unref/refcount, and PMM counters)
  all enter through the same `pmmWithAllocator` boundary, so the bitmap, hint,
  free-frame count, and refcount table are no longer raw global mutable state
  once secondary CPUs can call allocation paths.
- **Atomic last-ref release.** `pmm_frame_release` drops one COW reference and
  raw-frees the frame under the same PMM lock. VM user-frame teardown now uses
  this primitive instead of a split `pmm_frame_unref` / `pmm_free_page`
  sequence.
- **Executable checks.** Boot runs `pmmS4aConcurrencySelfTest()` after the S3d
  readiness checks, then sends a bounded PMM stress request to discovered
  secondary CPUs over the existing SGI/IPI path, and logs
  `S4a OK: PMM lock boundary ready`. After the userland demos, boot verifies the
  lock word is balanced, the PMM stress ack/failure masks are clean, and logs
  `S4a OK: PMM lock boundary stayed balanced`.
- **Host stress.** `tests/page_allocator_test.swift` keeps the existing unit and
  adversarial cases and adds an 8-worker threaded allocation/free/ref/unref
  stress through a synchronized wrapper over the same pure `PageAllocator`
  logic. It asserts no duplicate live frames and full frame-count recovery.
- **Static guard.** `tests/smp_release_guard_test.sh` requires the PMM lock
  helpers, the atomic release primitive, the bounded SGI PMM stress path,
  rejects direct optional PMM allocator access outside the wrapper, and checks
  the S4a boot-marker order. `tests/smp_boot_test.sh` and the UEFI boot smoke
  now require the S4a markers.
- **Non-goals.** No per-CPU page magazines yet, no lock-free bitmap operations,
  no small-object heap synchronization, and no VFS/handle/package-store pool
  locking in this slice.

### S4b — VFS lock boundary and handle accounting guard (DONE, 2026-06-10)

- **Coarse VFS lock.** `kernel/vfs/vfs.swift` now protects the shared VFS
  mutable pools (node table, per-process handle slots, shared open descriptions,
  pipes, endpoints, cwd nodes, and confinement roots) with an IRQ-save spinlock
  built from the S0b atomic CAS primitive. The lock has acquire/contention
  counters so boot can prove the boundary was exercised and left balanced.
- **Borrowed open descriptions.** Long operations borrow the open description
  before dropping the VFS lock. Pipe reads/writes and endpoint receives release
  the lock before `processYieldForIO()`, sockets run the TCP/UDP work without
  the VFS lock held, and disk-backed reads reserve the shared file offset before
  block I/O. `close`/`dup`/`fork`/`exec` handle refcount paths are serialized by
  the same boundary.
- **Executable checks.** Boot runs `vfsS4bReadinessSelfTest()` immediately after
  `vfsInit()` and logs `S4b OK: VFS lock boundary ready`. After userland demos
  it runs `vfsS4bLockBoundaryHeldSelfTest()`, which verifies the lock word is
  clear and fd/open-description/pipe/endpoint accounting is balanced, then logs
  `S4b OK: VFS lock boundary stayed balanced`.
- **Static guard.** `tests/smp_release_guard_test.sh` requires the VFS lock
  helpers, borrowed-description helpers, socket borrow helper, accounting
  self-test, and S4b boot-marker order. The SMP and UEFI boot smokes now require
  both S4b markers.
- **Non-goals.** S4b does not enable secondary EL0 execution, does not make the
  small-object kernel heap concurrent, and does not protect package-store
  mutation or network engine state beyond keeping VFS socket descriptors alive.

### S4c — kernel bump-heap lock boundary (DONE, 2026-06-10)

- **C heap lock.** `kernel/runtime/heap.c` now protects `heap_cursor`,
  `heap_limit`, and `heap_initialized` with an IRQ-save spinlock built from the
  S0b C atomic bridge. `swiftos_kernel_alloc`, `swift_slowAlloc`,
  `posix_memalign`, and `swiftos_kernel_heap_used_bytes` all pass through that
  boundary.
- **Idempotent init.** `swiftos_heap_init()` no longer rewinds the bump cursor
  after the heap is already live. The lazy allocation path initializes under
  the same lock if an early caller reaches it first.
- **Executable checks.** Boot runs `swiftos_heap_s4c_self_test()` after the S4b
  VFS readiness check and logs `S4c OK: kernel heap lock boundary ready`. After
  userland demos it runs `swiftos_heap_lock_boundary_self_test()` and logs
  `S4c OK: kernel heap lock boundary stayed balanced`.
- **Static guard.** `tests/smp_release_guard_test.sh` requires the C heap lock,
  counter/self-test exports through `io.h`, and S4c boot-marker order. SMP and
  UEFI boot smokes now require both S4c markers.
- **Non-goals.** This keeps the minimal bump allocator design. There is still
  no small-object free/reclaim, no per-CPU heap cache, and no secondary EL0
  execution in this checkpoint.

### S4d — package-store lock boundary (DONE, 2026-06-10)

- **Package-store lock.** `kernel/pkg/store.swift` now protects package-store
  payload/activation tables, active payload publication, record offsets, and
  S4d counters with a short IRQ-save spinlock.
- **Writer gate.** `pkgStoreInstall` uses a single-writer gate around the
  target-side install transaction. Hashing and virtio-blk reads/writes happen
  outside the spinlock; record reservation/commit and final active payload
  publication happen through short locked helpers.
- **Reader snapshot.** Active payload count/info/read paths copy the active
  payload index/offset/size snapshot under the S4d lock, then perform package
  store block I/O without holding it.
- **Executable checks.** Boot runs `pkgStoreS4dReadinessSelfTest()` immediately
  after `pkgStoreInit()` and before VFS consumes active package payloads, then
  logs `S4d OK: package-store lock boundary ready`. After the userland demos it
  runs `pkgStoreS4dLockBoundaryHeldSelfTest()` and logs
  `S4d OK: package-store lock boundary stayed balanced`.
- **Static guard.** `tests/smp_release_guard_test.sh` requires the S4d lock,
  writer gate, record reservation/commit helpers, unlocked payload reads, and
  S4d boot-marker order. SMP and UEFI boot smokes now require both S4d markers.
- **Non-goals.** S4d does not add a package-store journal, multi-writer
  transactions, or a package-management service. Install remains a serialized
  operation.

### S4e — network/socket lock boundary (DONE, 2026-06-10)

- **Network lock.** `kernel/net/socket.swift` now protects `gNet`, DNS scratch
  state, socket tables, TCP connection state, RX datagram rings, and the
  virtio-net poll/TX/RX boundary with a short IRQ-save spinlock and S4e
  acquire/contention counters.
- **Pump boundary.** `netPump()` is the public locked pump entry point;
  `netPumpLocked()` is the internal helper that may call `virtioNetPoll(&gNet)`
  and deliver RX frames into sockets. Blocking recv/accept/connect paths pump
  or wait without holding the lock, then take short locked snapshots to inspect
  socket state or copy payloads.
- **Boot probe boundary.** The net-a boot probe no longer reads `gNet` or calls
  virtio-net TX/poll helpers directly from `main.swift`; it uses small locked
  probe helpers for MAC, ARP, and ICMP echo checks.
- **Executable checks.** Boot runs `netS4eReadinessSelfTest()` immediately after
  `runVirtioNetProbe()` and logs `S4e OK: network lock boundary ready`. After
  the userland demos it runs `netS4eLockBoundaryHeldSelfTest()` and logs
  `S4e OK: network lock boundary stayed balanced`.
- **Static/runtime guard.** `tests/smp_release_guard_test.sh` requires the S4e
  lock, counters, pump/probe helpers, and boot-marker order. SMP and UEFI boot
  smokes require both S4e markers. Runtime network coverage was re-run across
  virtio-net ARP/ICMP, UDP/TCP echo, TCP active open, DNS, HTTP, TLS, zero-copy
  RX refs, socket handle transfer, IPv6 link-local/NDP smokes, and signed HTTP
  package repo install.
- **Non-goals.** S4e does not service-ize the network stack, add a NIC interrupt
  thread, or enable broad secondary network work. It is a correctness boundary
  for the current in-kernel polled engine; C5/network service work still owns
  the architectural move out of the kernel.

### S4f — restricted-SMP resource stress (DONE, 2026-06-10)

- **Userland workload.** `/bin/s4stress` is a small static C binary that drives
  the kernel resource paths hardened during S4. Each run repeats anonymous
  `mmap`/`munmap`, pipe create/dup/read/write/close, tmpfs
  write/rename/read cycles plus bounded create/unlink/mkdir/rmdir smoke paths,
  `fork`/`waitpid`, and `spawn`/exec of `/bin/argvdemo`, then prints `S4F-*`
  completion markers.
- **Runtime harness.** `tests/s4_resource_stress_test.sh` boots QEMU with
  `-smp 4`, logs in through the normal console path, runs `/bin/s4stress` from
  the packed base image, and requires the S2 timer heartbeat plus the S4e
  post-run lock-balance marker before accepting the S4f markers. `make test`
  runs the harness after the SMP boot smoke.
- **Post-boot SMP churn harness.** `tests/smp_resource_stress_test.sh` boots
  with `-smp 4`, logs in after the normal boot demos, and reruns resource-heavy
  userland paths (`forkdemo`, `fdopsdemo`, `execdemo`, `threadsdemo`, and a
  tmpfs create/write/pipe/move/remove loop) while all discovered CPUs remain
  online and ticking. It checks the S4a-S4e post-demo lock-boundary markers and
  its own `S4F-*` status markers, and is available as
  `make smp-resource-stress-test`.
- **Static guard.** `tests/smp_release_guard_test.sh` now requires the
  `/bin/s4stress` Makefile wiring, base-image install step, executable
  harnesses, and workload coverage markers so the S4f stress does not silently
  fall out of the release contract.
- **Non-goals.** S4f is intentionally a restricted-SMP stress pass for the
  current S2h gate. It does not enable broad secondary EL0 execution or make one
  address space execute concurrently on multiple CPUs; that remains S5.

### S5a — per-CPU utilization export (DONE, 2026-06-10)

- **Kernel accounting.** The existing per-CPU timer scaffold now also exposes
  idle ticks through the S5a `SYS_sysinfo` extension. CPU0 mirrors its legacy
  idle accounting from `processOnTick`; parked secondary CPUs account their
  timer interrupts as idle in the IRQ path.
- **Userland visibility.** The first 64 bytes of the `/bin/top` sysinfo record
  remain compatible with the previous layout. Userland that passes the extended
  record capacity receives `cpuCount`, `cpuCapacity`, `cpuTicks[8]`, and
  `cpuIdleTicks[8]` starting at offset 64. `/bin/top` renders aggregate
  busy/idle from those deltas plus a per-CPU busy line.
- **Executable checks.** Boot logs `S5a OK: per-CPU utilization counters ready`.
  `tests/top_test.sh` is parameterized by `SMP_CPUS`; `make
  smp-cpu-utilization-test` runs `/bin/top -b -n 2` under `-smp 4` and requires
  the four per-CPU busy entries.
- **Non-goals.** S5a is observability only. It does not broaden process
  placement, enable one address space on multiple CPUs, or change the restricted
  S2h secondary EL0 gate.

### S5b — bounded EL0 scheduler placement batch (DONE, 2026-06-10)

- **Scheduler placement acceptance.** `processRunS5bPlacementBatch` extends the
  restricted S2h gate from a pair demo to a three-process batch: the stable
  pair phase pins one `coproc` process to the explicitly started secondary
  scheduler CPU and one to CPU0, then a third CPU0 `coproc` tail runs before
  any of the batch slots are reaped. The default scheduler placement still
  remains CPU0 outside this acceptance path.
- **Telemetry before reap.** The batch captures per-process dispatch counts,
  dispatch CPU masks, and last-dispatch CPUs before the slots are reaped. The
  S5b guard requires the secondary-pinned process to dispatch on a non-primary
  online CPU under `-smp 4`, or the explicit CPU0 fallback under single-CPU boot.
- **Placement correctness fixes.** Requeue now preserves an existing process's
  `pHomeCpu` instead of recalculating the default CPU0 placement, and new slots
  explicitly clear dispatch/address-space telemetry before first enqueue. Live
  `klog` output also renders non-zero `detail=` fields, matching the SMP boot
  contract that already used structured details.
- **Executable checks.** Boot prints
  `S5b OK: three EL0 processes ran with scheduler placement` and logs either
  `S5b OK: EL0 scheduler placed batch across CPUs` or the CPU0 fallback. The
  SMP boot smoke checks marker ordering, the release guard checks capture-before
  reap and boot-order contracts, and `make s5-scheduler-placement-test` runs the
  focused `-smp 4` boot acceptance.
- **Non-goals.** S5b does not enable arbitrary secondary EL0 scheduling,
  migration, work stealing, cross-CPU wakeups, or concurrent execution of
  multiple EL0 threads in the same address space.

### S5c — repeated EL0 placement stress + run queue lock (DONE, 2026-06-10)

- **Run queue locking.** EL0 process run queue enqueue/dequeue now takes a
  small per-CPU IRQ-save spinlock. This keeps the CPU0 producer path and the
  secondary scheduler consumer path from racing on the `head`/`tail` pair when
  CPU0 publishes work to a secondary run queue. Cross-CPU enqueue also sends
  `sev` after the queue update so a parked secondary scheduler does not wait
  for the next timer interrupt before noticing new work.
- **Repeated placement workload.** `processRunS5cPlacementStress` runs three
  independent `coproc` primary/secondary rounds through the restricted S2h
  gate, then stops the secondary scheduler and runs two CPU0 tail processes.
  Slots are reaped after each round, but aggregate dispatch counts and CPU masks
  are captured before each reap and folded into S5c telemetry.
- **Executable checks.** Boot prints `S5c OK: repeated EL0 placement stress
  completed` and logs either `S5c OK: repeated EL0 placement stress crossed
  CPUs` or the CPU0 fallback. The S5c guard validates the expected process
  count, primary/secondary masks, nonzero dispatches, visible run queue lock
  activity, cleared gate masks, and idle queues. `make s5-placement-stress-test`
  runs the focused `-smp 4` boot acceptance.
- **Non-goals.** S5c still does not enable arbitrary process migration, load
  balancing, shared-address-space execution on multiple CPUs, or secondary
  scheduler access to unrelated kernel subsystems.

### S5d — independent EL0 fanout across scheduler CPUs (DONE, 2026-06-10)

- **Multi-secondary fanout.** `processRunS5dFanout` starts every online
  secondary scheduler CPU with a live timer heartbeat, creates one independent
  top-level `coproc` process for CPU0 and one for each started secondary CPU,
  then waits for all slots to become zombie and scheduler-quiesced before
  stopping the secondary schedulers.
- **Exact placement telemetry.** The fanout captures the scheduler CPU mask,
  aggregate dispatch CPU mask, secondary CPU mask, total dispatch count, and a
  count of processes whose dispatch mask exactly matched their home CPU before
  any fanout slot is reaped. The S5d guard requires those masks to match, all
  participating CPUs to record EL0 switches, all gate masks to be clear after
  stop, and every run queue to be idle.
- **Executable checks.** Boot prints `S5d OK: EL0 fanout ran across scheduler
  CPUs` and logs either `S5d OK: EL0 fanout crossed scheduler CPUs` or the CPU0
  fallback. `make s5-el0-fanout-test` runs the focused `-smp 4` boot
  acceptance, the SMP boot smoke enforces S5b -> S5c -> S5d marker ordering
  before Swift ps, and the release guard checks the fanout wiring.
- **Non-goals.** S5d still does not migrate a process after creation, run a
  single shared address space on multiple CPUs, enable arbitrary load balancing,
  or let secondary schedulers execute unrelated kernel-thread work.

### S5e — shared-address-space thread fanout (DONE, 2026-06-10)

- **Futex SMP boundary.** `kernel/sched/futex.swift` now protects the futex wait
  table with an IRQ-save spinlock and exposes S5e lock/waiter self-tests. The
  `FUTEX_WAIT` path records the waiter and marks the caller blocked while holding
  the futex lock, then releases the lock before yielding so a different CPU can
  run `FUTEX_WAKE` without deadlocking or losing the wake.
- **Gated thread placement.** `processRunS5eThreadFanout` starts online secondary
  scheduler CPUs, runs `/bin/threadsdemo` on CPU0, and temporarily enables an
  S5e-only `thread_create` placement policy. Created sibling threads share the
  creator TTBR0 and are placed round-robin on active secondary scheduler CPUs;
  ordinary `thread_create` remains CPU0-placed outside this acceptance path.
- **Telemetry and guard.** S5e records created/exited thread counts, shared
  address-space count, home/dispatch CPU masks, exact home-CPU dispatch matches,
  futex lock activity, and a protected telemetry-lock count before the top-level
  demo process is reaped. The guard requires two sibling threads, a shared
  address space, nonzero futex lock activity, idle futex waiters/run queues, and
  closed secondary gate masks.
- **Executable checks.** Boot prints `S5e OK: shared-address-space thread fanout
  completed` and logs either `S5e OK: shared-address-space threads crossed CPUs`
  or the CPU0 fallback. `make s5-thread-fanout-test` runs the focused `-smp 4`
  boot acceptance.
- **Non-goals.** S5e does not make all shared address spaces freely migratable,
  add load balancing/work stealing, or protect concurrent `mmap`/`brk` mutations
  from multiple threads. It proves the narrow thread/futex runtime path under the
  restricted S2h scheduler gate.

### S5f — run-any EL0 placement policy (DONE, 2026-06-10)

- **Gated run-any policy.** The ordinary default process placement still chooses
  CPU0 outside the acceptance window. `processRunS5fRunAnyPlacement` temporarily
  enables a run-any hook that round-robins new EL0 processes across CPU0 plus all
  active secondary scheduler CPUs, using the normal `homeCpu: unassignedCpu`
  creation path instead of explicit affinity.
- **More work than CPUs.** The boot demo starts all online secondary scheduler
  CPUs and creates more `/bin/coproc` processes than scheduler CPUs. This forces
  the run-any selector to wrap while each process remains pinned to the selected
  home CPU for the duration of the narrow test.
- **Telemetry and guard.** S5f captures the scheduler CPU mask, aggregate
  dispatch CPU mask/count, secondary CPU mask, policy selection count, process
  count, and exact home-CPU dispatch matches before reaping. The guard requires
  policy selections to match created processes, dispatch coverage to match the
  scheduler mask, every process to dispatch only on its selected CPU, and all
  run queues plus secondary gate masks to be idle after stop.
- **Executable checks.** Boot prints `S5f OK: run-any placement policy
  completed` and logs either `S5f OK: run-any placement covered scheduler CPUs`
  or the CPU0 fallback. `make s5-run-any-placement-test` runs the focused
  `-smp 4` boot acceptance.
- **Non-goals.** S5f does not add migration, work stealing, load balancing, or a
  production scheduler heuristic. It proves that the default placement path can
  select any active scheduler CPU under the existing restricted SMP boundary.

### S5 aggregate readiness gate (DONE, 2026-06-10)

- **Scope.** Added `make s5-test` as the review-facing aggregate for S5 runtime
  readiness. It runs the existing S5a-S5f focused gates in order:
  `smp-cpu-utilization-test`, `s5-scheduler-placement-test`,
  `s5-placement-stress-test`, `s5-el0-fanout-test`, `s5-thread-fanout-test`, and
  `s5-run-any-placement-test`.
- **Why.** S0/S1 already had aggregate targets (`s0-test`, `s1-test`), but S5
  required reviewers to remember the full focused-gate list. The aggregate target
  preserves the narrow gates and gives broader reviews a single command.
- **Guard.** `tests/phase1_roadmap_test.swift` checks the Makefile target and
  docs references so future S5 docs do not drift back to only naming the final
  focused gate.

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
  and is wired into `make test` after the UDP smoke. A harness-hardening follow-up
  makes the host UDP receive window more patient and fails fast with the serial
  tail if QEMU exits while the script is waiting for a marker.
- **Still deferred.** VMOs, async rings, batched descriptors, `ipc_call`, badges,
  service supervisor, userland drivers, Cells/resource domains, endpoint
  close-on-exec policy change, and SMP work remain later C/S milestones.

### C5a — restartable driver-service supervisor smoke (DONE, 2026-06-10)

- **Supervisor/service shape.** Added `/bin/drvsvcdemo`, a tiny userland
  supervisor, and `/bin/drvinputd`, a pseudo input-driver service. The supervisor
  creates two endpoint pairs, forks/execs the service with only the service-side
  endpoint fds left open, waits for a ready message, sends a command, receives an
  event, stops the service, and repeats the sequence with a fresh generation.
- **Restart evidence.** The service returns a generation-specific exit status
  after `STOP`, so the supervisor proves both the old service stopped and a new
  service instance recovered the endpoint protocol.
- **Executable checks.** Boot now runs the smoke and prints
  `C5a OK: restartable driver service recovered over IPC`; `make
  c5-driver-service-test` runs the focused `-smp 4` direct-boot acceptance.
- **Non-goals.** No real device handle, MMIO mapping, IRQ endpoint, DMA window, or
  virtio-input ownership is moved to userland yet. This is the C5 supervisor/IPC
  contract that the next device-handoff slice can attach hardware authority to.

### C5b — opaque device-handle handoff scaffold (DONE, 2026-06-10)

- **Device handle vocabulary.** `HandleKind.device` is now part of the typed
  handle table. Device grants default to `getattr + transfer` only: they can be
  inspected and moved over C4 IPC, but not duplicated, read, written, or mapped.
- **Registry scaffold.** VFS owns a tiny device registry with `pseudo-input.0`,
  a C5 scaffold entry marked `NO_MMIO_GRANT`. `device_claim(name, info*)`
  creates a unique device handle for the boot authority and returns `-16` while
  another live handle owns the grant. `device_info(fd, info*)` exposes fixed
  metadata; the MMIO base/length and IRQ fields are zero because C5b does not
  grant hardware access yet.
- **Lifecycle and IPC transfer.** Open-description refcounts now release device
  ownership on final close/process exit. `/bin/drvsvcdemo` claims the pseudo
  device, transfers it to `/bin/drvinputd` with `ipc_send(..., handle_fd)`,
  verifies the moved source fd becomes `-9`, observes `-16` on a concurrent
  claim while the service owns it, stops the service, and successfully reclaims
  the device.
- **Executable checks.** Boot now requires
  `C5b OK: opaque device handle transferred and released`; `make
  c5-device-handle-test` is the focused direct-boot acceptance. The host
  `handle_test` also covers `.device` kind stability and default rights.
- **Non-goals.** Still no MMIO map syscall, IRQ endpoint, DMA window, real
  virtio-input device claim, manifest matching, or driver replacement. C5b only
  makes the ownership/transfer/release contract executable.

### C5c — virtio-input device discovery and manifest matching (DONE, 2026-06-10)

- **Discovery ABI.** Added `device_discover(index, info*)` as syscall 64. It is
  read-only, requires the same boot authority capability as `device_claim`, and
  enumerates the device registry by manifest ordinal. It writes the same 64-byte
  `swiftos_device_info` record as `device_info`; out-of-range enumeration returns
  `-2`.
- **Discovery-backed registry.** The VFS device registry now probes the
  platform virtio-mmio window for device id 18 and registers `virtio-input.0`
  when a QEMU virtio-input transport is present. The grant metadata records
  `SWIFTOS_DEVICE_KIND_VIRTIO_INPUT`, `SWIFTOS_DEVICE_BUS_VIRTIO_MMIO`, the
  transport MMIO base/length, and `DISCOVERED | NO_MMIO_GRANT`.
- **Headless fallback.** Direct serial boots that do not attach a keyboard
  device still register `pseudo-input.0`, so the C5 supervisor and lifecycle
  smoke remains part of the broad boot path.
- **Supervisor/service manifest check.** `/bin/drvsvcdemo` prefers
  `virtio-input.0`, validates the manifest fields, transfers the device handle
  to `/bin/drvinputd`, proves the grant is busy while the service owns it, and
  reclaims it after service exit. `/bin/drvinputd` validates the same manifest
  before acknowledging. The focused path emits
  `C5c OK: virtio-input device grant discovered and matched`.
- **Executable checks.** `make c5-device-discovery-test` attaches QEMU
  `virtio-keyboard-device` and runs the C5 gate under `-smp 4`; the ordinary
  `boot_test.sh` still covers the pseudo fallback and requires
  `C5c OK: device discovery manifest matched pseudo input`.
- **Non-goals.** C5c still grants only `getattr + transfer`. No userland MMIO
  map syscall, IRQ endpoint, DMA window, or replacement of the in-kernel
  virtio-input queue owner lands in this slice.

### C5d — virtio-input discovery metadata (DONE, 2026-06-10)

- **Metadata source.** The virtio-input keyboard probe now scans
  `platform.virtioMmioBase/Stride/Count` instead of the old fixed QEMU window
  constants. VFS device-registry setup reuses the same read-only probe: when a
  `virtio-keyboard-device` is present, `virtio-input.0` reports
  `VIRTIO_MMIO`, the transport MMIO base, and the slot length in
  `swiftos_device_info`.
- **Authority boundary.** The registry still sets `NO_MMIO_GRANT`, and IRQ is
  still zero. These MMIO fields are discovery manifest metadata only; no userland
  mapping, IRQ endpoint, DMA window, or driver ownership is handed out.
- **Executable checks.** `/bin/drvsvcdemo` and `/bin/drvinputd` validate both the
  synthetic no-device fallback and the virtio-mmio metadata case. `make
  c5-device-metadata-test` boots with a QEMU virtio keyboard and asserts
  `C5d OK: virtio input discovery metadata surfaced`.

### C5e — device authority envelope preflight (DONE, 2026-06-10)

- **Authority flags.** `userland/lib/syscall.h` now reserves
  `SWIFTOS_DEVICE_FLAG_MMIO_GRANT`, `SWIFTOS_DEVICE_FLAG_IRQ_GRANT`, and
  `SWIFTOS_DEVICE_FLAG_DMA_GRANT`, plus the combined
  `SWIFTOS_DEVICE_FLAG_HARDWARE_AUTHORITY` mask. The current registry never sets
  those bits.
- **Executable boundary.** The supervisor and service both validate that device
  grants keep the future hardware-authority mask clear, keep `NO_MMIO_GRANT`
  set, and report `irq == 0`. This makes the current metadata-only contract a
  testable boundary rather than a comment.
- **Acceptance.** `make c5-device-authority-test` runs the focused C5 QEMU path
  with `virtio-keyboard-device` attached and asserts
  `C5e OK: device authority withheld until explicit handoff`.

### C5f — metadata-only device grant rights contract (DONE, 2026-06-10)

- **Shared rights helper.** `kernel/vfs/handle.swift` now defines
  `deviceMetadataGrantRights()` as the single metadata-only device grant shape:
  `.getattr + .transfer`. The VFS device claim path uses that helper instead of
  assembling device rights locally.
- **No implicit hardware authority.** The host handle test and static C5f guard
  reject accidental `.read`, `.write`, `.execute`, `.map`, `.duplicate`, or
  `.setattr` rights on current device grants. Runtime C5 still proves the grant
  can be inspected, moved over IPC, and not duplicated.
- **Acceptance.** `make c5-device-rights-test` runs the host handle vocabulary
  check plus `tests/device_authority_guard_test.sh`. The focused and broad C5
  boot smokes now require
  `C5f OK: device grant rights stayed metadata-only`.

### C5 aggregate readiness gate (DONE, 2026-06-10)

- **Scope.** Added `make c5-test` as the review-facing aggregate for C5
  readiness. It names the existing C5a-C5f gates in order:
  `c5-driver-service-test`, `c5-device-handle-test`,
  `c5-device-discovery-test`, `c5-device-metadata-test`,
  `c5-device-authority-test`, and `c5-device-rights-test`.
- **Why.** C5 review previously required remembering which QEMU gates cover the
  restartable driver-service path and which host/static guard covers
  metadata-only grant rights. The aggregate keeps focused gates available but
  gives broad reviews one command.
- **Guard.** `tests/phase1_roadmap_test.swift` checks the Makefile target and
  docs references so future C5 additions keep the aggregate readiness contract
  visible.

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
  the small bump heap).
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
- Resident at boot (`_start` 0x4008_0000 → `__image_end`, roughly **2.3 MiB** with the current linker
  reservation): 144 KiB code/data + 55 KiB bss + 64 KiB boot stack + 16 MiB early bump heap.
- Dynamic: of 256 MiB RAM the kernel, the 512 KiB sub-load-base hole, and the PMM bitmap consume about
  1.3 MiB before any process runs.
  The accounting/syscalls added by this feature grow the image by ~3 KiB.
- P13 server package smoke raised the disk-backed ELF exec staging buffer to
  8 MiB because the first static nginx package is larger than the earlier
  2 MiB busybox-sized buffer.

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

### I0 — host-verified tiny Llama2 inference core (DONE, 2026-06-09)

**Scope.** This is the smallest AI-hosting proof slice: a portable, I/O-free
`userland/lib/llama2.swift` implementation of the llama2.c checkpoint format,
transformer forward pass, SentencePiece-style BPE tokenizer, and deterministic
greedy generation. It is written so the same source can compile in the host
test runner now and later link into an EL0 `/bin/llm` demo.

**Test model.** `scripts/fetch-model.sh` fetches the tiny TinyStories
`stories260K.bin` checkpoint and `tok512.bin` tokenizer on demand into
`models/` (gitignored). `make model` is idempotent and `make test` depends on
those artifacts before running the host inference test.

**Acceptance.** `tests/llm_engine_test.swift` loads the tiny checkpoint,
checks the parsed config (`dim=64`, `layers=5`, `heads=8`, `kv=4`,
`vocab=512`, `seq=512`), and asserts that temperature-0 generation for
`Once upon a time` matches the upstream llama2.c reference output byte-for-byte
for 64 steps. This pins both tokenizer behavior and the floating-point forward
path without adding a kernel ABI or an in-guest `/bin/llm` yet.

### I1 — /bin/llm runs the inference engine in QEMU (DONE, 2026-06-09)

**Scope.** A native Embedded Swift EL0 app (`userland/llm.swift`, `/bin/llm`)
links the I0 engine (`userland/lib/llama2.swift`), reads the stories260K
checkpoint + tok512 tokenizer from the read-only base image into anonymous
`mmap`'d RAM, greedily generates text to the console, and reports tokens/sec.
This proves the engine runs end to end as an isolated EL0 process on the OS.

**Pieces.** The model files are packed into the base image under `/models`
(`make base-image` copies them from `./models`). `/bin/llm` is registered in the
`execResolve` allow-list (`kernel/user/exec.swift`). The app links the Unicode
data tables (the BPE tokenizer hashes `String` keys), like `/bin/calc`. One
freestanding-math fix was needed for EL0 (no libm): `Float.squareRoot()` lowers
to a `sqrtf` libcall, so `Mathf.sqrtf` is now a pure-Swift Heron iteration — the
host test still matches the reference byte-for-byte, confirming the accuracy;
`expf/sinf/cosf` were already hand-rolled in I0.

**Acceptance.** `tests/llm_run_test.sh` (in `make test`) boots, logs in as root,
runs `/bin/llm`, and asserts the generated story matches the llama2.c reference
text and that a tokens/sec figure is reported. Measured ~640–710 tok/s for the
260K model under QEMU TCG emulation with scalar FP and `-Osize` (an honest
baseline, not native throughput).

**Next.** I2 replaces the read-into-RAM load with a file-backed read-only `mmap`
of the weights (the documented "mmap-backed weights" primitive; today's `mmap`
is anonymous-only). I3 serves generated tokens over TCP via `poll()`.

### I2 — file-backed mmap of model weights (DONE, 2026-06-09)

**I2a — eager file-backed mmap.** New `mmap_file(fd, len, prot)` [`SYS_MMAP_FILE`=59]:
a read-only file-backed mmap of a disk-backed base-image file. I2a maps the whole
extent eagerly (the kernel reads it into private frames at mmap time); `/bin/llm`
switched from read-into-anonymous to this. `addressSpaceMmapFile` (vm.swift),
`vfsFileExtent(fd)` (vfs.swift), `processMmapFile` (process.swift), bridge
`swiftos_mmap_file`.

**I2b — demand paging (lazy).** `processMmapFile` now only reserves the VA range
and records a per-process file-VMA (`pFileVmas`); no frames are mapped at mmap
time. A translation fault on the region is serviced by `processHandleFileFault`
→ `addressSpaceMapFilePage`, which reads just the faulting page from disk, maps
it read-only, and retries. Hooked into the EL0 sync handler (main.swift, ESR
EC=0x24), disjoint from the COW write-fault path. VMAs are reset on exec/fresh
image and copied on fork/thread. A one-shot klog `demand-paged file mmap active`
marks the path; `fileDemandFaults` counts serviced faults. This realizes the
documented "mmap-backed weights / page-cache-friendly immutable model bundle"
primitive: resident memory grows only with pages actually touched, and startup
no longer reads the whole model up front.

**Tradeoff (honest).** Dense inference touches every weight page each token, so
the first forward pass faults in the whole model (~258 single-page reads):
first-token latency rises and steady-state resident still ≈ full model. Measured
~426 tok/s demand-paged vs ~800 eager (QEMU TCG, scalar FP). Demand paging wins
for huge/sparse/over-committed models and future shared-across-cells mappings;
eager wins for dense single-tenant. Exposing eager-vs-lazy as an `mmap_file` flag
is a natural follow-up. munmap of a lazily-reserved region does not yet
deactivate its VMA (the model-serving path maps once and exits, which is covered).

**Acceptance.** `tests/llm_run_test.sh` asserts the `file-backed` and
`demand-paged file mmap active` markers and that the generated story still
matches the llama2.c reference. Next: I3 serves tokens over TCP via `poll()`.

### I3 — /bin/llmd serves inference over TCP (DONE, 2026-06-09)

**Scope.** `userland/llmd.swift` (`/bin/llmd`) is the model-serving daemon and
the conclusion of the AI-hosting proof arc: the same Swift engine, weights
file-backed mmap'd from `/models` (I2), served over the network through the
existing capability-gated socket surface. Userland-only; no new kernel ABI is
required on the current VFS-loaded exec path.

**Server shape.** A poll()-driven loop (the `/bin/httpd` pattern: listener +
queued connections, one `poll()` multiplexing all fds). Endpoints:
`POST /completion` (body = prompt) streams the generated pieces to the socket
as they are produced (HTTP/1.0, `Connection: close` delimits the body);
`GET /health` reports liveness + model config; `GET /metrics` reports
`requests`, `tokens_total`, `last_ttft_ms`, `last_tok_s` — the first slice of
the AI-serving metrics list in ARCHITECTURE.md. Each request also logs
`llmd: served N tokens ttft=X ms rate=Y tok/s` on serial. Request parsing
handles multi-segment TCP delivery (bounded read loop until the blank line +
Content-Length bytes arrive). Generation runs inline on the single core; the
KV cache is safely reused across requests because every position is rewritten
before it is attended to.

**Measured (QEMU TCG, scalar FP, stories260K).** ttft=70 ms on the cold first
request — that includes demand-paging the whole model off virtio-blk (I2b) —
and ~376 tok/s streaming rate.

**Acceptance.** `tests/llm_serve_test.sh` (in `make test`): boots with a slirp
hostfwd, starts `/bin/llmd`, then from the host asserts the POSTed completion
matches the llama2.c reference story, `/health` and `/metrics` respond with
real counters, and the serial metrics line appeared. With I0–I3 complete, the
flagship claim is demonstrated end to end: swift-os loads an immutable model
bundle, mmaps the weights, and serves deterministic inference over TCP from an
isolated, capability-confined EL0 process.

### I4 — Q8_0 int8 quantization; llmd serves stories15M (DONE, 2026-06-09)

**Why.** The biggest product lever after I3: visibly coherent text (a 15M-param
model instead of the 260K toy) in ~3.6× less weight memory (60.8 MB fp32 →
17.1 MB int8). CPU-only int8 is exactly the "small immutable inference
appliance" profile.

**Quantizer (host).** `tools/quantize.swift` converts a legacy fp32 llama2.c
checkpoint into the llama2.c "version 2" Q8_0 format that upstream `runq.c`
consumes: 256-byte header (magic `ak42`, version 2, config, shared flag, group
size), fp32 rmsnorm weights, then per-tensor int8 `q[]` + fp32 `s[]` per-layer
interleaved. Quantization math is C-identical in fp32 (`scale = max|v|/127`,
`round` half-away-from-zero). GS is picked as the largest power of two ≤ 64
dividing both `dim` and `hidden_dim` — runq.c's matmul walks rows in GS steps,
so GS must divide every matmul row length (260K → GS=4, 15M → GS=32). Verified
by feeding the converted files to upstream runq.c itself. `make model` builds
`models/stories260K-q8.bin` + `models/stories15M-q8.bin` via Makefile rules;
`fetch-model.sh` also fetches `stories15M.bin` and the full 32000-entry Llama-2
`tokenizer.bin`.

**Engine.** `userland/lib/llama2.swift` gains a `LlamaModel` protocol (the
fp32 `Llama2` and the new `QLlama2` both conform; `llamaGenerate` is generic,
statically dispatched per the kernel protocol guidance) and a faithful runq.c
int8 path: activations quantized per matmul into (int8, scales), int32
accumulation per group scaled by `s_w * s_x`. One deliberate divergence:
the token-embedding row is dequantized on the fly per token — element-for-
element the same values as runq.c's predequantized table, without spending
`vocab*dim*4` bytes (36 MB for 15M) of RAM on a copy. An all-zero activation
group writes q=0, s=0 (same zero contribution as C, without its NaN-cast UB).

**TDD.** `tests/llm_q8_engine_test.swift` (host, `-O`, in `make test`) pins
both quantized checkpoints to upstream runq.c goldens byte-for-byte
(temperature 0, "Once upon a time", 64 steps) — including the 32000-vocab
tokenizer path. Both matched on the first run; the hand-rolled
expf/sinf/cosf/sqrtf survive the bigger model.

**Serving.** `/bin/llmd` now picks the engine by checkpoint magic and defaults
to `/models/stories15M-q8.bin` + `/models/tokenizer.bin` (argv can override:
`llmd [model] [tokenizer]`); `/bin/llm` stays on the fp32 260K demo (its test
is unchanged). The base image packs the q8 bundle (base.img 4.6 → 22.4 MB).

**Measured (QEMU TCG, scalar).** fp32 260K console demo: ~492 tok/s. Served
15M-q8 over TCP: ttft=1150 ms on the cold first request (demand-paging all
~17 MB of weights through I2b plus prompt prefill) and ~10 tok/s steady
streaming — a real, visibly coherent TinyStories model served by an isolated
Swift process. `tests/llm_serve_test.sh` asserts the richer 15M reference text
("She loved to play outside in the sunshine", "It was the sun!"), the
quantized-engine marker (`llmd: model int8 Q8_0 GS=32`), and live metrics.

### I5 — verified model bundles with generation fallback (DONE, 2026-06-09)

**Scope.** The model-storage model from ARCHITECTURE.md made executable:
`/models/<name>/<generation>/{manifest.toml, model.bin, tokenizer.bin}` with
integrity verification at load and the verify-and-roll-back policy. Userland +
host tooling only; no kernel change.

**Pieces.**
- `userland/lib/modelbundle.swift` — I/O-free (host + Embedded, the
  llama2.swift pattern): a small-TOML-subset manifest parser (`key = value`,
  `[table]`, `#` comments; unknown keys/tables tolerated for forward
  compatibility — a `[signature]` table slot is reserved for when an Ed25519
  primitive exists), payload verification (size first, then SHA-256 via
  kernel/crypto/sha256.swift), and the newest-first generation policy.
  `tests/llm_bundle_test.swift` (host, in `make test`) covers parse, corrupt
  and size-mismatch rejection, case-insensitive hex, and ordering.
- `tools/modelmanifest.swift` — host generator: hashes the payloads and emits
  the manifest; `make base-image` stages generation 1 (the real q8 bundle) and
  a DELIBERATELY corrupt generation 2 (gen-1 manifest hashes over a truncated
  model.bin), so every boot demonstrates the fallback.
- `/bin/llmd` resolves the bundle by default: scan `/models/stories15M` via
  getdents for numeric generations, try newest first — parse manifest, mmap
  payloads, verify; a bad generation logs
  `llmd: generation 2 rejected (model size/sha256 mismatch)` and the loop
  falls back, then logs `llmd: bundle stories15M generation 1 verified
  (sha256)`. argv still overrides with raw paths (no verification) for
  debugging. A rejected generation's partial mapping stays mapped until exit
  (lazy-VMA munmap remains a recorded follow-up; verify-model-first ordering
  bounds the cost to one VMA slot per bad generation).

**Measured effect.** Verifying the mmap'd weights hashes every byte, which
demand-pages the whole model in at startup: first-request ttft dropped from
1150 ms (I4, cold fault-in) to **90 ms** — verified means resident. Steady
rate unchanged (~10 tok/s, QEMU TCG). `tests/llm_serve_test.sh` asserts the
rejection + verification markers plus the I4 checks.

**Still future.** Real signatures (needs Ed25519), staging new generations at
runtime (needs a writable model store — tmpfs or the persistent update store)
and hot reload/drain, per-cell model servers (C6).

### I6 — munmap drops file-VMA (demand-paging correctness) (DONE, 2026-06-09)

**Bug.** `processMunmap` reclaims the mmap cursor when the bottom region is
freed, so the next mmap reuses the same VA range — but a lazily-reserved file
VMA (I2b) survived munmap. A new `mmap_file` landing on the recycled VA would
demand-fill its pages from the OLD file's disk extent (the stale VMA matches
first), and repeated `mmap_file`+`munmap` cycles leaked VMA slots until the
8-slot table was exhausted (relevant to llmd-style reload loops; I5's bundle
fallback already consumes a slot per rejected generation).

**Fix.** `processMunmap` deactivates any file VMA overlapping the unmapped
range. A partial munmap drops demand paging for the whole VMA (materialized
pages stay mapped; untouched pages become fatal on access) — acceptable for the
map-whole/unmap-whole pattern and documented at the code site until a VMA split
is warranted.

**Regression.** `/bin/mmapdemo` gains an I6 section: `/etc/motd` via
`mmap_file` must match `read()`; after munmap, `/etc/hostname` mapped into the
recycled VA must show hostname bytes (`I6-OK file munmap drops stale VMA`);
then 12 map/unmap cycles prove slot recycling past the 8-slot table
(`I6-OK file vma slots recycled`). `tests/mmap_test.sh` asserts both markers;
`llm_run_test` and `llm_serve_test` re-validated on the patched kernel.

### I7 — Ed25519; signed model-bundle manifests (DONE, 2026-06-09)

**Primitive.** `kernel/crypto/ed25519.swift` — RFC 8032 Ed25519 in pure,
Embedded-compatible Swift, self-contained like the other crypto files: field
arithmetic mod 2^255−19 on sixteen 16-bit limbs (the compact TweetNaCl shape,
rewritten in Swift), edwards25519 in extended coordinates, a constant-time
conditional-swap ladder, scalar reduction mod the group order. SHA-512 (RFC
8032's hash) added as `kernel/crypto/sha512.swift`. **Every constant was
generated by exact integer arithmetic** (SHA-512 K/H from prime roots; d,
base point, sqrt(−1), L from first principles) rather than transcribed — a
from-memory sqrt(−1) would in fact have been the wrong root. Test vectors were
fetched from rfc-editor.org, not recalled.

**TDD.** `tests/ed25519_test.swift` (host, `make test`): FIPS 180-4 SHA-512
vectors (python3-hashlib cross-checked), RFC 8032 §7.1 TEST 1/2/3/SHA(abc) —
public-key derivation and deterministic signatures byte-for-byte, verification,
tampered-R/tampered-S/tampered-message/cross-key rejection. All green on the
first run after one carry-propagation fix.

**Signed bundles.** The signature covers every manifest byte before the
`[signature]` table (appended last by the signer; `modelManifestSignedRange`
in modelbundle.swift is shared by the host tool and the target verifier).
`tools/modelsign.swift` (host): `keygen` / `sign` (strip + re-sign, idempotent)
/ `verify`. `make base-image` generates a dev keypair under `models/`
(gitignored), signs BOTH generation manifests — gen 2's signature is valid;
its payload hash is what fails, proving the layers act independently — and
ships the public key as the trust root at `/etc/swos/model-signing.pub`.

**Policy.** `/bin/llmd` loads the trust root at startup; when present,
manifests MUST carry a valid signature (`generation N rejected (bad manifest
signature)` otherwise) and the accepted generation logs
`verified (ed25519+sha256)`; without a trust root it stays in integrity-only
mode. The manifest deliberately does not carry the key. `llm_serve_test.sh`
asserts the trust-root marker and the dual-layer verification line.

**Still future.** Key rotation / multiple trust roots, signing the base image
itself (the A/B story), and revocation.

### I8 — signed base image (kernel is the root of trust) (DONE, 2026-06-09)

**Scope.** The packed base image is now signed, and the kernel refuses to mount
an unsigned or tampered one — the foundation of the A/B-image story. The kernel
itself is the trust anchor (loaded via `-kernel` or embedded in the EFI loader),
so a single compiled-in public key roots the whole userland.

**Format (SWOSBASE v3).** `tools/packfs.swift` gained a signed layout: 72-byte
entries (the v2 fields + a 32-byte per-file content SHA-256; directories carry
zeros) and a 64-byte Ed25519 signature over header|entries|strings sitting
between the string table and the payload. `tools/basepack.swift`, given the
image-signing seed, hashes each file and signs the metadata (closures keep
`packfs.swift` crypto-free; swpkg payloads stay v2). The Makefile mints a
dedicated IMAGE-signing keypair (distinct lifecycle from the model key) under
`models/` and embeds its public half via `kernel/security/trust_root.S`
(`.incbin build/image_trust_root.bin`).

**Kernel-grade crypto.** `kernel/crypto/{ed25519,sha512}.swift` were rewritten
onto `InlineArray` (stack storage, the percpu.swift idiom) and stack temporary
allocations, so verification does no heap allocation beyond one message buffer —
safe on the 256 KiB bump heap at boot. Added a streaming `Sha256Stream` (also
InlineArray) so file content is hashed in 4 KiB chunks off virtio-blk with
bounded memory regardless of file size; the host test pins it to the one-shot
across tail/block-spanning sizes. ed25519/sha256/sha512 are now compiled into
the kernel image.

**Two-layer verification.** At mount, `buildBaseFromDisk` reads
header|entries|strings + the detached signature and `ed25519Verify`s against
`image_trust_root` BEFORE building a single vnode (`base image signature
verified (ed25519)` on success; refuses the disk base otherwise). Then content
is verified lazily, once per file on first use: `vfsOpen`, `vfsDiskImageExtent`
(exec), and `vfsFileExtent` (mmap) all call `vfsVerifyNodeContent`, which
streams the extent and compares to the signed per-entry hash, caching the
result in the vnode. Fail-closed per file (a bad file returns EACCES; the OS
keeps running), not per boot.

**Acceptance.** `tests/signed_image_test.sh` (in `make test`): Case A flips a
byte in the signed metadata → mount refused (`signature INVALID`, no
`mounted from disk`); Case B flips a file payload byte → image mounts (metadata
intact) but `cat /etc/motd` trips `content hash mismatch` while the shell
survives. `base_image_test.swift` upgraded to v3 and re-hashes every entry;
`boot_test` asserts the mount-time signature marker. Verification cost is
negligible at boot (signature over ~5 KiB metadata; content hashed on first use).

**Still future.** Key rotation / multiple trust roots; signing the kernel image
itself + an A/B boot manifest with rollback (loader/update-store territory);
revocation.

## A/B signed system updates (U-series)

Extends the trust chain (I5–I8: signed model bundles → signed base image, kernel
as root of trust) toward ARCHITECTURE.md §"Persistent update store" + the
"A/B image discipline" design value: two image slots + an atomic boot manifest,
verified slot selection, rollback to the known-good slot. (The roadmap sequences
A/B late in Phase 1; brought forward here as the trust-chain capstone — the
Ed25519 primitive is ready. Storage-medium + scope forks confirmed with the
maintainer: a dedicated writable virtio-blk disk, read-side first.)

### U1a — A/B update store: verified slot selection + fallback (DONE, 2026-06-10)

**Scope (read side of A/B).** Select + verify + fall back. A persistent writable
virtio-blk "update store" disk carries a `SWOSBOOT` boot manifest + two slots,
each a full signed `SWOSBASE`-v3 base image. The kernel reads the manifest, picks
the active slot, mounts+verifies it via the unchanged I8 path, and rolls back to
the known-good fallback slot if the active image fails verification. Boot-state
write-back (attempt counter, health confirm, attempt-based rollback persisted
across reboots) is U1b; kernel-image A/B via the loader is U1c.

**Format (`SWOSBOOT` v1).** `kernel/fs/swosboot.swift` — an I/O-free, no-mutable-
global manifest core (parser + CRC32) shared by the kernel (Embedded), the host
builder, and the host test, like the crypto. One 512-byte sector, two copies
(LBA 0/1, double-buffered for U1b's torn-write-safe rewrite; reader picks the
valid copy with the highest sequence). Header {magic, version, slot_count=2,
active_slot, fallback_slot, sequence} + a 2-entry slot table {present, state,
base_lba, length_sectors, generation, attempt_count} + trailing CRC32 over
[0,508). Layout: manifest @ LBA 0–7, slot 0 image @ LBA 8, slot 1 after. CRC32 is
IEEE reflected (poly 0xEDB88320); the canonical check value crc32("123456789")
== 0xCBF43926 is pinned by the host test. Format documented in docs/UPDATE_STORE.md.

**Trust boundary (deliberate).** The manifest is CRC32-protected, NOT signed: the
kernel holds only the *public* image key and so cannot sign the boot-state it
writes at runtime (U1b). Sound because the manifest is not a trust anchor — it
only *selects among* self-authenticating signed images. A store-disk attacker can
at worst point "active" at the other (still-signed) slot or induce a boot loop:
availability/DoS, never a code-integrity bypass (a forged image still fails
Ed25519 at mount). Same posture the base-image disk already has.

**Kernel.** `virtio_blk.swift` gains a slot-relative read — `blkBaseByteOffset`
added to every `virtioBlkReadRange`, so the unchanged VFS mount/verify/exec/mmap
paths read the active slot transparently (a single choke point); the legacy
single-image disk keeps offset 0. `blkFallbackByteOffset` holds the known-good
slot, consumed once by `virtioBlkUseFallbackBase()`. `virtioBlkInit` now prefers
a SWOSBOOT store disk > a SWOSBASE base disk > the first device.
`kernel/fs/updatestore.swift` `updateStoreInit()` (called at the top of
`vfsInit`) reads both manifest copies, picks the active slot, sets the offsets,
logs the selection. `vfsInit` mounts the active slot via `buildBaseFromDisk`
(the I8 path); if it rejects the slot (bad signature/content), it calls
`virtioBlkUseFallbackBase()` and remounts the known-good slot. No virtio-blk
*write* yet (U1a is read-only; the disk is writable for U1b). Two new globals
(`blkBaseByteOffset`, `blkFallbackByteOffset`) added to docs/SMP_STATE_AUDIT.md —
set once at boot before EL0.

**Host + test.** `tools/updatestore.swift` builds the store (places two slot
images, writes the CRC'd manifest, self-parses to verify). `tests/
updatestore_test.swift` (host, in `make test`) pins the CRC32 check value +
round-trip + corruption rejection. `tests/ab_update_test.sh` (in `make test`):
Case A (active=A) → "active slot A", mounted, exec from slot; Case B (active=B, a
*different* LBA) → "active slot B", mounted, exec — proves manifest-driven
selection, not "always slot 0"; Case FB (active=B with tampered slot-B metadata)
→ slot B rejected ("base image signature INVALID"), "rolling back to fallback
slot", slot A mounted and serves /etc/motd to a working shell — verified fallback
over a persistent disk.

**Gotcha caught.** The interactive M7 tty demo gates the boot before login, so an
A/B-selection assertion must await a pre-login marker (mount markers / the tty
prompt), not "swift-os login:", unless it drives the tty. And `await` is a literal
substring match — the rollback marker is "...failed verification — rolling back to
fallback slot", so the awaited substring must not include a non-contiguous prefix.

**Still future (U1b+).** virtio-blk write; boot-attempt counter + health-confirm
(capability-gated /bin/swos-confirm + syscall) + attempt-based rollback persisted
across reboots; staging a new generation into the inactive slot + atomic active
flip; kernel-image A/B via the loader (Ed25519 + EFI Block I/O); key rotation.

### U1b — persistent boot-state: manifest write-back + boot-attempt counter (DONE, 2026-06-10)

**Scope.** The writable half U1a lacked: the virtio-blk *write* path + durable,
atomic write-back of the SWOSBOOT manifest, used here to persist a per-slot
boot-attempt counter across reboots. (The attempt-based rollback policy +
health-confirm that *consume* this counter are U1c.)

- `kernel/drivers/virtio_blk.swift`: `blkDoWrite` (VIRTIO_BLK_T_OUT; the data
  descriptor is device-READABLE — the device reads our bytes) + a one-sector
  `virtioBlkWriteSector(sector, buf)`. **Absolute** sectors, NOT slot-relative:
  the manifest at LBA 0/1 lives outside the A/B image slots, so writes skip
  `blkBaseByteOffset`.
- `kernel/fs/swosboot.swift`: `serializeSwosbootManifest` — the exact inverse of
  the parser; the host test pins parse(serialize(m)) == m.
- `kernel/fs/updatestore.swift`: after selecting the active slot, `updateStoreInit`
  increments that slot's attempt_count, bumps `sequence`, and writes the manifest
  to the OTHER double-buffer copy (torn-write safe — the reader picks the highest
  valid sequence, so an interrupted write leaves the prior copy intact). A
  CONFIRMED slot is skipped (forward-compat no-op until U1c sets that state).
  Marker: "update-store: recorded boot attempt N for active slot X".
- No new top-level globals (the driver gained funcs + one `let`); SMP audit
  unchanged at 173 entries.

**Durability.** A virtio-blk write completes when the device acks (polled used
ring). The acceptance test attaches the store with `cache=writethrough` so each
completed write is durable to the backing file even across an ungraceful kill.
(A virtio-blk FLUSH for durability without writethrough is future hardening.)

**Acceptance.** `tests/ab_persist_test.sh` (in `make test`): boots the SAME
writable store disk 3× and asserts the attempt counter increments 1→2→3 across
reboots — proving write + atomic double-buffered write-back + reboot persistence.
`tests/updatestore_test.swift` gains the serialize↔parse round-trip; U1a's
`ab_update_test.sh` still passes (write-back does not disturb selection/fallback).

**Still future (U1c).** Attempt-based rollback (switch active↔fallback when an
unconfirmed slot exceeds a max-attempts threshold) + health-confirm (a
capability-gated /bin/swos-confirm + syscall that marks the active slot CONFIRMED
and resets attempts). Then U1d = kernel-image A/B via the loader.

### U1c — health-confirm: /bin/swos-confirm pins a slot CONFIRMED (DONE, 2026-06-10)

**Scope.** The "confirm" half of the boot-state machine: an operator marks a
freshly-activated slot healthy so it stops accruing boot attempts (and, once U1d
lands, is never rolled back). Attempt-based rollback that consumes the counter is
U1d.

- New syscall `SYS_UPDATE_CONFIRM` (65), **capConsole-gated**, dispatched to
  `updateStoreConfirm()` (`kernel/fs/updatestore.swift`): re-reads the manifest,
  marks the slot booted this session (tracked in the new `updateStoreActiveSlot`
  global) CONFIRMED + resets its attempt_count, persists via the U1b
  double-buffered write-back. Bridge: `syscall.h` `update_confirm()` +
  `swiftos_update_confirm()`.
- `/bin/swos-confirm` (`userland/swos-confirm.swift`): calls it and prints the
  result; registered in `execResolve` + staged in the base image. capConsole
  means root can run it; a guest is refused (EPERM).
- `updateStoreInit` refactored onto shared helpers (`updateStoreReadChosen` /
  `updateStoreWriteBack`), now shared with the confirm path; the selection log
  shows the slot state (untried/confirmed/failed). One new global
  `updateStoreActiveSlot` (SMP audit → 174).

**Acceptance.** `tests/ab_confirm_test.sh` (in `make test`): boot 1 drives to a
root shell and runs `/bin/swos-confirm` → "active slot confirmed healthy" + kernel
"slot A confirmed healthy"; boot 2 (same writable store) → the kernel sees
"active slot A gen 1 confirmed" and records NO new boot attempt. U1a/U1b A/B
tests + the legacy disk path are unaffected.

**Still future (U1d).** Attempt-based rollback (switch active↔fallback past a
max-attempts threshold; mark the exhausted slot FAILED) + stage-into-inactive-slot
+ atomic active flip; then kernel-image A/B via the loader (Ed25519 + EFI Block I/O).

### U1d — attempt-based rollback: unconfirmed slot fails over (DONE, 2026-06-10)

**Scope.** Closes the "rollback on failed health check" loop. The counter (U1b)
+ confirm (U1c) infrastructure is now driven by a policy: an active slot that is
not CONFIRMED and has reached `maxBootAttempts` (=3) boot attempts is presumed
unhealthy (it booted but the operator never ran /bin/swos-confirm). The kernel
marks it FAILED, swaps active↔fallback in the manifest, and boots the known-good
fallback — all persisted via the U1b double-buffered write-back.

- `kernel/fs/updatestore.swift`: `updateStoreInit` gains the rollback decision
  before it commits to a slot — `maxBootAttempts` (a `let`, no new global). The
  write-back now persists both the rollback swap and the (new) active slot's
  attempt increment in one update. This is the "boots-but-never-confirmed" path;
  the BAD-IMAGE path (Ed25519/content verification failure) stays in vfsInit
  (U1a, immediate verified fallback at mount). Markers: "active slot X exhausted
  N attempts — rolling back to slot Y".
- A CONFIRMED slot (U1c) is exempt — never counted, never rolled back. A FAILED
  slot is still a valid rollback *target* (if both slots are unconfirmable the
  system fails over back and forth until an operator confirms a good one — honest
  behavior; an availability concern, documented).

**Acceptance.** `tests/ab_rollback_test.sh` (in `make test`): boots the SAME
store (active=A, both valid, neither confirmed) 4×; slot A records attempts
1/2/3, then boot 4 exhausts them and rolls over to slot B (which records its own
first attempt) — persisted across the reboots. U1a–U1c A/B tests + the legacy
disk path are unaffected.

**A/B story complete (read + write + confirm + rollback).** Remaining is forward
build-out: stage-into-inactive-slot + atomic active flip from a running system,
and kernel-image A/B via the loader (Ed25519 + EFI Block I/O); hardening:
virtio-blk FLUSH (durability without cache=writethrough).

### U1e — promote the inactive slot: /bin/swos-activate (DONE, 2026-06-10)

**Scope.** The operator "promote" control — switch which slot boots next, from a
running system. This is the activation/atomic-flip half of staging; writing a NEW
image into the inactive slot (the data half) is a separate piece with a genuine
fork (image source + multi-device virtio-blk), surfaced before it is built.

- New syscall `SYS_UPDATE_ACTIVATE` (66), capConsole-gated -> `updateStoreActivateOther()`
  (`kernel/fs/updatestore.swift`): makes the inactive slot (1 − booted slot) the
  active slot, the current slot the fallback, marks the new active UNTRIED +
  attempts=0 (boots "on trial"), and persists via the U1b double-buffered
  write-back. Reuses `updateStoreReadChosen`/`updateStoreWriteBack`. Bridge:
  `syscall.h` `update_activate()` + `swiftos_update_activate()`.
- `/bin/swos-activate` (`userland/swos-activate.swift`): calls it, prints the
  result; registered in execResolve + staged in the base image. root only
  (capConsole); guest EPERM.
- No new globals (reuses `updateStoreActiveSlot`); SMP audit unchanged (174).

**Operator workflow now complete for slots that already hold images:** activate
the inactive slot → reboot → it boots on trial → `/bin/swos-confirm` if healthy
(U1c), else attempt-based rollback returns to the fallback (U1d).

**Acceptance.** `tests/ab_activate_test.sh` (in `make test`): boot slot A, run
`/bin/swos-activate` from a shell → "activated slot B (on trial)"; reboot → slot
B is active, UNTRIED, records its first attempt. U1a–U1d + the legacy disk path
are unaffected.

**Still future.** Writing a new image into the inactive slot from a running
system (target-side `swos-update`) needs an image-source decision (read-only
payload disk vs network vs tmpfs) + multi-device virtio-blk; then kernel-image
A/B via the loader.

### Fix — `vfs_disk_test.sh` red since I8 (signed base + sparse-disk S2b guard) (DONE, 2026-06-10)

`tests/vfs_disk_test.sh` had been failing since the I8 commit ("signed base
image"): I8 updated `signed_image_test.sh` / `base_image_test.swift` but not
this one. Two layered causes, two layered fixes — both confined to the test
fixture; no kernel, guard, or boot-path change.

**1. Unsigned image refused at mount.** The test packed its throwaway disk with
`basepack <root> <img>` (legacy v2, unsigned). Since I8 the kernel embeds an
image-signing trust root and `buildBaseFromDisk` refuses anything but signed v3
("unsigned base image refused — signed v3 required"), so it fell back to the
compiled-in literals (no real busybox) and the shell never started. Fix: sign
the disk with the same dev image key `make base-image` mints —
`SEED="$ROOT/models/dev-image-signing.seed"`, require it, pass it as basepack's
4th arg. Also fixed the stale standalone-build fallback (line ~20): basepack now
needs `tools/packfs.swift` + the crypto sources, mirroring the Makefile
`$(BASEPACK)` rule.

**2. S2b guard panic on the sparse no-console-login disk.** Past the mount, the
boot hit `panic: S2b secondary EL0 execution guard failed`. The cause is *not*
an SMP bug: this sparse disk carries only busybox (no console-login/ttydemo), so
init runs the milestone EL0 demos straight through, and the post-userland S2b
guard (`smpS2bNoSecondaryEl0Execution`) requires CPU0 to have actually
dispatched an EL0 process — `smpPerCpuEl0SwitchCount(primary) != 0`. With every
demo binary missing from the disk ("demo: missing on disk /bin/…"), CPU0 ran
zero EL0 work and the guard tripped. The full-base boot paths (boot_test,
signed_image_test, ab_update_test) carry the demo binaries and pass. This
matches how the same guard's owner resolved it on the parallel SMP line (seed a
demo binary into the sparse disk). Fix: seed `/bin/ps`, the last demo before the
guard, so `runPsDemo` supplies the EL0 switch. The guard is correct as designed.

**Verification.** `./tests/vfs_disk_test.sh` green (3/3 stable). No SMP
regression: `./tests/boot_test.sh` and `SMP_CPUS=4 ./tests/smp_boot_test.sh`
both green (the latter logs "S2b OK: no secondary EL0 execution" at -smp 4).

**Repo note.** Applied on a branch off `origin/main` (`a6391b1`), where the bug
lives. The local `main` line had diverged (~100 commits of SMP S2c–S2h + package
work) and never received I8 signing, so the test already passed there — the fix
belongs on the I8 line.

### U1f-1 — secondary read-only virtio-blk device (the A/B update payload) (DONE, 2026-06-10)

**Scope.** The multi-device foundation for staging a new image from a running
system. The virtio-blk driver was single-device; U1f-1 lets it also see and read
a second disk — the update *payload* (a signed SWOSBASE image) attached
alongside the SWOSBOOT store. U1f-2 will copy that payload into the inactive slot.

- `kernel/drivers/virtio_blk.swift`: `virtioBlkInit` now scans ALL block devices
  and classifies each by sector-0 magic (store=SWOSBOOT, base/payload=SWOSBASE)
  instead of returning on the first store. When a store is selected, a separate
  SWOSBASE disk is recorded as the payload (`blkPayloadDevice`; `blkStoreDevice`
  keeps the store index so we can return to it). Accessors
  `virtioBlkHasPayload()`, `virtioBlkSelectPayload()` (selects the payload and
  returns its capacity), `virtioBlkReselectStore()`. The hardware path is reused
  by selecting between the two disks — fine since I/O is serial on the one CPU.
  Two new globals in `docs/SMP_STATE_AUDIT.md` (set once at boot).
- `kernel/fs/updatestore.swift`: `updateStorePayloadProbe()` (called from vfsInit
  after updateStoreInit) reads the payload's sector-0 header through the secondary
  path and verifies it is a signed v3 SWOSBASE image, logging "update-store:
  update payload disk present, N sectors, signed v3 base image", then re-selects
  the store so the base mounts from it.

**Acceptance.** `tests/ab_payload_test.sh` (in `make test`): boot with the store
disk + base.img attached as a read-only payload; assert the payload is discovered
and read, AND the active slot still mounts from the store (the probe's device
re-selection does not disturb the base mount). U1a–U1e A/B tests + the legacy
disk path unaffected.

**Still future (U1f-2).** The stage copy: `/bin/swos-update` reads the payload
disk and writes it into the inactive slot, then the operator runs swos-activate
+ reboots. Needs a chunked copy loop (read payload → write store slot) and, for
acceptable speed on a multi-MB image under TCG, likely multi-sector virtio
requests (the driver does one sector per request today).

**Test-harness follow-up.** The interactive `to_shell` serial drive (M7 tty +
login) intermittently drops a typed line on the emulated PL011 (~10-15%), seen
across all to_shell tests (ab_update_test, ab_confirm_test, signed_image_test).
ab_activate_test (U1e) fixed it with a settle + byte-by-byte `send`; the other
A/B tests still use whole-line `printf` and should be migrated to that pattern.

### U1f-2a — multi-sector virtio-blk transfers (DONE, 2026-06-10)

**Scope.** The driver moved one 512-byte sector per virtio request, which makes
the U1f-2 stage copy of a multi-MB image untenably slow under TCG (thousands of
round trips). U1f-2a adds a variable-length data descriptor: one request now
transfers up to `BLK_MULTI_SECTORS` (128 = 64 KiB) consecutive sectors.

- `kernel/drivers/virtio_blk.swift`: a contiguous `BLK_MULTI_PAGES`-page DMA
  region (`blkMultiBase`, `pmm_alloc_pages`, allocated once like the ring/data
  pages — one new global in `docs/SMP_STATE_AUDIT.md`). `blkDoMulti(sector,
  count, write:)` drives a header→data→status chain where the single data
  descriptor is `count*512` bytes (device-writable for T_IN, device-readable for
  T_OUT). Public API: `virtioBlkReadSectors` / `virtioBlkWriteSectors` (copy in/
  out of a caller buffer) and the no-copy `virtioBlkFillMulti` /
  `virtioBlkFlushMulti` / `virtioBlkMultiMax` for U1f-2b's disk-to-disk stage copy
  (blkMultiBase survives a bring-up, so read-from-payload then write-to-store
  needs no intermediate kernel buffer). `virtioBlkReadRange` — which backs EVERY
  base-image read (mount, signature/content verify, ELF load, file-backed mmap) —
  now pulls whole sector runs per request, capped to the DMA region and capacity.
  The single-sector `blkDoRead`/`blkDoWrite` (sector-0 classification, manifest
  LBA 0/1 write-back) are unchanged.

**Acceptance.** `tests/multisector_test.sh` (in `make test`): the multi-sector
read path is verified end-to-end by the base image's own cryptography — a single
misread byte fails one of three checks across chunk sizes: the signed Ed25519
metadata region, a small payload file (/etc/motd), and busybox.elf (~1.1 MB ≈ 18
of the 64 KiB chunks, loaded by execResolve in one `virtioBlkReadRange` — the ash
shell only launches if that large multi-chunk read is byte-exact). boot_test +
signed_image + the U1a–U1f-1 A/B suite unaffected (all base reads now flow
through the multi-sector path).

### U1f-2b — the A/B stage copy: /bin/swos-update (DONE, 2026-06-10)

**Scope.** Close the staging loop: copy the attached read-only payload disk
(U1f-1) into the inactive A/B slot from a running system, so an operator can then
swos-activate + reboot onto the new image.

- `kernel/fs/updatestore.swift`: `updateStoreStagePayload()` (syscall 67
  `SYS_UPDATE_STAGE`, capConsole-gated). Reads the chosen manifest, picks the
  inactive slot (1−booted), brings up the payload and reads its SWOSBASE header —
  requires a signed v3 image and computes its length (`dataOffset`@48 +
  `payloadLen`@56, rounded up to sectors). Rejects a payload that is truncated on
  its disk (> payload capacity, EINVAL) or larger than the slot's
  `length_sectors` (EFBIG). Copies payload[0,N) → store[slotBaseLBA,+N) in 64 KiB
  runs via U1f-2a's no-copy `virtioBlkFillMulti`/`FlushMulti` (read into the
  driver's DMA buffer from the payload, re-select the store, flush it out — no
  intermediate kernel buffer; serial on the one CPU). Then marks the slot present
  + UNTRIED, attempts 0, generation++, persisted via the U1b double-buffered
  write-back. Copies BYTES only — the staged image's own Ed25519 signature is
  verified at the NEXT boot's mount (unchanged I8 path), so a corrupt payload
  simply fails on trial and U1a/U1d return to the known-good slot. No new globals.
- `/bin/swos-update` (`userland/swos-update.swift`, bridge `swiftos_update_stage`
  / `update_stage`); registered in execResolve + the Makefile ELF/staging rules.

**Acceptance.** `tests/ab_stage_test.sh` (in `make test`): a store with a valid
active slot A and a deliberately CORRUPT slot B (a same-size copy of base.img with
a signed byte flipped — so it fits the payload exactly but fails verification) +
a valid payload disk. Boot A → shell → swos-update (stage) → swos-activate. Reboot
→ slot B is active AND its image now passes Ed25519 verification and mounts (no
"signature INVALID"): a clean verified mount of the once-corrupt slot proves the
stage copy wrote a valid image. The full operator update workflow is now complete:
swos-update → swos-activate → reboot on trial → swos-confirm (U1c) / rollback (U1d).

**Still future.** Kernel-image A/B via the loader (Ed25519 + EFI Block I/O);
virtio-blk FLUSH (durability without `cache=writethrough`); key rotation. Next
free syscall = 63.

### U1h — virtio-blk FLUSH: durable boot-state writes (DONE, 2026-06-10)

**Scope.** Until now, durability of the manifest/stage writes relied on a host
`cache=writethrough` backend (forced in the A/B tests). U1h negotiates
`VIRTIO_BLK_F_FLUSH` and flushes the device write cache after each commit, so
boot-state survives a crash under a normal write-back cache.

- `kernel/drivers/virtio_blk.swift`: bring-up now reads device-feature word 0
  (`R_DEVFEAT`/`R_DEVFEATSEL` = 0x010/0x014) and accepts `VIRTIO_BLK_F_FLUSH`
  (bit 9) when offered, recording it in `blkFlushOK` (one new SMP-audit global,
  set per bring-up; reflects the currently-bound device). `blkDoFlush()` issues a
  `VIRTIO_BLK_T_FLUSH` (type 4) request — a header(device-read)+status
  (device-write) chain, no data. Public `virtioBlkFlush()` (0 also when the
  device exposes no cache — the write is then already durable) and
  `virtioBlkFlushSupported()`.
- `kernel/fs/updatestore.swift`: `updateStoreWriteBack` flushes after the manifest
  sector write (treating a failed flush as a failed write-back, so a rejected
  FLUSH stalls rather than silently loses state); `updateStoreStagePayload`
  flushes the staged slot data before the manifest is pointed at it (so a crash
  can never leave a committed manifest referencing half-written slot bytes).
  `updateStoreInit` logs the durability mode ("write durability via virtio FLUSH").

**Acceptance.** `tests/ab_flush_test.sh` (in `make test`): boots the SAME store
with the default **write-back** cache (no `cache=writethrough`) and asserts the
FLUSH marker AND that the boot-attempt counter persists 1→2→3 — which also
verifies the flush request succeeds (a rejected FLUSH would fail the write-back
and stall the counter). Caveat: QEMU writes land in the host page cache, which
survives a kill, so this exercises the negotiate+flush+commit path under the
realistic cache mode but cannot simulate host power loss. boot_test, ab_persist
(writethrough path), and the rest of the A/B suite unaffected. No new syscalls.

### U1g-1 — UEFI loader reads the kernel from an ESP file (DONE, 2026-06-10)

**Scope.** First slice of kernel-image A/B (U1g). The loader compiled the kernel
in as an embedded blob (`kernel_blob.S` `.incbin`), which cannot be A/B-staged on
disk. U1g-1 decouples the kernel image from the loader binary: the loader now
reads the kernel from a file on the ESP via `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`.
Mechanism chosen with the maintainer: ESP file (Simple File System), not raw
Block I/O — lowest risk, the ESP is already FAT. Later slices add an A/B manifest
+ second kernel image + Ed25519 verification.

- `boot/efi/efi.h`: added `EFI_LOADED_IMAGE_PROTOCOL` (to reach the boot volume's
  `DeviceHandle`), `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`/`EFI_FILE_PROTOCOL`,
  `EFI_FILE_INFO`, the three GUIDs, and typed `BootServices->HandleProtocol`.
- `boot/efi/loader.c`: `open_esp_kernel()` (HandleProtocol(LoadedImage) →
  HandleProtocol(SimpleFileSystem) on its DeviceHandle → OpenVolume → Open
  `\EFI\swift-os\kernel.bin` → GetInfo for the size) and `read_file_into()` (a
  Read loop, since the File protocol may return short). `efi_main` opens the file
  to learn its size, reserves the right number of pages at `KERNEL_LOAD_ADDR`,
  reads it in, and logs "UEFI: kernel loaded from ESP file N bytes". The embedded
  blob stays as a **fallback** (file absent/unreadable → "using embedded blob"),
  so the boot path is never less robust than before.
- `Makefile` stages `kernel.bin` to `build/esp/EFI/swift-os/kernel.bin`;
  `scripts/make-disk.sh` copies it into the real GPT ESP (`::/EFI/swift-os/`).

**Gotcha caught.** First run fell back to the blob: `GetInfo` needs the full
`EFI_FILE_INFO` (80-byte prefix + the CHAR16 file name), so an 88-byte buffer
returned `EFI_BUFFER_TOO_SMALL` — bumped to 512.

**Acceptance.** `tests/uefi_boot_test.sh` (in `make test`, disk + SMP-4 variants)
now also asserts "UEFI: kernel loaded from ESP file"; the kernel boots all the way
to busybox from the ESP-loaded image (single-core and `-smp 4`). The embedded-blob
fallback keeps the path safe if the file is ever missing.

**Still future (U1g-2/3).** A kernel A/B manifest on the ESP + a second kernel
image + slot selection; then Ed25519 verification of the selected kernel against
the compiled-in trust root.

### U1g-2 — kernel A/B manifest + slot selection on the ESP (DONE, 2026-06-10)

**Scope.** Second slice of kernel-image A/B. The loader now reads a small boot
manifest from the ESP and chooses between two kernel slots, falling back to the
other when the active slot's file is missing/unopenable.

- **SWOSKERN manifest** (`\EFI\swift-os\kernel-boot`, 24 bytes LE): magic
  "SWOSKERN", version=1, active(0/1), fallback(0/1), generation. Host-authored at
  image build for now (no CRC; a CRC + double-buffering, like SWOSBOOT, come once
  the OS writes it at runtime). Two slot images: `kernelA.bin` / `kernelB.bin`.
- `boot/efi/loader.c`: `open_esp_kernel` generalized to `open_esp_file(path,…)`;
  `read_kernel_manifest()` parses+validates the manifest; `efi_main` selects the
  active slot's path, and if it won't open and a distinct fallback exists, rolls
  back to the fallback slot (logs "rolling back to slot X"). Logs the active slot
  ("kernel A/B manifest active slot B gen N") and the slot actually booted
  ("booted kernel slot A/B"). No manifest → defaults to slot A. The embedded blob
  remains the final fallback. The generic "kernel loaded from ESP file N bytes"
  line is kept (so uefi_boot_test still asserts it).
- `tools/kernelboot.swift`: host generator (`kernelboot <out> A|B [gen]`).
- `Makefile`/`scripts/make-disk.sh`: stage `kernelA.bin`, `kernelB.bin`, and an
  active-A `kernel-boot` into both the virtual-FAT ESP and the GPT image.

**Acceptance.** `tests/uefi_kernel_ab_test.sh` (in `make test`) edits ESP copies
of the GPT image with mtools: (1) active=B → loader reports "active slot B" +
"booted kernel slot B" and the kernel boots from slot B; (2) active=B but
`kernelB.bin` deleted → loader rolls back to slot A, "booted kernel slot A", boots.
uefi_boot_test (default active-A manifest) still boots to busybox, single-core and
`-smp 4`.

**Still future (U1g-3).** Ed25519 verification of the selected kernel against the
compiled-in trust root (`kernel/security/trust_root.S`), so a tampered/garbage
slot is rejected at load and triggers fallback — the kernel-image analogue of the
base-image signature check.

### U1g-3a — kernel slot SHA-256 integrity verification (DONE, 2026-06-10)

**Scope.** The loader could select an A/B slot but not tell a corrupt/truncated
kernel from a good one (a bad image just crashed after the jump). U1g-3a adds a
SHA-256 **integrity** check: the manifest carries each slot's hash, the loader
hashes the loaded image and rejects a mismatch, rolling back to the other slot —
the same verify-then-fallback shape as the base-image content check. This is
integrity (catches corruption), NOT yet authenticity; the manifest is still
unsigned, so a tamperer who rewrites the slot can rewrite its hash too. Authenticity
is U1g-3b (Ed25519 over the manifest/kernel).

- `boot/efi/loader_sha256.h`: header-only FIPS 180-4 SHA-256 (the loader has no
  libc/crypto). Host-tested so the exact code is trusted.
- **SWOSKERN manifest v2**: appends `slotA_size`+`slotA_sha256` (off 24/32) and
  `slotB_size`+`slotB_sha256` (off 64/72); 104 bytes. v1 (no hashes) still parses.
- `boot/efi/loader.c`: `load_slot(slot, expect_hash)` opens→allocates→reads→(if a
  hash is given) SHA-256-verifies into `KERNEL_LOAD_ADDR`, freeing its pages and
  returning 0 on any failure (missing file, alloc fail, OR hash mismatch — logs
  "kernel slot X FAILED integrity check (sha256)"). `efi_main` tries the active
  slot, rolls back to the other on failure, then the embedded blob. `FreePages`
  typed in efi.h so a rejected slot's pages are reclaimed before the retry.
- `tools/kernelboot.swift` v2: reads both kernel files, embeds their SHA-256
  (host `kernel/crypto/sha256.swift`); now `@main` (multi-file build disallows
  top-level code). Makefile/make-disk stage the v2 manifest computed over
  `kernel.bin`.

**Acceptance.** `tests/loader_sha256_test.c` (host, in `make test`) checks the C
SHA-256 against FIPS 180-4 vectors. `tests/uefi_kernel_ab_test.sh` gains a third
case: corrupt `kernelA.bin` (byte-flipped, so its hash ≠ the manifest's) with
active=A → loader logs the slot-A integrity failure and boots the valid slot B.
Plus the existing active-B and missing-slot cases. `uefi_boot_test` (default
active-A, now SHA-256-verified) still boots to busybox, single-core and `-smp 4`.

**Gotcha.** `kernelboot.swift` compiled fine standalone but broke once
`sha256.swift` was added to the build ("expressions are not allowed at the top
level") — a multi-file Swift module needs `@main`, not top-level statements.

**Still future (U1g-3b).** Ed25519 signature over the manifest (or the kernel
images) verified against the compiled-in trust root, for authenticity — needs
Ed25519+SHA-512 in the loader (C port of `kernel/crypto/{ed25519,sha512}.swift`).

### U1g-3b — kernel manifest Ed25519 authenticity in the loader (DONE, 2026-06-10)

**Scope.** U1g-3a gave integrity (a corrupt slot is caught) but not authenticity
(the manifest was unsigned, so a tamperer who rewrites a slot can rewrite its
hash). U1g-3b signs the manifest and has the loader verify it against the
compiled-in image-signing key — the kernel-image analogue of I8's signed base
image. This completes the kernel-A/B trust chain: a manifest is honored only with
a valid signature; otherwise the loader boots its own embedded blob (never an
attacker-chosen slot).

- `boot/efi/loader_ed25519.h`: header-only SHA-512 + Ed25519 **verify** (RFC 8032),
  the compact TweetNaCl shape ported from the tested `kernel/crypto/{ed25519,
  sha512}.swift` with curve constants copied verbatim. Host-tested.
- `boot/efi/efi_pubkey.S`: incbins `build/image_trust_root.bin` (the same
  image-signing pubkey the kernel embeds) as `efi_image_signing_pubkey`.
- **SWOSKERN manifest v3**: appends a 64-byte Ed25519 signature over the 104-byte
  body (168 bytes). `read_kernel_manifest` returns "trusted" only for v3 with a
  valid signature; v1/v2 (unsigned) and bad-signature manifests are refused
  ("kernel manifest signature INVALID" / "unsigned … ignoring"). `efi_main` boots
  the embedded blob when there is no trusted manifest. Integrity (U1g-3a) then runs
  within the trusted manifest, so authenticity + integrity are layered.
- `tools/kernelboot.swift` v3: signs the body with the image-signing seed
  (host `ed25519Sign`). Makefile passes `$(IMG_SIGNING_SEED)`; the loader links
  `efi_pubkey.obj`.

**Acceptance.** `tests/loader_ed25519_test.c` (host, in `make test`) checks the C
verify against RFC 8032 §7.1 vectors and that it rejects a tampered sig/message.
`tests/uefi_kernel_ab_test.sh` gains a fourth case: a byte flipped in the
manifest's signature → loader logs "signature INVALID" and boots the embedded
blob. The active-B, missing-slot, and SHA-256-mismatch cases now run against
signed v3 manifests. `uefi_boot_test` (default disk, signed v3) verifies the
signature and boots slot A to busybox, single-core and `-smp 4` — an end-to-end
check that the loader's embedded pubkey matches the signing key.

**Note.** Verify-only in the loader; signing stays host-side (Swift). The manifest
is still single-copy/no-CRC — runtime writes (CRC + double-buffering) come when
the OS can flip the kernel slot. The kernel-image A/B trust chain (sign → verify →
integrity → fallback) is now complete.

### U1g-4a — kernel reaches + parses the ESP (GPT) boot disk (DONE, 2026-06-10)

**Scope.** First slice of *runtime* kernel staging (the kernel analogue of U1f's
stage/activate). For the OS to stage a new kernel it must reach the ESP the loader
boots from. Two findings shaped this:
1. **Transport.** The ESP/GPT disk was attached `if=virtio` = virtio-**PCI** on
   `-M virt`; the kernel drives only virtio-**mmio**, so it never saw the ESP.
   Verified AAVMF boots fine from a virtio-mmio disk, so the boot configs now
   attach the ESP disk on mmio (`if=none,id=esp` + `-device virtio-blk-device`) —
   both firmware and kernel can drive it.
2. **Trust model (decided).** Runtime staging will follow U1f's *courier* model:
   the OS writes pre-signed-offline artifacts (kernel image + signed manifest); it
   never signs. (The signed-manifest-vs-writable-selection split is a later slice.)

- `kernel/drivers/virtio_blk.swift`: the device scan now also recognizes a GPT
  disk by the "EFI PART" magic at LBA 1 (`blkBounceIsEfiPart`), recording it as
  `blkEspDevice`; `blkServedDevice` tracks the base/store device. Accessors
  `virtioBlkHasEsp()`, `virtioBlkSelectEsp()` (selects ESP, returns capacity),
  `virtioBlkReselectServed()`. Two new SMP-audit globals.
- `kernel/fs/esp.swift`: `espProbe()` (called after `vfsInit`) selects the ESP
  disk, parses the GPT header (LBA 1) + partition array, finds the ESP-type-GUID
  partition, logs "kernel-store: ESP partition found at LBA N, M sectors", then
  re-selects the served disk. Read-only; no mutable globals.
- Boot configs (Makefile UEFI flags, disk-run, run-gfx; uefi tests) moved the ESP
  disk to virtio-mmio.

**Acceptance.** `tests/uefi_boot_test.sh` (disk + SMP-4) now asserts the kernel
locates the ESP partition, and still boots to busybox. `uefi_kernel_ab_test.sh`
(4 cases) unchanged in behavior with the ESP on mmio.

**Then (U1g-4b/c/d + U1g-5).** FAT32 read/write, activation, and the
signed-manifest/writable-boot-state split landed in later U1g slices.

### U1g-4b — kernel FAT32 reader: read the kernel A/B manifest from the ESP (DONE, 2026-06-10)

**Scope.** With the ESP reachable (U1g-4a), the kernel now reads the loader's
kernel A/B manifest off the FAT32 ESP — the read half of runtime staging, and the
groundwork for the FAT32 writer (U1g-4c).

- `kernel/fs/esp.swift`: a minimal read-only FAT32 in `Fat32Vol` + helpers —
  `fatReadBPB` (BPB at the partition's first sector: bytes/sec must be 512,
  sec/clus, reserved, #FATs, FATSz32, rootClus → firstDataSector), `fatClusterLBA`,
  `fatNext` (FAT32 chain lookup), and `fatFindChild` (directory walk matching a
  path component against the assembled **LFN** long name OR the reconstructed 8.3
  short name, case-insensitively — so it finds "EFI" (8.3), "swift-os" (lowercase
  8.3), and "kernel-boot" (LFN, short name "KERNEL~1") robustly).
  `fatReadKernelManifest` walks `\EFI\swift-os\kernel-boot`, reads the manifest's
  first sector, validates "SWOSKERN", and returns the active slot + generation.
  `espProbe` now logs "kernel-store: ESP kernel A/B active slot A gen N (read from
  FAT32)". All InlineArray/stack scratch — no heap on the boot path.

**Acceptance.** `tests/uefi_boot_test.sh` (disk + SMP-4) now also asserts the
kernel reads the manifest from FAT32 and reports active slot A — so the BPB,
cluster chain, LFN directory walk, and manifest parse are all exercised end-to-end
(the value must match what the loader independently read and booted). The 4-case
`uefi_kernel_ab_test` is unaffected (the kernel read is log-only).

**Then (U1g-4c/d + U1g-5).** FAT32 write, activation, attempts, rollback, health
confirmation, and mutable boot-state active selection landed in later U1g slices.

### U1g-4c — kernel FAT32 writer: stage the inactive slot image (DONE, 2026-06-10)

**Scope.** The write half of runtime kernel staging: the kernel writes the
inactive kernel slot on the FAT32 ESP. Kept deliberately safe — an **in-place**
copy of the active slot's image into the inactive slot (the two files are the same
size, so only data sectors are overwritten; no cluster allocation, FAT, or
directory changes). A buggy write can only spoil the *inactive* slot, which the
loader's SHA-256 check (U1g-3a) then rejects, falling back to the still-good
active slot — so the bootable slot is never at risk.

- `kernel/fs/esp.swift`: `fatCopyChain` walks the src (active) and dst (inactive)
  cluster chains in lockstep, copying sector-by-sector
  (`virtioBlkRead`→`virtioBlkWriteSector`), then `virtioBlkFlush`; `fatVerifyChain`
  re-reads both chains and confirms every sector matches (so a no-op write fails
  the verify). `espStageActiveToInactive()` (capConsole) finds kernelA/B.bin +
  reads the manifest's active slot, requires equal sizes, copies active→inactive,
  flushes, verifies. Logs "kernel-store: staged active slot image into inactive
  slot, verified (FAT32)".
- Syscall 68 `SYS_KERNEL_STAGE`; `/bin/swos-kstage` (`userland/swos-kstage.swift`,
  bridge `swiftos_kernel_stage`/`kernel_stage`); registered in execResolve + the
  Makefile ELF/staging rules.

**Acceptance.** `tests/uefi_kstage_test.sh` (in `make test`): a disk copy whose
inactive slot B is a byte-flipped (same-size) copy of the kernel; boot under AAVMF
(ESP on mmio), reach a root shell, run `/bin/swos-kstage`. The kernel copies
slot A over slot B and verifies — which only passes if the write landed (a no-op
would leave B corrupt and fail the in-kernel verify). Proves the FAT32 write path
end-to-end without touching the bootable slot or the manifest.

**Then (U1g-4d/U1g-5).** The first activate path used a pre-signed courier
manifest; U1g-5 later moved attempts, health confirmation, and mutable active
selection into `kernel-state`.

### U1g-4d — runtime kernel-slot activate: /bin/swos-kactivate (DONE, 2026-06-10)

**Scope.** The capstone of runtime kernel staging: flip the active kernel slot
from a running system, persisted, so the loader boots the newly-activated slot.
Because the OS cannot sign, it follows the **courier** model — it installs an
offline-signed alternate manifest rather than producing one.

- A second manifest `\EFI\swift-os\kernel-boot-alt` (active = slot B) is generated
  by `kernelboot` at image build, signed with the image-signing key (Makefile +
  make-disk stage it alongside `kernel-boot`).
- `kernel/fs/esp.swift`: `espActivateOtherKernel()` (capConsole) reads the live
  `kernel-boot` and `kernel-boot-alt` active slots, requires the alternate to
  select the *other* slot, then copies the alternate's manifest sector over
  `kernel-boot` in place (`virtioBlkWriteSector` + `virtioBlkFlush`) and re-reads
  to confirm. Logs "kernel-store: activated kernel slot B for next boot (signed
  manifest)". No new globals.
- Syscall 69 `SYS_KERNEL_ACTIVATE`; `/bin/swos-kactivate`
  (`userland/swos-kactivate.swift`, bridge `swiftos_kernel_activate`/
  `kernel_activate`); execResolve + Makefile rules.

**Acceptance.** `tests/uefi_kactivate_test.sh` (in `make test`): boot the disk copy
(active A), reach a root shell, run `/bin/swos-kactivate`; reboot the SAME disk
(`cache=writethrough`) → the loader logs "kernel A/B manifest active slot B
(signature OK)" and "booted kernel slot B", with no "signature INVALID" — proving
the flip persisted and the offline signature held.

**Superseded by U1g-5d.** This courier-manifest flow proved activation end to
end, then U1g-5d moved mutable active selection into the writable boot-state so
activation no longer needs `kernel-boot-alt`.

**Still future.** A real new-kernel *payload* source (today both slots are the
same build; staging a genuinely different signed kernel needs a payload disk or
an update channel) plus key rotation / revocation.

### U1g-5a — loader boot-attempt counter on the ESP (DONE, 2026-06-10)

**Scope.** First slice of kernel attempt-based rollback (the U1b analogue). The
loader gains its first ESP *write*: a per-slot boot-attempt counter in a writable,
hash-protected `kernel-state` file, persisted across reboots. This is the
"writable boot-state" half of the signed-selection split — the kernel images stay
independently signed/hashed, so the boot-state need not be (its SHA-256 only
guards against torn/garbage writes, like SWOSBOOT's CRC).

- `boot/efi/loader.c`: the loader boot-state helpers open `\EFI\swift-os\kernel-state`
  with READ|WRITE|CREATE (EFI File protocol), reads + validates the 512-byte record
  ("SWOSKSTA", version, seq, attemptA/B, stateA/B, lastBooted, SHA-256 over
  [0,480)), re-initializes it if absent/corrupt, increments the booted slot's
  attempt + seq, rehashes, and writes it back (Close flushes). Self-managed — no
  build/disk staging needed; the loader creates it on first boot. Best-effort: a
  write failure logs but never blocks boot. Uses the existing `loader_sha256.h`.
  `efi.h` gains `EFI_FILE_MODE_WRITE`/`CREATE`.

**Acceptance.** `tests/uefi_kattempt_test.sh` (in `make test`): boots the SAME
writable disk copy three times under AAVMF (ESP on mmio, `cache=writethrough`) and
asserts the active slot's counter increments 1→2→3 across reboots — proving the
loader's EFI write lands and persists. The signed manifest (v3) is untouched, so
the existing kernel-A/B tests are unaffected.

**Then.** U1g-5d moves `active` into the writable boot-state so activate no
longer needs a pre-signed alternate manifest.

### U1g-5b — attempt-based kernel rollback in the loader (DONE, 2026-06-10)

**Scope.** The U1d analogue for the kernel. The loader now uses the U1g-5a
boot-attempt counter to fail over: an unconfirmed active slot that has exhausted
its attempts is presumed unhealthy ("boots but never confirmed"), so the loader
boots the other slot instead and marks the original FAILED — persisted in the
writable boot-state.

- `boot/efi/loader.c`: `loader_bump_attempt` refactored into `loader_open_kstate`
  + `loader_read_kstate` (validates / re-inits) + `loader_write_kstate` (rehash +
  write). `efi_main` reads the kernel-state *before* loading; if the manifest's
  active slot is not `CONFIRMED` and `attempt >= KS_MAX_ATTEMPTS` (3) and a
  distinct fallback exists, it tries the fallback first (logs "kernel slot A
  unconfirmed after N attempts, rolling back to slot B"), marks the active slot
  `FAILED`, and counts the booted slot's attempt. The existing per-slot SHA-256
  load + hash-failure fallback is preserved (a bad active *image* still fails over
  too). A CONFIRMED slot stops counting (the U1c hook, used in 5c).

**Acceptance.** `tests/uefi_krollback_test.sh` (in `make test`): boot the same
disk copy 4× (ESP on mmio, `cache=writethrough`); boots 1–3 record attempts
1/2/3 for the unconfirmed slot A, and boot 4 fails over to slot B ("rolling back
to slot B" + "booted kernel slot B" + the kernel starts). `uefi_kattempt_test`
(3 boots, no rollback) and the signed kernel-A/B tests are unaffected.

### U1g-5c — kernel-slot health confirm from userland (DONE, 2026-06-10)

**Scope.** The U1c analogue for the ESP kernel A/B path. The loader records the
slot it actually booted in the writable `kernel-state`; `/bin/swos-kconfirm`
marks that slot `CONFIRMED`, resets its attempt counter, rehashes the record, and
flushes the FAT32 ESP write. A confirmed slot stops accruing attempts and is not
rolled back by U1g-5b.

- `boot/efi/loader.c`: the boot-state offset 32 is now `lastBooted`; `efi_main`
  stores `loaded_slot` there whenever an ESP slot is booted.
- `kernel/fs/esp.swift`: adds `espConfirmBootedKernel()` and the in-place
  kernel-state read/validate/rehash/write path.
- Syscall 70 `SYS_KERNEL_CONFIRM`; `/bin/swos-kconfirm`
  (`userland/swos-kconfirm.swift`, bridge `swiftos_kernel_confirm`/
  `kernel_confirm`); Makefile stages it into the base image.

**Acceptance.** `tests/uefi_kconfirm_test.sh` (in `make test`): boot the disk copy
to a root shell, run `/bin/swos-kconfirm`, then reboot the same writable ESP copy
three more times. The loader stays on slot A, reports boot attempt 0 each time,
and never rolls back.

### U1g-5d — mutable kernel active slot in kernel-state (DONE, 2026-06-10)

**Scope.** Retire `kernel-boot-alt`. The signed `kernel-boot` manifest now
authenticates slot sizes/hashes and provides a default active slot; the mutable
active slot lives in the loader-managed, hash-protected `kernel-state` record.
This matches the SWOSBOOT split: signed immutable bytes plus writable health and
selection state.

- `boot/efi/loader.c`: kernel-state layout adds `active` at offset 36. The loader
  verifies the signed manifest, resolves active from kernel-state when valid,
  logs the boot-state active slot, and persists the actually booted slot as active
  after successful load/rollback.
- `kernel/fs/esp.swift`: `espActivateOtherKernel()` no longer reads
  `kernel-boot-alt` or rewrites the signed manifest. It validates `kernel-state`,
  flips active to the other slot, resets that slot to UNTRIED/attempt 0, clears
  `lastBooted`, rehashes, writes, flushes, and verifies the sector.
- `Makefile` and `scripts/make-disk.sh`: stop generating/copying
  `kernel-boot-alt`; `make uefi` removes stale staged copies.

**Acceptance.** `tests/uefi_kactivate_test.sh` now asserts the disk image has no
`kernel-boot-alt`; after `/bin/swos-kactivate`, the next boot still reports the
signed manifest default active slot A, then reports kernel-state active slot B
and boots slot B. `uefi_kattempt_test`, `uefi_kconfirm_test`, and
`uefi_krollback_test` cover the adjacent boot-state flows.

**Still future.** A real new-kernel payload source and key rotation / revocation
remain separate follow-ups.
