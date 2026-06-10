# SwiftOS User Guide

This guide describes how to use the current SwiftOS system from the serial
console. It is written for operators, testers, and application developers who
need to understand what is available inside a running guest.

## Console Model

SwiftOS is currently headless by default. The primary UI is the serial console
provided by QEMU `-nographic`.

The boot flow is:

1. Kernel initializes hardware, memory, scheduler, VFS, security, and userland.
2. The early tty demo may ask for one input line and then a Ctrl-C.
3. `/bin/console-login` starts as init.
4. After authentication, the configured shell is executed.
5. When the shell exits, `console-login` is started again for the next session.

There is no graphical desktop shell in the current product profile.

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
| 6 | `capLogExport` | Reserved for future log export authority |

Capabilities are not Unix uid 0. They are explicit process authority bits. File
handles also carry per-handle rights; see [API_REFERENCE.md](API_REFERENCE.md)
for handle rights.

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
echo abc >/tmp/mode-demo
chmod 600 /tmp/mode-demo
chown 2 /tmp/mode-demo
ls -l /tmp/mode-demo
```

Writes to the base image fail by design:

```sh
echo no >/etc/motd
```

Use `/tmp` for runtime scratch state.

## Programs In `/bin`

The base image stages native Swift programs, C demos, and busybox.

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
| `udpecho`, `tcpecho`, `tcpget`, `tlsget`, `nslookup`, `httpd` | Network tools |
| `threadsdemo`, `mmapdemo` | Runtime and VM demos |

Busybox is staged as `/bin/busybox` and is used for the login shell. It is a
legacy bring-up and compatibility tool, not the long-term application model.

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

Interactive `top` uses raw terminal mode. Press `q` to quit.

## Networking

Network use requires:

1. QEMU launched with a virtio-net device.
2. A process with `capNet` (`root` has it in the seeded image).

See [GETTING_STARTED.md](GETTING_STARTED.md) for a full QEMU launch command with
host forwarding.

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

### TLS Demo

`/bin/tlsget` contains the current userland TLS client groundwork. Certificate
verification is deliberately incomplete in the current branch; use it as a TLS
runtime demo, not as a production trust decision.

## Runtime Demos

### Threads

Run the EL0 thread/futex demo:

```sh
/bin/threadsdemo
```

It creates EL0 threads in one address space and uses futex-backed synchronization
to prove correct shared counter updates.

### mmap And W^X

Run the anonymous mmap, mprotect, and W^X demo:

```sh
/bin/mmapdemo
```

The demo maps zero-filled RAM, writes and reads across a page boundary, switches
a page from RW to RX for a small JIT-style call, and confirms RWX mappings are
rejected.

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

## Known Current Limits

These are current implementation boundaries, not necessarily design goals:

- No Linux syscall ABI.
- Static userland only; no dynamic loader.
- No persistent writable filesystem.
- No general package install flow inside the guest yet.
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
