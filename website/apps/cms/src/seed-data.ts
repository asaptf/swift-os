/* Seed content for the swift-os website CMS. Grounded in the swift-os repo
 * (README, docs/*, Makefile) — no invented version numbers, no "served by
 * swift-os" overclaim. Mirrors apps/web/src/lib/content/defaults.ts so a fresh
 * database renders the site identically to the bundled fallback. */

export const home = {
  eyebrow: 'Embedded Swift · aarch64 · experimental, but real',
  titleHtml: 'A real operating system,<br>written entirely in <span class="accent-word">Swift</span>.',
  leadHtml:
    'Most hobby kernels stop at <span class="mono" style="white-space:nowrap">“Hello from the kernel.”</span> swift-os keeps going — a native Swift userland, an in-kernel TCP/IP stack, capability-based isolation, its own HTTP server, and a <strong style="color:var(--text)">native Swift AI inference server</strong>. You can even try it in your browser.',
  featuresEyebrow: 'What it is',
  featuresHeading: 'Efficient, reliable minimalism — not another Unix.',
  featuresLead:
    'A small trusted core, capability-based isolation, deterministic boot, and signed immutable images. swift-os removes legacy rather than emulating it.',
  features: [
    { icon: 'minimal', title: 'Minimal Swift kernel', bodyHtml: 'A freestanding Embedded Swift kernel — no Foundation, no stdlib, no GC. Value types and <code>~Copyable</code> ownership at the metal.' },
    { icon: 'shield', title: 'Capability security', bodyHtml: 'Authority is a capability you hold, not a uid you are. No ambient <code>root==0</code> power; typed handles are landing now.' },
    { icon: 'swift', title: 'Native Swift userland', bodyHtml: 'Real tools — a shell, <code>id</code>, <code>ps</code>, <code>top</code>, <code>httpd</code>, <code>ssh</code> — compiled as Embedded Swift, running unprivileged at EL0.' },
    { icon: 'net', title: 'In-kernel networking', bodyHtml: 'A pure-Swift TCP/IP stack over virtio-net: IPv4, DHCP, DNS, TCP/UDP — driving its own <code>/bin/httpd</code>.' },
    { icon: 'chip', title: 'AI inference, natively', bodyHtml: '<code>/bin/llmd</code> serves a TinyStories transformer over HTTP — <code>POST /completion</code> — written in Embedded Swift. The flagship app/AI-hosting profile, proven.' },
    { icon: 'cube', title: 'Immutable images', bodyHtml: 'Boot a signed, read-only <code>base.img</code>; writes land in a tmpfs that vanishes on reboot. Reproducible by design.' }
  ],
  worksEyebrow: 'Honest by default',
  worksHeading: 'We tell you exactly what works today.',
  worksLead:
    'Experimental but real means no overclaiming. The status page carries the honesty so the rest of the site can be confident.',
  worksBadges: [
    { label: 'AArch64 boot', variant: 'ok' },
    { label: 'QEMU virt', variant: 'ok' },
    { label: 'Swift userland', variant: 'ok' },
    { label: 'TCP/IP + HTTP', variant: 'ok' },
    { label: 'TinyStories llmd', variant: 'ok' },
    { label: 'Capabilities · hardening', variant: 'accent' },
    { label: 'Packages · 12 ports', variant: 'warn' },
    { label: 'SMP · active', variant: 'warn' },
    { label: 'Linux ABI · non-goal', variant: 'muted' },
    { label: 'x86-64 · non-goal', variant: 'muted' }
  ],
  startEyebrow: 'Start here',
  startHeading: 'Pick a path.',
  startCards: [
    { title: 'Try it in your browser', bodyHtml: 'Boot swift-os with zero setup — <code>qemu-system-aarch64</code> in WebAssembly.', href: '/try' },
    { title: 'Run it in 5 minutes', bodyHtml: 'clone → build → <code>make run</code>. Boots in QEMU on Apple Silicon.', href: '/quickstart' },
    { title: 'Understand the design', bodyHtml: 'Vector diagrams of boot, isolation, networking, and the security model.', href: '/architecture' }
  ]
};

export const liveProof = {
  heading: 'swift-os answers real requests.',
  body: 'A pure-Swift, in-kernel TCP/IP stack drives virtio-net. <code>/bin/httpd</code> serves files and <code>/bin/llmd</code> serves a TinyStories transformer over HTTP on <code>:8080</code> — both native Embedded Swift, running unprivileged at EL0. Boot it in your browser and hit it yourself.',
  bootLog: `[ ok ] swift-os kernel (Embedded Swift, signed)
[ ok ] MMU enabled · EL1 · 256 MiB
[ ok ] virtio-net up · DHCPv4 10.0.2.15/24
[ ok ] httpd listening on :8080
[ ok ] llmd ready · GET /health · POST /completion`,
  hostedNote: 'Embedded Swift · aarch64 · Apache-2.0',
  stats: [
    { label: 'Kernel', value: 'Embedded Swift', sub: 'freestanding · no stdlib / Foundation' },
    { label: 'Boot to login', value: '< 1s', sub: 'deterministic · signed image', accent: true },
    { label: 'Seed packages', value: '12', sub: 'lua · nginx · sqlite3 · curl …', countTo: 12 },
    { label: 'Serving', value: 'httpd · llmd<br>:8080', sub: 'static files + TinyStories' }
  ]
};

export const statusPage = {
  eyebrow: 'Status · what works today',
  heading: "No overclaiming. Here's exactly where swift-os stands.",
  lead: 'Experimental, but real. This page carries the honesty so the rest of the site can be confident. Everything marked <span style="color:var(--ok);font-weight:600">Works</span> is exercised by an acceptance gate in <code>make test</code>.',
  build: 'Embedded Swift · aarch64 · QEMU virt',
  updated: 'Phase 1 — hardening (active) · no stable version yet, built from source',
  testLog: `PASS  boot_test.sh               boots to swift-os login
PASS  cap_enforce_test.sh        EL0 cannot open without the capability
PASS  ipc_socket_transfer_test   endpoint handle move semantics
PASS  smp_boot_test.sh           boots with -smp 4 · per-CPU timers
PASS  llm_serve_test.sh          POST /completion returns text
PASS  package-local-install      signed .swpkg installs + verifies
─── make test · host unit + in-QEMU boot assertions ───`,
  nonGoals: [
    { title: 'Not a Unix-compatibility exercise', body: 'No Linux ABI, no POSIX emulation layer. Existing binaries are recompiled against our own syscall surface, not ported.' },
    { title: 'Single architecture, on purpose', body: "AArch64 only. Supporting x86-64 would double the trusted surface for little gain to the project's goals." },
    { title: 'Volatile by default', body: 'The base image is read-only and <code>/tmp</code> vanishes on reboot; durable state is an explicit choice — you write it to the persistent <code>/data</code> tier. Persistence is opt-in, never accidental.' },
    { title: 'No ambient authority, no GPU runtime', body: "Being \"root\" grants nothing by itself, and AI hosting is CPU-only — no GPU/NPU acceleration is in scope today." }
  ],
  coverage: [
    { to: 12, decimals: 0, label: 'ports in the seed repo' },
    { to: 4, decimals: 0, suffix: ' CPUs', label: 'SMP boot tested (-smp 4)' },
    { to: 0, decimals: 0, label: 'panics on the boot gate', accent: true },
    { to: 51, decimals: 0, suffix: '+', label: 'syscalls in the ABI' }
  ]
};

export const capabilities = [
  { name: 'AArch64 boot', note: 'cortex-a72 · -kernel + UEFI', status: 'Works', variant: 'ok', detail: 'Deterministic boot to a Swift login in under a second.', order: 1 },
  { name: 'QEMU virt machine', note: 'qemu-system-aarch64', status: 'Primary', variant: 'accent', detail: 'The reference target; every gate runs here.', order: 2 },
  { name: 'UEFI / GPT boot', note: 'BOOTAA64.EFI · make disk-run', status: 'Works', variant: 'ok', detail: 'Signed image, GPT-partitioned, AAVMF firmware.', order: 3 },
  { name: 'Swift userland', note: 'shell + native tools at EL0', status: 'Works', variant: 'ok', detail: 'ls, cat, ps, top, id, httpd, ssh — Embedded Swift.', order: 4 },
  { name: 'Three-tier storage', note: 'ro base.img · tmpfs /tmp · /data', status: 'Works', variant: 'ok', detail: 'Signed packed base, volatile /tmp, and a persistent on-disk /data (datafs) that survives reboot; crash-safe SQLite via fsync.', order: 5 },
  { name: 'Networking', note: 'in-kernel TCP/IP · virtio-net', status: 'Works', variant: 'ok', detail: 'IPv4, DHCP, DNS, TCP/UDP, ICMP/ARP. IPv6 partial.', order: 6 },
  { name: 'HTTP server', note: '/bin/httpd · :8080', status: 'Works', variant: 'ok', detail: 'Concurrent poll-driven static server with MIME + listings.', order: 7 },
  { name: 'AI inference', note: '/bin/llmd · TinyStories', status: 'Works', variant: 'ok', detail: 'Native Swift transformer over HTTP. CPU proof, not a GPU runtime.', order: 8 },
  { name: 'Package system', note: '.swpkg · signed repo · 12 ports', status: 'Works', variant: 'ok', detail: 'pkg install NAME from a signed static repository.', order: 9 },
  { name: 'Capability handles', note: 'principal · typed handles', status: 'Hardening', variant: 'warn', detail: 'Capability bits today; C1–C5 typed handles landed, C6 active.', order: 10 },
  { name: 'SMP', note: 'multi-core scheduling', status: 'Active', variant: 'warn', detail: 'Boots with -smp 4; S0–S2 done, S3–S5 in progress.', order: 11 },
  { name: 'TLS 1.3', note: 'ChaCha20-Poly1305 · client', status: 'Active', variant: 'warn', detail: 'Client path works; cert verification incomplete.', order: 12 },
  { name: 'Linux ABI', note: 'syscall compatibility', status: 'Non-goal', variant: 'muted', detail: 'We remove legacy, not emulate it. Tools are recompiled.', order: 13 },
  { name: 'Docker / x86-64', note: 'containers · alt arch', status: 'Non-goal', variant: 'muted', detail: 'Isolation is native; AArch64 only, deliberately.', order: 14 }
];

export const roadmapItems = [
  { phase: 'done', label: 'Boot to Swift login (direct + UEFI)', order: 1 },
  { phase: 'done', label: 'MMU process isolation (EL0/EL1)', order: 2 },
  { phase: 'done', label: 'In-kernel TCP/IP + <code>/bin/httpd</code>', order: 3 },
  { phase: 'done', label: 'TinyStories inference (<code>/bin/llmd</code>)', order: 4 },
  { phase: 'done', label: 'Signed base image + .swpkg packages', order: 5 },
  { phase: 'done', label: 'Try-in-browser (qemu-wasm) demo', order: 6 },
  { phase: 'done', label: 'Persistent <code>/data</code> filesystem (datafs)', order: 7 },
  { phase: 'active', label: 'Typed capability handles (C5–C6)', order: 7 },
  { phase: 'active', label: 'SMP scheduling (S3–S5)', order: 8 },
  { phase: 'active', label: 'Restartable driver services', order: 9 },
  { phase: 'active', label: 'TLS 1.3 record layer + cert verification', order: 10 },
  { phase: 'planned', label: 'Node.js / JVM hosting (Phase 2)', order: 12 },
  { phase: 'planned', label: 'Real-hardware AArch64 boards', order: 13 }
];

export const quickstartPage = {
  eyebrow: 'Quickstart',
  heading: 'Run swift-os in about ten minutes.',
  leadHtml:
    "No OS-internals knowledge needed. You'll clone the repo, cross-build a small toolchain once, and boot a real swift-os image in QEMU. First login is <code>root</code> / <code>swordfish</code>.",
  needHtml:
    '<strong>You\'ll need</strong>~2&nbsp;GB free disk, <code>qemu-system-aarch64</code>, and the pinned Swift toolchain (see <code>docs/NOTES.md</code>). <strong style="display:inline;color:var(--accent)">macOS Apple Silicon is the primary, best-tested path.</strong>',
  tracks: [
    {
      key: 'mac',
      label: 'macOS · Apple Silicon',
      icon: 'apple',
      steps: [
        { title: 'Install the toolchain', bodyHtml: 'QEMU via Homebrew, plus the pinned Swift toolchain. Exact versions live in <code>docs/NOTES.md</code> (overridable with <code>make SWIFTC=…</code>).', commandTitle: 'Terminal — zsh', command: '$ brew install qemu llvm lld\n# Swift toolchain: see docs/NOTES.md (e.g. swift-6.3.2-RELEASE)' },
        { title: 'Clone the repository', commandTitle: 'Terminal — zsh', command: '$ git clone https://github.com/asaptf/swift-os\n$ cd swift-os' },
        { title: 'Cross-build newlib + busybox (once)', bodyHtml: 'A one-time step that builds the C runtime and the busybox shell the userland links against.', commandTitle: 'Terminal — zsh', command: '$ make newlib busybox' },
        { title: 'Build & boot', bodyHtml: 'Build the kernel + signed base image, then launch QEMU on the serial console.', commandTitle: 'Terminal — zsh', command: '$ make build base-image build/virt.dtb\n$ make run', expectedTitle: 'qemu · swift-os', expected: '[ ok ] swift-os kernel (Embedded Swift, signed)\n[ ok ] MMU enabled · EL1 · 256 MiB\n[ ok ] virtio-net up · DHCPv4 10.0.2.15/24\n[ ok ] httpd listening on :8080\n\nswift-os login: root\nPassword: ••••••••\nWelcome to swift-os, root\nroot@swift-os:~$ ' },
        { title: 'Say hello', bodyHtml: 'Log in as <code>root</code> / <code>swordfish</code>, then inspect your principal, the network, and the read-only base.', commandTitle: 'swift-os shell', command: 'root@swift-os:~$ id\nsession: principal=1 session=1 caps=63\nroot@swift-os:~$ netinfo\nipv4 10.0.2.15/24  gw 10.0.2.2  dns 10.0.2.3\nroot@swift-os:~$ cat /etc/motd', callout: { type: 'tip', html: '<strong>Zero-setup option</strong>Want to skip the toolchain? Boot swift-os right in your browser at <a href="/try" style="color:var(--accent)">/try</a>.' } }
      ],
      footWarnHtml: '<strong>To quit QEMU</strong>Press <span class="kbd">Ctrl</span> <span class="kbd">A</span> then <span class="kbd">X</span>. Anything you wrote to <code>/tmp</code> is gone on the next boot — that\'s intended.'
    },
    { key: 'linux', label: 'Linux', calloutType: 'note', noteHtml: '<strong>Linux is a secondary path</strong>The same AArch64 image runs under <code>qemu-system-aarch64</code>. Install QEMU + a recent Swift toolchain, then build and boot exactly as on macOS.', commandTitle: 'Terminal — bash', command: '$ sudo apt install qemu-system-arm\n$ git clone https://github.com/asaptf/swift-os && cd swift-os\n$ make newlib busybox\n$ make build base-image build/virt.dtb && make run' },
    { key: 'uefi', label: 'UEFI boot', noteHtml: 'Boot a GPT-partitioned, signed image through a UEFI loader (<code>BOOTAA64.EFI</code>) under QEMU + AAVMF firmware, instead of QEMU\'s direct <code>-kernel</code> load.', commandTitle: 'Terminal', command: '$ make disk        # build the GPT disk + EFI loader\n$ make disk-run    # UEFI boot from the disk\n# or: make uefi-run   (quick FAT dir, no GPT)' },
    { key: 'net', label: 'Networking', noteHtml: 'swift-os drives virtio-net and acquires <code>10.0.2.15</code> over DHCP on QEMU\'s slirp user network. Inspect and exercise it from inside the guest.', commandTitle: 'swift-os shell', command: 'root@swift-os:~$ netinfo\nroot@swift-os:~$ nslookup example.com\nroot@swift-os:~$ httpd 8080      # serve /www\nroot@swift-os:~$ llmd            # TinyStories inference on :8080' },
    { key: 'vbox', label: 'VirtualBox ARM', calloutType: 'warn', noteHtml: '<strong>Best-effort only</strong>VirtualBox ARM is a manual, non-gated path (see <code>docs/VIRTUALBOX.md</code>). QEMU is the primary, tested target — use the raw image with an EFI-enabled ARM VM if you must.' }
  ]
};

export const glossaryTerms = [
  { key: 'kernel', definition: 'The trusted core of the OS. It runs at the highest privilege (EL1), owns memory and hardware, and mediates everything userland programs are allowed to do.' },
  { key: 'el0', definition: 'Exception Level 0 — the unprivileged mode where normal applications run on AArch64. Code here cannot touch hardware directly; it must ask the kernel via syscalls.' },
  { key: 'el1', definition: 'Exception Level 1 — the privileged kernel mode on AArch64. The MMU, scheduler, and drivers live here.' },
  { key: 'mmu', definition: 'Memory Management Unit — hardware that maps virtual addresses to physical ones. swift-os uses it to give each process its own isolated address space (its own TTBR0).' },
  { key: 'capability', definition: 'An unforgeable token granting a specific right to a specific object. Authority comes from holding the capability — not from being user 0. swift-os is moving from capability bits to typed handles.' },
  { key: 'embedded swift', definition: 'A mode of Swift that compiles without the full runtime, standard library, or garbage collector — suitable for freestanding kernel and bare-metal code. The whole swift-os kernel is written in it.' },
  { key: 'tmpfs', definition: 'A filesystem that lives in RAM. Fast, and it vanishes on reboot — swift-os mounts writable /tmp this way over a signed read-only base image. Durable state goes to /data instead.' },
  { key: 'datafs', definition: 'swift-os’s persistent on-disk filesystem, mounted at /data on a dedicated virtio-blk data disk. Unlike the read-only base image and the RAM-backed /tmp, files written under /data survive reboot; SQLite databases there are crash-safe via fsync.' },
  { key: 'virtio-net', definition: 'A paravirtualized network device. Under QEMU it is the NIC the in-kernel pure-Swift TCP/IP stack drives.' },
  { key: 'uefi', definition: 'Unified Extensible Firmware Interface — the modern firmware standard that hands control to the bootloader (BOOTAA64.EFI), replacing legacy BIOS.' },
  { key: 'syscall', definition: 'A controlled doorway from EL0 into EL1: a userland program requests a privileged operation and the kernel decides whether to perform it. swift-os has its own POSIX-like syscall surface, not the Linux ABI.' },
  { key: 'llmd', definition: 'The native Swift inference daemon — serves a TinyStories transformer over HTTP (GET /health, POST /completion). swift-os’s proof of the application & AI-hosting profile.' },
  { key: 'swpkg', definition: 'swift-os’s signed package format. Packages install from a signed static repository into a content-addressed store, verified by Ed25519 signature + SHA-256.' }
];

export const faqs = [
  { question: 'Is this a Linux clone?', answerHtml: 'No. swift-os removes legacy rather than emulating it. There is no Linux ABI and no Unix-compatibility layer — tools are recompiled against our own POSIX-like syscall surface.', category: 'General', order: 1 },
  { question: 'Why Swift for an OS?', answerHtml: 'Embedded Swift gives memory safety and modern ergonomics without a garbage collector or heavy runtime — a good fit for a freestanding kernel. The whole kernel is Swift, with no Foundation or stdlib.', category: 'General', order: 2 },
  { question: 'Does it really serve HTTP and run AI?', answerHtml: 'Yes — the in-kernel TCP/IP stack, <code>/bin/httpd</code>, and <code>/bin/llmd</code> (a TinyStories transformer over HTTP) are real and tested. <code>llmd</code> is a CPU proof-of-concept, not a general GPU model runtime. <em>This marketing site</em> is built with SvelteKit + Strapi — but you can boot swift-os in your browser and hit its httpd yourself.', category: 'General', order: 3 },
  { question: 'What hardware does it run on?', answerHtml: 'AArch64 under QEMU <code>virt</code> is the reference target (direct <code>-kernel</code> and UEFI/GPT). Real AArch64 boards are planned; x86-64 is a deliberate non-goal.', category: 'Running it', order: 4 },
  { question: 'How do I run it?', answerHtml: 'Clone the repo, install QEMU + the Swift toolchain, then <code>make newlib busybox</code> once, and <code>make build base-image build/virt.dtb && make run</code>. See the Quickstart, or try it in your browser with zero setup.', category: 'Running it', order: 5 },
  { question: 'Does anything persist across reboots?', answerHtml: 'Yes — anything you write under <code>/data</code>. swift-os has three storage tiers: a signed <strong>read-only</strong> base image, a <strong>volatile</strong> RAM tmpfs at <code>/tmp</code> that vanishes on reboot, and a <strong>persistent</strong> on-disk filesystem (datafs) mounted at <code>/data</code> on its own virtio-blk disk. SQLite databases under <code>/data</code> survive reboot and are crash-safe via <code>fsync</code>; <code>/tmp</code> and the read-only base are not for durable state.', category: 'Running it', order: 6 },
  { question: 'Is it multi-core yet?', answerHtml: 'Partly. It boots and runs restricted tests with <code>-smp 4</code> (S0–S2 of the SMP arc are done); full per-CPU scheduling, TLB shootdown, and arbitrary secondary EL0 execution (S3–S5) are active work.', category: 'Running it', order: 7 },
  { question: 'Can I run Node.js or a JVM?', answerHtml: 'Not yet. The libc surface, threading model, and syscall set are kept so as not to foreclose them, but Node.js / JVM hosting is recorded Phase-2 design, not something you can run today.', category: 'Roadmap', order: 8 }
];

export const articles = [
  {
    slug: 'why-swift-for-an-os',
    title: 'Why Swift for an OS?',
    eyebrow: 'Manifesto',
    excerpt: 'Memory safety and modern ergonomics on bare metal — without a garbage collector. The case for Embedded Swift in the kernel.',
    readingMinutes: 6,
    date: '2026-05-30',
    body: `Most kernels are written in C, and for good reasons: it is close to the metal, predictable, and universally supported. But "close to the metal" has always come with a tax — manual memory management, undefined behavior, and a class of bugs that mature tooling only partly contains.

## The Embedded Swift bet

**Embedded Swift** compiles Swift without a garbage collector or a heavy runtime. The swift-os kernel is fully freestanding: no Foundation, no standard library. You keep value types, \`~Copyable\` ownership with \`deinit\` for resources (pages, locks, handles), and the type system; you drop the parts that assume an allocator and a runtime are always present.

> The goal was never "Swift because we like Swift." It was memory safety and modern ergonomics with a cost model we can actually predict.

## What we give up — on purpose

Value types and \`Unsafe*\` pointers at the low level; classes only after the heap is up, and sparingly, because ARC has a cost on hot paths. That discipline is a feature — it keeps the trusted core small and legible.

## What we get back

- A compiler that catches whole categories of mistakes before boot.
- Code in the kernel that reads like application code.
- One language across the kernel, the userland, and the host build tools.`
  },
  {
    slug: 'serving-http-and-ai-from-swiftos',
    title: 'Serving HTTP and AI from swift-os',
    eyebrow: 'What is real',
    excerpt: 'A pure-Swift in-kernel TCP/IP stack, a real HTTP server, and a TinyStories inference daemon — what is shipping, and what is still ahead.',
    readingMinutes: 5,
    date: '2026-06-08',
    body: `swift-os does more than print to a console. Let us be precise about what is live and what is ahead.

## What is live today

The network stack is a **pure-Swift, sans-IO core** — Ethernet/ARP, IPv4, ICMP, UDP, TCP, and DNS — with no per-packet heap allocation, driving a modern virtio-net device. On top of it:

- \`/bin/httpd\` is a real concurrent, \`poll()\`-driven static file server with MIME types and directory listings, on \`:8080\`.
- \`/bin/llmd\` serves a **TinyStories transformer** over HTTP: \`GET /health\`, \`POST /completion\`, \`GET /metrics\`. The transformer and tokenizer are written in Embedded Swift and compiled into a static EL0 binary.

Both run unprivileged, holding only a \`net:bind\` capability.

> "Hello from the kernel" is where most hobby OSes stop. Answering a real HTTP request end-to-end — NIC → in-kernel TCP → an unprivileged Swift handler — is a much harder, much more convincing demonstration.

## What is honest about it

The current \`llmd\` is a **TinyStories proof** of the application & AI-hosting profile — not a general ONNX/GGUF/PyTorch or GPU runtime. TLS 1.3 has a working client path (ChaCha20-Poly1305), but production certificate verification is incomplete. Node.js and JVM hosting are recorded **Phase-2 design**, not implementation.

## Why it matters

The flagship profile is application and AI hosting. A native HTTP server and a native inference daemon, both in Embedded Swift on a capability-secured base, are the concrete first proof that the profile is more than a slogan.`
  },
  {
    slug: 'how-swiftos-boots',
    title: 'How swift-os boots',
    eyebrow: 'Deep dive',
    excerpt: 'From QEMU firmware to a Swift login prompt in under a second — deterministic, signed, and easy to reason about.',
    readingMinutes: 7,
    date: '2026-06-02',
    body: `A boot is a chain of trust and a sequence of handoffs. swift-os keeps both short, and treats boot time as a product feature.

## The chain

1. **Firmware** — QEMU \`virt\`, or a UEFI environment that loads \`BOOTAA64.EFI\` and calls \`ExitBootServices\`.
2. The **kernel** takes over at EL1, brings up an early UART console, builds translation tables, and enables the MMU.
3. It initializes the GIC and the generic timer, then the scheduler and process substrate.
4. It mounts the **three storage tiers**: a signed, read-only packed base, a RAM tmpfs at \`/tmp\`, and — when a data disk is present — the persistent \`/data\` filesystem (datafs).
5. It spawns \`/bin/swos-init\` → \`/bin/console-login\` → the shell.

## Why determinism matters

Boot defers optional drivers, services, and diagnostics until after the first shell runs, and favors packed precomputed metadata over probing loops. Every boot starts from the same known-good, signed image — so a boot is reproducible, and \`/tmp\` being volatile is a feature, not a limitation. Both the direct \`-kernel\` path and the UEFI/GPT path are tested on every change, on 1 CPU and \`-smp 4\`.`
  }
];
