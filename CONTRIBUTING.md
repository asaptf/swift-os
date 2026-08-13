<!-- SPDX-License-Identifier: Apache-2.0 -->

# Contributing to swift-os

Thanks for looking. swift-os is a learning-first operating system written in
Embedded Swift — small, testable, and deliberately free of legacy surface. Help
is welcome, and the rules below exist to keep the core small enough to trust.

Start here if you want a task: the [good first issues][gfi]. If you want to
understand the system first, read [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md),
then [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/PHILOSOPHY.md](docs/PHILOSOPHY.md).

[gfi]: https://github.com/asaptf/swift-os/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22

## Get a build running first

Nothing else matters until you can boot the kernel yourself. On macOS (Apple
Silicon) or Linux:

```sh
make newlib && make busybox   # one-time: cross-build the libc + bring-up shell
make tools-check              # verify toolchain paths
make build && make run        # boot under QEMU virt (exit the serial with Ctrl-A X)
make test                     # host unit tests + in-QEMU boot assertions
```

Toolchain versions and the exact Embedded Swift flags are pinned in
[docs/NOTES.md](docs/NOTES.md) — they are **toolchain-version-specific**. Do not
copy flags from another project or from memory; confirm them against the
installed toolchain. If a build fails, [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
covers the common causes before you file an issue.

## The rules that are not up for debate

These are first principles of the project, not preferences. A change that
violates one will be asked to change direction, however good the code is.

1. **Swift by default.** Kernel, userland utilities and host tooling are written
   in Embedded Swift (host Swift for build tools). C or assembly is acceptable
   only for third-party code we don't own (busybox, the newlib port), for
   low-level bridges Swift cannot express (volatile MMIO, syscall/runtime shims,
   boot and exception assembly), or for a measured toolchain limitation recorded
   in [docs/NOTES.md](docs/NOTES.md). Prefer rewriting existing C in Swift over
   extending it.
2. **Freestanding kernel style.** No Foundation, no full standard library. Value
   types and `Unsafe*` pointers at the low level; `~Copyable` structs with
   `deinit` for resource ownership; classes only above the heap, and sparingly
   (ARC has a cost).
3. **No new legacy surface.** No Linux ABI, no dynamic linking, no
   amd64/x86-64 — see the Non-Goals section of the [README](README.md#non-goals-minimalism-by-removing-legacy).
   Minimalism here comes from *removing* legacy, not emulating it.
4. **Correctness is proven by tests.** Every change that can be observed from the
   outside ships an executable check — a host unit test, an in-QEMU boot
   assertion, or both. See [docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md).
5. **Every new source file we author starts with an SPDX header.**
   `// SPDX-License-Identifier: Apache-2.0` for Swift/C/headers/assembly,
   `# SPDX-License-Identifier: Apache-2.0` for shell, Make and linker scripts.
   Vendored files keep their upstream headers untouched.
6. **English for all code, comments, docs and commit messages.**

If you think one of these is wrong for your change, open an issue and make the
argument before writing the code — that discussion is welcome; a surprise pull
request that re-litigates it is wasted work.

## Making a change

Small changes (a doc fix, a missing test, a userland utility flag) need no
discussion — send the pull request. For anything that touches the kernel,
the syscall ABI, the base-image format, or the capability model, **open an issue
first** and agree on the shape. The project moves one reviewable milestone at a
time, and a large unstable leap is harder to accept than three small ones.

Before you push:

```sh
make build            # it compiles
make run              # it still boots
make test             # host unit tests + QEMU boot assertions pass
```

Also run the focused gate that covers your area, when there is one — for
example `make smp-test`, `make datafs-sqlite-test`, `make nginx-test`,
`make node-test`, `make c5-test`. [docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md)
maps areas to gates.

Then:

- One logical change per pull request, with a clear title and a description of
  **what** changed and **why**. Match the surrounding code style, including
  comment density.
- No dead or half-finished files, no commented-out code, no unrelated
  reformatting mixed into a functional change.
- Update the docs you invalidate. This repository treats
  [docs/](docs/DOCUMENTATION.md) as part of the product; a syscall or command
  change that leaves the reference stale is incomplete.
- Say in the pull request which gates you ran and on what host (macOS Apple
  Silicon or Linux, QEMU version). CI runs the same suite, but the reviewer
  needs to know what you actually saw.

## What is especially useful right now

- **Ports.** Cross-building another static program against the swift-os ABI and
  packaging it — see [docs/PORTING_GUIDE.md](docs/PORTING_GUIDE.md) and
  [ports/README.md](ports/README.md). Each successful port is direct evidence the
  ABI is real.
- **Native Swift userland utilities.** Replacing a busybox tool with an
  Embedded Swift one over the `userland/lib/swift_user.*` bridge — see
  [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md).
- **New hardware bring-up.** Boards beyond QEMU `virt` and Hetzner Cloud ARM
  (Raspberry Pi in particular) — see [docs/PORTING_GUIDE.md](docs/PORTING_GUIDE.md).
- **Tests for existing behaviour.** Anything currently proven only by reading the
  code is worth an executable check.
- **Documentation gaps.** If a guide sent you the wrong way, fixing it is a real
  contribution.

## Reporting bugs and security issues

Functional bugs go to the [issue tracker](https://github.com/asaptf/swift-os/issues)
with the serial log attached and the exact `make` invocation you used;
[docs/SUPPORT_GUIDE.md](docs/SUPPORT_GUIDE.md) describes how to collect evidence.

**Do not open a public issue for a security vulnerability** — follow
[SECURITY.md](SECURITY.md) instead.

## Licensing of contributions

swift-os is licensed under the Apache License 2.0 (see [LICENSE](LICENSE) and
[NOTICE](NOTICE)). By opening a pull request you agree that your contribution is
licensed under the same terms. Do not paste code from a source whose license you
have not checked — in an OS kernel that is a real problem, not a formality.
Bundled third-party components keep their own licenses (busybox is GPL-2.0-only,
the newlib port is BSD-style); do not copy code between them and our Apache-2.0
sources.
