# SwiftOS User Guide

This guide describes how to use the current SwiftOS system from the serial
console. It is written for operators, testers, and application developers who
need to understand what is available inside a running guest.

For a short explanation of SwiftOS terms such as base image, tmpfs, principals,
capabilities, handles, and package payloads, see [CONCEPTS.md](CONCEPTS.md).

## Console Model

SwiftOS is currently headless by default. The primary UI is the serial console
provided by QEMU `-nographic`.

The boot flow is:

1. Kernel initializes hardware, memory, scheduler, VFS, security, and userland.
2. The early TTY smoke prompt may ask for one input line and then a Ctrl-C.
3. `/bin/swos-init` starts configured boot services and then hands off to
   `/bin/console-login`.
4. After authentication, the configured shell is executed.
5. When the shell exits, init/login is started again for the next session.

There is no graphical desktop shell in the current product profile.

## Choose A Console Task

After login, start from the task you need to perform. The seeded `root` account
can exercise every current workflow; `user` and `guest` are useful for
capability checks.

| Task | Run first | Then use |
| --- | --- | --- |
| Confirm the boot is healthy | `id`, `cat /etc/motd`, `ps`, `top -b -n 2 -d 1` | [Process Inspection](#process-inspection), [Observability Guide](OBSERVABILITY_GUIDE.md) |
| Inspect the immutable base image | `ls -l /`, `ls -l /bin`, `cat /readme.txt` | [Filesystem](#filesystem), [Base Image](BASE_IMAGE.md) |
| Use writable scratch space | `mkdir /tmp/work`, `echo ok >/tmp/work/check.txt`, `cat /tmp/work/check.txt` | [Filesystem](#filesystem) |
| Compare account authority | `id`, then retry a file or network command under another login | [Accounts And Capabilities](#accounts-and-capabilities), [Security Guide](SECURITY_GUIDE.md) |
| Serve static files | `/bin/httpd` after booting with TCP 8080 forwarding | [HTTP Server](#http-server), [Service Guide](SERVICE_GUIDE.md) |
| Serve local AI completions | `/bin/llmd` after booting with TCP 8080 forwarding | [AI Inference Server](#ai-inference-server), [AI Hosting Guide](AI_HOSTING_GUIDE.md) |
| Test TCP or UDP networking | `/bin/tcpecho`, `/bin/udpecho`, `/bin/tcpget`, or `/bin/nslookup` | [Networking](#networking), [Networking Guide](NETWORKING_GUIDE.md) |
| Run runtime smoke programs | `/bin/threadsdemo` or `/bin/mmapdemo` | [Runtime Smoke Programs](#runtime-smoke-programs) |
| Validate update commands | `swos-update`, `swos-activate`, `swos-confirm`, or the `swos-k*` commands only in the matching profile | [Update Commands](#update-commands), [Update And Rollback Guide](UPDATE_GUIDE.md) |

First five guest commands for a new session:

```sh
id
cat /etc/motd
ls -l /
echo hello >/tmp/hello.txt
cat /tmp/hello.txt
```

Those commands prove the login context, base-image read path, directory
metadata, tmpfs write path, and tmpfs readback without requiring networking.

## Accounts And Capabilities

SwiftOS uses principals, sessions, and capability masks. The seeded identity
store is `base/etc/swos/passwd`; the compatibility views are `base/etc/passwd`
and `base/etc/group`.

| Account | Password | Principal | Capability mask | Meaning |
| --- | --- | ---: | ---: | --- |
| `root` | `swordfish` | 1 | `0x3f` | Console login authority, spawn, filesystem read, tmpfs write, inspect, network |
| `user` | `swordfish` | 2 | `0x0e` | Spawn, filesystem read, tmpfs write |
| `guest` | `guest` | 3 | `0x02` | Spawn only |

Check the current context:

```sh
id
```

Examples:

```text
principal=1(root) session=1 caps=0x3f
principal=2(user) session=2 caps=0xe
principal=3 session=3 caps=0x2
```

The capability bits are:

| Bit | Name | Effect |
| ---: | --- | --- |
| 0 | `capConsole` | May call `login()` to adopt another authenticated context |
| 1 | `capSpawn` | Process-launch authority bit in the identity model |
| 2 | `capFsRead` | May open and inspect filesystem objects |
| 3 | `capTmpWrite` | May create, write, rename, unlink, chmod, and chown tmpfs nodes |
| 4 | `capProcessInspect` | Process-inspection authority bit in the identity model |
| 5 | `capNet` | May create sockets and resolve names |
| 6 | `capLogExport` | May export the local kernel log ring with `logtail` |

Capabilities are not Unix uid 0. They are explicit process authority bits. File
handles also carry per-handle rights; see [API_REFERENCE.md](API_REFERENCE.md)
for handle rights and [SECURITY_GUIDE.md](SECURITY_GUIDE.md) for the complete
current security model. To change accounts, capability masks, or base-image
configuration, see [ADMINISTRATION_GUIDE.md](ADMINISTRATION_GUIDE.md).

## Filesystem

SwiftOS has a two-tier filesystem:

| Tier | Path examples | Writable | Lifetime |
| --- | --- | --- | --- |
| Packed base image | `/bin`, `/etc`, `/www`, `/hello.txt` | No | Immutable across boot |
| tmpfs scratch | `/tmp` | Yes, with `capTmpWrite` | Lost on reboot |

Read base files:

```sh
cat /etc/motd
cat /readme.txt
cat /hello.txt
```

List directories:

```sh
ls /
ls -l /bin
ls -l /etc
```

Create scratch files:

```sh
mkdir /tmp/work
echo one >/tmp/work/a.txt
echo two >>/tmp/work/a.txt
cat /tmp/work/a.txt
```

Rename and remove scratch files:

```sh
mv /tmp/work/a.txt /tmp/work/message.txt
rm /tmp/work/message.txt
rmdir /tmp/work
```

Change tmpfs metadata:

```sh
echo abc >/tmp/mode-sample
chmod 600 /tmp/mode-sample
chown 2 /tmp/mode-sample
ls -l /tmp/mode-sample
```

Writes to the base image fail by design:

```sh
echo no >/etc/motd
```

Use `/tmp` for runtime scratch state.

## Programs In `/bin`

The base image stages native Swift programs, C diagnostic programs, and busybox. The C5
service smoke is available as `/bin/drvsvcdemo`; it starts and restarts the
driver-service worker `/bin/drvinputd` over endpoint IPC, then transfers an
opaque input-device handle to prove device ownership can move to a restartable
service. In the focused C5 gate that handle is discovered as `virtio-input.0`
when QEMU exposes a keyboard device, the C5d metadata gate confirms its
virtio-mmio base and length are visible as discovery metadata only, and C5e/C5f
prove that current grants still carry no real MMIO, IRQ, DMA, or queue
authority. Headless boots use the `pseudo-input.0` fallback so the same
lifecycle remains testable.

Common native Swift tools:

| Program | Purpose |
| --- | --- |
| `ls` | List files, including `-l` metadata |
| `cat` | Print file contents |
| `echo` | Print arguments |
| `pwd` | Print current directory |
| `ps` | Process list |
| `top` | Process and memory statistics |
| `id` | Principal, session, and capability mask |
| `mkdir`, `rmdir`, `rm`, `mv` | tmpfs file operations |
| `chmod`, `chown` | tmpfs metadata updates |
| `head`, `wc`, `touch`, `date` | Core utility coverage |
| `calc` | Interactive expression REPL over Swift heap and ARC |
| `kv` | In-memory key-value REPL |
| `llm`, `llmd` | Native Swift TinyStories inference client and HTTP serving daemon |
| `logtail` | Capability-gated local kernel log ring export |
| `udpecho`, `tcpecho`, `tcpget`, `tlsget`, `nslookup`, `httpd` | Network tools |
| `swos-update`, `swos-activate`, `swos-confirm` | Checked base-image A/B update-store commands |
| `swos-kstage`, `swos-kactivate`, `swos-kconfirm` | Checked UEFI ESP kernel-slot commands |
| `threadsdemo`, `mmapdemo` | Runtime and VM smoke programs |

Busybox is staged as `/bin/busybox` and is used for the login shell. It is a
legacy bring-up and compatibility tool, not the long-term application model.

For exact syntax, examples, capability notes, and acceptance-test coverage for
each shipped command, see [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md).

## Shell Basics

The default shell is busybox `ash`.

Useful commands:

```sh
pwd
ls -l /
cat /etc/motd
echo hello
echo hello >/tmp/hello.txt
cat /tmp/hello.txt
ps
id
exit
```

Pipes and redirection are supported through the SwiftOS fd, pipe, dup, fcntl,
and exec paths:

```sh
cat /etc/motd | wc
echo hello >/tmp/r
echo again >>/tmp/r
cat /tmp/r
```

## Process Inspection

List processes:

```sh
ps
```

Batch process summary:

```sh
top -b -n 2 -d 1
```

`top` shows uptime, task counts, aggregate CPU busy/idle, discovered CPU count,
per-CPU busy percentages, memory summaries, kernel footprint, and a process
table. The host-side SMP utilization gate is `make smp-cpu-utilization-test`;
the restricted independent EL0 fanout gate is `make s5-el0-fanout-test`, and
the default run-any process placement gate is `make s5-run-any-placement-test`.

Interactive `top` uses raw terminal mode. Press `q` to quit.

## Networking

Network use requires:

1. QEMU launched with a virtio-net device.
2. A process with `capNet` (`root` has it in the seeded image).

See [GETTING_STARTED.md](GETTING_STARTED.md) for a full QEMU launch command with
host forwarding, and [NETWORKING_GUIDE.md](NETWORKING_GUIDE.md) for complete
network runbooks and tests.

### HTTP Server

Start the static file server:

```sh
/bin/httpd
```

It binds TCP port 8080 and serves only `/www`:

| Request path | VFS path |
| --- | --- |
| `/` | `/www/index.html` |
| `/hello.txt` | `/www/hello.txt` |
| `/sub/note.txt` | `/www/sub/note.txt` |

Host commands with TCP host forwarding:

```sh
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/hello.txt
```

`httpd` is poll-driven and can service multiple live connections.

### AI Inference Server

For the complete AI hosting guide, including model-bundle verification and
service evidence, see [AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

Start the model-serving daemon:

```sh
/bin/llmd
```

It binds TCP port 8080 and serves the TinyStories model from `/models`.
By default, it verifies the bundle rooted at `/models/stories15M`, rejects any
bad newest generation, and falls back to the newest generation whose signed
manifest, model, and tokenizer hashes match. Pass
`llmd [model.bin] [tokenizer.bin]` to test another supported
checkpoint/tokenizer pair without signed-bundle verification.

Host commands with TCP host forwarding:

```sh
curl http://127.0.0.1:8080/health
curl -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl http://127.0.0.1:8080/metrics
```

`llmd` and `httpd` both bind guest TCP port 8080, so run one of them at a time.
The daemon uses the same `capNet` requirement as the other socket tools.

### TCP Echo

Guest:

```sh
/bin/tcpecho
```

Host:

```sh
printf 'swos tcp\n' | nc 127.0.0.1 5555
```

The server accepts one connection, echoes one chunk, prints the byte count, and
exits.

### UDP Echo

Guest:

```sh
/bin/udpecho
```

Host:

```sh
printf 'swos udp' | nc -u 127.0.0.1 5555
```

The server receives one datagram, echoes it, prints the sender, and exits.

### Outbound TCP

QEMU slirp maps `10.0.2.2` to the host. If the host has a server listening:

```sh
/bin/tcpget 10.0.2.2 5555
```

### DNS

Resolve through the default slirp DNS server:

```sh
/bin/nslookup example.com
```

Resolve through an explicit server and port:

```sh
/bin/nslookup test.swos 10.0.2.2 5354
```

### TLS Runtime Smoke

`/bin/tlsget` contains the current userland TLS client groundwork. Certificate
verification is deliberately incomplete in the current branch; use it as a TLS
runtime smoke path, not as a production trust decision.

## Runtime Smoke Programs

### Threads

Run the EL0 thread/futex smoke program:

```sh
/bin/threadsdemo
```

It creates EL0 threads in one address space and uses futex-backed synchronization
to prove correct shared counter updates.

### mmap And W^X

Run the anonymous mmap, mprotect, and W^X smoke program:

```sh
/bin/mmapdemo
```

The program maps zero-filled RAM, writes and reads across a page boundary,
switches a page from RW to RX for a small JIT-style call, and confirms RWX
mappings are rejected.

## Update Commands

SwiftOS has checked A/B validation paths for base images and UEFI kernel slots.
They are operator/test workflows, not a general online updater. Run them only in
the matching boot profile described by [UPDATE_GUIDE.md](UPDATE_GUIDE.md).

Base-image A/B store commands:

```sh
swos-update
swos-activate
swos-confirm
```

`swos-update` stages an attached signed SWOSBASE payload disk into the inactive
slot. `swos-activate` promotes that inactive slot for the next boot. After a
healthy trial boot, `swos-confirm` marks the slot healthy so boot-attempt
rollback will not fail back to the previous slot.

UEFI ESP kernel-slot commands:

```sh
swos-kstage
swos-kactivate
swos-kconfirm
```

`swos-kstage` copies and verifies the active ESP kernel image into the inactive
kernel slot. `swos-kactivate` selects the inactive slot in the loader-managed
`kernel-state` for the next boot; the signed `kernel-boot` manifest still
authenticates the slot hashes. After the trial boot is healthy, `swos-kconfirm`
marks the booted kernel slot confirmed in `kernel-state` so its attempt counter
resets and it is not rolled back. Unconfirmed kernel slots still roll back after
the checked attempt window.

All `swos-*` update commands require privileged update authority through the
current `capConsole` path. The focused acceptance gates are in
[TESTING_GUIDE.md](TESTING_GUIDE.md), and the on-disk trust model is in
[UPDATE_STORE.md](UPDATE_STORE.md).

## Security Notes

- The base filesystem is immutable.
- Writable state is intentionally tmpfs-only in the current design.
- A process cannot gain authority from a handle it was not given.
- `spawn_handles` can explicitly pass selected handles to a child with attenuated
  rights.
- `confine(path)` can narrow a process's filesystem view to a subtree.
- Networking is gated by `capNet`.
- Login context changes are gated by `capConsole`.

Security is capability-centered rather than Unix-root-centered. Some compatibility
layers still expose POSIX-like names for ported software, but the kernel checks
its own capability and handle model.

For the full current security model, including login, password storage, handle
rights, confinement, W^X memory mappings, package overlays, and current limits,
see [SECURITY_GUIDE.md](SECURITY_GUIDE.md).

## Known Current Limits

These are current implementation boundaries, not necessarily design goals:

- No Linux syscall ABI.
- Static userland only; no dynamic loader.
- No persistent writable filesystem.
- Package install exists for local `.swpkg` files and signed static HTTP
  repository fixtures, including name-based dependency resolution. The checked
  ports seed publishes Lua, zlib, bzip2, zstd, xz, libarchive,
  ca-certificates, pcre2, tzdata, nginx, and sqlite into one signed local
  repository, installs all eleven by package name, and runs Lua, `minigzip`,
  bzip2, zstd, xz, `bsdtar`, the CA bundle marker, `pcre2grep`, zoneinfo,
  nginx, and SQLite smoke commands in QEMU. The static-host workflow publishes that
  seed into a deployable web root and proves the same install path from the
  hosted layout.
  The hosted-URL smoke proves that `/bin/pkg` can install from a DNS-resolved
  HTTP repository hostname. Remove, upgrade, rollback, public production
  channels, version-constraint solving, and large-package streaming downloads
  are not implemented yet.
- No graphical desktop shell.
- Userland networking is currently exposed through kernel socket syscalls; the
  roadmap moves more services out of the kernel.
- TLS certificate verification is not production-grade yet.
- `guest` carries only the spawn-model authority bit and cannot read the
  filesystem, by design.

## Exiting And Rebooting

Exit the current shell:

```sh
exit
```

QEMU returns to the login prompt after the session ends. To stop the VM from the
host terminal, use Ctrl-A X in QEMU `-nographic`, or terminate the QEMU process.
