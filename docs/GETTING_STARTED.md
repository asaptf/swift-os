# Getting Started With SwiftOS

This guide takes you from a fresh checkout to a running SwiftOS serial console.
It focuses on the QEMU `virt` target, which is the primary development and test
platform. For a quick map of SwiftOS terms such as base image, tmpfs,
principals, capabilities, and package payloads, see [CONCEPTS.md](CONCEPTS.md).

## What You Get

A default SwiftOS boot gives you:

- A freestanding Embedded Swift kernel running at EL1 on AArch64.
- A serial console through QEMU's `-nographic` terminal.
- A read-only packed base filesystem plus writable `/tmp` RAM scratch space.
- `/bin/console-login` as init, followed by a static busybox `ash` shell.
- Native Embedded Swift userland tools such as `ls`, `cat`, `ps`, `top`, `id`,
  `calc`, `kv`, `httpd`, `udpecho`, and `tcpecho`.
- Package fixtures for local `.swpkg` install, signed repository install, and
  the eight-package ports seed repository fixture.
- A POSIX-like syscall ABI that is intentionally not the Linux ABI.

## Host Requirements

The default Makefile expects these tools:

- Swift toolchain at
  `~/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain`.
- Host Swift compiler at `/usr/bin/swift` for host-side Swift tests.
- LLVM tools under `/opt/homebrew/opt/llvm/bin`.
- `ld.lld` under `/opt/homebrew/opt/lld/bin`.
- `qemu-system-aarch64` in `PATH`.
- `aarch64-elf-gcc` and a built `sysroot/` only for newlib and busybox work.

Tool paths are overridable:

```sh
make SWIFTC=/path/to/swiftc QEMU=/path/to/qemu-system-aarch64 build
```

For the complete set of build, boot, QEMU, board, and test configuration knobs,
see [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md).
For a profile-by-profile install and verification guide, see
[INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md).
For common product and compatibility questions, see [FAQ.md](FAQ.md).

The current pinned flags are in the Makefile and recorded in
[NOTES.md](NOTES.md). Do not reuse flags from memory; Embedded Swift target
flags are toolchain-version-specific.

## Build

Build the kernel image:

```sh
make build
```

Build the packed base image:

```sh
make base-image
```

Build both plus the QEMU device tree used by `make run`:

```sh
make build base-image build/virt.dtb
```

The most important outputs are:

| Output | Purpose |
| --- | --- |
| `build/kernel.elf` | Kernel image loaded by QEMU `-kernel` |
| `build/base.img` | Packed read-only base filesystem |
| `build/virt.dtb` | QEMU `virt` device tree blob loaded into guest RAM |
| `build/swift-os.img` | UEFI boot disk image, when `make disk` is used |

## Boot In QEMU

The normal serial-console boot is:

```sh
make run
```

You should see early kernel logs, an interactive TTY smoke prompt, and then the
login prompt. At the smoke prompt, type a line when asked, press Enter, then
press Ctrl-C when the next prompt asks for it. The system then starts
`console-login`.

## First Login

Seeded accounts are stored in `base/etc/swos/passwd`.

| Login | Password | Principal | Capabilities |
| --- | --- | ---: | --- |
| `root` | `swordfish` | 1 | console, spawn, filesystem read, tmpfs write, process inspect, networking |
| `user` | `swordfish` | 2 | spawn, filesystem read, tmpfs write |
| `guest` | `guest` | 3 | spawn only |

Example session:

```text
swift-os login: root
Password:
Welcome to swift-os, root
session: principal=1 session=1 caps=63
```

Check your identity:

```sh
id
```

Expected root output:

```text
principal=1(root) session=1 caps=0x3f
```

## Try The System

List the root filesystem:

```sh
ls -l /
```

Read a base file:

```sh
cat /etc/motd
cat /hello.txt
```

Create scratch data in tmpfs:

```sh
mkdir /tmp/work
echo hello >/tmp/work/message.txt
cat /tmp/work/message.txt
rm /tmp/work/message.txt
rmdir /tmp/work
```

Inspect processes:

```sh
ps
top -b -n 2 -d 1
```

When booted through SMP test profiles, `top` also reports per-CPU busy/idle
utilization lines.

Use native Swift tools:

```sh
calc
kv
date
wc /etc/motd
head /etc/swos/passwd
```

`/tmp` is RAM-backed scratch storage. It is writable when your session has
`capTmpWrite`, and it is lost on reboot. The base filesystem is immutable and
read-only.

## Networking Quick Start

`make run` does not attach a NIC by default. To run network programs, build the
normal artifacts and launch QEMU with a virtio-net device:

```sh
make build base-image build/virt.dtb

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp::8080-:8080,hostfwd=tcp::5555-:5555,hostfwd=udp::5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

After logging in as `root`, serve the `/www` docroot over HTTP:

```sh
/bin/httpd
```

From the host:

```sh
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/hello.txt
```

Run a one-shot TCP echo server:

```sh
/bin/tcpecho
```

From the host:

```sh
printf 'hello tcp\n' | nc 127.0.0.1 5555
```

Run a one-shot UDP echo server:

```sh
/bin/udpecho
```

From the host:

```sh
printf 'hello udp' | nc -u 127.0.0.1 5555
```

Guest-initiated TCP can reach the host through QEMU slirp at `10.0.2.2`:

```sh
/bin/tcpget 10.0.2.2 5555
```

DNS defaults to QEMU slirp's resolver when the server IP is `0`:

```sh
/bin/nslookup example.com
```

For complete network launch profiles, service runbooks, TLS and IPv6 notes, and
network test coverage, see [NETWORKING_GUIDE.md](NETWORKING_GUIDE.md).

## UEFI Boot

Build the UEFI disk image:

```sh
make disk
```

Run the UEFI boot path:

```sh
make disk-run
```

Run with a graphical framebuffer window:

```sh
make run-gfx
```

See [VIRTUALBOX.md](VIRTUALBOX.md) for the VirtualBox ARM board notes.
See [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) when choosing between direct,
UEFI disk, graphical, and VirtualBox boot profiles.

## Tests

Run the normal test suite:

```sh
make test
```

Run the SMP smoke and readiness tests:

```sh
make smp-test
make s1-test
make smp-cpu-utilization-test
make s5-run-any-placement-test
make c5-test
```

Run focused package and ports fixture gates:

```sh
make package-local-install-test
make package-repo-install-test
make ports-catalog-test
make ports-recipe-test
make ports-lua-repo-fixture
make package-lua-repo-install-test
make ports-zlib-repo-fixture
make ports-seed-repo-fixture
make package-ports-seed-repo-install-test
make ports-static-host-publish
make package-static-host-repo-install-test
make ports-hosted-url-verify-test
make package-static-host-dns-repo-install-test
```

The test suite includes host-side Swift unit tests and in-QEMU boot assertions.
Some tests attach QEMU networking, drive the serial console through a FIFO, or
exercise the UEFI boot image.

## Clean Builds

Remove build artifacts:

```sh
make clean
```

`make clean` removes generated artifacts. Newlib, busybox, and model files are
expensive to rebuild; check [NOTES.md](NOTES.md) before cleaning during a
long-running development session.

## Troubleshooting

### QEMU exits immediately while dumping the DTB

The `build/virt.dtb` target intentionally runs QEMU with `-M virt,dumpdtb=...`.
That QEMU invocation exits after writing the DTB.

### Login succeeds but file commands fail

Check your capabilities:

```sh
id
```

`guest` has only the spawn-model authority bit, so shell builtins can work while
filesystem reads such as `cat /etc/motd` and directory listings are denied with
`EACCES`.

### Network programs fail at `socket`

Make sure QEMU was launched with `-netdev user,...` and a
`virtio-net-device`. The process also needs `capNet`; the seeded `root`
principal has it.

### Writes outside `/tmp` fail

That is expected. The base image is read-only by design. Use `/tmp` for scratch
state.
