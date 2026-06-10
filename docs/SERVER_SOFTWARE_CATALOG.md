# SwiftOS Server Software Catalog

This catalog explains which server and administration packages SwiftOS should
support first, what those packages require from the OS, and how each future
package should prove that it works. It is written for operators evaluating the
platform direction, application owners choosing target workloads, and port
maintainers planning `swift-os-ports` recipes.

> Status: planning input for the package ecosystem. The current checked-in
> system already has host `.swpkg` tooling, read-only package payload overlays,
> package-store boot activation, and a narrow local `/bin/pkg install FILE`
> path. It also has a P5c signed static HTTP repository fixture with
> `pkg repo set`, `pkg update [URL]`, `pkg search`, `pkg info`, and
> `pkg install NAME`, including name-based dependency resolution. P6a adds the
> checked `ports/catalog.json` seed catalog and `swport catalog` validator.
> P6b-P13 add checked Lua, zlib, ca-certificates, pcre2, tzdata, and nginx
> `Port.json` recipes with recipe validation, manifest generation,
> checksum-verified source fetch,
> `.swpkg` creation from clean staged roots, signed local repository fixture
> generation, real AArch64 static cross-builds where applicable, and a
> six-package signed seed repository fixture. The
> `package-lua-repo-install-test` installs and runs Lua from its signed
> repository inside QEMU. The `package-ports-seed-repo-install-test` boots
> SwiftOS with a default repository URL, runs `pkg update`, installs `lua`,
> `zlib`, `ca-certificates`, `pcre2`, `tzdata`, and `nginx`, and runs the
> package smoke commands. `make ports-static-host-publish`
> now emits a static-hostable web root for that seed repository, and
> `make package-static-host-repo-install-test` proves installs from that layout.
> P9 adds host-side hosted URL verification and a QEMU smoke where `/bin/pkg`
> installs Lua, zlib, ca-certificates, pcre2, tzdata, and nginx from a
> DNS-resolved HTTP repository URL. Public production domains/channels,
> target-side HTTPS, remove, upgrade, version-constraint solving, and rollback
> flows are still roadmap work.

Use this guide with:

- [Package Guide](PACKAGE_GUIDE.md) for the package workflows that work today.
- [Package Management](PACKAGE_MANAGEMENT.md) for the full package-manager
  design.
- [Package Build Automation Guide](PACKAGE_BUILD_AUTOMATION.md) for `swport`,
  CI, and repository publishing plans.
- [Compatibility Guide](COMPATIBILITY_GUIDE.md) for platform and runtime
  compatibility boundaries.
- [Porting Guide](PORTING_GUIDE.md) for the source-port workflow.
- [Service Guide](SERVICE_GUIDE.md) for daemon lifecycle and supervisor limits.
- [Deployment Guide](DEPLOYMENT_GUIDE.md) for validated candidate handoff.

## Current User-Visible Package State

SwiftOS does not yet have a public hosted package repository. These package
paths are available in the current tree:

| Path | User-visible result | Proof |
| --- | --- | --- |
| Host `.swpkg` tooling | Build, inspect, and verify `build/pkghello.swpkg` | `make package-fixture` |
| Direct payload overlay | Boot with read-only `/usr/bin/pkghello` | `make package-overlay-test` |
| Package-store boot activation | Boot a preseeded active package generation | `make package-store-test` |
| Local guest install | Run `pkg install /packages/pkghello.swpkg`, then execute `/usr/bin/pkghello` | `make package-local-install-test` |
| Signed HTTP repository fixture | Run `pkg repo set URL`, `pkg update`, `pkg install pkghello`, then execute `/usr/bin/pkghello` | `make package-repo-install-test` |
| Ports seed catalog | Validate the first server package priorities, dependencies, and blockers | `make ports-catalog-test` |
| Checked recipe repository paths | Validate the Lua, zlib, ca-certificates, pcre2, tzdata, and nginx recipes and prove their staged-root package flow can feed `swpkg create`/`verify` and a signed `pkgrepo` fixture | `make ports-recipe-test` |
| Lua binary repository fixture | Cross-build real static AArch64 Lua and publish the runtime interpreter into a signed local repository fixture | `make ports-lua-repo-fixture` |
| Lua target repository install | Install Lua from the signed local repository fixture and run it in QEMU | `make package-lua-repo-install-test` |
| zlib binary repository fixture | Cross-build real static zlib, headers, pkgconf metadata, and `minigzip`, then publish them into a signed local repository fixture | `make ports-zlib-repo-fixture` |
| ca-certificates repository fixture | Package the pinned CA bundle and publish it into a signed local repository fixture | `make ports-ca-certificates-repo-fixture` |
| pcre2 binary repository fixture | Cross-build real static PCRE2, headers, pkgconf metadata, and `pcre2grep`, then publish them into a signed local repository fixture | `make ports-pcre2-repo-fixture` |
| tzdata repository fixture | Compile IANA TZif zoneinfo files with host `zic`, package `/usr/share/zoneinfo`, and publish the signed local repository fixture | `make ports-tzdata-repo-fixture` |
| nginx binary repository fixture | Cross-build minimal static HTTP-only nginx, then publish it into a signed local repository fixture | `make ports-nginx-repo-fixture` |
| Ports seed repository fixture | Publish Lua, zlib, ca-certificates, pcre2, tzdata, and nginx into one signed local repository and install all six from SwiftOS using a default repository URL | `make package-ports-seed-repo-install-test` |
| Static-host publish root | Publish the seed repository into a deployable web root and install all six packages from SwiftOS using that hosted layout | `make package-static-host-repo-install-test` |
| DNS hosted repository smoke | Install Lua, zlib, ca-certificates, pcre2, tzdata, and nginx from SwiftOS using a hostname repository URL resolved through DNS | `make package-static-host-dns-repo-install-test` |
The `pkg install` examples later in this catalog are the intended repository
UX. Today, the implemented repository path has both an explicit fixture form:

```sh
pkg repo set http://10.0.2.2:<port>/aarch64/current
pkg update
pkg search pkghello
pkg info pkghello
pkg install pkghello
/usr/bin/pkghello
```

and a hosted-style default repository form for the ports seed fixture:

```sh
pkg update
pkg install lua
pkg install zlib
pkg install ca-certificates
pkg install pcre2
/usr/bin/lua -e 'print(21 * 2)'
/usr/bin/minigzip /tmp/zlib.txt
cat /usr/share/certs/swiftos-ca-bundle.version
echo nginx-lighttpd > /tmp/pcre2.txt
/usr/bin/pcre2grep 'nginx|lighttpd' /tmp/pcre2.txt
```

The package priority data in this document is mirrored into the checked
machine-readable seed catalog:

```sh
make ports-catalog-test
make ports-recipe-test
make ports-lua-repo-fixture
make ports-zlib-repo-fixture
make ports-ca-certificates-repo-fixture
make ports-pcre2-repo-fixture
make ports-seed-repo-fixture
make ports-static-host-publish
make ports-hosted-url-verify-test
make package-ports-seed-repo-install-test
make package-static-host-repo-install-test
make package-static-host-dns-repo-install-test
build/swport catalog list ports/catalog.json
build/swport catalog inspect nginx ports/catalog.json
build/swport recipe validate lang/lua
build/swport recipe validate archivers/zlib
build/swport recipe validate security/ca-certificates
build/swport recipe validate devel/pcre2
build/swport recipe manifest lang/lua --output build/lua-manifest.json
build/swport recipe manifest archivers/zlib --output build/zlib-manifest.json
build/swport recipe manifest security/ca-certificates --output build/ca-certificates-manifest.json
build/swport recipe manifest devel/pcre2 --output build/pcre2-manifest.json
build/swport recipe package lang/lua --root <staged-root> --output build/lua.swpkg
build/swport recipe repo-fixture lang/lua --root <staged-root> --output build/lua-repo-root
```

The local-file form remains available:

```sh
pkg list
pkg install /packages/pkghello.swpkg
pkg list
/usr/bin/pkghello
```

The installed payload is still immutable package content under `/usr`; SwiftOS
does not unpack packages into a mutable root filesystem.

## Purpose

The package manager should make a useful server no harder to provision than a
small Ubuntu machine:

```sh
pkg update
pkg install web-basic postgresql nodejs
```

Those commands describe the intended public repository experience. Today, use
the signed repository fixtures for repository smoke tests, `pkg install FILE`
for local `.swpkg` smoke tests, `build/swport catalog ...` for package priority
inspection, `build/swport recipe ...` for the checked Lua, zlib,
ca-certificates, pcre2, tzdata, and nginx recipes, and the host package tooling for packageconstruction.

The hard work belongs in `swift-os-ports` and CI. The target machine should only
download signed binary packages, verify them, activate them atomically, and run
the installed programs.

This catalog answers two questions:

1. Which server packages should exist first?
2. What kernel, libc, and static-linking work do those packages force us to
   confront?

## Difficulty Scale

- `S`: data-only or small C package; expected early.
- `M`: normal portable Unix software; needs a useful POSIX-like libc surface.
- `L`: large codebase or evented/networked daemon; will expose ABI gaps.
- `XL`: runtime, database, compiler, or VM class; requires threads, mmap, signal,
  process, and filesystem maturity.
- `Blocked`: do not schedule until a named OS capability exists.

## Shared Prerequisite Bundles

Package rows below use these short names to avoid repeating the same syscall
lists everywhere. Each row still calls out package-specific extras where needed.

| Bundle | Required OS/libc/kernel surface |
| --- | --- |
| `base-posix` | `open`, `read`, `write`, `close`, `lseek`, `stat`, `fstat`, `mkdir`, `unlink`, `rename`, `readdir`, `getcwd`, `chdir`, `isatty`, `errno`, `argv`, `envp`, exit status, monotonic/realtime clocks, `getpid`, `uname`, and deterministic path handling. |
| `proc-basic` | `spawn`/`exec`, `waitpid`, pipes, fd inheritance/close-on-exec, `dup2`, basic signals, and exit status propagation. `fork` is not assumed unless listed explicitly. |
| `net-client` | `socket`, `connect`, `send`, `recv`, `shutdown`, DNS resolver or `getaddrinfo`, IPv4 at first, timeouts, and `poll` or `select`. |
| `net-server` | `bind`, `listen`, `accept`, nonblocking sockets, `poll`/`select`, socket options, address reuse, backlog handling, and fd limits. |
| `tls-base` | Cryptographic entropy, reliable realtime clock, CA certificate store, file permissions for private keys, and a TLS library package. |
| `term-ui` | `termios`, terminal size ioctl, ANSI console behavior, UTF-8 path/text handling, and stable stdin/stdout/stderr semantics. |
| `pty` | Pseudo-terminal allocation, session/process-group concepts, signal delivery for interactive programs, and window-size propagation. |
| `db-fs` | `fsync`, `fdatasync`, file locks, durable rename, pread/pwrite, directory sync if available, large files, monotonic time, and clear ENOSPC behavior. |
| `mmap-vm` | `mmap`, `munmap`, `mprotect`, page permissions, executable mappings if JIT is enabled, guard pages, address-space layout control, and signal/trap reporting. |
| `threads` | pthread-like threads, thread-local storage, mutexes, condition variables, atomics, blocking wakeups, and scheduler behavior under many sleeping threads. |
| `service` | First-party service supervisor, service manifests, log routing, restart policy, persistent config/data directories, system users/groups or an equivalent capability model. |
| `procfs-like` | A documented way to inspect process, memory, fd, network, and system metrics. It does not have to be Linux `/proc`, but tools need a stable API. |

## Priority Tiers

### Tier 0: Package and Server Bootstrap

These packages make the package ecosystem and basic remote troubleshooting
possible. They should be the first real ports after `pkghello` and `lua`.

| Package | Role and why it matters | Likely upstream/project | Difficulty | Runtime dependencies | Syscall/libc/kernel prerequisites | Static-linking concerns | First smoke test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ca-certificates` | Trust store for HTTPS clients, ACME, package mirrors, Git, database clients, and language runtimes. | Mozilla CA bundle, packaged as data. | S | None. | `base-posix`; package-store support for data files under `/usr/share/certs` and `/usr/etc/ssl`. | Packaged. Current canonical cert-file path is `/usr/etc/ssl/cert.pem` until base links or non-`/usr` package paths are supported. | Install from the seed repository and `cat /usr/share/certs/swiftos-ca-bundle.version` in QEMU. |
| `tzdata` | Time zone data for logs, databases, TLS validation, and language runtimes. | IANA Time Zone Database. | S | None. | `base-posix`; realtime clock; stable data path such as `/usr/share/zoneinfo`. | Data-only. Keep UTC-only fallback in base OS, but package full zoneinfo. | Set `TZ=UTC` and `TZ=Europe/Madrid`; run a tiny date conversion test. |
| `zlib` | Compression library used by TLS stacks, Git, nginx, PostgreSQL, PNG/tools, and many archives. | zlib-ng in zlib-compat mode, or classic zlib. | S | None. | `base-posix` for test tools. | Static library is straightforward. Decide whether package name exposes `libz.a` only or also `zlib.pc`. | Compress and decompress a known string; verify SHA-256 of output. |
| `zstd` | Modern package/archive compression and backup compression. | facebook/zstd. | S | libc, optional pthreads disabled early. | `base-posix`; `threads` only for parallel mode. | Build static CLI and library with threading off at first. Later enable multithreaded compression. | `zstd input && zstd -d input.zst` and compare hash. |
| `xz` | `.xz` and `liblzma` support for upstream source tarballs and packages. | Tukaani XZ Utils. | M | libc. | `base-posix`. | Audit upstream release choice carefully because this is a supply-chain-sensitive package. Static CLI is fine. | Compress/decompress a fixture and compare hash. |
| `bzip2` | Legacy archive support for many upstream distfiles. | Sourceware bzip2 or maintained distribution mirror. | S | libc. | `base-posix`. | Static build is simple. Keep library packaging minimal. | `bzip2 -c fixture > fixture.bz2 && bzip2 -dc fixture.bz2`. |
| `libarchive` | Unified `tar`, `cpio`, and archive extraction for ports tooling and target admin use. | libarchive/bsdtar. | M | zlib, zstd, xz, bzip2. | `base-posix`; large-file support. | Static build is feasible but pulls many compression libs. Disable formats not needed initially. | `bsdtar -cf test.tar dir && bsdtar -tf test.tar`. |
| `curl` | HTTP(S) client for admin workflows, diagnostics, package repo debugging, and many scripts. | curl project. | M | TLS library, zlib optional, ca-certificates. | `base-posix`, `net-client`, `tls-base`. | Prefer static `curl` plus `libcurl.a`. Disable protocols beyond HTTP/HTTPS at first to reduce dependencies. | Start a host HTTP server in QEMU test; run `curl http://server/file` and compare content. |
| `pcre2` | Regex library needed by nginx, lighttpd, text tools, and scripting runtimes. | PCRE2. | S | None. | `base-posix`; full recursive `pcre2grep` mode waits for the dirent libc surface. | Packaged as static `libpcre2-8.a`, `libpcre2-posix.a`, headers, pkgconf metadata, and `pcre2grep`; JIT is disabled until executable mappings and W^X policy are settled. | Install from the seed repository and run `pcre2grep 'nginx\|lighttpd' /tmp/pcre2.txt` in QEMU. |
| `busybox-extra` | Temporary collection of admin utilities beyond the base busybox set. | BusyBox. | M | libc. | `base-posix`, `proc-basic`; selected applets may need `net-client`, `term-ui`, or `service`. | Single static binary works well. Applet symlink/hardlink behavior must match swift-os package image rules. | Run `busybox --list`; execute selected applets: `awk`, `sed`, `find`, `tar`, `wget` if enabled. |
| `pkg-tools` | Host and target helper tools for inspecting `.swpkg`, catalogs, signatures, and repo state. | swift-os first-party. | S | libc, crypto library if signatures are external. | `base-posix`; `net-client` for remote inspection later. | Keep parsers small and static. Avoid pulling large JSON/TLS stacks into base unless already accepted. | `pkg inspect sample.swpkg` prints deterministic manifest fields. |

### Tier 1: Day-One Server Administration

These packages make a headless server usable by an operator over serial console
and, later, the network.

| Package | Role and why it matters | Likely upstream/project | Difficulty | Runtime dependencies | Syscall/libc/kernel prerequisites | Static-linking concerns | First smoke test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `oksh` | Small interactive shell with a friendlier admin experience than minimal `sh`. | oksh. | M | libc, terminfo optional. | `base-posix`, `proc-basic`, `term-ui`. | Static build is expected. Job control can be disabled until process groups exist. | Boot QEMU, run `oksh -c 'echo ok && pwd'`. |
| `mksh` | Alternative portable shell, useful if `oksh` hits portability trouble. | MirBSD Korn Shell. | M | libc. | `base-posix`, `proc-basic`, `term-ui`. | Static build is practical. Locale and job-control features can be trimmed. | `mksh -c 'for x in a b; do echo $x; done'`. |
| `nano` | Simple terminal editor for config files. | GNU nano. | M | ncurses or termcap, gettext optional. | `base-posix`, `term-ui`. | Static with ncurses is fine. Disable spellcheck, gettext, and mouse support initially. | Open a file in scripted mode if possible, or run `nano --version` and verify term init. |
| `vim-tiny` | Familiar editor for admins, but trimmed to avoid scripting and GUI complexity. | Vim. | L | ncurses, optional gettext. | `base-posix`, `term-ui`; `proc-basic` for shell escapes if enabled. | Static is possible but feature selection matters. Disable dynamic language plugins. | `vim --clean -Nu NONE -n +'set nomore' +q`. |
| `mc` | Midnight Commander file manager, viewer, editor, and diff tool for serial/SSH admin work. | Midnight Commander. | L | ncurses or slang, glib if upstream requires it, shell. | `base-posix`, `proc-basic`, `term-ui`; `pty` for subshell support later. | Static build may be bulky because of glib/slang/ncurses. First build should disable subshell, VFS plugins, and network filesystems. | `mc --version`; later scripted start in a pseudo terminal and exit cleanly. |
| `less` | Pager for logs, docs, SQL output, and diagnostics. | less. | S | ncurses or termcap. | `base-posix`, `term-ui`. | Static build is small. Regex backend may add dependency. | `printf 'a\nb\n' \| less -F` exits successfully. |
| `grep-sed-awk` | Full-feature text processing beyond busybox when ports and admin scripts need compatibility. | GNU grep, GNU sed, one-true-awk or gawk. | M | libc, regex. | `base-posix`; `proc-basic` for script pipelines. | Static GNU tools are usually easy but larger. Start with smaller BSD/awk variants if license or size is better. | Run known POSIX regex, substitution, and awk field tests. |
| `coreutils-small` | More complete `install`, `stat`, `sort`, `sha256sum`, `env`, and file tools than busybox. | uutils-coreutils or GNU coreutils. | L | libc; Rust runtime if using uutils. | `base-posix`, `proc-basic`; file metadata parity. | GNU static C build is large but known. Rust/uutils waits for Rust target support. | `sha256sum fixture`, `sort`, `install -m 0755` into tmpfs. |
| `dns-tools` | `dig`/`drill`-like DNS debugging for package repos, ACME, databases, and web hosting. | ldns `drill` first; BIND tools later. | M | OpenSSL or libressl optional, ca-certificates for DoT later. | `base-posix`, `net-client`. | Prefer `drill` over full BIND first. Static BIND tools are much heavier. | Query a host-provided DNS fixture or local UDP DNS responder. |
| `ip-tools` | Inspect addresses, routes, listeners, and network status. | swift-os first-party initially. | M | libc. | Stable network-control syscalls or diagnostics API; `procfs-like` later. | First-party static tool avoids Linux netlink dependency from `iproute2`. | `ip addr` or `swos-netstat` prints the configured QEMU network interface. |
| `logrotate` | Keeps logs bounded on persistent disks and package-managed services. | logrotate. | M | libc, compression optional. | `base-posix`, `proc-basic`, file permissions, durable rename. | Static build is normal. Script hooks should be disabled or tightly controlled first. | Rotate a fixture log and verify compressed/renamed output. |
| `rsync` | File synchronization, backup transport, deployment, and admin copy. | rsync. | L | zlib, xxhash optional, OpenSSL optional. | `base-posix`, `proc-basic`, `net-client`; file metadata; optional ssh client. | Static is feasible. Extended attrs, ACLs, hardlinks, and device files should be disabled until supported. | Sync a small directory over local rsync protocol or local filesystem mode. |
| `dropbear` | Small SSH client/server, likely easier first remote login than OpenSSH. | Dropbear SSH. | L | zlib optional, crypto backend, ca-certificates not required for SSH. | `base-posix`, `net-client`, `net-server`, `term-ui`, `pty`, `service`, entropy. | Static-friendly. Server mode needs host keys, users, pty, and a clear auth story. Client-only package can land earlier. | Client: connect to host SSH test server. Server: login to QEMU and run `echo ok`. |
| `openssh-client` | Standard SSH client, scp, and sftp for admin and deployment. | OpenSSH portable. | L | OpenSSL/libressl, zlib. | `base-posix`, `net-client`, `term-ui`, entropy, config file support. | Static portable OpenSSH is possible. Kerberos, PAM, FIDO, and dynamic features should be disabled. | `ssh -V`; then connect to a host test server with a generated key. |
| `openssh-server` | Standard remote login service, file copy, and tunneling. | OpenSSH portable. | XL | OpenSSL/libressl, zlib, shell, service manager. | `base-posix`, `net-server`, `pty`, `service`, users/groups or capability model, entropy, file permissions. | Static possible but privilege separation, host-key storage, chroot, PAM, and user database need explicit swift-os decisions. | Start `sshd` under service supervisor; login with key; run `uname`. |

### Tier 2: Web Hosting Core

This tier should produce the first convincing server demo: static site,
automatic certificate path, reverse proxy path, logs, and a small app behind it.

| Package | Role and why it matters | Likely upstream/project | Difficulty | Runtime dependencies | Syscall/libc/kernel prerequisites | Static-linking concerns | First smoke test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lighttpd` | First practical HTTP daemon candidate before nginx if we need a smaller C server. | lighttpd. | L | pcre2 optional, zlib optional, TLS library optional. | `base-posix`, `net-server`, `service`; `tls-base` for HTTPS. | Static build is realistic. Dynamic modules must be disabled or built in. CGI/FastCGI can be deferred. | Serve `/var/www/index.html`; host runs `curl http://qemu/`. |
| `nginx` | Main web server and reverse proxy target for real hosting workloads. | nginx open source. | L | pcre2, zlib, OpenSSL/libressl, ca-certificates for upstream TLS. | `base-posix`, `net-server`, `service`, file permissions, timers; optional `tls-base`. | Build modules statically. Disable dynamic modules, sendfile, aio, and PCRE JIT until supported. | `nginx -t`; serve static file; reverse proxy to a tiny local HTTP app. |
| `caddy` | Modern web server with automatic HTTPS; attractive long-term UX. | Caddy. | Blocked until Go runtime/toolchain target works. | Go runtime, ca-certificates. | `base-posix`, `net-server`, `tls-base`, `service`, `threads`; Go target support. | Go can produce static binaries, but only after the Go runtime knows swift-os syscalls, netpoll, DNS, time, and threads. | `caddy validate`; serve static file with local CA or HTTP-only mode first. |
| `acme-sh` | Shell-based ACME client; likely easiest Let's Encrypt path before Go/Python clients. | acme.sh. | M | shell, curl or wget, openssl tool, ca-certificates. | `base-posix`, `proc-basic`, `net-client`, `tls-base`, reliable clock, file permissions. | Script package, not a static binary. Requires a capable POSIX shell and external tools. | Use Pebble/Boulder test ACME server; complete HTTP-01 challenge against local web root. |
| `lego` | ACME client and library written in Go; cleaner single-binary future option. | go-acme/lego. | Blocked until Go runtime/toolchain target works. | Go runtime, ca-certificates. | `base-posix`, `net-client`, `tls-base`, DNS resolver, reliable clock. | Static after Go support. DNS provider plugins may pull many dependencies. | Against Pebble: request staging cert via HTTP-01 using a temporary webroot. |
| `openssl` | TLS library and command-line tool for HTTPS, certs, curl, nginx, OpenSSH, and tests. | OpenSSL. | L | ca-certificates for verification. | `base-posix`, `tls-base`, entropy, time. | Static library is common but large. Provider/module model in newer OpenSSL must be handled without dynamic loading, or providers must be built in. | `openssl rand 16`; verify a local certificate chain; run `s_client` later. |
| `libressl` | Smaller TLS alternative, useful if OpenSSL provider model is awkward. | LibreSSL. | M | ca-certificates. | `base-posix`, `tls-base`, entropy, time. | Static builds are usually simpler than OpenSSL. Compatibility with nginx/curl/OpenSSH must be tested. | `openssl version` from LibreSSL tool; verify a local certificate chain. |
| `pcre2` | Regex library needed by nginx, many text tools, and scripting runtimes. | PCRE2. | S | libc. | `base-posix`; `mmap-vm` only if JIT enabled. | Static is simple. Disable JIT until executable mappings and W^X policy are clear. | Run `pcre2grep` or a small test binary against known patterns. |
| `fcgiwrap` | CGI/FastCGI bridge for simple web apps and admin endpoints. | fcgiwrap or spawn-fcgi ecosystem. | L | libc, web server. | `base-posix`, `proc-basic`, `net-server` or Unix sockets when available, `service`. | Static possible. Depends on process spawning and socket passing choices. | nginx/lighttpd calls a fixture CGI script returning `200 ok`. |
| `php-fpm` | Common hosting runtime for legacy and simple web apps. | PHP project. | XL | libxml2, sqlite, openssl, pcre2, zlib, optional database clients. | `base-posix`, `proc-basic`, `net-server`, `service`, `threads` depending build, file locks. | Static PHP is possible but extensions are normally modular. Start with CLI-only `php` before FPM. | `php -r 'echo PHP_VERSION;'`; later serve `phpinfo()` through FastCGI. |

### Tier 3: Data Stores

Databases are where filesystem correctness becomes visible. SQLite should be
early; PostgreSQL and MariaDB should wait until the package manager, tmpfs/base
image split, persistent disk story, and service supervisor are stable.

| Package | Role and why it matters | Likely upstream/project | Difficulty | Runtime dependencies | Syscall/libc/kernel prerequisites | Static-linking concerns | First smoke test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `sqlite` | Embedded database for tools, package metadata experiments, small apps, and smoke tests. | SQLite. | S | libc. | `base-posix`, `db-fs` for durable mode; tmpfs ok for non-durable tests. | Amalgamation static build is ideal. Decide compile-time options for JSON, FTS, and readline shell. | `sqlite3 /tmp/t.db 'create table t(x); insert into t values(1); select x from t;'`. |
| `postgresql-client` | `psql`, `pg_dump`, and client library for apps before server port lands. | PostgreSQL. | L | OpenSSL/libressl optional, zlib, readline optional. | `base-posix`, `net-client`, `term-ui`, `tls-base` for SSL. | Static client build is easier than server. Disable LDAP, PAM, GSSAPI, and dynamic plugin assumptions. | Connect from QEMU to host PostgreSQL; run `select 1`. |
| `postgresql-server` | Primary serious open-source relational database target. | PostgreSQL. | XL | zlib, OpenSSL/libressl optional, ICU optional, readline for tools. | `base-posix`, `proc-basic`, `net-server`, `db-fs`, `service`, shared memory/semaphores or replacement, signals; likely `mmap-vm`. | Static server is possible but extensions, `dlopen`, locale/ICU, shared libraries, and process model are hard. PostgreSQL traditionally uses multiple processes. | `initdb` on persistent disk; start server; `psql -c 'select 1'`; reboot and query again. |
| `mariadb-client` | MySQL-compatible client and library for apps before server port lands. | MariaDB Connector/C and MariaDB client tools. | L | OpenSSL/libressl, zlib, ncurses optional. | `base-posix`, `net-client`, `term-ui`, `tls-base`. | Static connector is feasible. Authentication plugins must be built in or limited. | Connect to host MariaDB; run `select 1`. |
| `mariadb-server` | MySQL-compatible database for common web hosting stacks. | MariaDB Server. | XL | OpenSSL/libressl, zlib, pcre2, ncurses tools, compression libs. | `base-posix`, `net-server`, `db-fs`, `service`, `threads`, `mmap-vm`, file locks, atomics, large files. | Static build is difficult because storage engines and auth are often plugin-oriented. Start with a minimal engine set and no dynamic plugins. | Initialize datadir; start server; run `mysql -e 'select 1'`; reboot and verify table persists. |
| `redis-compatible` | Cache/session store for web apps. | Valkey preferred, Redis licensing must be reviewed per policy. | L | libc, optional TLS. | `base-posix`, `net-server`, `service`, timers, `db-fs` for persistence; `fork` if upstream snapshotting is required. | Static build is straightforward, but persistence and snapshot/fork assumptions need patching. | Start with persistence disabled; `SET k v` then `GET k`; later test AOF persistence. |
| `memcached` | Simple cache daemon with smaller surface than Redis-like systems. | memcached. | M | libevent. | `base-posix`, `net-server`, `service`, timers. | Static build with libevent is normal. SASL disabled initially. | `set k 0 0 1`/`get k` through a tiny client or netcat equivalent. |

### Tier 4: Language Runtimes and Application Platforms

These make swift-os useful beyond static C utilities, but they should not block
the first package manager. Each runtime must be treated as an ABI test suite.

| Package | Role and why it matters | Likely upstream/project | Difficulty | Runtime dependencies | Syscall/libc/kernel prerequisites | Static-linking concerns | First smoke test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lua` | Small scripting runtime; ideal first real port and package demo. | Lua. | S | libc, readline optional. | `base-posix`; `term-ui` for interactive REPL. | Static build is simple. Dynamic C modules disabled until loader policy exists. | `lua -e 'print(_VERSION)'`. |
| `python-minimal` | Automation scripts, admin tooling, many ACME/build utilities, and later app support. | CPython. | XL | libffi optional, openssl, zlib, xz, bzip2, sqlite. | `base-posix`, `proc-basic`, `net-client`, `tls-base`, `db-fs`, `threads`, `mmap-vm`, signals. | Static CPython is possible but extension modules are normally dynamic. Build a curated static module set. | `python3 -c 'import ssl,sqlite3,json; print("ok")'`. |
| `nodejs` | JavaScript server runtime for modern web apps and tooling. | Node.js. | XL | V8, OpenSSL, zlib, ICU, c-ares or resolver. | `base-posix`, `net-client`, `net-server`, `tls-base`, `threads`, `mmap-vm`, signals, high-resolution timers, event notification. | Static Node is hard but possible in custom builds. V8 JIT needs executable memory; start with JIT policy decision or interpreter/JITless mode. Native addons are deferred without dynamic loading. | `node -e 'require("http").createServer((_,r)=>r.end("ok")).listen(8080)'` and fetch from host. |
| `openjdk-runtime` | JVM target for Java services and long-horizon project goal. | OpenJDK, with Adoptium as packaging reference. | XL | zlib, libffi optional, font/rendering pieces disabled for headless, ca-certificates. | `base-posix`, `net-client`, `net-server`, `tls-base`, `threads`, `mmap-vm`, signals, atomics, large files, entropy. | Static HotSpot is not the normal distribution model. Expect major build-system and runtime porting. Dynamic class loading is fine at Java level, but native JNI libraries are deferred. | `java -version`; then run a one-file HTTP server or `HelloWorld.class`. |
| `swift-runtime-minimal` | Runtime support for native Swift server apps compiled off-target. | Swift project plus swift-os ABI support. | XL | Swift runtime pieces chosen for static apps; libc bridge if needed. | `base-posix`, `proc-basic`, `net-client` for server apps, `threads` depending concurrency model. | Prefer statically linked app packages first. Full Swift standard library and concurrency runtime need a deliberate ABI/runtime plan. | Run a statically linked Swift `hello` and a tiny TCP echo server. |
| `swift-toolchain` | On-target Swift compiler and package manager; long-horizon developer experience. | Swift project, LLVM. | Blocked until large runtime and storage work. | LLVM/Clang, Foundation pieces, libxml2, zlib, curl/git for package manager workflows. | `base-posix`, `proc-basic`, `db-fs`, `threads`, `mmap-vm`, large memory, reliable temp files. | Very large static toolchain. More likely distributed as multiple package images or kept host-side for a long time. | `swiftc hello.swift -o hello && ./hello`, but this is not an early target. |
| `go-runtime-toolchain` | Enables Caddy, lego, rclone, Prometheus exporters, many admin tools. | Go project. | XL | Go runtime. | `base-posix`, `net-client`, `net-server`, `threads`, `mmap-vm`, signals, futex-like waits, DNS, time. | Go emits mostly static binaries, but requires a first-class OS port in the runtime. Toolchain itself is large. | Cross-build `hello`; run it on swift-os; then run a tiny HTTP server. |
| `php-cli` | CLI PHP for scripts and first step toward PHP web hosting. | PHP project. | L | pcre2, zlib, libxml2, sqlite, openssl optional. | `base-posix`, `proc-basic`, `net-client`, `tls-base` for HTTPS streams. | Static core with selected extensions. Dynamic PECL modules deferred. | `php -r 'echo json_encode([1+1]);'`. |
| `ruby-minimal` | Some admin tooling and web app compatibility, lower priority than Python/Node. | Ruby. | XL | openssl, zlib, libffi, readline, gdbm optional. | `base-posix`, `proc-basic`, `net-client`, `tls-base`, `threads`, `mmap-vm`. | Static build can work, but gems with native extensions need a toolchain and dynamic-loading policy. | `ruby -e 'puts RUBY_VERSION'`. |
| `perl-minimal` | Build scripts and legacy admin tooling. | Perl. | L | libc, optional db/zlib. | `base-posix`, `proc-basic`. | Static perl is feasible but extension model is large. Useful mainly for build compatibility. | `perl -e 'print "ok\n"'`. |

### Tier 5: Build Essentials

Ports should be built off-target in CI first. On-target build packages are still
valuable later for users and for dogfooding the OS, but they should not define
the first package manager.

| Package | Role and why it matters | Likely upstream/project | Difficulty | Runtime dependencies | Syscall/libc/kernel prerequisites | Static-linking concerns | First smoke test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `pkgconf` | Provides `.pc` dependency metadata for builds and port recipes. | pkgconf. | S | libc. | `base-posix`. | Static build is simple. | `pkgconf --version`; resolve a fixture `.pc` file. |
| `make` | Required by many simple upstream builds and useful for users. | bmake first, GNU make later if needed. | M | libc. | `base-posix`, `proc-basic`. | Static build is practical. GNU make jobserver and shell behavior need process tests. | Build a two-target fixture using `/bin/sh`. |
| `ninja` | Fast modern build executor for CMake, LLVM, Swift, and many ports. | Ninja. | M | libc, C++ runtime if not avoided. | `base-posix`, `proc-basic`. | Static C++ binary depends on libc++/libstdc++ port choice. | Build a fixture with two commands and dependency ordering. |
| `cmake` | Common build generator for modern C/C++ projects. | CMake. | XL | libarchive, zlib, curl optional, C++ runtime. | `base-posix`, `proc-basic`, large file tree handling. | Static CMake is large. It may be more valuable host-side in `swift-os-ports` than target-side early. | Configure and build a tiny C project with Ninja. |
| `meson` | Build system used by many modern projects. | Meson. | Blocked until Python works. | Python. | Same as `python-minimal`; `proc-basic`. | Script package. No static concern beyond Python runtime. | Configure and build a tiny C project with Ninja. |
| `autoconf-automake-libtool` | Legacy source builds and FreeBSD ports compatibility. | GNU Autoconf, Automake, Libtool. | L | shell, m4, perl. | `base-posix`, `proc-basic`; good temp-file behavior. | Script packages. On-target value is later; host-side tooling matters first. | Regenerate and run configure for a tiny fixture. |
| `m4` | Required by autoconf. | GNU m4. | M | libc. | `base-posix`. | Static build is normal. | Run macro expansion fixture. |
| `patch` | Applies upstream and local patches in ports and admin workflows. | GNU patch or BSD patch. | S | libc. | `base-posix`. | Static build is simple. | Apply a unified diff fixture. |
| `git` | Source checkout, deployment, and package recipe work. | Git. | L | curl, OpenSSL/libressl, zlib, pcre2 optional, expat. | `base-posix`, `proc-basic`, `net-client`, `tls-base`, file locks. | Static Git is possible, but helpers are many executables. Disable perl/python extras first. | `git init`, commit a file, clone over local HTTP later. |
| `clang-llvm` | C/C++ compiler stack and prerequisite for native Swift toolchain. | LLVM/Clang. | XL | libc++, zlib, zstd optional, libxml2 optional. | `base-posix`, `proc-basic`, `db-fs`, `mmap-vm`, large memory. | Very large static package. More useful in the cross toolchain before target-side packaging. | Compile `int main(){return 0;}` and run result. |
| `lld` | Static linker for target binaries and on-target experiments. | LLVM lld. | L | libc++, zlib optional. | `base-posix`, `proc-basic`, large files. | Static binary is large but simpler than all of LLVM. | Link a tiny object into an executable and run it. |

### Tier 6: Monitoring, Logging, Backup, and Operations

Some common Linux tools depend heavily on `/proc`, netlink, cgroups, systemd, or
dynamic plugins. For swift-os, first-party tiny tools may be better than trying
to fake Linux compatibility.

| Package | Role and why it matters | Likely upstream/project | Difficulty | Runtime dependencies | Syscall/libc/kernel prerequisites | Static-linking concerns | First smoke test |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `swos-syslogd` | First-party log receiver and file writer for services. | swift-os first-party. | M | libc. | `base-posix`, `service`, durable append/rename, clock. | Static and small. Define log format before third-party log tools depend on it. | Service writes one log line; file appears under `/var/log`. |
| `swos-service` | Service supervisor and `service start/stop/status` interface for daemons. | swift-os first-party. | L | libc. | `base-posix`, `proc-basic`, `service`, signals, restart policy, config store. | Static and base-adjacent. Keep package service hooks declarative, not arbitrary root scripts. | Install `hello-service`; supervisor starts it and reports status. |
| `swos-metrics` | Native metrics exporter for uptime, memory, disk, network, and service state. | swift-os first-party. | M | libc, optional HTTP server library. | `procfs-like` or native kernel metrics API, `net-server` if HTTP exporter. | Static. Prefer a tiny text endpoint compatible with Prometheus scraping later. | Fetch `/metrics` and verify uptime and memory lines exist. |
| `prometheus-node-exporter` | Standard monitoring endpoint for many deployments. | Prometheus node_exporter. | Blocked until Go and metrics APIs exist. | Go runtime. | `procfs-like`, `net-server`, `threads`; no Linux `/proc` assumption. | Static after Go port. Many collectors must be rewritten or disabled. | Start exporter; scrape a minimal swift-os collector. |
| `logtail-tools` | `tail`, `logger`, `watch`, and simple log inspection. | BusyBox/coreutils or first-party. | S | libc. | `base-posix`, `term-ui` for watch. | Static small tools. | Append to a file and `tail -f` sees new line. |
| `backup-basic` | Meta-package for local backup primitives: `bsdtar`, `zstd`, checksums, and restore docs. | swift-os package set. | S | libarchive, zstd, coreutils-small. | Dependencies' prerequisites; persistent filesystem. | Meta-package only. | Create archive of `/etc`; restore into tmpfs; compare manifest. |
| `restic` | Encrypted remote backups to object storage. | restic. | Blocked until Go runtime/toolchain target works. | Go runtime, TLS, ca-certificates. | `base-posix`, `net-client`, `tls-base`, `threads`, file locking. | Static after Go port. Needs careful entropy and clock behavior. | Backup and restore a small directory to a host S3-compatible test service. |
| `borgbackup` | Deduplicated backups. | BorgBackup. | Blocked until Python and native extension story works. | Python, OpenSSL, zstd/lz4, msgpack. | `base-posix`, `proc-basic`, `db-fs`, `threads`. | Static Python extension packaging is complex. Later than restic unless Python lands first. | Create repo in tmpfs; backup and restore one directory. |
| `rclone` | Remote file sync to object stores. | rclone. | Blocked until Go runtime/toolchain target works. | Go runtime, TLS. | `base-posix`, `net-client`, `tls-base`, `threads`. | Static after Go port. Provider matrix may be trimmed. | Copy a file to a host WebDAV/S3 fixture and back. |
| `top` | Basic live process/memory view. | first-party `swos-top`, not Linux `procps` initially. | M | libc, terminal library optional. | `procfs-like`, `term-ui`, timers. | Static. Avoid Linux `/proc` compatibility trap. | Start two processes; `top -b -n1` lists them. |
| `htop` | Familiar interactive process viewer. | htop. | Blocked until process metrics API and terminal maturity exist. | ncurses. | `procfs-like`, `term-ui`. | Static build with ncurses is fine after metrics mapping. | `htop --version`; later scripted terminal smoke. |

## Recommended First Package Waves

### Wave A: Prove Binary Packaging

Goal: exercise package format, dependency metadata, install/remove, and QEMU
smoke tests without relying on hard kernel features.

Packages:

- `pkghello`
- `lua`
- `ca-certificates`
- `zlib`
- `zstd`
- `bzip2`
- `xz`
- `patch`
- `pkgconf`

Acceptance demo:

```sh
pkg update
pkg install lua zlib ca-certificates
lua -e 'print(_VERSION)'
echo zlib-ok > /tmp/zlib.txt
minigzip /tmp/zlib.txt
minigzip -d /tmp/zlib.txt.gz
cat /usr/share/certs/swiftos-ca-bundle.version
```

### Wave B: Usable Admin Console

Goal: make a serial-console server comfortable enough for debugging ports.

Packages:

- `oksh`
- `less`
- `grep-sed-awk`
- `libarchive`
- `curl` over HTTP first, HTTPS when TLS is ready
- `dns-tools`
- `nano`
- `mc` with reduced features

Acceptance demo:

```sh
pkg install admin-basic
curl http://repo.local/ping
drill repo.local
mc --version
```

### Wave C: First Web Server

Goal: host a static site and proxy to a tiny local service.

Packages:

- `lighttpd` or `nginx` HTTP-only first
- `pcre2`
- `openssl` or `libressl`
- `acme-sh`
- `logrotate`
- `swos-service`
- `swos-syslogd`

Acceptance demo:

```sh
pkg install web-basic
service start nginx
curl http://127.0.0.1/
```

Then add ACME through a local Pebble test server before using Let's Encrypt
production.

### Wave D: Data and Dynamic Apps

Goal: show a real app stack while keeping durability bugs visible.

Packages:

- `sqlite`
- `postgresql-client`
- `postgresql-server`
- `memcached`
- `php-cli` before `php-fpm`
- `python-minimal`

Acceptance demo:

```sh
pkg install postgresql-server
service start postgresql
psql -c 'select 1'
```

### Wave E: Major Runtimes

Goal: satisfy long-horizon server platform goals after the OS has threads,
`mmap`, service management, durable storage, and networking.

Packages:

- `nodejs`
- `go-runtime-toolchain`
- `caddy`
- `lego`
- `openjdk-runtime`
- `swift-runtime-minimal`
- `swift-toolchain` much later

Acceptance demos:

```sh
node -e 'console.log(process.version)'
java -version
swift-hello
```

## Suggested Meta-Packages

Meta-packages should not hide what they install; `pkg info web-basic` should
show the dependency list clearly.

| Meta-package | Initial dependencies | Purpose |
| --- | --- | --- |
| `admin-basic` | `oksh`, `less`, `grep-sed-awk`, `libarchive`, `curl`, `dns-tools`, `nano` | Comfortable serial-console administration. |
| `web-basic` | `nginx` or `lighttpd`, `pcre2`, TLS library, `ca-certificates`, `acme-sh`, `swos-service`, `swos-syslogd`, `logrotate` | Static hosting and reverse proxy baseline. |
| `db-basic` | `sqlite`, `postgresql-client`, `memcached` | Lightweight app data and client tooling. |
| `postgresql` | `postgresql-server`, `postgresql-client`, `swos-service`, `backup-basic` | Complete PostgreSQL service once durability support is ready. |
| `ssh-basic` | `dropbear` or `openssh-client`, later server package | Remote administration. |
| `backup-basic` | `libarchive`, `zstd`, `coreutils-small` | Local backup and restore primitives. |
| `build-base` | `pkgconf`, `make`, `patch`, `m4`, `ninja`; later `cmake`, `clang-llvm`, `lld` | On-target build experiments, not required for normal package installs. |
| `runtime-web` | `nodejs` or `php-fpm` or `python-minimal`, database client libs | Application runtime selection. |

## Repository Automation Expectations

Every package in `swift-os-ports` should have a machine-readable recipe with at
least:

- upstream source URL and expected SHA-256;
- license metadata;
- target ABI tuple;
- static-linkage declaration;
- dependency list;
- configure/build/install commands;
- files installed into the package image;
- one QEMU smoke test command;
- known unsupported upstream features.

The CI path should be:

```text
Port.json changed
  -> fetch source by hash
  -> apply patches
  -> cross-build into DESTDIR
  -> create .swpkg
  -> run host verifier
  -> boot QEMU
  -> pkg install ./artifact.swpkg
  -> run package smoke test
  -> upload artifact on PR
  -> trusted merge rebuilds, signs, publishes catalog
```

Do not accept a package into the public catalog without its first smoke test.
For daemon packages, the smoke test must start the daemon under the service
supervisor once that supervisor exists. Before then, daemon packages can be
published only to an experimental channel.

## Key Porting Recommendations

1. Port `zstd`, `bzip2`, `patch`, and `pkgconf` next after the checked `lua`,
   `zlib`, `ca-certificates`, and `pcre2` packages. They test the package
   system without forcing network, threads, or VM semantics.
2. Make `curl` the first serious network client. It will quickly expose DNS,
   sockets, timeouts, TLS, entropy, and CA-store problems.
3. Choose either OpenSSL or LibreSSL as the first blessed TLS provider before
   nginx and ACME work. Keep the other as an experimental alternative.
4. Port `lighttpd` before or alongside nginx if nginx blocks on module or event
   assumptions. The user-facing `web-basic` meta-package can switch to nginx
   later.
5. Treat PostgreSQL as the first serious durability test, not as an early
   package-manager test. It should wait for `db-fs`, service management, and a
   persistent disk story.
6. Treat MariaDB, Node.js, OpenJDK, Swift toolchain, Go, and Caddy as platform
   ports. They are important, but they should be scheduled after threads,
   `mmap`, signals, TLS, DNS, and service supervision are stable.
7. Prefer first-party `swos-service`, `swos-syslogd`, `swos-metrics`, and
   `swos-top` over pretending to be Linux `/proc`, netlink, cgroups, or systemd.
8. Keep package install hooks declarative. Service manifests, users, writable
   directories, and config defaults should be data in the package manifest, not
   arbitrary maintainer scripts.
9. Use local fixtures first: host HTTP server for curl, Pebble/Boulder for ACME,
   host PostgreSQL/MariaDB for client tools, and QEMU loopback services for
   daemon tests.
10. Publish only binary `.swpkg` artifacts to users. Source builds stay in
    `swift-os-ports` CI and release automation.
