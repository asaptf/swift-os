# SwiftOS Security Guide

This guide describes the current SwiftOS security model for operators,
application developers, and reviewers. It covers what is enforced today, how to
inspect it from the guest, and which parts remain roadmap work.

Use this guide with:

- [User Guide](USER_GUIDE.md) for shell behavior and available tools.
- [Administration Guide](ADMINISTRATION_GUIDE.md) for account and capability
  administration procedures.
- [API Reference](API_REFERENCE.md) for exact syscall and structure layouts.
- [Capabilities](CAPABILITIES.md) for the longer object-capability roadmap.
- [Troubleshooting](TROUBLESHOOTING.md) for failure diagnosis.

## Security Model At A Glance

SwiftOS is not Unix-root-centered. A process carries an explicit security
context:

```text
principal:u32
session:u32
capability-mask:u64
cell:u32
```

The current system enforces security through several layers:

| Layer | Current enforcement |
| --- | --- |
| Address spaces | Each EL0 process has its own user address space |
| User/kernel boundary | EL0 enters the kernel only through the SwiftOS syscall ABI |
| Identity | `console-login` authenticates a principal from `/etc/swos/passwd` |
| Coarse capabilities | Filesystem read, tmpfs write, console login, and networking are gated |
| Handle rights | File, pipe, tty, socket, IPC endpoint, and opaque device-grant handles carry per-handle rights |
| Immutable base | `/bin`, `/etc`, `/www`, and model files come from a read-only base image |
| Writable scratch | Runtime writes go to tmpfs and are lost on reboot |
| Memory permissions | `mmap`/`mprotect` reject writable-executable mappings |
| Package overlays | Package payloads are read-only images attached at boot |

The main design direction is to move from coarse process-wide bits toward
object-scoped handles. Some of that already exists in file descriptors,
`spawn_handles`, IPC handle transfer, and filesystem confinement; the broader
C-series capability work is tracked in [CAPABILITIES.md](CAPABILITIES.md).

## Current Guarantees

The checked-in system currently provides these practical guarantees:

1. An ordinary process cannot call `login()` to grant itself another principal
   or more capabilities unless it already holds `capConsole`.
2. A process without `capFsRead` cannot open base files or list directories.
3. A process without `capTmpWrite` cannot create, rename, unlink, chmod, or
   chown tmpfs nodes.
4. The base filesystem is read-only even for the fully capable seeded `root`
   principal.
5. A process without `capNet` cannot create sockets or use the kernel resolver.
6. Read and write operations on an already-open descriptor are checked against
   per-handle rights.
7. `spawn` starts a child with stdio only; `spawn_handles` starts a child with
   exactly the handles requested by the parent, with attenuated rights.
8. IPC handle passing moves one handle to the receiver and clears the sender's
   source fd on success.
9. C5b-C5f device discovery and opaque grants are metadata-only handles: the
   supervisor can discover `virtio-input.0` when QEMU exposes it or the
   `pseudo-input.0` fallback on headless boots, inspect the grant, observe
   virtio-mmio base/length as discovery metadata, prove future authority bits
   stay clear, prove current grant rights remain metadata-only, and prove
   ownership movement, but cannot use it for MMIO, IRQ, DMA, or real
   virtio-input queue access.
10. Device discovery and claiming are gated to the boot authority; claimed
    device grants are inspectable and transferable but not duplicable.
11. `confine(path)` can narrow a process to a filesystem subtree and cannot widen
   an existing confinement.
12. `mmap`/`mprotect` reject `PROT_WRITE | PROT_EXEC`.

## Current Limits

The current model is useful and testable, but it is not the final security
architecture.

| Limit | Meaning |
| --- | --- |
| Coarse capability bits | `capFsRead` covers the readable namespace; it is not yet `fs:read:/one/subtree` |
| No production password policy | Passwords are salted SHA-256, not a memory-hard KDF |
| No target-side account management | Accounts are edited in `base/etc/swos/passwd` and repacked into the image |
| No persistent user data store | `/tmp` is scratch; reboot clears it |
| `capSpawn` and `capProcessInspect` are scaffold bits | They are part of the identity model, but not the main enforcement boundary yet |
| `capLogExport` is reserved | No seeded account receives it by default |
| Drivers and networking are still in kernel | C5d proves virtio-input or pseudo fallback discovery metadata plus an opaque device grant, but real MMIO/IRQ/DMA driver handoff remains roadmap work |
| Single global cell today | `CellId` exists as a field; real Cells are future work |

Do not describe the current system as a finished object-capability OS. It is a
capability-aware OS with an active migration path toward object-scoped authority.

## Accounts And Identity Store

The identity store lives in the immutable base image:

```text
/etc/swos/passwd
```

The source file is:

```text
base/etc/swos/passwd
```

Each non-comment line has this shape:

```text
name:principal:session:caps:salt$sha256hex:shell
```

The password hash is:

```text
SHA-256(salt + password)
```

This is better than plaintext for the current bring-up image, but it is not a
production password storage policy. A stronger KDF and password rotation
workflow remain future hardening work.

Seeded accounts:

| Login | Password | Principal | Session | Caps decimal | Caps hex | Purpose |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `root` | `swordfish` | 1 | 1 | 63 | `0x3f` | Full seeded authority except reserved log export |
| `user` | `swordfish` | 2 | 2 | 14 | `0x0e` | Spawn, filesystem read, tmpfs write |
| `guest` | `guest` | 3 | 3 | 2 | `0x02` | Restricted capability checks |

Compatibility files:

```text
/etc/passwd
/etc/group
```

These exist for userland compatibility. They are not the kernel's source of
security policy.

## Capability Bits

The capability constants are defined in `kernel/security/security.swift`.

| Bit | Name | Mask | Current role |
| ---: | --- | ---: | --- |
| 0 | `capConsole` | `0x01` | Allows `SYS_LOGIN` to adopt an authenticated context |
| 1 | `capSpawn` | `0x02` | Identity-model spawn authority bit; seeded accounts use it |
| 2 | `capFsRead` | `0x04` | Allows filesystem opens that read |
| 3 | `capTmpWrite` | `0x08` | Allows tmpfs writes and namespace mutations |
| 4 | `capProcessInspect` | `0x10` | Identity-model process-inspection authority bit |
| 5 | `capNet` | `0x20` | Allows sockets and DNS resolver use |
| 6 | `capLogExport` | `0x40` | Reserved for future log export and sink installation |

Check the current process:

```sh
id
```

Examples:

```text
principal=1(root) session=1 caps=0x3f
principal=2(user) session=2 caps=0xe
principal=3 session=3 caps=0x2
```

`/bin/id` prints the numeric context even when it cannot read the identity store
to resolve a name.

## Login Flow

The boot context starts with:

```text
principal=1 session=1 caps=capConsole|capSpawn|capFsRead|capTmpWrite|capProcessInspect|capNet
```

`/bin/console-login` runs as init, reads `/etc/swos/passwd`, prompts for a login
name and password, verifies the salted SHA-256 password field, calls
`SYS_LOGIN`, and then `execve`s the configured shell.

Important behavior:

- Password input is not echoed.
- Wrong passwords return to the login prompt.
- `SYS_LOGIN` is denied unless the caller holds `capConsole`.
- The adopted principal, session, and capability mask survive the exec into the
  shell.
- When the shell exits, init returns to a fresh login prompt.

Acceptance evidence:

```sh
./tests/console_login_test.sh
```

## Filesystem Security

SwiftOS has a two-tier filesystem:

| Tier | Writable | Authorization |
| --- | --- | --- |
| Packed base image | No | Reads require `capFsRead` |
| tmpfs scratch | Yes | Reads require `capFsRead`; writes require `capTmpWrite` |

The open path enforces:

| Operation | Required capability |
| --- | --- |
| Open for read | `capFsRead` |
| Open for write | `capTmpWrite` |
| `O_CREAT` | `capTmpWrite` |
| `O_TRUNC` | `capTmpWrite` |
| `mkdir`, `rmdir`, `unlink`, `rename` | `capTmpWrite` |
| `chmod`, `chown` | `capTmpWrite` |

The base image stays read-only even when the caller has `capTmpWrite`.

Example: restricted guest cannot read the filesystem:

```sh
id
cat /etc/motd
ls /
```

Expected guest context:

```text
principal=3 session=3 caps=0x2
```

Expected read/list failures include:

```text
can't open '/etc/motd'
can't open '/'
```

Acceptance evidence:

```sh
./tests/cap_enforce_test.sh
```

Example: `user` can read and write tmpfs, but not network:

```sh
id
cat /etc/motd
echo ok >/tmp/user-ok.txt
cat /tmp/user-ok.txt
/bin/nslookup example.com
```

The file operations should work. The network command should fail without
`capNet`.

## File Ownership And Modes

Base image files and tmpfs nodes carry owner and mode metadata. `ls -l` displays
that metadata:

```sh
ls -l /etc
echo sample >/tmp/mode-demo
chmod 600 /tmp/mode-demo
chown 2 /tmp/mode-demo
ls -l /tmp/mode-demo
```

Current authorization is still capability-first. Mode and owner metadata are
visible and useful for compatibility, but the capability checks above are the
primary enforcement boundary.

Acceptance evidence:

```sh
./tests/ls_l_test.sh
./tests/swift_chmodown_test.sh
```

## Handle Rights

Every open file, pipe, tty, socket, IPC endpoint, or opaque device grant is
represented as a per-process descriptor with a handle kind and rights. Rights
are defined in
`userland/lib/syscall.h` and `kernel/vfs/handle.swift`.

Common rights:

| Right | Meaning |
| --- | --- |
| `READ` | May read from the handle |
| `WRITE` | May write to the handle |
| `DUPLICATE` | May duplicate the handle |
| `TRANSFER` | May pass or move the handle through supported APIs |
| `GETATTR` | May inspect handle metadata |
| `SETATTR` | May change supported metadata |

The open mode determines the read/write rights on a file handle. Subsequent
`read`, `write`, `ftruncate`, `poll`, and socket operations check the handle's
rights, not only the process capability mask.

### Spawn With Explicit Handles

Plain `spawn` starts the child with stdio only. Use `spawn_handles` when a child
needs a specific file, pipe, socket, or endpoint.

The parent supplies:

```c
struct swiftos_spawn_handle {
    int source_fd;
    int target_fd;
    unsigned int rights;
    unsigned int flags;
};
```

The child receives only the listed handles. Requested rights are attenuated: the
child cannot receive rights the parent handle does not hold.

### IPC Handle Transfer

IPC endpoints can send bytes and optionally move one handle. On successful
transfer:

1. The sender's source fd is cleared.
2. The receiver gets a new fd.
3. Endpoint send requires write and transfer rights.
4. Endpoint receive requires read rights, and transfer rights when importing a
   transferred handle.

Acceptance evidence:

```sh
./tests/spawn_self_exec_test.sh
./tests/ipc_socket_transfer_test.sh
```

### Opaque Device Grants

C5b adds the first device-shaped handle, C5c adds discovery metadata/manifest
matching, C5d keeps the discovered virtio-mmio base and length visible as
non-authoritative metadata, C5e proves future hardware-authority bits stay
clear, and C5f proves the current grant rights remain metadata-only for the
checked-in driver-service smoke. The
supervisor discovers the current input grant with `device_discover`, claims the
discovered name with `device_claim`, checks its metadata with `device_info`,
moves it to `/bin/drvinputd` over an IPC endpoint, and then proves the registry
reports the device as busy until the service exits and closes its final fd.

Security properties:

- The grant is a handle, not a global permission bit.
- Discovery returns metadata for the current input grant and then reports
  exhaustion. In the focused gate that grant is `virtio-input.0`; in headless
  boots it is `pseudo-input.0`.
- The sender loses the fd when `ipc_send` moves the handle.
- A second `device_claim` of the discovered name returns `-16` while the
  service owns the live grant.
- The C5e metadata always carries `SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT` and keeps
  the `SWIFTOS_DEVICE_FLAG_HARDWARE_AUTHORITY` mask clear.
  `virtio-input.0` includes MMIO base/length as manifest metadata only; there is
  still no userland mapping, IRQ endpoint, DMA window, or queue ownership.
- C5f keeps the grant's runtime rights at metadata-only authority: no accidental
  read, write, transfer, or map expansion is accepted as real hardware access.
- Closing the final device fd releases the claim.

This is a security boundary smoke, not a production driver sandbox. Real device
handoff still needs MMIO-range handles, IRQ endpoints, DMA windows, and a real
userland driver.

Acceptance evidence:

```sh
make c5-device-metadata-test
```

`make c5-device-discovery-test` and `make c5-device-handle-test` remain
compatible aliases through the same driver-service harness.

## Filesystem Confinement

`confine(path)` narrows the current process to a filesystem subtree. It is
confine-only: a process can move to the same or a deeper subtree, but cannot
widen its view after confinement.

Developer example:

```c
#include "lib/syscall.h"

int main(void) {
    if (confine("/www") < 0) {
        write(2, "confine failed\n", 15);
        return 1;
    }
    /* Opens outside /www are denied from this point. */
    return 0;
}
```

Confinement is a current object-scoped primitive and a step toward the stronger
handle/cell model.

## Network Security

Network authority is currently coarse:

```text
capNet
```

A process without `capNet` cannot create sockets and cannot use the kernel DNS
resolver. `root` has `capNet` in the seeded image; `user` and `guest` do not.

Operational example:

```sh
/bin/nslookup example.com
/bin/httpd
/bin/tcpecho
/bin/udpecho
```

These require both:

1. QEMU launched with virtio-net.
2. A principal holding `capNet`.

Longer term, the architecture wants object-scoped grants such as
`net:listen:tcp:8080`, not one global network bit. That transition is part of
the C-series and service-ization roadmap.

Acceptance evidence:

```sh
./tests/virtio_net_test.sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/dns_test.sh
```

## Memory Security

EL0 programs run in separate user address spaces. The kernel validates user
buffers before copying data across the syscall boundary.

Memory mapping rules:

- `mmap` creates anonymous user memory.
- `munmap` removes mappings.
- `mprotect` changes permissions.
- `PROT_WRITE | PROT_EXEC` is rejected.

This supports a W^X discipline for future language runtimes. A JIT-style flow
must map writable memory, write code, switch it to executable with `mprotect`,
and then execute.

Acceptance evidence:

```sh
./tests/mmap_test.sh
```

## Immutable Base And Package Security

Installed system files come from immutable images:

- `build/base.img` for the base OS and `/bin` tools.
- Package payload images for `/usr` overlays.

Operational consequences:

1. A running guest cannot edit `/bin`, `/etc`, `/www`, or `/models`.
2. Changing base content requires rebuilding `build/base.img`.
3. Package overlay content is attached read-only at boot.
4. Local `pkg install FILE` can activate a local `.swpkg` through a writable
   package-store image, but package payload content remains read-only once
   active.
5. `pkg repo set URL` and `pkg update [URL]` verify a signed repository
   catalog, reject expired or incompatible metadata, validate dependency
   entries, and `pkg install NAME` verifies downloaded package hashes before
   reusing the local package-store install path.
6. Remove, upgrade, rollback, version-constraint solving, public hosted package
   channels, and package-level publisher signatures are not implemented yet.

The host `.swpkg` tool verifies package structure and payload hashes. Repository
signatures authenticate the fixture catalog, while catalog expiry,
target compatibility, dependency validation, and package SHA-256 checks reject
common stale or tampered repository states. Broader public repository policy
remains later package-management work.

Acceptance evidence:

```sh
./tests/vfs_disk_test.sh
make package-overlay-test
make package-local-install-test
```

## Security Checklist

Before using an image as a security demo, verify:

```sh
make build
./tests/console_login_test.sh
./tests/cap_enforce_test.sh
./tests/ls_l_test.sh
./tests/swift_chmodown_test.sh
./tests/spawn_self_exec_test.sh
./tests/ipc_socket_transfer_test.sh
make c5-device-metadata-test
./tests/mmap_test.sh
make package-overlay-test
```

For a broader release gate:

```sh
make test
```

## Reporting Security Issues

Include:

- Git commit and branch.
- Exact QEMU command.
- Serial log around the first failure.
- Account used and output of `id`.
- Whether the issue involves process identity, filesystem access, handle
  inheritance, IPC transfer, networking, memory permissions, or packages.
- The targeted test that should have caught it, if one exists.

If a security behavior is not backed by code and an acceptance test, treat it as
roadmap language rather than current product behavior.
