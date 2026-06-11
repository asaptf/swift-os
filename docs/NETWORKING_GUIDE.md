# SwiftOS Networking Guide

This guide explains how to run and verify networking on the current SwiftOS
image. It is written for operators, application authors, and support engineers
who need a working network profile, exact command examples, and a clear picture
of the current limits.

SwiftOS networking today is real but intentionally small: a QEMU `virt`
virtio-net device, an in-kernel pure-Swift TCP/IP stack, capability-gated socket
syscalls, DHCPv4 lease acquisition with a QEMU/slirp static fallback, and a set
of native userland network tools. It is enough to serve static files, serve
local TinyStories completions, run TCP and UDP echo services, resolve DNS, and
exercise the TLS 1.3 client path. It also includes an SSH client transport
preflight against OpenSSH and an SSHD session/exec preflight that accepts a
normal OpenSSH client on guest TCP/22, loads development SSH key material from
the base image, authenticates a configured Ed25519 key, and runs one direct
remote command.

Use this guide with:

- [Getting Started](GETTING_STARTED.md) for the shortest first-boot path.
- [Service Guide](SERVICE_GUIDE.md) for readiness markers and service behavior.
- [AI Hosting Guide](AI_HOSTING_GUIDE.md) for `/bin/llmd` bundle operation.
- [Command Reference](COMMAND_REFERENCE.md) for exact command syntax.
- [Observability Guide](OBSERVABILITY_GUIDE.md) for serial logs and metrics.
- [Troubleshooting](TROUBLESHOOTING.md) for failure diagnosis.
- [API Reference](API_REFERENCE.md) for socket syscall details.

## Current Network Model

| Area | Current behavior |
| --- | --- |
| Hardware profile | QEMU `virt` with `virtio-net-device` over virtio-mmio |
| Link mode | QEMU user networking, also called slirp; cloud virtio-net DHCP is the first deployment target |
| Guest IPv4 | DHCPv4 lease when offered; fallback `10.0.2.15` for QEMU slirp |
| Host/gateway alias | DHCP router option when offered; fallback `10.0.2.2` |
| Default DNS | DHCP DNS option when offered; fallback QEMU slirp DNS at `10.0.2.3:53` |
| IPv4 routing | Outbound sockets ARP same-subnet peers directly and use the configured gateway for off-link or `/32` destinations |
| DHCP | Minimal boot-time DHCPv4 DISCOVER/OFFER/REQUEST/ACK; no renewal or user command yet |
| Socket authority | Processes need `capNet`; seeded `root` has it |
| Inbound host access | QEMU `hostfwd` from host ports to guest ports |
| Outbound guest access | Guest clients connect to `10.0.2.2` for host services |
| IPv6 | Link-local/NDP and IPv6 socket smoke paths exist; hostfwd varies by host |
| TLS | `/bin/tlsget` proves the TLS 1.3 runtime path; production certificate verification is not complete |

The current implementation lives in the trusted core. The virtio-net driver and
the network stack are in the kernel today, while the roadmap moves toward
restartable userland drivers and narrower network services.

## Build Artifacts

Build the normal direct-boot artifacts before running any manual network
session:

```sh
make build base-image build/virt.dtb
```

The resulting QEMU session needs three pieces:

1. The kernel: `build/kernel.elf`.
2. The immutable base filesystem: `build/base.img`.
3. A virtio-net device attached to a slirp `-netdev`.

`make run` does not attach a NIC by default, so manual network sessions use an
explicit QEMU command.

## Choose A Network Workflow

Start from the traffic direction and service shape. Inbound services need
`hostfwd`; guest-initiated clients only need a slirp NIC. All socket commands
need a login context with `capNet`, so the examples below assume `root`.

| Goal | QEMU profile | Guest command | Host action | Proof |
| --- | --- | --- | --- | --- |
| Serve static files | HTTP-or-LLM profile | `/bin/httpd` | `curl -fsS http://127.0.0.1:8080/` | `./tests/httpd_test.sh` |
| Serve local AI completions | HTTP-or-LLM profile | `/bin/llmd` | `curl -fsS -X POST --data "Once upon a time" http://127.0.0.1:8080/completion` | `./tests/llm_serve_test.sh` |
| Test one TCP request | Echo profile | `/bin/tcpecho` | `printf 'swos tcp\n' | nc -w8 127.0.0.1 5555` | `./tests/tcp_echo_test.sh` |
| Test one UDP datagram | Echo profile | `/bin/udpecho` | `printf 'swos udp' | nc -u -w2 127.0.0.1 5555` | `./tests/udp_echo_test.sh` |
| Connect from guest to host | Outbound-only profile | `/bin/tcpget 10.0.2.2 5555` | `printf 'srv-reply\n' | nc -l 5555` | `./tests/tcp_connect_test.sh` |
| Resolve DNS | Outbound-only profile | `/bin/nslookup example.com` | None for default slirp DNS | `./tests/dns_test.sh` |
| Exercise TLS runtime path | Outbound-only profile | `/bin/tlsget 10.0.2.2 44310 localhost` | Start the host TLS 1.3 test server | `./tests/tls_test.sh` |
| Exercise SSH client transport | Outbound-only profile | `/bin/ssh 10.0.2.2 <port>` | Start a host OpenSSH `sshd` | `./tests/ssh_transport_test.sh` |
| Exercise SSHD remote command | SSHD profile | Autostart from `/etc/swos/services`; manual `/bin/sshd` for custom ports | `ssh -i fixtures/ssh/sshd_hc5_ed25519 -p <host-port> root@127.0.0.1 /bin/id` | `./tests/sshd_transport_test.sh` |
| Exercise SSHD restart proof | SSHD supervised profile | Custom `/etc/swos/services` containing `sshd-once` | Two host OpenSSH commands before and after restart | `make sshd-supervision-test` |
| Exercise IPv6 link-local/NDP | IPv6 smoke profile | Test harness driven | None beyond QEMU profile | `./tests/ipv6_smoke_test.sh` |

Operator flow:

1. Build `build/kernel.elf`, `build/base.img`, and `build/virt.dtb`.
2. Boot the smallest QEMU profile that matches the workflow.
3. Log in as `root`.
4. Wait for the readiness marker before sending host traffic.
5. Save the serial log and host command output when debugging.
6. Run the focused proof before broadening to `make test`.

Do not run `/bin/httpd` and `/bin/llmd` together in the same guest; both bind
TCP 8080. The echo programs are one-shot and exit after a single request.

## QEMU Network Profiles

### All-In-One Validation Profile

This profile exposes the HTTP and echo service ports and is the best starting
point for manual validation:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=udp:127.0.0.1:5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

Use this profile for:

- `/bin/httpd` on guest TCP 8080.
- `/bin/llmd` on guest TCP 8080.
- `/bin/tcpecho` on guest TCP 5555.
- `/bin/udpecho` on guest UDP 5555.

Run only one TCP 8080 service at a time. `/bin/httpd` and `/bin/llmd` both bind
guest TCP port 8080.

### HTTP-Or-LLM Profile

Use this smaller profile when you only need a TCP 8080 service:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

### Echo Profile

Use this when testing only the echo tools:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=udp:127.0.0.1:5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

### SSHD Session Profile

Use this profile to validate host-to-guest SSH reachability through a minimal
authenticated remote command. The current `/bin/sshd` exchanges SSH
identification strings with an OpenSSH client, negotiates `curve25519-sha256`,
`ssh-ed25519`, OpenSSH strict KEX, and `chacha20-poly1305@openssh.com`,
loads its host-key seed from `/etc/ssh/ssh_host_ed25519_seed`, authenticates
`root` with a key from `/etc/ssh/authorized_keys`, opens a `session` channel,
executes a bounded direct `/bin/<tool>` command, and forwards small remote
stdin payloads into fd 0. It currently returns up to 4096 bytes of captured
stdout/stderr per remote exec and logs when output is truncated. TCP write-side
backpressure now waits for ACK-driven send-buffer space on blocking socket
writes; larger streaming stdin/stdout remains a later SSHD milestone.

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

### Outbound-Only Profile

Guest-initiated clients such as `/bin/tcpget`, `/bin/nslookup`, `/bin/tlsget`,
and `/bin/ssh` do not need host forwarding. They only need a slirp NIC:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

### IPv6 Smoke Profile

IPv6 link-local and NDP setup is enabled with `ipv6=on`:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,ipv6=on \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

On Darwin, QEMU/slirp IPv6 host forwarding can be unavailable or inconsistent.
The checked-in IPv6 tests fall back to the link-local/NDP smoke when the host
cannot provide true IPv6 host forwarding.

## Login And Capability

After boot, complete the interactive TTY smoke prompt and log in as `root`:

```text
swift-os login: root
password: swordfish
```

The seeded `root` principal has `capNet`. The seeded `user` and `guest`
principals do not, which makes them useful for confinement checks:

```sh
id
/bin/nslookup example.com
```

When a process lacks `capNet`, socket and resolver operations fail before any
network traffic is sent.

## Tool Catalog

| Tool | Direction | Guest port | Host requirement | Proof |
| --- | --- | ---: | --- | --- |
| `/bin/httpd` | Host to guest | TCP 8080 | TCP hostfwd to 8080 | `./tests/httpd_test.sh` |
| `/bin/llmd` | Host to guest | TCP 8080 | TCP hostfwd to 8080 | `./tests/llm_serve_test.sh` |
| `/bin/tcpecho` | Host to guest | TCP 5555 | TCP hostfwd to 5555 | `./tests/tcp_echo_test.sh` |
| `/bin/udpecho` | Host to guest | UDP 5555 | UDP hostfwd to 5555 | `./tests/udp_echo_test.sh` |
| `/bin/sshd` | Host to guest | TCP 22 | TCP hostfwd to 22 | `./tests/sshd_transport_test.sh` |
| `/bin/tcpget` | Guest to host | Client-chosen | Host TCP listener | `./tests/tcp_connect_test.sh` |
| `/bin/nslookup` | Guest to DNS | UDP client | Slirp DNS or host responder | `./tests/dns_test.sh` |
| `/bin/tlsget` | Guest to host | TCP client | Host TLS 1.3 server | `./tests/tls_test.sh` |

`/bin/tcpecho` and `/bin/udpecho` are one-shot programs: they serve one request,
print their result, and exit. Start them again for another request.

## Runbooks

### Verify The NIC

Use the virtio-net acceptance test for the lowest-level network bring-up:

```sh
./tests/virtio_net_test.sh
```

Healthy serial output includes:

```text
net-dhcp OK: lease 10.0.2.15 gateway 10.0.2.2 dns 10.0.2.3
net-a: virtio-net up, MAC
net-a: ARP reply, 10.0.2.2 is at
net-a OK: ICMP echo reply from 10.0.2.2
```

These markers prove that the driver attached, ARP resolved the slirp gateway,
and the ICMP probe completed.

If a DHCP server does not answer, the boot path logs the fallback and keeps the
old slirp constants so local QEMU validation remains usable.

### Serve Static Files

Boot with TCP 8080 forwarded, log in as `root`, and start:

```sh
/bin/httpd
```

Wait for:

```text
httpd: listening on 8080
```

Then run host requests:

```sh
curl -fsS http://127.0.0.1:8080/
curl -fsS http://127.0.0.1:8080/hello.txt
curl -fsS http://127.0.0.1:8080/sub/
curl -i http://127.0.0.1:8080/nope
```

Expected behavior:

- `/` maps to `/www/index.html`.
- Static paths are resolved under `/www`.
- Common file suffixes receive MIME types.
- Directories without `index.html` return a simple listing.
- Missing paths return `404`.
- The server can multiplex multiple live TCP connections through `poll`.

Proof:

```sh
./tests/httpd_test.sh
bash ./tests/net_zero_copy_throughput_test.sh
```

### Serve Local AI Completions

Boot with TCP 8080 forwarded, log in as `root`, and start:

```sh
/bin/llmd
```

Healthy default startup verifies the signed bundle under `/models/stories15M`
and logs:

```text
llmd: trust root loaded (/etc/swos/model-signing.pub)
llmd: generation 2 rejected (model size/sha256 mismatch)
llmd: bundle stories15M generation 1 verified (ed25519+sha256)
llmd: serving on 8080
```

Host requests:

```sh
curl http://127.0.0.1:8080/health
curl -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl http://127.0.0.1:8080/metrics
```

For model-bundle layout, raw override behavior, health semantics, metrics, and
support evidence, see [AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

Proof:

```sh
./tests/llm_serve_test.sh
```

### Run TCP Echo

Boot with TCP 5555 forwarded, log in as `root`, and start:

```sh
/bin/tcpecho
```

Wait for:

```text
tcpecho: listening on 5555
```

Then send from the host:

```sh
printf 'swos tcp\n' | nc -w8 127.0.0.1 5555
```

The guest prints a byte count and exits. Start `/bin/tcpecho` again for another
connection.

Proof:

```sh
./tests/tcp_echo_test.sh
```

### Run UDP Echo

Boot with UDP 5555 forwarded, log in as `root`, and start:

```sh
/bin/udpecho
```

Wait for:

```text
udpecho: listening on 5555
```

Then send from the host:

```sh
printf 'swos udp' | nc -u -w2 127.0.0.1 5555
```

The guest prints the sender and exits. Start `/bin/udpecho` again for another
datagram.

Proof:

```sh
./tests/udp_echo_test.sh
```

### Exercise SSHD Remote Command

Boot with host TCP 2222 forwarded to guest TCP 22. The default base image starts
`/bin/sshd` through `/bin/swos-init` because `/etc/swos/services` contains
`sshd`. Custom images can stage a different service manifest with
`SWOS_SERVICES_FILE=PATH`; `sshd-supervised` restarts a normal SSHD child and
`sshd-once` is the restart acceptance token used by `make sshd-supervision-test`.
For a manual debug run or a custom port, log in as `root` and start:

```sh
/bin/sshd
```

Wait for:

```text
sshd: listening on 22 (session exec preflight)
```

Then connect from the host:

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

Expected current behavior is a successful SSH command with remote software
version `swift-os_sshd-session`, KEX debug lines for `curve25519-sha256`,
`ssh-ed25519`, and `chacha20-poly1305@openssh.com`, publickey authentication,
stdout like `principal=1(root) ...`, and exit status 0. The checked test also
proves that the old HC4 key is rejected, the HC5 key is loaded from
`/etc/ssh/authorized_keys`, the host-key seed is loaded from
`/etc/ssh/ssh_host_ed25519_seed`, the host OpenSSH client pins the derived
SwiftOS host key through known_hosts, `/bin/id` runs as root, and `/bin/echo
HC6-OK` receives an argv argument. It also runs a quoted `/bin/echo` command
that proves quote removal, backslash escaping, and empty argv preservation,
pipes a small host payload into remote `/bin/cat` and requires exact stdout,
then reads a capped long output from `/bin/cat /models/tok512.bin` and requires
the truncation marker. This proves TCP/22 reachability through SSH KEX,
host-key pinning, encrypted userauth, session channel setup, bounded direct
remote exec, bounded stdin forwarding, and bounded output capture; PTY, shell
command parsing, scp, sftp, runtime host-key rotation, real entropy, larger
streaming, and broader authorized-key options are follow-up work.

For deploy-specific image-time keys, generate a host-key seed with
`build/sshkey seed --out support/keys/ssh_host_ed25519_seed`, create
`support/keys/authorized_keys` with the allowed login public keys, then build
with `make base-image` while setting `SSHD_HOST_SEED_FILE` and
`SSHD_AUTHORIZED_KEYS_FILE`. Derive the host known_hosts line from the exact
staged seed.

Proof:

```sh
./tests/sshd_transport_test.sh
```

### Exercise The SSH Client

Start a host OpenSSH `sshd` on a high loopback port with an Ed25519 host key and
modern algorithms, boot SwiftOS with a slirp NIC, log in as `root`, and run:

```sh
/bin/ssh 10.0.2.2 2222
```

The current client preflight connects outbound, exchanges SSH identification
strings, completes `curve25519-sha256`, verifies the server's `ssh-ed25519`
host-key signature over the exchange hash, matches the host key against
`/etc/ssh/known_hosts`, handles OpenSSH strict KEX, derives
`chacha20-poly1305@openssh.com` keys, and completes one encrypted
`ssh-userauth` service request/accept. It does not yet implement user
authentication, session/exec channels, PTY, scp, or sftp.

Proof:

```sh
./tests/ssh_transport_test.sh
```

### Connect From Guest To Host

Start a host listener:

```sh
printf 'srv-reply\n' | nc -l 5555
```

Boot SwiftOS with a slirp NIC, log in as `root`, and run:

```sh
/bin/tcpget 10.0.2.2 5555
```

`10.0.2.2` is the QEMU slirp alias for the host. `/bin/tcpget` sends
`GET swos\n`, prints connection status, and prints the reply.

Proof:

```sh
./tests/tcp_connect_test.sh
```

### Resolve DNS

With QEMU user networking attached, query the default slirp resolver:

```sh
/bin/nslookup example.com
```

For hermetic tests or local DNS experiments, pass an explicit server and port:

```sh
/bin/nslookup test.swos 10.0.2.2 5354
/bin/nslookup example.com 10.0.2.3 53 AAAA
```

The final `AAAA` argument requests IPv6 records. Full eight-group IPv6 server
addresses are accepted by the command parser.

Proof:

```sh
./tests/dns_test.sh
```

### Exercise The TLS Client

`/bin/tlsget` opens a TCP connection, performs the current TLS 1.3 client flow,
sends `GET / HTTP/1.1`, and prints decrypted response body bytes.

Run a host TLS server with TLS 1.3 and ChaCha20-Poly1305 support, then connect
from the guest:

```sh
/bin/tlsget 10.0.2.2 44310 localhost
```

Certificate verification is deliberately incomplete in the current branch. Use
`tlsget` as a runtime smoke and interoperability path, not as a production trust
decision.

Proof:

```sh
./tests/tls_test.sh
```

### Exercise IPv6 Paths

Use `ipv6=on` in the QEMU `-netdev` and run:

```sh
./tests/ipv6_smoke_test.sh
./tests/ipv6_tcp_echo_test.sh
./tests/ipv6_udp_echo_test.sh
```

The smoke test requires `net: IPv6 link-local configured`. The TCP and UDP echo
tests exercise the dual-stack path; on Darwin they may report a hostfwd skip
after the IPv6 smoke passes.

## Verification Matrix

Run the narrowest proof for the path you changed:

| Area | Command |
| --- | --- |
| Host network protocol unit tests | `make test` builds and runs `tests/net_test.swift` |
| Virtio-net attach, ARP, ICMP | `./tests/virtio_net_test.sh` |
| Static HTTP | `./tests/httpd_test.sh` |
| HTTP zero-copy throughput smoke | `bash ./tests/net_zero_copy_throughput_test.sh` |
| TCP echo | `./tests/tcp_echo_test.sh` |
| UDP echo | `./tests/udp_echo_test.sh` |
| SSHD remote-command preflight | `./tests/sshd_transport_test.sh` |
| SSH client transport preflight | `./tests/ssh_transport_test.sh` |
| Guest-to-host TCP | `./tests/tcp_connect_test.sh` |
| DNS resolver and `nslookup` | `./tests/dns_test.sh` |
| TLS client smoke | `./tests/tls_test.sh` |
| IPv6 link-local/NDP | `./tests/ipv6_smoke_test.sh` |
| IPv6 TCP path | `./tests/ipv6_tcp_echo_test.sh` |
| IPv6 UDP path | `./tests/ipv6_udp_echo_test.sh` |
| LLM serving over HTTP | `./tests/llm_serve_test.sh` |
| Full checked-in gate | `make test` |

The protocol-core unit coverage is in [tests/net_test.swift](../tests/net_test.swift).
The user-visible end-to-end paths are the shell tests above.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `socket failed` | No virtio-net device, no `capNet`, or unsupported socket path | Boot with `-netdev user` and `-device virtio-net-device`; log in as `root` |
| `bind failed` | Port already in use in the guest, or a stale service is still running | Run only one service per guest port; reboot or stop the previous QEMU session |
| Host `curl` cannot connect | Missing or mismatched `hostfwd`, service not ready, or host port conflict | Wait for the service readiness marker; confirm the hostfwd rule; choose another host port |
| TCP or UDP echo works once then stops | Echo programs are one-shot | Start `/bin/tcpecho` or `/bin/udpecho` again |
| `/bin/tcpget` cannot reach host | Host listener not running or wrong port | Start the host listener first and connect to `10.0.2.2:<port>` |
| `/bin/ssh` fails before preauth | Host `sshd` is not listening, algorithms are unsupported, `/etc/ssh/known_hosts` does not trust the host key, or the base image is stale | Start an OpenSSH server with `curve25519-sha256`, `ssh-ed25519`, and `chacha20-poly1305@openssh.com`; rebuild `base-image`; check for `ssh: host key matched /etc/ssh/known_hosts`; run `./tests/ssh_transport_test.sh` |
| DNS fails | Resolver not reachable or explicit test responder not running | Try `/bin/nslookup example.com`; for tests, start the responder and use `10.0.2.2 5354` |
| SSH exits before stdout | Missing private key, stale base image, missing `/etc/ssh/authorized_keys`, missing `/etc/ssh/ssh_host_ed25519_seed`, stale or wrong host known_hosts entry, unsupported command syntax, or a protocol regression | Use a private key whose `.pub` line was staged into the exact image, rebuild `base-image`, derive known_hosts from the exact image seed with `build/sshkey`, run a simple `/bin/id`, and check for `swift-os_sshd-session`, `sshd: loaded host key seed /etc/ssh/ssh_host_ed25519_seed`, host-key match in OpenSSH debug output, `sshd: authorized key matched /etc/ssh/authorized_keys`, publickey auth, and `sshd: session exec completed status 0` |
| TLS succeeds but certificate is untrusted | Expected current limit | Do not use `tlsget` for production trust decisions |
| IPv6 echo skipped on Darwin | QEMU/slirp hostfwd limitation | Treat a pass from `./tests/ipv6_smoke_test.sh` as the current host proof |

For deeper diagnosis, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#networking-problems)
and collect serial evidence with [OBSERVABILITY_GUIDE.md](OBSERVABILITY_GUIDE.md).

## Security And Product Limits

Current limits that matter when exposing a SwiftOS network service:

- `capNet` is coarse. It grants the ability to create sockets generally, not a
  specific port, address, or protocol.
- There is no target-side firewall command, routing table command, or network
  configuration command yet. DHCPv4 is boot-time only and does not renew leases.
- `/bin/sshd` is a session/exec preflight, not a full login daemon. It uses a
  base-image host-key seed from `/etc/ssh/ssh_host_ed25519_seed`; the checked-in
  default seed and authorized key are development-only, and deploy builds should
  provide `SSHD_HOST_SEED_FILE` and `SSHD_AUTHORIZED_KEYS_FILE`. KEX entropy is
  still weak and temporary. It supports only simple `ssh-ed25519` lines in
  `/etc/ssh/authorized_keys`, bounded stdout/stdin, and direct
  single-component `/bin/<tool>` remote exec with whitespace splitting, quote
  removal, and backslash escaping; PTY, shell command parsing, scp, sftp,
  runtime host-key rotation, real entropy, larger streaming, and broader
  authorized-key options are still missing.
- `/bin/ssh` is a client transport preflight, not a full SSH client. It verifies
  the server's host-key signature for the current exchange and checks a minimal
  `/etc/ssh/known_hosts` trust store, but has no user authentication and no
  session/exec or file-copy modes.
- TLS certificate verification is not production-ready.
- `httpd` is an HTTP static-file service, not a hardened Internet-facing web
  server.
- `/bin/llmd` is a foreground service with no service manager or restart
  policy yet.
- The writable filesystem is RAM-backed `/tmp`; no network service state
  persists across reboot unless it is built into the base image or provided by a
  read-only package payload.
- The virtio-net driver and TCP/IP stack are currently in the kernel. The
  hardening roadmap moves this authority toward restartable userland services.

Use host-only loopback forwarding, such as `hostfwd=tcp:127.0.0.1:8080-:8080`,
for local validation. Do not expose current services directly to an untrusted
network.

## Source Map

| Area | Source |
| --- | --- |
| Socket constants and static slirp addresses | [kernel/net/socket.swift](../kernel/net/socket.swift) |
| DHCPv4 codec | [kernel/net/dhcp.swift](../kernel/net/dhcp.swift) |
| Virtio-net driver | [kernel/drivers/virtio_net.swift](../kernel/drivers/virtio_net.swift) |
| Socket syscall dispatch | [kernel/syscall/syscall.swift](../kernel/syscall/syscall.swift) |
| Native Swift socket bridge | [userland/lib/swift_user.h](../userland/lib/swift_user.h) |
| Static HTTP server | [userland/httpd.swift](../userland/httpd.swift) |
| LLM HTTP server | [userland/llmd.swift](../userland/llmd.swift) |
| SSH client transport preflight | [userland/ssh.swift](../userland/ssh.swift) |
| SSHD session/exec preflight | [userland/sshd.swift](../userland/sshd.swift) |
| TCP echo | [userland/tcpecho.swift](../userland/tcpecho.swift) |
| UDP echo | [userland/udpecho.swift](../userland/udpecho.swift) |
| TCP client | [userland/tcpget.swift](../userland/tcpget.swift) |
| DNS client | [userland/nslookup.swift](../userland/nslookup.swift) |
| TLS client | [userland/tlsget.swift](../userland/tlsget.swift) |
