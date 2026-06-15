<!-- SPDX-License-Identifier: Apache-2.0 -->
# node-compat — Linux-API shims for the Node.js / libuv masquerade

These headers exist only for the SwiftOS Node.js port (`ports/lang/nodejs`),
whose first build pass targets `--dest-os=linux` (NPM27) and therefore compiles
libuv's Linux backend (`deps/uv/src/unix/linux.c`). That backend pulls a handful
of Linux-only headers that newlib and `userland/compat` do not provide.

This directory is **deliberately separate from `userland/compat`** so that adding
Linux-API surfaces (epoll, inotify, …) cannot change feature detection for the
other source ports (nginx, curl, …) that build against the shared compat layer.
`scripts/build-node.sh` puts this directory on the include path ahead of
`userland/compat` for the Node build only.

The headers declare exactly the subset libuv references. The behavioural
implementations (epoll over `poll`/`eventfd`, `getifaddrs`, inotify, `prctl`,
raw `syscall` returning `-ENOSYS`, `dlopen` stubs) are provided by a companion
compat translation unit and tracked as separate NPM milestones (NPM29+).
SwiftOS has `poll`, `eventfd`, and futex but no `epoll`; epoll is therefore
emulated over `poll` rather than shimmed 1:1.
