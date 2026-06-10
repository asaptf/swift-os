# SwiftOS Command Reference

This reference describes the commands shipped by the current checked-in
SwiftOS base image and package overlay. It is written for people using the
serial console, writing acceptance tests, or building native applications that
need to understand the operating environment.

SwiftOS intentionally has a small command surface. The system favors native,
static tools that exercise the SwiftOS syscall ABI over a broad Unix-compatible
userland. Busybox is present as the login shell and bring-up compatibility
layer, but the long-term application model is native SwiftOS programs.

## Command Environment

Commands normally run after logging in on the serial console. The seeded
accounts are described in [USER_GUIDE.md](USER_GUIDE.md).

Important environment rules:

- The immutable base image provides `/bin`, `/etc`, `/www`, model files, and
  read-only sample content.
- `/tmp` is RAM-backed tmpfs scratch space. It is lost on reboot.
- Mutating `/tmp` requires `capTmpWrite`.
- Reading files requires `capFsRead`.
- Spawning commands requires `capSpawn`.
- Process inspection requires the current process to have the inspection
  authority used by the kernel path.
- Networking commands require a virtio-net device and `capNet`.
- Package overlay commands require a mounted package payload.

Most examples assume the `root` account from the seeded image because it has
the full current capability mask.

## Console And Shell

SwiftOS is headless by default. QEMU provides the primary serial console with
`-nographic`.

The login shell is busybox `ash`, started by `/bin/console-login`. It supports
normal command execution, pipes, redirection, and the PATH used by the base
image. The examples below can be pasted at the shell prompt after login.

```sh
pwd
ls -l /
cat /etc/motd
echo hello >/tmp/hello.txt
cat /tmp/hello.txt | wc
ps
id
exit
```

## Core Commands

### `ls`

List directory entries or show a single file.

```text
ls [-l] [PATH]
```

Examples:

```sh
ls /
ls -l /bin
ls -l /tmp/work/file.txt
```

Notes:

- With no path, `ls` lists the current working directory.
- `-l` prints mode, owner, group, size, timestamp, and name.
- Owner and group names are resolved from `/etc/passwd` and `/etc/group` when
  available; otherwise numeric IDs are printed.
- A non-directory path is printed directly.

Acceptance coverage: `tests/swift_ls_test.sh`, `tests/ls_l_test.sh`,
`tests/swift_fileops_test.sh`, `tests/swift_chmodown_test.sh`.

### `cat`

Print file contents, or copy standard input to standard output.

```text
cat [FILE...]
```

Examples:

```sh
cat /etc/motd
cat /readme.txt /hello.txt
echo hello | cat
```

Notes:

- With no file arguments, `cat` reads stdin.
- Missing or unreadable files report `cat: cannot open file`.

Acceptance coverage: `tests/swift_coreutils_test.sh`.

### `echo`

Print arguments separated by spaces.

```text
echo [-n] [ARG...]
```

Examples:

```sh
echo hello SwiftOS
echo -n prompt:
echo data >/tmp/data.txt
```

Notes:

- `-n` suppresses the trailing newline.
- The native SwiftOS implementation does not interpret backslash escapes.

Acceptance coverage: `tests/swift_coreutils_test.sh`.

### `pwd`

Print the current working directory.

```text
pwd
```

Examples:

```sh
pwd
cd /etc
pwd
```

Acceptance coverage: `tests/swift_coreutils_test.sh`.

### `id`

Print the current principal, session, and capability mask.

```text
id
```

Examples:

```sh
id
```

Example output:

```text
principal=1(root) session=1 caps=0x3f
principal=3 session=3 caps=0x2
```

Notes:

- Principal names are shown when the process can read the identity store.
- Without filesystem read authority, the numeric principal is still printed.

Acceptance coverage: `tests/busybox_test.sh`, `tests/cap_enforce_test.sh`.

### `ps`

Print a process snapshot.

```text
ps [-eA] [-f] [-p pid[,pid...]] [-o pid,ppid,state,stat,user,uid,cmd]
ps aux
```

Examples:

```sh
ps
ps -f
ps -p 1,2
ps -o pid,ppid,state,cmd
ps aux
```

Notes:

- `-e` and `-A` select the full process list.
- `-f` prints the fuller user/PID/PPID/state/command format.
- `-p` filters by one or more process IDs.
- `-o` accepts a comma-separated field list. Supported fields are `pid`,
  `ppid`, `state`, `stat`, `user`, `uid`, and `cmd`.
- `ps aux` is accepted as a familiar compatibility spelling.

Acceptance coverage: `tests/busybox_test.sh`, `tests/disk_exec_test.sh`.

### `top`

Print system and process statistics.

```text
top [-b] [-d secs] [-n iterations]
```

Examples:

```sh
top -b -n 1
top -b -n 2 -d 1
top
```

Notes:

- `-b` uses batch mode. It does not clear the screen or use raw input.
- `-d` sets the refresh delay in seconds.
- `-n` exits after the selected number of refreshes.
- SMP test profiles include per-CPU busy/idle utilization lines.
- Interactive mode accepts `q` to quit.

Acceptance coverage: `tests/top_test.sh`, `make smp-cpu-utilization-test`,
`make s5-el0-fanout-test`.

## File And Tmpfs Commands

SwiftOS has an immutable base image and a writable `/tmp`. The commands in this
section are mainly useful for `/tmp` workflows.

### `mkdir`

Create one or more directories.

```text
mkdir DIR...
```

Examples:

```sh
mkdir /tmp/work
mkdir /tmp/a /tmp/b
```

Acceptance coverage: `tests/swift_fileops_test.sh`.

### `rmdir`

Remove one or more empty directories.

```text
rmdir DIR...
```

Examples:

```sh
rmdir /tmp/work
```

Notes:

- The directory must be empty.
- Use `rm -r` for recursive removal of a tmpfs tree.

Acceptance coverage: `tests/swift_fileops_test.sh`.

### `rm`

Remove files, or recursively remove directories.

```text
rm [-rRf] FILE...
```

Examples:

```sh
rm /tmp/work/file.txt
rm -r /tmp/work
rm -f /tmp/missing
```

Notes:

- `-r` and `-R` enable recursive directory removal.
- `-f` ignores missing paths.
- Directories are rejected unless recursive removal is selected.

Acceptance coverage: `tests/swift_fileops_test.sh`,
`tests/swift_rm_r_test.sh`.

### `mv`

Rename or move a tmpfs path.

```text
mv SRC DST
```

Examples:

```sh
mv /tmp/work/a.txt /tmp/work/b.txt
```

Acceptance coverage: `tests/swift_fileops_test.sh`.

### `chmod`

Change tmpfs file mode bits.

```text
chmod OCTAL FILE...
```

Examples:

```sh
chmod 600 /tmp/secret.txt
chmod 644 /tmp/public.txt
```

Notes:

- The mode must be octal.
- The current implementation is for tmpfs metadata, not for mutating the packed
  read-only base image.

Acceptance coverage: `tests/swift_chmodown_test.sh`.

### `chown`

Change tmpfs file owner to a numeric principal ID.

```text
chown UID FILE...
```

Examples:

```sh
chown 2 /tmp/user-owned.txt
```

Notes:

- Owner names are not parsed. Use a numeric principal ID.
- Seeded principal IDs are listed in [USER_GUIDE.md](USER_GUIDE.md).

Acceptance coverage: `tests/swift_chmodown_test.sh`.

### `head`

Print the first lines of files or standard input.

```text
head [-n N|-nN] [FILE...]
```

Examples:

```sh
head /etc/motd
head -n 3 /readme.txt
cat /readme.txt | head -n2
```

Notes:

- With no file arguments, `head` reads stdin.
- The default limit is 10 lines.

Acceptance coverage: `tests/swift_headwc_test.sh`.

### `touch`

Create files if they do not already exist.

```text
touch FILE...
```

Examples:

```sh
touch /tmp/empty
ls -l /tmp/empty
```

Notes:

- `touch` is most useful in `/tmp`, where the process can create files.

Acceptance coverage: `tests/swift_headwc_test.sh`.

### `wc`

Count lines, words, and bytes.

```text
wc [FILE...]
```

Examples:

```sh
wc /etc/motd
cat /etc/motd | wc
```

Notes:

- With no file arguments, `wc` reads stdin.
- Output is `lines words bytes` plus the file name for file arguments.

Acceptance coverage: `tests/swift_headwc_test.sh`.

### `date`

Print the current UTC wall-clock time.

```text
date
```

Examples:

```sh
date
```

Notes:

- The time path reads the PL031 RTC provided by the QEMU virt platform.

Acceptance coverage: `tests/swift_date_test.sh`.

## Networking Commands

Networking commands require a QEMU virtio-net device and `capNet`. The examples
below assume the standard slirp setup from [GETTING_STARTED.md](GETTING_STARTED.md).
For complete QEMU profiles, host-forwarding rules, and network test coverage,
see [NETWORKING_GUIDE.md](NETWORKING_GUIDE.md).

### `httpd`

Serve static files from `/www`.

```text
httpd [6|-6]
```

Examples in the guest:

```sh
/bin/httpd
/bin/httpd -6
```

Examples on the host, when TCP port 8080 is forwarded:

```sh
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/hello.txt
```

Notes:

- IPv4 mode listens on TCP port 8080.
- `6` or `-6` selects the IPv6 socket path.
- `/` maps to `/www/index.html`.
- Other request paths are resolved under `/www`.
- The server is poll-driven and can service multiple live connections.

Acceptance coverage: `tests/httpd_test.sh`,
`tests/net_zero_copy_throughput_test.sh`.

### `llmd`

Serve TinyStories completions over HTTP from the native Embedded Swift inference
engine.

```text
llmd [model.bin] [tokenizer.bin]
```

Examples in the guest:

```sh
/bin/llmd
```

Examples on the host, when TCP port 8080 is forwarded:

```sh
curl http://127.0.0.1:8080/health
curl -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl http://127.0.0.1:8080/metrics
```

Endpoints:

| Endpoint | Method | Response |
| --- | --- | --- |
| `/health` | `GET` | Liveness plus model shape |
| `/completion` | `POST` | Generated text for the request body prompt |
| `/metrics` | `GET` | `requests`, `tokens_total`, `last_ttft_ms`, `last_tok_s` |

Notes:

- `llmd` listens on TCP port 8080, the same guest port used by `httpd`; run one
  server at a time.
- By default, the daemon resolves the verified bundle rooted at
  `/models/stories15M`.
- Bundle generations live under
  `/models/stories15M/<generation>/{manifest.toml,model.bin,tokenizer.bin}`.
  The loader tries numeric generations newest-first, requires a valid Ed25519
  manifest signature when `/etc/swos/model-signing.pub` is present, rejects
  malformed manifests or hash/size-mismatched payloads, and serves the newest
  verified generation.
- The checked-in base image deliberately includes a corrupt generation 2 and a
  valid generation 1, so a healthy default boot logs the generation 2 rejection
  and then verifies generation 1.
- The default serving checkpoint is Q8_0 int8 with group size 32; startup logs
  `llmd: model int8 Q8_0 GS=32`.
- Optional positional arguments select another checkpoint and tokenizer pair:
  `llmd [model.bin] [tokenizer.bin]`. Raw path overrides bypass bundle manifest
  signature and payload-hash verification; the loader still detects supported
  fp32 and Q8 checkpoint formats at runtime.
- Model weights are mapped from the read-only base image with file-backed mmap.
- The default generation length is 64 tokens.
- Generation runs inline on the current single-core system. Other connections
  can queue while one request is generating.
- Socket creation still requires `capNet`.

Acceptance coverage: `tests/llm_serve_test.sh`.

For the full serving runbook, bundle layout, health and metrics semantics, and
support evidence checklist, see [AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

### `tcpecho`

Run a one-shot TCP echo server.

```text
tcpecho [6|-6]
```

Examples in the guest:

```sh
/bin/tcpecho
/bin/tcpecho -6
```

Example on the host, when TCP port 5555 is forwarded:

```sh
printf 'swos tcp\n' | nc 127.0.0.1 5555
```

Notes:

- The server listens on TCP port 5555.
- It accepts one connection, echoes one received chunk, prints the byte count,
  and exits.
- `6` or `-6` selects the IPv6 socket path.

Acceptance coverage: `tests/tcp_echo_test.sh`,
`tests/ipv6_tcp_echo_test.sh`.

### `udpecho`

Run a one-shot UDP echo server.

```text
udpecho [6|-6]
```

Examples in the guest:

```sh
/bin/udpecho
/bin/udpecho -6
```

Example on the host, when UDP port 5555 is forwarded:

```sh
printf 'swos udp' | nc -u 127.0.0.1 5555
```

Notes:

- The server binds UDP port 5555.
- It receives one datagram, echoes it, prints sender information, and exits.
- `6` or `-6` selects the IPv6 socket path.

Acceptance coverage: `tests/udp_echo_test.sh`,
`tests/ipv6_udp_echo_test.sh`.

### `tcpget`

Connect to a TCP server, send one request line, and print the reply.

```text
tcpget [ip] [port]
```

Examples:

```sh
/bin/tcpget
/bin/tcpget 10.0.2.2 5555
```

Notes:

- The default target is `10.0.2.2:5555`, the usual QEMU slirp host alias.
- The client sends `GET swos\n`.
- It prints connection status, bytes sent, and received data.

Acceptance coverage: `tests/tcp_connect_test.sh`.

### `tlsget`

Connect to a TLS server, perform the current TLS 1.3 client flow, and print
decrypted response body bytes.

```text
tlsget [ip] [port] [host]
```

Examples:

```sh
/bin/tlsget 10.0.2.2 443 localhost
```

Notes:

- The default target is `10.0.2.2:443` with host `localhost`.
- The client sends an HTTPS `GET / HTTP/1.1` request after the handshake.
- Certificate verification is not complete in this branch. Treat `tlsget` as a
  TLS runtime demo and interoperability test, not as a production trust
  decision.

Acceptance coverage: `tests/tls_test.sh`.

### `nslookup`

Resolve a DNS name through UDP.

```text
nslookup <name> [server-ip] [port] [AAAA]
```

Examples:

```sh
/bin/nslookup example.com
/bin/nslookup test.swos 10.0.2.2 5354
/bin/nslookup example.com 10.0.2.3 53 AAAA
```

Notes:

- With no server, SwiftOS uses the QEMU slirp DNS server.
- `server-ip` may be IPv4 or a full eight-group IPv6 address.
- The optional final `AAAA` requests IPv6 records.

Acceptance coverage: `tests/dns_test.sh`.

## Interactive And Application Demos

### `calc`

Run an interactive Int64 expression REPL written in Embedded Swift.

```text
calc
```

Example session:

```text
1 + 2 * 3
x = 40 + 2
x
:vars
:mem
:q
```

Commands:

| Command | Meaning |
| --- | --- |
| `:q` | Quit |
| `:mem` | Print the current heap break |
| `:vars` | Print variable count |
| `:sum` | Sum previous result values |
| `:help` | Print REPL help |

Acceptance coverage: `tests/calc_test.sh`.

### `kv`

Run an in-memory key-value REPL written in Embedded Swift.

```text
kv
```

Example session:

```text
SET name swiftos
GET name
KEYS
COUNT
:stats
:q
```

Commands:

| Command | Meaning |
| --- | --- |
| `SET key value` | Store a string value |
| `GET key` | Print a value or `(nil)` |
| `DEL key` | Delete a key |
| `KEYS` | List keys |
| `COUNT` | Print key count |
| `:stats` | Print key and value byte counts |
| `:mem` | Print the current heap break |
| `:help` | Print REPL help |
| `:q` | Quit |

Acceptance coverage: `tests/kv_test.sh`.

### `llm`

Run the native Embedded Swift LLM demo.

```text
llm [prompt] [steps]
```

Examples:

```sh
/bin/llm
/bin/llm "Once upon a time" 32
```

Notes:

- The default prompt is `Once upon a time`.
- The default step count is 64.
- The command reads `/models/stories260K.bin` and `/models/tok512.bin`.
- Build or fetch the model files with the repository model target before using
  the demo in a fresh checkout.

Acceptance coverage: `tests/llm_run_test.sh`.

See also `llmd` for serving the same native Swift inference engine over TCP
with the larger quantized default model. The complete AI runbook is in
[AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

## Runtime And Diagnostic Commands

These commands are useful for validation, acceptance tests, and low-level
debugging. They are user-visible in the current image, but many are closer to
diagnostic fixtures than stable application interfaces.

| Command | Synopsis | Purpose | Acceptance coverage |
| --- | --- | --- | --- |
| `threadsdemo` | `threadsdemo` | Create EL0 threads and prove futex-backed synchronization. | `tests/threads_test.sh` |
| `mmapdemo` | `mmapdemo` | Exercise anonymous mmap, mprotect, executable mapping, and W^X rejection. | `tests/mmap_test.sh` |
| `sleepprobe` | `sleepprobe` | Probe nanosleep timing and timer wakeups. | `tests/sleep_test.sh` |
| `console-login` | `console-login` | Run the console login program used as init. | `tests/console_login_test.sh` |
| `busybox` | `busybox [APPLET] [ARGS...]` | Login shell and compatibility applet provider. | `tests/busybox_test.sh`, `tests/vi_test.sh` |
| `c4b-sockxfer` | `c4b-sockxfer` | Exercise IPC transfer of a UDP socket handle. | `tests/ipc_socket_transfer_test.sh` |
| `pkg` | `pkg repo set URL`, `pkg repo show`, `pkg update [URL]`, `pkg search TEXT`, `pkg info NAME`, `pkg install FILE\|NAME`, or `pkg list` | Install local `.swpkg` files, install by name from signed HTTP repository fixtures, and list active package records. | `tests/pkg_local_install_test.sh`, `tests/pkg_repo_install_test.sh`, `tests/pkg_ports_seed_repo_install_test.sh` |

Examples:

```sh
/bin/threadsdemo
/bin/mmapdemo
/bin/sleepprobe
/bin/busybox vi /tmp/note.txt
pkg list
```

## Package Commands

### `pkg`

Install a local SwiftOS package file, update/search/inspect the signed HTTP
repository fixture, install a package by name from that fixture, or list active
package-store records.

```text
pkg repo set URL
pkg repo show
pkg update [URL]
pkg search TEXT
pkg info NAME
pkg install FILE
pkg install NAME
pkg list
```

Example local install fixture:

```sh
pkg list
pkg install /packages/pkghello.swpkg
pkg list
/usr/bin/pkghello
```

Expected output includes:

```text
no packages installed
pkg: installed pkghello-1.0.0_1
pkghello-1.0.0_1
pkghello: hello from package overlay
```

Example signed repository fixture:

```sh
pkg repo set http://10.0.2.2:<port>/good/aarch64/current
pkg repo show
pkg update
pkg search pkghello
pkg info pkghello
pkg install pkghello
pkg list
/usr/bin/pkghello
```

Expected output includes:

```text
pkg: repository set http://10.0.2.2:<port>/good/aarch64/current
http://10.0.2.2:<port>/good/aarch64/current
pkg: catalog updated http://10.0.2.2:<port>/good/aarch64/current
pkghello-1.0.0_1
sha256:
depends: pkgdep
pkg: fetching pkgdep-1.0.0_1
pkg: installed pkgdep-1.0.0_1
pkg: installed pkghello-1.0.0_1
pkgdep-1.0.0_1
pkghello-1.0.0_1
pkghello: hello from package overlay
```

Notes:

- `pkg install FILE` expects a local `.swpkg`.
- `pkg repo set URL` stores the active repository URL in tmpfs for the current
  boot. `pkg repo show` prints the configured URL. If `/etc/pkg/repo-url` is
  present in the base image, `pkg update` can use it without a prior
  `pkg repo set`; the test base image is built with `PKG_DEFAULT_REPO_URL`.
- `pkg update [URL]` expects a P5c signed static HTTP repository URL, such as
  the QEMU fixture path under
  `http://10.0.2.2:<port>/good/aarch64/current`. It rejects expired catalogs,
  incompatible package entries, and invalid dependency entries.
- `pkg search`, `pkg info`, and `pkg install NAME` use the verified catalog
  cached by `pkg update`; install by name resolves package-name dependencies
  and verifies each downloaded package SHA-256 before activation.
- The guest must be booted with a writable package-store image for install to
  succeed.
- `pkg list` reports the package records currently visible through the active
  package store.
- See [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md) for the complete runbook.

Acceptance coverage: `tests/pkg_local_install_test.sh` and
`tests/pkg_repo_install_test.sh`; the multi-package ports seed/default-repo
flow is covered by `tests/pkg_ports_seed_repo_install_test.sh`.

### `pkghello`

Run the package overlay hello program.

```text
/usr/bin/pkghello
```

Example:

```sh
/usr/bin/pkghello
```

Expected output:

```text
pkghello: hello from package overlay
```

Notes:

- This command is not in the base image. It is provided by the package overlay
  acceptance fixture or package-store fixture.
- See [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md) for package boot workflows,
  [PACKAGE_MANAGEMENT.md](PACKAGE_MANAGEMENT.md) for package design, and
  [SWPKG_FORMAT.md](SWPKG_FORMAT.md), [PKGSTORE_FORMAT.md](PKGSTORE_FORMAT.md),
  and [PKGREPO_FORMAT.md](PKGREPO_FORMAT.md) for package format details.

Acceptance coverage: `tests/package_overlay_test.sh` and
`tests/pkg_store_boot_test.sh`.

## Bring-up Demo Commands

The following programs remain staged in `/bin` because they prove specific
kernel and userland paths. They are valuable to developers and tests, but they
are not the primary operator interface.

| Command | Purpose |
| --- | --- |
| `hello` | Minimal user program smoke test. |
| `ttydemo` | Early tty interaction demo. |
| `argvdemo` | Argument passing demo. |
| `spawndemo` | Spawn path demo. |
| `selfexecdemo` | Self-exec path demo. |
| `fsdemo` | Filesystem syscall demo. |
| `brkdemo` | Program break and heap growth demo. |
| `newlibtest` | newlib compatibility smoke test. |
| `coproc` | Coprocess and pipe demo. |
| `forkdemo` | fork compatibility demo. |
| `execdemo` | exec compatibility demo. |
| `fdopsdemo` | fd, dup, pipe, and fcntl operation demo. |
| `securitydemo` | Capability and security-path demo. |
| `identitydemo` | Principal and login identity demo. |

Prefer the commands in the earlier sections for normal use. Use these demo
commands when validating a specific milestone or investigating a regression.

## Troubleshooting Command Failures

Common failure causes:

- `cannot open file`: the path does not exist, the process lacks `capFsRead`, or
  the path is outside its current confinement root.
- `bind failed` or `socket failed`: the guest was booted without virtio-net, the
  process lacks `capNet`, or the port is already in use.
- `cannot remove directory`: use `rm -r` for recursive removal, or ensure
  `rmdir` sees an empty directory.
- Package command not found: boot with the package overlay fixture or run the
  package overlay acceptance workflow.
- LLM model load failure: run the repository model target so the base image can
  include `/models/stories260K.bin`, `/models/tok512.bin`, and the verified
  serving bundle under `/models/stories15M`.

For end-to-end recovery steps, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
