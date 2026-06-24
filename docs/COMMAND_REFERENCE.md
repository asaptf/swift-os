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

## Choose A Command

Use this table when you know the task but not the command name yet. Detailed
syntax, examples, limits, and acceptance coverage remain in the sections below.

| Task | Commands | Required setup | Focused proof |
| --- | --- | --- | --- |
| Confirm login and authority | `id` | Any seeded account | `tests/cap_enforce_test.sh` |
| Inspect files and metadata | `ls`, `cat`, `head`, `wc`, `date` | `capFsRead` for base-image reads | `tests/swift_coreutils_test.sh`, `tests/swift_ls_test.sh`, `tests/swift_headwc_test.sh` |
| Use tmpfs scratch space | `mkdir`, `touch`, `echo`, `mv`, `rm`, `rmdir`, `chmod`, `chown` | `capTmpWrite` and paths under `/tmp` | `tests/swift_fileops_test.sh`, `tests/swift_chmodown_test.sh` |
| Inspect processes and resources | `ps`, `top` | Process-inspection authority in the current context | `tests/top_test.sh`, `tests/busybox_test.sh` |
| Inspect kernel logs | `logtail`, `logtail --stats` | `capLogExport` in the current context | `tests/log_export_test.sh` |
| Serve HTTP content | `httpd` | QEMU virtio-net, TCP 8080 host forwarding, `capNet` | `tests/httpd_test.sh` |
| Serve AI completions | `llmd` | QEMU virtio-net, TCP 8080 host forwarding, `capNet`, readable model bundle | `tests/llm_serve_test.sh` |
| Exercise SSH client preauth | `ssh` | QEMU virtio-net, host OpenSSH server, `capNet`; attach virtio-rng for runtime entropy proof | `tests/ssh_transport_test.sh`, `tests/ssh_runtime_entropy_test.sh` |
| Exercise SSHD remote command | `sshd` | QEMU virtio-net, TCP 22 host forwarding, `capNet`, authorized key; default base image autostarts it via `swos-init`; attach virtio-rng for runtime entropy proof | `tests/sshd_transport_test.sh`, `tests/sshd_runtime_entropy_test.sh`, `tests/sshd_kex_seed_test.sh`, `tests/sshd_authorized_keys_test.sh`, `tests/sshd_ipv6_supervision_test.sh`, `tests/sshd_deploy_preflight_test.sh` |
| Inspect network status | `netinfo` | QEMU virtio-net and `capNet` | `tests/netinfo_test.sh` |
| Test TCP, UDP, DNS, or TLS | `tcpecho`, `udpecho`, `tcpget`, `nslookup`, `tlsget` | QEMU virtio-net and `capNet`; inbound tools also need host forwarding | Network tests listed in [Networking Guide](NETWORKING_GUIDE.md) |
| Exercise runtime features | `threadsdemo`, `mmapdemo`, `calc`, `kv` | Normal login shell | `tests/threads_test.sh`, `tests/mmap_test.sh`, `tests/calc_test.sh`, `tests/kv_test.sh` |
| Validate update slots | `swos-update`, `swos-activate`, `swos-confirm`, `swos-kstage`, `swos-kactivate`, `swos-kconfirm` | Matching A/B update-store or UEFI ESP test profile | Update tests listed in [Update And Rollback Guide](UPDATE_GUIDE.md) |
| Work with packages | `pkg`, `/usr/bin/pkghello`, `/usr/bin/lua`, `/usr/bin/minigzip`, `/usr/bin/bzip2`, `/usr/bin/pcre2grep`, `/usr/bin/nginx`, `/usr/bin/sqlite3` | Package payload, package-store, or signed repository fixture mounted or installed | Package tests listed in [Package Guide](PACKAGE_GUIDE.md) |
| Prove driver-service/device-grant behavior | `drvsvcdemo`, `deviceauthdemo` | C5 test profile or manual direct boot | `make c5-device-authority-test`, `make device-authority-cap-test` |

Example: to prove writable scratch space from the guest shell, use only tmpfs
paths:

```sh
mkdir /tmp/work
echo ok >/tmp/work/check.txt
cat /tmp/work/check.txt
rm /tmp/work/check.txt
rmdir /tmp/work
```

## Console And Shell

SwiftOS is headless by default. QEMU provides the primary serial console with
`-nographic`.

The boot init is `/bin/swos-init`. It starts configured boot services from
`/etc/swos/services`, then either hands the serial console to
`/bin/console-login` or stays alive for opt-in supervised service tokens.
The login shell is busybox `ash`. It supports normal command execution, pipes,
redirection, and the PATH used by the base image. The examples below can be
pasted at the shell prompt after login.

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

### `sudo`

Run a command as another principal (root by default) after authenticating the
invoking user. `/bin/sudo` is the one setuid-root binary in the signed base
image: exec'ing it elevates the process's effective identity to root, then sudo
re-authenticates the invoker against `/etc/swos/passwd`, applies the
`/etc/swos/sudoers` policy, and runs the command as the target.

```text
sudo [-u user] command [args...]
```

- The invoking user types **their own** password (the Unix default), not the
  target's.
- The `root` principal is always permitted and is never prompted.
- A bare command name resolves under `/bin` (e.g. `sudo id` runs `/bin/id`).
- `-u user` selects a target other than root, taken from `/etc/swos/passwd`.

Examples:

```sh
sudo id                 # run /bin/id as root
sudo -u guest id        # run /bin/id as the guest principal
```

Example session (logged in as the unprivileged `user`):

```text
$ id
principal=2(user) session=2 caps=0xe
$ sudo id
[sudo] password for user:
principal=1(root) session=1 caps=0x3f
```

`/etc/swos/sudoers` format — one rule per line, `#` comments ignored:

```text
name commands     # commands = ALL, or a comma-separated list of absolute paths
user ALL
```

Notes:

- A user not present in `/etc/swos/sudoers` is refused.
- The elevated identity does not leak back into the login shell: sudo only
  affects the command it execs, which is the process the parent shell awaits.
- The setuid bit is honored only for read-only base-image binaries, never tmpfs.

Acceptance coverage: `tests/sudo_test.sh`.

### `logtail`

Print a serialized tail of the in-memory kernel log ring.

```text
logtail [max-records]
logtail --stats
```

Examples:

```sh
logtail
logtail 8
logtail --stats
```

Notes:

- The caller must hold `capLogExport`; seeded accounts do not receive it by
  default.
- Output is newline-separated key=value records such as
  `tick=N level=I source=tag msg="text"`.
- `--stats` prints ring `capacity`, `available`, `total`, and `overwritten`
  counters for diagnosing truncated support captures.
- This is a local diagnostic command, not a persistent log store or remote
  collector.

Acceptance coverage: `tests/log_export_test.sh`.

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
- **Mode bits are metadata, not an access gate.** They are stored and shown by
  `ls -l`, but they do not restrict who may read, write, or execute the file.
  Read/write access is decided by process capabilities (`capFsRead`,
  `capTmpWrite`) and per-handle rights, not by the `rwx` bits. In particular
  `chmod 600 /tmp/secret` does **not** hide the file from another process that
  holds `capFsRead`. The only bit the kernel acts on is the execute bit
  (`0o111`), which is checked at `exec`, plus the setuid bit on signed base-image
  binaries. See [SECURITY_GUIDE.md](SECURITY_GUIDE.md) and
  [CAPABILITIES.md](CAPABILITIES.md).

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
- Like `chmod`, the owner field is metadata for `ls -l`, not an access gate;
  it does not by itself grant or deny access. The owner principal is consulted
  by the setuid-on-exec path for signed base-image binaries.

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

### `netinfo`

Print the guest's current network status snapshot, or turn that snapshot into a
deploy-readiness check.

```text
netinfo [--check] [--require-static6]
```

Examples in the guest:

```sh
/bin/netinfo
/bin/netinfo --check
/bin/netinfo --check --require-static6
```

Typical QEMU slirp output:

```text
netinfo: ready yes
netinfo: ipv4 10.0.2.15/24 source dhcp
netinfo: gateway4 10.0.2.2
netinfo: dns4 10.0.2.3
netinfo: ipv6 fe80:0000:0000:0000:... prefix 64 source link-local
netinfo: gateway6 none
netinfo: HC27 OK
```

Successful check output adds:

```text
netinfo: check ok
```

Notes:

- The command uses `SYS_NETINFO`, which is read-only but still requires
  `capNet`.
- IPv4 source is `dhcp` when the lease completed and `fallback` when the QEMU
  slirp defaults are in use.
- IPv6 source is `static` when `/etc/swos/net-ipv6` was staged at image build
  time, otherwise `link-local`.
- `--check` exits nonzero if the link is not ready or if IPv4 address, prefix,
  gateway, or DNS state is missing.
- `--require-static6` implies `--check` and also exits nonzero unless static
  IPv6, prefix `/64`, and an IPv6 gateway are present.

Acceptance coverage: `tests/netinfo_test.sh`, `make netinfo-test`,
`tests/sshd_deploy_preflight_test.sh`.

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

### `ssh`

Run the current SSH client transport preflight.

```text
ssh [ip] [port]
```

Examples in the guest:

```sh
/bin/ssh
/bin/ssh 10.0.2.2 2222
```

Notes:

- The default target is `10.0.2.2:22`, the usual QEMU slirp host alias.
- This command opens an outbound TCP stream, exchanges SSH identification
  strings with a normal OpenSSH server, sends client KEXINIT, completes
  `curve25519-sha256`, verifies the server's `ssh-ed25519` host-key signature
  over the exchange hash, matches the host key against `/etc/ssh/known_hosts`,
  handles OpenSSH strict KEX, derives
  `chacha20-poly1305@openssh.com` keys, and performs one encrypted
  `ssh-userauth` service request/accept exchange.
- This is a pre-auth transport proof only. Its known_hosts parser supports
  simple `ssh-ed25519` entries for bare IPv4 hosts or `[IPv4]:port` patterns.
  It does not implement user authentication, remote exec/session channels, PTY,
  scp, or sftp yet. Its KEX cookie and Curve25519 client ephemeral scalar use
  `SYS_RANDOM` when virtio-rng is attached, with a development fallback for
  non-rng QEMU profiles.
- A successful run exits 0 after printing `ssh: transport ready (preauth)`.

Acceptance coverage: `tests/ssh_transport_test.sh`,
`tests/ssh_runtime_entropy_test.sh`.

### `sshd`

Run the current SSH server session/exec preflight.

```text
sshd [-p PORT]
sshd [PORT]
```

Examples in the guest:

```sh
/bin/sshd
/bin/sshd -p 2222
```

Example on the host, when host TCP 2222 is forwarded to guest TCP 22:

```sh
make sshkey
build/sshkey known-host \
  --host '[127.0.0.1]:2222' \
  --seed-file base/etc/ssh/ssh_host_ed25519_seed \
  > build/swift-os-sshd-known-hosts

ssh -F /dev/null -vvv -p 2222 \
  -i fixtures/ssh/sshd_hc5_ed25519 \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o PasswordAuthentication=no \
  -o PubkeyAuthentication=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=build/swift-os-sshd-known-hosts \
  -o KexAlgorithms=curve25519-sha256 \
  -o HostKeyAlgorithms=ssh-ed25519 \
  -o Ciphers=chacha20-poly1305@openssh.com \
  -o MACs=hmac-sha2-256 \
  root@127.0.0.1 /bin/id
```

Notes:

- The default guest port is TCP 22.
- The default base image starts `/bin/sshd` at boot through `/bin/swos-init`
  and `/etc/swos/services`; manual `/bin/sshd` remains useful for custom ports
  or debug runs.
- Pass `-6` or `--ipv6` to bind an AF_INET6 stream socket. Custom service
  manifests can use the `sshd6` token to autostart `/bin/sshd -6` from
  `/bin/swos-init`; `sshd6-supervised` keeps the same IPv6 listener under the
  restart loop, and `sshd6-once` is the deterministic IPv6 restart test token.
- Custom base images can replace `/etc/swos/services` with
  `SWOS_SERVICES_FILE=PATH`. The opt-in tokens `sshd-supervised` and
  `sshd-once` keep `/bin/swos-init` alive as a restart loop for SSHD
  preflights; the IPv6 variants are `sshd6-supervised` and `sshd6-once`.
  Default `sshd` still hands off to the serial login.
- This command exchanges SSH identification strings with a normal OpenSSH
  client, negotiates `curve25519-sha256`, `ssh-ed25519`, OpenSSH strict KEX, and
  `chacha20-poly1305@openssh.com`, authenticates `root` with an `ssh-ed25519`
  key listed in `/etc/ssh/authorized_keys`, opens a `session` channel, and runs
  a bounded direct `/bin/<tool>` or `/usr/bin/<tool>` command. It forwards up
  to 512 bytes of remote stdin into the command's fd 0 and returns up to 4096
  bytes of captured stdout/stderr.
- Use `build/sshkey known-host --host HOST --seed-file
  base/etc/ssh/ssh_host_ed25519_seed` to derive the host known_hosts line from
  the same seed file `/bin/sshd` loads in the guest. For a deploy-specific
  image-time host key, generate a seed with `build/sshkey seed --out PATH` and
  build with `make SSHD_HOST_SEED_FILE=PATH base-image`. A deploy candidate can
  also stage an image-time KEX mix seed with `SSHD_KEX_SEED_FILE=PATH`; runtime
  entropy comes from `SYS_RANDOM` when the VM exposes virtio-rng. For
  deploy-specific login keys, build with
  `make SSHD_AUTHORIZED_KEYS_FILE=PATH base-image`.
- It uses a base-image host-key seed from `/etc/ssh/ssh_host_ed25519_seed`; the
  checked-in default seed is development-only. It mixes a daemon-local KEX
  session counter, runtime entropy from `SYS_RANDOM` when virtio-rng is
  attached, and, when present, `/etc/ssh/ssh_kex_seed`. It can bind IPv4 by
  default or AF_INET6 with `-6`/`sshd6`. `make
  sshd-deploy-preflight-test` proves one local static-IPv6/deploy-key/`sshd6`
  image profile; provider-routed SSHD-over-IPv6 remains a real-cloud deploy
  acceptance item. The
  `authorized_keys` parser supports simple `ssh-ed25519` public-key lines plus
  the safe restriction options `restrict`, `no-pty`, `no-port-forwarding`,
  `no-agent-forwarding`, and `no-X11-forwarding`. Other options, including
  forced commands and source restrictions, fail closed until `/bin/sshd` can
  enforce them. The
  command parser supports direct single-component `/bin/` and `/usr/bin/`
  executables with whitespace splitting, quote removal, and backslash escaping;
  redirects, globbing, shell sessions, PTY, scp, sftp, runtime host-key
  rotation, larger streaming stdin/stdout, and broader key option enforcement
  are not implemented yet.
  Output beyond the current 4096-byte cap is truncated and logged on the serial
  console.
- A successful host command exits 0 and prints the remote command's stdout.

Acceptance coverage: `tests/sshd_transport_test.sh`,
`tests/sshd_usr_bin_exec_test.sh`,
`tests/sshd_host_key_rotation_test.sh`,
`tests/sshd_runtime_entropy_test.sh`,
`tests/sshd_kex_seed_test.sh`,
`tests/sshd_authorized_keys_test.sh`,
`tests/sshd_ipv6_supervision_test.sh`,
`tests/sshd_deploy_preflight_test.sh`.

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
  TLS runtime smoke path and interoperability test, not as a production trust
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

### `acme`

Obtain an HTTPS certificate end to end from an ACME (RFC 8555) directory over the
in-tree TLS 1.3 stack, driving directory → newNonce → newAccount → newOrder →
authz → http-01 → finalize → certificate. A fresh P-256 account key and
certificate key are generated; the issued PEM chain and key are written under the
state directory and `fsync`ed for durability.

```text
acme <ip> <port> <dir-path> <domain> <webroot> <statedir> [--force] [--ca <pem>]
```

Examples:

```sh
/bin/acme 10.0.2.2 14010 /directory site.swos /data/www /data/acme
/bin/acme 10.0.2.2 14010 /directory site.swos /data/www /data/acme --force
```

Notes:

- The ACME directory is reached at `https://<ip>:<port><dir-path>`.
- `webroot` is the served directory; the http-01 token file is written under
  `<webroot>/.well-known/acme-challenge/<token>`.
- `statedir` holds the persistent `account.key` and per-domain `cert.pem` /
  `key.pem`. An existing certificate is kept unless `--force` is given.
- `--ca <pem>` enables TLS server-certificate verification against the given
  roots. Without it the client does not verify the server certificate — fine for
  the mock/Pebble harness, not for production trust.

Acceptance coverage: `tests/acme_mock_test.sh`, `tests/acme_persist_test.sh`, `tests/acme_verify_test.sh`.

## Interactive And Application Commands

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

Run the native Embedded Swift LLM inference command.

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
  this command in a fresh checkout.

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
| `pthreadprobe` | `pthreadprobe` | Exercise the C/newlib pthread facade over thread_create and futex. | `tests/pthread_test.sh` |
| `threadsyncprobe` | `threadsyncprobe` | Exercise C/newlib POSIX semaphores and pthread read/write locks. | `tests/threadsync_test.sh` |
| `selectprobe` | `selectprobe` | Exercise C/newlib `select` and `pselect` over the poll backend. | `tests/select_test.sh` |
| `eventfdprobe` | `eventfdprobe` | Exercise C/newlib eventfd counters and poll/select readiness. | `tests/eventfd_test.sh` |
| `epollprobe` | `epollprobe` | Exercise the node-compat epoll-over-poll emulation (create/ctl/wait/del) used by the Node.js/libuv masquerade. | `tests/epoll_test.sh` |
| `uvsemprobe` | `uvsemprobe` | Exercise C/newlib POSIX semaphores used by libuv's Unix semaphore wrappers. | `tests/uvsem_test.sh` |
| `uvrwlockprobe` | `uvrwlockprobe` | Exercise C/newlib pthread read/write locks used by libuv's Unix rwlock wrappers. | `tests/uvrwlock_test.sh` |
| `uvmutexprobe` | `uvmutexprobe` | Exercise C/newlib mutex types used by libuv's Unix mutex wrappers. | `tests/uvmutex_test.sh` |
| `uvthreadnameprobe` | `uvthreadnameprobe` | Exercise C/newlib thread names used by libuv's Unix thread helpers. | `tests/uvthreadname_test.sh` |
| `uvthreadstackprobe` | `uvthreadstackprobe` | Exercise C/newlib thread stack sizing used by libuv's `uv_thread_create_ex` path. | `tests/uvthreadstack_test.sh` |
| `uvkeyonceprobe` | `uvkeyonceprobe` | Exercise C/newlib thread-local keys, once guards, thread identity, join, and detach used by libuv's Unix thread layer. | `tests/uvkeyonce_test.sh` |
| `uvenvprobe` | `uvenvprobe` | Exercise C/newlib environment mutation and libuv-style child env propagation through `execvp`. | `tests/uvenv_test.sh` |
| `envchild` | `envchild` | Helper process for `uvenvprobe`; validates child-side `envp` and `environ` agreement. | `tests/uvenv_test.sh` |
| `uvbarrierprobe` | `uvbarrierprobe` | Exercise C/newlib pthread barriers used by libuv's native barrier path. | `tests/uvbarrier_test.sh` |
| `uvcondprobe` | `uvcondprobe` | Exercise C/newlib timed condition waits used by libuv's Unix thread layer. | `tests/uvcond_test.sh` |
| `uvsocketpairprobe` | `uvsocketpairprobe` | Exercise C/newlib `AF_UNIX` socketpair behavior used by libuv local streams. | `tests/uvsocketpair_test.sh` |
| `uvwakeprobe` | `uvwakeprobe` | Exercise C/newlib pthread-to-eventfd async wake over a blocking poll waiter. | `tests/uvwake_test.sh` |
| `uvsignalprobe` | `uvsignalprobe` | Exercise C/newlib libuv-style signal watcher self-pipe behavior. | `tests/uvsignal_test.sh` |
| `uvatforkprobe` | `uvatforkprobe` | Exercise C/newlib `pthread_atfork` ordering used by libuv fork reinitialization paths. | `tests/uvatfork_test.sh` |
| `uvspawnprobe` | `uvspawnprobe` | Exercise C/newlib fork/exec process-spawn behavior used by libuv's Unix `uv_spawn` path. | `tests/uvspawn_test.sh` |
| `signalprobe` | `signalprobe` | Exercise C/newlib signal disposition, current-process handler frame delivery, kill probes, SIGTERM child termination, and waitpid status. | `tests/signal_test.sh` |
| `ptyprobe` | `ptyprobe` | Exercise the pseudo-terminal line discipline end to end: canonical line assembly, echo, ONLCR output, backspace editing, and EOF on master close. | `tests/pty_test.sh` |
| `ptysigprobe` | `ptysigprobe` | Exercise PTY job-control SIGINT: Ctrl-C on the master delivers SIGINT to the foreground process under both default disposition and an installed handler. | `tests/ptysig_test.sh` |
| `socketprobe` | `socketprobe flags \| client HOST PORT \| server PORT` | Exercise C/newlib fd-flag helpers and TCP socket client/server paths. | `tests/socket_test.sh` |
| `mmapdemo` | `mmapdemo` | Exercise anonymous mmap, mprotect, executable mapping, and W^X rejection. | `tests/mmap_test.sh` |
| `largemmapprobe` | `largemmapprobe` | Exercise C/newlib multi-MiB mmap, partial mprotect, and bottom-region munmap reuse. | `tests/largemmap_test.sh` |
| `mmapreserveprobe` | `mmapreserveprobe` | Exercise C/newlib PROT_NONE reservation and mprotect commit/decommit. | `tests/mmapreserve_test.sh` |
| `mapfixedprobe` | `mapfixedprobe` | Exercise C/newlib MAP_FIXED reservation, guard-page, and fixed-region JIT behavior. | `tests/mapfixed_test.sh` |
| `sleepprobe` | `sleepprobe` | Probe nanosleep timing and timer wakeups. | `tests/sleep_test.sh` |
| `swos-init` | `swos-init` | Start allowlisted boot services from `/etc/swos/services`, then exec `console-login` or supervise opt-in service tokens. | `tests/sshd_transport_test.sh`, `tests/sshd_supervision_test.sh` |
| `console-login` | `console-login` | Run the serial login program used after boot init. | `tests/console_login_test.sh` |
| `busybox` | `busybox [APPLET] [ARGS...]` | Login shell and compatibility applet provider. | `tests/busybox_test.sh`, `tests/vi_test.sh` |
| `c4b-sockxfer` | `c4b-sockxfer` | Exercise IPC transfer of a UDP socket handle. | `tests/ipc_socket_transfer_test.sh` |
| `shmringprobe` | `shmringprobe` | Create a full-duplex shared-memory ring channel, fork, and round-trip records between parent and child over the mapped pages with no per-record syscall (LA3 data path). | `tests/shmring_test.sh` (`make shmring-test`, `-smp 4`) |
| `drvsvcdemo` | `drvsvcdemo` | Exercise restartable driver-service supervision plus opaque device-handle handoff, virtio-input discovery metadata, and the withheld-authority envelope over endpoint IPC. | `make c5-device-authority-test` (`-smp 4`) |
| `deviceauthdemo` | `deviceauthdemo` | Prove a non-console principal cannot discover or claim opaque device grants. | `make device-authority-cap-test` |
| `pkg` | `pkg repo set URL`, `pkg repo show`, `pkg update [URL]`, `pkg search TEXT`, `pkg info NAME`, `pkg install FILE\|NAME`, `pkg remove NAME`, `pkg list`, or `pkg files NAME` | Install local `.swpkg` files, install by name from signed HTTP repository fixtures or DNS-resolved HTTP repository URLs, inspect catalog or installed package metadata, deactivate installed packages for the next boot, list active package records, and list files in an installed package. | `tests/pkg_local_install_test.sh`, `tests/pkg_remove_test.sh`, `tests/pkg_repo_install_test.sh`, `tests/pkg_ports_seed_repo_install_test.sh`, `tests/pkg_static_host_dns_repo_install_test.sh` |
| `swos-confirm` | `swos-confirm` | Mark the booted A/B update-store slot confirmed healthy. | `tests/ab_confirm_test.sh` |
| `swos-activate` | `swos-activate` | Promote the inactive A/B update-store slot for the next boot. | `tests/ab_activate_test.sh` |
| `swos-update` | `swos-update` | Stage the attached signed SWOSBASE payload disk into the inactive A/B slot. | `tests/ab_stage_test.sh` |
| `swos-kstage` | `swos-kstage` | Copy the active ESP kernel slot image into the inactive kernel slot and verify it. | `tests/uefi_kstage_test.sh` |
| `swos-kactivate` | `swos-kactivate` | Select the inactive ESP kernel slot in loader-managed `kernel-state` for the next boot. | `tests/uefi_kactivate_test.sh` |
| `swos-kconfirm` | `swos-kconfirm` | Mark the booted ESP kernel slot confirmed healthy. | `tests/uefi_kconfirm_test.sh` |
| `reboot` | `reboot` | Flush `/data` and warm-reboot the machine via PSCI `SYSTEM_RESET`. Needs `capConsole`; a non-console principal is refused. | `tests/reboot_test.sh` |
| `shutdown` | `shutdown` | Flush `/data` and power the machine off via PSCI `SYSTEM_OFF` (QEMU `virt` exits). Needs `capConsole`; a non-console principal is refused. | `tests/reboot_test.sh` |
| `cellstatprobe` | `cellstatprobe` | C6a: fork children and assert `cell_stat` aggregates the live per-cell `{processes, residentPages, handles}` domain and reclaims reaped charge. | `tests/c6_cell_accounting_test.sh` |
| `cellcreateprobe` | `cellcreateprobe` | C6b: create a cell + control handle and `cell_spawn` `cellchild` into it; assert the child charges to the new cell, not globalCell. | `tests/c6_cell_create_test.sh` |
| `cellchild` | `cellchild` | C6b workload: announce liveness then block on a pipe barrier so the supervisor can measure its cell-charged footprint. | `tests/c6_cell_create_test.sh` |
| `cellnsprobe` | `cellnsprobe` | C6c: root a cell at `/www` and assert the spawned member is confined to it. | `tests/c6_cell_namespace_test.sh` |
| `cellnschild` | `cellnschild` | C6c workload: resolve a file inside the cell root but be refused `/etc` and `/` (namespace confinement). | `tests/c6_cell_namespace_test.sh` |
| `cellcapprobe` | `cellcapprobe` | C6d: cap a cell's resident pages, spawn until refused, enumerate members (`cell_pids`), prove `cell_destroy` is EBUSY while live, then reap + free + reuse the CellId. | `tests/c6_cell_lifecycle_test.sh` |
| `cellhello` | `cellhello` | C6e service: a request/reply IPC service that proves its own isolation and replies `pong` to `ping` over its granted endpoints. | `tests/c6_cell_service_test.sh` |
| `cellsvcprobe` | `cellsvcprobe` | C6e: assemble a cell { `/www` root + restricted handles + page cap }, host `cellhello`, drive a live round-trip, then tear down. | `tests/c6_cell_service_test.sh` |
| `cellgrower` | `cellgrower` | C7a workload: `sbrk`/`mmap` its own heap until the cell's resident-page cap refuses it (intra-member enforcement). | `tests/c7_cell_pagecap_test.sh` |
| `cellgrowprobe` | `cellgrowprobe` | C7a: cap a cell, host `cellgrower`, assert `cell_stat.residentPages <= cap` while an uncapped global member is unaffected. | `tests/c7_cell_pagecap_test.sh` |
| `cellopener` | `cellopener` | C7b workload: `open()` files until the cell's handle cap refuses with `EMFILE`. | `tests/c7_cell_handlecap_test.sh` |
| `cellhandleprobe` | `cellhandleprobe` | C7b: cap a cell's handles, host `cellopener`, assert `cell_stat.handles <= cap` while an uncapped global member is unaffected. | `tests/c7_cell_handlecap_test.sh` |
| `cell-svc` | `cell-svc serve\|crash` | C7c demo service: reply `pong` to `ping` (exit non-zero on `die`), or crash immediately, so the supervisor can drive restart and crash-loop paths. | `tests/c7_cell_supervisor_test.sh` |
| `cell-supervisor` | `cell-supervisor` | C7c: a persistent restart/FDIR supervisor that hosts `cell-svc` in a cell, restarts it in a fresh CellId on exit, and bounds restarts so a crash loop halts. | `tests/c7_cell_supervisor_test.sh` |
| `cell-kv-supervisor` | `cell-kv-supervisor` | C7d: lift the real `/bin/kv` store into a supervised cell over pipes — restricted handles + caps, a live `SET`/`GET` round-trip, restart in a fresh cell with fresh state, clean teardown. | `tests/c7_cell_realservice_test.sh` |
| `crond` | `crond [crontab-file...]` | Native Swift cron daemon: launches commands on a schedule (classic five-field rows plus `@reboot`/`@hourly`/`@every <dur>` shortcuts) merged from the signed `/etc/crontab` and the durable `/data/crond/crontab`, running each fired job synchronously as `/bin/sh -c` (fork+exec+wait). No live reload; a job that never exits stalls the scheduler (no `WNOHANG` yet). | `tests/crond_test.sh` |
| `inputd` | `inputd` | C5j persistent userland virtio-input driver started by `swos-init`: a poll loop drains the event virtqueue, decodes evdev key presses to ASCII, and injects each byte into the kernel tty (`swiftos_tty_inject`, `capConsole`-gated). Exits 0 cleanly on a board with no virtio-input window. | `tests/c5_tty_inject_test.sh` |
| `svc-input` | `svc-input` | LA1 native Swift driver service built on the reusable `UserlandService` template: announces `DRVREADY`, serves `PING`/`DEVH`/`STOP` over endpoint IPC, and validates a transferred device grant metadata-only (never ambient). Launched by `svc-supervisor`. | `tests/userland_service_test.sh` |
| `svc-supervisor` | `svc-supervisor` | LA1 persistent PID-1-style supervisor for native Swift services: creates endpoint pairs, publishes/looks up the service endpoint in the kernel name registry, spawns `svc-input` with the explicit-handle ABI, hands the device grant over by IPC transfer only, reclaims it on stop, and runs a bounded restart loop over two generations. | `tests/userland_service_test.sh` |
| `netsvc` | `netsvc <shmring-id>` | NS3 restartable userland net service that owns the secondary `virtio-net.1` NIC and relays Ethernet frames over a shared-memory (shmring) data plane — the network analog of the C5 driver service. Control records carry `RDY`/`STP`; frame records carry raw Ethernet. Exits 0 when no secondary NIC exists. | `tests/ns3_net_service_test.sh` |
| `netsvc-demo` | `netsvc-demo` | NS3 supervisor + client boot self-test that drives `/bin/netsvc` over an shmring channel: spawns the service for two generations, round-trips an ARP request frame through it against the slirp gateway, and proves a kill+restart recovers the service over the same data plane. Exits 0 when no secondary NIC exists. | `tests/ns3_net_service_test.sh` |
| `sctld` | `sctld` | SwiftCube control-plane daemon (SC2). On-device it runs the in-process control-plane self-test (token join → register → heartbeat → expiry → watch lifecycle over the real mutual-TLS engine with an injected clock); its production form serves SC2 RPCs to remote `slet` agents over mTLS-TCP. | `tests/sc2_join_test.sh` |
| `slet` | `slet` | SwiftCube node agent (SC2). On-device it exercises the node-side identity path (generate an EC P-256 key, build a PKCS#10 CSR, verify it parses back to the same key); the SC3 reconcile loop and C6 Cell-supervisor seam compile in but the SwiftCube→C6 mapping is honestly not yet wired. Its production form connects to a remote `sctld` over mTLS-TCP. | `tests/sc2_join_test.sh` |
| `ptyrun` | `ptyrun [program]` | Manual diagnostic that runs a program on a pseudo-terminal slave via the exact `openpty` + `swiftos_pty_spawn_shell` path `/bin/sshd` uses for an interactive session, printing `PTYRUN:` exit markers — built to reproduce a PTY/SSH-only crash without the network. Not wired into an automated test of its own; the related automated PTY-over-SSH scenario is `make mc-test`. | `make mc-test` |
| `swos-stagebase` | `swos-stagebase <image-file> <version>` | Stream a signed `SWOSBASE` image from a file into the inactive A/B slot and commit it (OS-3b); the file-driven exerciser for the base-image streaming syscalls. Needs `capConsole`. Run `/bin/swos-activate` + reboot to boot it on trial. | `tests/os_stage_test.sh` |
| `swos-kinstall` | `swos-kinstall <kernel-image-file> <entry-file>` | Install a genuinely NEW host-signed kernel into the inactive ESP slot (OS-1c-2b): stream the padded image, then commit its 104-byte signed manifest entry (the kernel verifies full-slot write, size, on-disk re-hash, and the per-slot Ed25519 signature). Needs `capConsole`. Run `/bin/swos-kactivate` + reboot to boot it on trial. | `tests/uefi_kinstall_test.sh` |

### `swos-init`

Start the current boot service handoff program.

```text
swos-init
```

Notes:

- The kernel starts `/bin/swos-init` automatically when it is present in the
  base image.
- `swos-init` reads immutable `/etc/swos/services`, starts allowlisted services
  such as `sshd`, and then `execve()`s `/bin/console-login`.
- The opt-in tokens `sshd-supervised` and `sshd-once` keep `swos-init` alive as
  a simple restart loop. `sshd-once` is a test token: it starts `/bin/sshd` in
  one-session mode and proves the supervisor can restart it for a second SSH
  command. `sshd6-supervised` and `sshd6-once` do the same for `/bin/sshd -6`.
- It is deliberately not a full service manager: there is no dependency graph,
  package service activation, or production health policy yet.

Acceptance coverage: `tests/sshd_transport_test.sh`,
`tests/sshd_supervision_test.sh`.

Examples:

```sh
/bin/threadsdemo
/bin/mmapdemo
/bin/sleepprobe
/bin/busybox vi /tmp/note.txt
/bin/drvsvcdemo
pkg list
swos-update
swos-activate
swos-confirm
swos-kstage
swos-kactivate
swos-kconfirm
```

`drvsvcdemo` starts `/bin/drvinputd` twice, exchanges endpoint IPC messages,
expects `C5a OK: restartable driver service recovered over IPC`, claims either
the discovered `virtio-input.0` device grant or the `pseudo-input.0` fallback,
transfers it to the restarted service, and expects
`C5b OK: opaque device handle transferred and released`. When the QEMU keyboard
device is attached, it also expects
`C5c OK: virtio-input device grant discovered and matched`. It is a
driver-service shape smoke with an opaque registry grant, not a userland
MMIO/IRQ/DMA driver handoff. The C5d metadata gate additionally expects
`C5d OK: virtio input discovery metadata surfaced`; the C5e authority gate
expects `C5e OK: device authority withheld until explicit handoff`; the C5f
rights guard expects `C5f OK: device grant rights stayed metadata-only`.

## System Update Commands

These commands are part of the checked A/B validation paths. They require the
matching boot profile and update media; they are not a general online updater.
Use [UPDATE_GUIDE.md](UPDATE_GUIDE.md) for the operator runbook.

### `swos-update`

Stage the attached signed SWOSBASE payload disk into the inactive base-image
A/B slot.

```text
swos-update
```

Expected success:

```text
swos-update: payload staged into the inactive slot; run swos-activate then reboot
```

Acceptance coverage: `tests/ab_stage_test.sh`

### `swos-activate`

Promote the inactive base-image A/B slot for the next boot.

```text
swos-activate
```

Expected success:

```text
swos-activate: inactive slot activated (on trial); reboot to use it
```

Acceptance coverage: `tests/ab_activate_test.sh`

### `swos-confirm`

Mark the currently booted base-image A/B slot healthy.

```text
swos-confirm
```

Expected success:

```text
swos-confirm: active slot confirmed healthy
```

Acceptance coverage: `tests/ab_confirm_test.sh`

### `swos-kstage`

Copy the active ESP kernel image into the inactive kernel slot and verify the
copy.

```text
swos-kstage
```

Expected success:

```text
swos-kstage: active kernel image staged into the inactive ESP slot (verified)
```

Acceptance coverage: `tests/uefi_kstage_test.sh`

### `swos-kactivate`

Select the inactive ESP kernel slot for the next boot.

```text
swos-kactivate
```

Expected success:

```text
swos-kactivate: inactive kernel slot activated; reboot to use it
```

Acceptance coverage: `tests/uefi_kactivate_test.sh`, `tests/uefi_kattempt_test.sh`,
`tests/uefi_krollback_test.sh`

### `swos-kconfirm`

Mark the ESP kernel slot booted by the loader healthy.

```text
swos-kconfirm
```

Expected success:

```text
swos-kconfirm: booted kernel slot confirmed healthy
```

Acceptance coverage: `tests/uefi_kconfirm_test.sh`

Notes:

- `swos-update`, `swos-activate`, and `swos-confirm` operate on the SWOSBOOT
  base-image update store.
- `swos-kstage`, `swos-kactivate`, and `swos-kconfirm` operate on UEFI ESP
  kernel-slot files, the signed slot manifest, and the loader-managed
  `kernel-state`.
- Permission failures print `permission denied (need capConsole)`.
- Kernel-slot boot-attempt persistence is tested by `tests/uefi_kattempt_test.sh`;
  attempt-based kernel-slot rollback is tested by
  `tests/uefi_krollback_test.sh`. Kernel-slot health confirmation is tested by
  `tests/uefi_kconfirm_test.sh`.

### `swupdate`

Update the **hosted static site** (the nginx docroot) on a running box without a
base-image reflash. nginx serves from `/data/www/current` on the persistent `/data`
tier; `swupdate` seeds it, and atomically swaps in a new generation from a signed
bundle. This is content-only — it does **not** update the kernel or base image
(use the A/B commands above for those). Build a bundle with the host `sitepack`
tool ([HOST_TOOL_REFERENCE.md](HOST_TOOL_REFERENCE.md)).

```text
swupdate seed                      # boot-time: seed/recover /data/www/current
swupdate apply-local <bundle.swsite>   # apply a local signed bundle (offline/testing)
swupdate site <https-url>          # fetch a signed bundle over HTTPS and apply it
```

`seed` runs automatically from `/bin/swos-init` before any service: on an empty
`/data` it copies the baked default site into `/data/www/current`, and it recovers
a crash-interrupted swap (finishing `next`→`current`, or rolling back to `prev`).

`apply-local` / `site` verify the bundle's Ed25519 signature against the baked
`/etc/swupdate/site-root.pub` **and** its payload SHA-256 before unpacking into
`/data/www/next` and atomically swapping (`current`→`prev`, `next`→`current`). The
previous generation is retained in `/data/www/prev` for rollback.

Expected success:

```text
swupdate: applied site bundle; /data/www/current updated
```

A bad bundle is refused without touching the live docroot:

```text
swupdate: bundle signature INVALID — rejected
```

Notes:

- **Security.** The trigger is gated by the operator SSH key (the bounded-exec
  allowlist permits `/bin/*`); the content by the Ed25519 bundle signature. No
  scp, no writable root. TLS provides confidentiality only (the cert is not yet
  verified) — the signature is the authenticity anchor, so a MITM serving a
  different bundle fails verification.
- **Inode budget.** datafs holds 256 inodes total; with `current`+`next`+`prev`
  that is ~3× the site, so a bundle is capped at 64 entries.
- Acceptance coverage: `make site-seed-test`, `make site-bundle-test`,
  `make site-update-test`.

## Package Commands

### `pkg`

Install a local SwiftOS package file, update/search/inspect the signed HTTP
repository fixture, install a package by name from that fixture, list active
package-store records, or list files in an installed package.

```text
pkg repo set URL
pkg repo show
pkg update [URL]
pkg search TEXT
pkg info NAME
pkg install FILE
pkg install NAME
pkg remove NAME
pkg list
pkg files NAME
```

Example local install fixture:

```sh
pkg list
pkg install /packages/pkghello.swpkg
pkg list
pkg info pkghello
pkg files pkghello
pkg remove pkghello
/usr/bin/pkghello
```

Expected output includes:

```text
no packages installed
pkg: installed pkghello-1.0.0_1
pkghello-1.0.0_1
source: installed
/usr/bin/pkghello
pkg: deactivated pkghello (effective after reboot)
pkghello: hello from package overlay
```

Example signed repository fixture:

```sh
pkg repo set http://10.0.2.2:<port>/good/aarch64/current
pkg repo set http://pkg.test.swos:<port>/aarch64/current
pkg repo show
pkg update
pkg search pkghello
pkg info pkghello
pkg install pkghello
pkg list
pkg files pkgdep
pkg files pkghello
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
/usr/bin/pkgdep
/usr/bin/pkghello
pkghello: hello from package overlay
```

Notes:

- `pkg install FILE` expects a local `.swpkg`.
- `pkg repo set URL` stores the active repository URL in tmpfs for the current
  boot. `pkg repo show` prints the configured URL. If `/etc/pkg/repo-url` is
  present in the base image, `pkg update` can use it without a prior
  `pkg repo set`; the test base image is built with `PKG_DEFAULT_REPO_URL`.
- `pkg update [URL]` expects a signed static HTTP repository URL, such as
  the QEMU fixture path under
  `http://10.0.2.2:<port>/good/aarch64/current`. It rejects expired catalogs,
  incompatible package entries, and invalid dependency entries.
- Repository URLs are currently HTTP-only. The host can be numeric IPv4 or a
  DNS hostname. If a test or deployment needs an explicit DNS resolver, provide
  `/etc/pkg/dns-server` in the base image; the makefile accepts
  `PKG_DEFAULT_DNS_SERVER=IP[:port]`.
- `pkg search` and `pkg install NAME` use the verified catalog cached by
  `pkg update`; install by name resolves package-name dependencies and verifies
  each downloaded package SHA-256 before activation. `pkg info NAME` prints the
  verified catalog entry when present, otherwise it falls back to active
  installed package metadata.
- The guest must be booted with a writable package-store image for install to
  succeed.
- `pkg remove NAME` appends a new package-store activation without the named
  package. In the current VFS, package payloads are not live-unmounted, so the
  deactivation becomes visible after rebooting with the same writable
  package-store image.
- `pkg list` reports the package records currently visible through the active
  package store. `pkg files NAME` reports newline-separated absolute file paths
  from the named active package payload.
- See [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md) for the complete runbook.

Acceptance coverage: `tests/pkg_local_install_test.sh`,
`tests/pkg_remove_test.sh`, and
`tests/pkg_repo_install_test.sh`; the multi-package ports seed/default-repo
flow for Lua, zlib, bzip2, zstd, xz, libarchive, ca-certificates, OpenSSL, pcre2, tzdata, nginx, and sqlite is
by `tests/pkg_ports_seed_repo_install_test.sh`, and the DNS-resolved
hosted-style URL flow is covered by
`tests/pkg_static_host_dns_repo_install_test.sh`.

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

### `sqlite3`

The SQLite command-line shell (packaged port, baked into the base image as
`/bin/sqlite3`). Create and query databases. Durable databases live on the
persistent `/data` tier (datafs); `:memory:` and `/tmp` databases are ephemeral.

```text
sqlite3 [DB] [SQL]
```

Example:

```sh
sqlite3 /data/app.db "create table t(x text); insert into t values('hi');"
sqlite3 /data/app.db "select * from t;"
```

Notes:

- Built from the SQLite amalgamation (`SQLITE_OMIT_WAL`, `SQLITE_THREADSAFE=0`);
  it uses a rollback journal, so a database on `/data` is crash-safe via `fsync`.
- A database stored under `/data` survives reboot; under `/tmp` it does not.

Acceptance coverage: `tests/datafs_sqlite_test.sh`.

## Bring-up Diagnostic Commands

The following programs remain staged in `/bin` because they prove specific
kernel and userland paths. They are valuable to developers and tests, but they
are not the primary operator interface.

| Command | What it proves | Run directly? | Acceptance coverage |
| --- | --- | --- | --- |
| `hello` | Minimal static ELF user program and exit-status path. | Yes, as a smoke test. | `tests/boot_test.sh`, `tests/userland_elf_test.sh` |
| `ttydemo` | Canonical tty input, echo, and Ctrl-C signal delivery. | Usually only during scripted boot flows. | `tests/boot_test.sh`, `tests/vi_test.sh` |
| `argvdemo` | `argc`/`argv` setup plus C2/C3/C4 handle-right denial probes when spawned with test arguments. | Yes for basic argv display; special modes are driven by `spawndemo`. | `tests/boot_test.sh` |
| `spawndemo` | `spawn`, `spawn_handles`, explicit handle inheritance, and endpoint rights attenuation. | Yes, for process-launch diagnostics. | `tests/boot_test.sh` |
| `selfexecdemo` | Open executable reuse and malformed argv pointer rejection without an EL1 panic. | Yes, for exec regression checks. | `tests/spawn_self_exec_test.sh` |
| `fsdemo` | `getcwd`, `getdents`, `stat`, `chdir`, tmpfs I/O, and confinement checks. | Yes, for filesystem ABI diagnostics. | `tests/boot_test.sh` |
| `brkdemo` | `sbrk` heap growth across page boundaries. | Yes, for allocator bring-up diagnostics. | `tests/boot_test.sh` |
| `newlibtest` | newlib `printf`, `malloc`, `fopen`, and file I/O over the SwiftOS syscall port. | Yes, when validating C compatibility. | `tests/boot_test.sh` |
| `clockprobe` | newlib compat `clock_gettime`, `clock_getres`, realtime clock, monotonic ticks, and `nanosleep` interaction. | Yes, when validating C runtime timing compatibility. | `tests/clock_test.sh` |
| `mprotectprobe` | newlib compat `mmap`, `mprotect`, executable mappings, and W^X rejection. | Yes, when validating C runtime memory-permission compatibility. | `tests/mprotect_test.sh` |
| `largemmapprobe` | newlib compat multi-MiB `mmap`, partial `mprotect`, bottom-region `munmap` reuse, and zero-fill checks. | Yes, when validating C runtime large-mapping compatibility. | `tests/largemmap_test.sh` |
| `mmapreserveprobe` | newlib compat `mmap(PROT_NONE)`, `MAP_NORESERVE`, `mprotect` commit/decommit, and reserved-region RW->RX execution. | Yes, when validating C runtime lazy-reservation compatibility. | `tests/mmapreserve_test.sh` |
| `mapfixedprobe` | newlib compat `MAP_FIXED`, `MAP_FIXED_NOREPLACE`, guard-page recommit, fixed-region replacement, and RW->RX execution. | Yes, when validating C runtime fixed-address mmap compatibility. | `tests/mapfixed_test.sh` |
| `pthreadprobe` | newlib compat `pthread_create`, `pthread_join`, mutexes, condition variables, once, and thread-specific data. | Yes, when validating C runtime threading compatibility. | `tests/pthread_test.sh` |
| `threadsyncprobe` | newlib compat `sem_init`, `sem_wait`, `sem_post`, `sem_timedwait`, and `pthread_rwlock_*`. | Yes, when validating C runtime synchronization compatibility. | `tests/threadsync_test.sh` |
| `selectprobe` | newlib compat `select`, `pselect`, and `fd_set` readiness over pipes. | Yes, when validating C runtime event-loop compatibility. | `tests/select_test.sh` |
| `eventfdprobe` | newlib compat `eventfd`, `eventfd_read`, `eventfd_write`, and readiness over poll/select. | Yes, when validating C runtime event notification compatibility. | `tests/eventfd_test.sh` |
| `epollprobe` | node-compat epoll emulation over poll/eventfd (`epoll_create1`/`epoll_ctl`/`epoll_wait`), the SwiftOS backend for libuv's linux event loop. | Yes, when validating the Node.js/libuv epoll masquerade. | `tests/epoll_test.sh` |
| `uvsemprobe` | newlib compat POSIX semaphore init, try/wait/timedwait/post, cross-thread wake, counting, and overflow behavior, matching libuv's Unix semaphore wrappers. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvsem_test.sh` |
| `uvrwlockprobe` | newlib compat pthread read/write lock init, writer exclusion, concurrent readers, and blocked-writer wake behavior, matching libuv's Unix rwlock wrappers. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvrwlock_test.sh` |
| `uvmutexprobe` | newlib compat `PTHREAD_MUTEX_ERRORCHECK` and `PTHREAD_MUTEX_RECURSIVE`, matching libuv's Unix mutex wrappers. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvmutex_test.sh` |
| `uvthreadnameprobe` | newlib compat `pthread_setname_np` and `pthread_getname_np`, matching libuv's Unix thread naming helpers. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvthreadname_test.sh` |
| `uvthreadstackprobe` | newlib compat `getrlimit(RLIMIT_STACK)`, `getpagesize`, and `pthread_attr_setstacksize`, matching libuv's `uv_thread_create_ex` stack sizing path. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvthreadstack_test.sh` |
| `uvkeyonceprobe` | newlib compat `pthread_once`, thread-local keys, `pthread_self`/`pthread_equal`, join, and detach, matching libuv's Unix thread wrappers. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvkeyonce_test.sh` |
| `uvenvprobe` | newlib compat `getenv`/`setenv`/`unsetenv`, `execve` envp stack propagation, and `environ` override before `execvp`, matching libuv child env setup. | Yes, when validating C runtime libuv process/environment compatibility. | `tests/uvenv_test.sh` |
| `envchild` | Helper launched by `uvenvprobe` to validate inherited `envp`, global `environ`, and `getenv` from the child side. | Usually launched by `uvenvprobe`, not manually. | `tests/uvenv_test.sh` |
| `uvbarrierprobe` | newlib compat reusable `pthread_barrier_*` phases, matching libuv's native barrier branch. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvbarrier_test.sh` |
| `uvcondprobe` | newlib compat `pthread_cond_timedwait` with `CLOCK_MONOTONIC` timeout and signal wake, matching libuv's Unix timed condition waits. | Yes, when validating C runtime libuv thread compatibility. | `tests/uvcond_test.sh` |
| `uvsocketpairprobe` | newlib compat full-duplex `AF_UNIX` `socketpair`, matching libuv local stream/process pipe expectations. | Yes, when validating C runtime libuv local stream compatibility. | `tests/uvsocketpair_test.sh` |
| `uvwakeprobe` | newlib compat worker-thread `eventfd_write` waking a main-thread blocking `poll`, matching libuv async wake expectations. | Yes, when validating C runtime event-loop wake compatibility. | `tests/uvwake_test.sh` |
| `uvsignalprobe` | newlib compat `pthread_sigmask` facade and handler-to-pipe wake, matching libuv signal watcher setup and dispatch shape. | Yes, when validating C runtime libuv signal-watcher compatibility. | `tests/uvsignal_test.sh` |
| `uvatforkprobe` | newlib compat `pthread_atfork` prepare/parent/child ordering around `fork`, matching libuv fork reinitialization expectations. | Yes, when validating C runtime libuv process compatibility. | `tests/uvatfork_test.sh` |
| `uvspawnprobe` | newlib compat `fork`/`execvp` close-on-exec error pipe, `dup2` stdio mapping, and `waitpid`, matching libuv's Unix `uv_spawn` child setup. | Yes, when validating C runtime libuv process compatibility. | `tests/uvspawn_test.sh` |
| `signalprobe` | newlib compat `sigaction`, `signal`, `raise`, `sigreturn` handler frames, `kill`, and `waitpid` signaled status. | Yes, when validating C runtime process-control compatibility. | `tests/signal_test.sh` |
| `socketprobe` | newlib compat `pipe2`, `socket` flags, `accept4`, `getaddrinfo`, socket options, TCP client, and TCP server paths. | Yes, when validating C runtime network compatibility. | `tests/socket_test.sh` |
| `coproc` | CPU-bound EL0 scheduling and preemption telemetry. | Usually launched by kernel/test harnesses with tags. | `tests/boot_test.sh`, `tests/smp_boot_test.sh` |
| `forkdemo` | `fork`, `waitpid`, inherited cwd/fd state, IPC polling, and moved-handle receive. | Yes, for process and IPC diagnostics. | `tests/boot_test.sh`, `tests/cow_test.sh` |
| `execdemo` | `execve` replacement of the current process image. | Yes, for exec diagnostics. | `tests/boot_test.sh` |
| `fdopsdemo` | `dup`, `dup2`, shared offsets, pipes, `poll`, rename, unlink, mkdir, and rmdir. | Yes, for fd/VFS diagnostics. | `tests/boot_test.sh` |
| `securitydemo` | Invalid pointer, bad fd, readonly, directory, and syscall abuse rejection. | Yes, for syscall hardening diagnostics. | `tests/boot_test.sh` |
| `deviceauthdemo` | C5g negative device discovery and claim checks for restricted principals. | Yes, but run it as `guest` or prefer the make target. | `make device-authority-cap-test` |
| `identitydemo` | Boot principal/session/capability context and fork inheritance of security context. | Yes, for identity diagnostics. | `tests/boot_test.sh`, `tests/base_image_test.swift` |
| `logtail-probe` | Capability-gate probe for `SYS_LOG_READ` and `SYS_LOG_STATS`: denied without `capLogExport`, then reads after an explicit admin-context grant. | Yes, for log export acceptance only. | `tests/log_export_test.sh` |
| `s4stress` | S4f resource churn across mmap, pipes, tmpfs, fork/wait, and spawn under `-smp 4`. | Yes, but prefer the make target. | `make s4-resource-stress-test` |
| `drvsvcdemo` | C5a-C5f pseudo/virtio-input driver supervisor, discovery metadata, withheld hardware authority, metadata-only grant rights, opaque grant transfer, restart, and reclaim. | Yes, for C5 diagnostics. | `make c5-test` |
| `drvinputd` | Worker service started by `drvsvcdemo`; validates endpoint and device-grant handoff. | No; it expects endpoint fd arguments from the supervisor. | `make c5-device-authority-test` |
| `orphandemo` | QW3 orphan-zombie reaper: a parent exits leaving running children, which are reparented and reaped without leaking process slots or endpoints. | Yes, for process-teardown diagnostics. | `make orphan-reap-test` |
| `qw2-ipc` | QW2 blocking IPC: a receiver parks on an empty endpoint and is woken by `ipc_send` or by the last sender closing (EOF). | Yes, for IPC park/wake diagnostics. | `make qw2-blocking-ipc-test` |
| `ipc-call-test` | QW1 synchronous request/reply IPC: `ipc_call`/`ipc_reply_recv` over a kernel reply port — correlated replies, a handle round-tripped both ways, and EINVAL/EPIPE error paths. | Yes, for synchronous-IPC diagnostics. | `make ipc-call-test` |
| `qw4-badge` | QW4 endpoint badges: stamps a distinct server-chosen badge into two clients' send handles with `ipc_badge`, then proves `ipc_recv_badged` reports the right badge per client (and `0` for an unbadged send) on otherwise-identical endpoints. | Yes, for endpoint-badge diagnostics. | `make qw4-badge-test` |
| `qw5-rightsxfer` | QW5 rights intersection on IPC transfer: moves a `/dev/zero` handle (READ\|WRITE\|TRANSFER) over an endpoint requesting only READ\|TRANSFER, then proves the receiver can read but not write (WRITE attenuated away, `effective = held ∩ requested`) and the sender's source fd was invalidated (move semantics). | Yes, for capability-attenuation diagnostics. | `make qw5-rights-intersection-test` |
| `devicemmapprobe` | LA2 device-MMIO-map authority: a mappable device grant carries the `.map` right and `device_mmap` returns a live mapping whose virtio identification registers read back the expected magic/version/device-id, while a no-MMIO grant and a non-console claim are both refused with EACCES. | Yes, for device-MMIO authority diagnostics. | `tests/device_mmio_map_test.sh` |
| `netmmapprobe` | NS1 network-serviceization: the NIC's MMIO authority reaches userland via the mappable `virtio-net.0` grant — it `device_mmap`s the transport window and reads the identity registers plus the config-space MAC — without disturbing the in-kernel net driver that keeps owning the NIC. Exits 0 on a board with no NIC. | Yes, for NIC MMIO-grant diagnostics. | `tests/ns1_net_grant_test.sh` |
| `netdriverprobe` | NS2 userland virtio-net driver: an EL0 driver brings up the SECONDARY `virtio-net.1` NIC via the shared userland virtio-net core and completes an ARP round-trip against the slirp gateway, never touching the live kernel-owned NIC. Exits 0 on a single-NIC profile. | Yes, for userland NIC driver diagnostics. | `tests/ns2_net_driver_test.sh` |
| `edgestress` | Milestone-3 memory edge cases: sparse page-table pressure (munmap reclaims the intermediate page-table frames back to the free-frame baseline, and an absurd reservation is refused gracefully with no panic) and the COW fork lifecycle (the inc-on-fork/dec-on-exit refcount path leaks no frames). | Yes, but prefer the make target. | `tests/edge_stress_test.sh` |
| `satstress` | Fixed-size kernel-pool saturation: each bounded pool (processes, per-process fds, pipes, IPC endpoints) saturates with a clean negative errno rather than a panic, and returns to a usable baseline after release (no slot leak); a tmpfs vnode create/unlink churn stays balanced. | Yes, but prefer the make target. | `tests/saturation_test.sh` |
| `smprace` | Concurrent cross-CPU resource churn: N copies placed on different CPUs (S5f run-any) hammer the shared frame allocator, VFS/tmpfs, and pipe pools at once; the kernel asserts the S4 lock-boundary guards stay balanced and `pmm_free_count` returns to baseline after every copy is reaped. | Usually launched by the kernel/test harness under `-smp 4`. | `tests/smp_race_stress_test.sh` |
| `futexprobe` | TH8 raw `SYS_FUTEX` boundaries: `FUTEX_WAIT` with `*uaddr != val` returns 0 without blocking, `FUTEX_WAKE` with no waiters returns 0 without faulting, and one word with several waiters wakes every waiter with no lost wakeup across CPUs (built for `-smp 4`). | Yes, when validating futex boundaries. | `tests/futex_test.sh` |

Prefer the commands in the earlier sections for normal use. Use these diagnostic
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
