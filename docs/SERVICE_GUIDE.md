# SwiftOS Service Guide

This guide explains how to run, observe, test, and design services on the
current SwiftOS image. It describes the checked-in system, not only the future
service architecture.

Use it with:

- [Operations Guide](OPERATIONS_GUIDE.md) for boot profiles and verification
  gates.
- [Networking Guide](NETWORKING_GUIDE.md) for virtio-net launch profiles, host
  forwarding, DNS, TCP/UDP, TLS, IPv6 smoke paths, and network tests.
- [Command Reference](COMMAND_REFERENCE.md) for exact command syntax.
- [Application Cookbook](APPLICATION_COOKBOOK.md) for build-and-test recipes.
- [API Reference](API_REFERENCE.md) for syscall and Swift bridge details.
- [Support Guide](SUPPORT_GUIDE.md) for evidence collection.

## Current Service Model

SwiftOS can run network-facing EL0 programs today, and C5a-C5d adds a narrow
restartable driver-service plus device-discovery and opaque device-handle
smoke. It does not yet have a general service manager. Most services are static
user programs started from the serial shell after login. Long-running services
run in the foreground and report readiness through deterministic serial log
markers.

| Property | Current behavior |
| --- | --- |
| Launch | Manual shell command after login |
| Supervision | None yet; restart manually by rerunning the command |
| Configuration | Command arguments, immutable base image files, or `/tmp` scratch |
| Writable state | `/tmp` only; cleared on reboot |
| Service identity | The logged-in principal and its capability mask |
| Network authority | Requires `capNet`; the seeded `root` principal has it |
| Logging | Serial console markers and service-prefixed messages |
| Port exposure | QEMU `hostfwd` from host ports to guest ports |
| Persistence | Rebuild the base image or attach package overlays for installed files |

This is enough for product demos, acceptance tests, and early application
hosting experiments. The roadmap moves toward explicit handle-based service
launch, restart policy, package service manifests, and restartable driver and
network services.

## Service Catalog

| Program | Class | Guest port | Readiness marker | Proof |
| --- | --- | ---: | --- | --- |
| `/bin/httpd` | Static-file HTTP server | TCP 8080 | `httpd: listening on 8080` | `./tests/httpd_test.sh` |
| `/bin/llmd` | TinyStories HTTP inference server | TCP 8080 | `llmd: serving on 8080` | `./tests/llm_serve_test.sh` |
| `/bin/tcpecho` | One-shot TCP echo server | TCP 5555 | `tcpecho: listening on 5555` | `./tests/tcp_echo_test.sh` |
| `/bin/udpecho` | One-shot UDP echo server | UDP 5555 | `udpecho: listening on 5555` | `./tests/udp_echo_test.sh` |
| `/bin/tcpget` | Guest-to-host TCP client | Client-chosen | Request output | `./tests/tcp_connect_test.sh` |
| `/bin/nslookup` | DNS client | UDP client | Query output | `./tests/dns_test.sh` |
| `/bin/tlsget` | TLS client demo | TCP client | Handshake/output markers | `./tests/tls_test.sh` |
| `/bin/drvsvcdemo` | C5 driver-service/device-metadata smoke | n/a | `C5a OK: restartable driver service recovered over IPC`; C5d gate also expects `C5d OK: virtio input discovery metadata surfaced` | `make c5-device-metadata-test` |

`/bin/httpd` and `/bin/llmd` both bind guest TCP port 8080. Run one of them at a
time.

The echo servers are intentionally one-shot demos: they serve one request and
exit. Start them again for another request. `httpd` and `llmd` are long-running
servers that keep accepting connections.

## Restartable Driver-Service Smoke

C5a proves the service shape that future userland drivers need, C5b adds an
opaque transferable device handle, and C5c/C5d match that handle against a
discovered QEMU virtio-input transport and surface its metadata when one is
attached. The demo supervisor
starts `/bin/drvinputd` with only endpoint file descriptors, exchanges a pseudo
input event, transfers the opaque device handle, proves the grant moves and
stays busy while the service owns it, stops the service, starts a fresh
generation, and verifies that communication recovers.

Focused host gate:

```sh
make c5-device-metadata-test
```

The target boots QEMU with `SMP_CPUS=4` and uses
`tests/driver_service_test.sh` to assert the supervisor markers.

Manual guest command:

```sh
/bin/drvsvcdemo
```

Expected serial output includes:

```text
drvsvc: C5a supervisor starting
drvsvc: C5c device manifest matched
drvsvc: C5c discovery exhausted
drvsvc: C5d virtio-input metadata discovered
drvsvc: C5b device grant moved
drvinputd: C5b device grant accepted
C5a OK: restartable driver service recovered over IPC
C5b OK: opaque device handle transferred and released
C5c OK: virtio-input device grant discovered and matched
C5d OK: virtio input discovery metadata surfaced
```

The ordinary headless boot path has no QEMU keyboard device, so it exercises
the same lifecycle with the `pseudo-input.0` fallback and emits
`C5c OK: device discovery manifest matched pseudo input`.

This is not a production device manager yet. C5d exposes discovery metadata for
manifest matching, but it still does not grant MMIO ranges, IRQ endpoints, DMA
windows, or real virtio-input queue ownership to userland.

## Network Launch Profile

`make run` does not attach a NIC by default. Use an explicit QEMU profile when
running socket services. For service-specific profiles and troubleshooting, see
[NETWORKING_GUIDE.md](NETWORKING_GUIDE.md).

```sh
make build base-image build/virt.dtb

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=udp:127.0.0.1:5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

Log in as `root` for socket programs:

```text
swift-os login: root
password: swordfish
```

The seeded `user` and `guest` principals are useful for confinement checks, but
they do not have `capNet` and cannot open sockets.

## Running Static HTTP

Start the service in the guest:

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
- Static files are served from `/www`.
- Common suffixes receive MIME types.
- Directories without an index return a simple listing.
- Missing paths return `404`.
- Multiple live TCP connections are multiplexed through `poll`.

The source implementation is [userland/httpd.swift](../userland/httpd.swift).
The acceptance test is [tests/httpd_test.sh](../tests/httpd_test.sh).

## Running LLM Serving

For the full AI hosting runbook, including bundle format, raw model override,
health and metrics semantics, and performance limits, see
[AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

Start the service in the guest:

```sh
/bin/llmd
```

Default startup verifies the bundle rooted at `/models/stories15M`. The checked
in base image deliberately contains corrupt generation 2 and valid generation 1,
so a healthy boot logs:

```text
llmd: generation 2 rejected (model size/sha256 mismatch)
llmd: bundle stories15M generation 1 verified (ed25519+sha256)
llmd: model int8 Q8_0 GS=32
llmd: serving on 8080 (POST /completion, GET /health, GET /metrics)
```

Then use the HTTP API from the host:

```sh
curl -fsS http://127.0.0.1:8080/health
curl -fsS -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl -fsS http://127.0.0.1:8080/metrics
```

Endpoint behavior:

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/health` | `GET` | Liveness plus model shape, for example `ok model dim=288` |
| `/completion` | `POST` | Uses the request body as the prompt and returns generated text |
| `/metrics` | `GET` | `requests`, `tokens_total`, `last_ttft_ms`, and `last_tok_s` |

Generation runs inline on the current single-core system. Other connections can
queue while one request is generating.

To serve another supported checkpoint and tokenizer without bundle manifest
verification, pass both paths:

```sh
/bin/llmd /models/stories260K.bin /models/tok512.bin
```

The source implementation is [userland/llmd.swift](../userland/llmd.swift). The
bundle verifier is [userland/lib/modelbundle.swift](../userland/lib/modelbundle.swift).
The acceptance tests are [tests/llm_serve_test.sh](../tests/llm_serve_test.sh)
and [tests/llm_bundle_test.swift](../tests/llm_bundle_test.swift).

## Running Echo Services

Start the TCP echo server in the guest:

```sh
/bin/tcpecho
```

From the host:

```sh
printf 'hello tcp\n' | nc -w8 127.0.0.1 5555
```

Expected serial markers:

```text
tcpecho: listening on 5555
tcpecho: got 10 bytes
```

Start the UDP echo server in the guest:

```sh
/bin/udpecho
```

From the host:

```sh
printf 'hello udp' | nc -u -w2 127.0.0.1 5555
```

Expected serial markers:

```text
udpecho: listening on 5555
udpecho: got 9 bytes from 10.0.2.2:<host-port>
```

Use these programs as small references for socket setup and service-prefixed
error handling:

- [userland/tcpecho.swift](../userland/tcpecho.swift)
- [userland/udpecho.swift](../userland/udpecho.swift)

## Client Tools

Some networking programs are clients rather than services.

### Guest To Host TCP

Start a host listener:

```sh
printf 'srv-reply\n' | nc -l 5555
```

Run the guest client:

```sh
/bin/tcpget 10.0.2.2 5555
```

`10.0.2.2` is QEMU slirp's host alias.

### DNS

Run:

```sh
/bin/nslookup example.com
```

SwiftOS uses QEMU slirp's resolver by default when booted with user networking.

### TLS Demo

`/bin/tlsget` exercises the native TLS 1.3 record and handshake path. Treat it
as a demo and test target, not a production HTTPS client: production trust-store
and certificate policy work is still future work.

## Operational Evidence

For service bugs, capture both host client output and the serial log.

Run the narrowest service test:

```sh
./tests/httpd_test.sh
./tests/llm_serve_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
```

For manual runs, redirect QEMU output:

```sh
qemu-system-aarch64 ... >swiftos-service.log 2>&1
```

Host evidence examples:

```sh
curl -v http://127.0.0.1:8080/ >curl-httpd.txt 2>&1
curl -v http://127.0.0.1:8080/health >curl-llmd-health.txt 2>&1
printf 'hello tcp\n' | nc -w8 127.0.0.1 5555 >tcp-echo.txt 2>&1
```

Include:

- The exact QEMU command and host forwarding rules.
- The login principal used to launch the service.
- The first error marker, if startup failed.
- The readiness marker, if startup succeeded.
- Host client command and output.
- The focused acceptance test result.

## Service Design Contract

New SwiftOS services should follow this contract so operators and tests get
predictable behavior.

| Area | Rule |
| --- | --- |
| Name | Use a stable lowercase program name and prefix every service log line with it |
| Readiness | Print one deterministic readiness marker only after bind/listen or equivalent setup succeeds |
| Errors | Print a short failure marker before returning nonzero |
| Capabilities | Document required capability bits, especially `capNet`, `capFsRead`, `capTmpWrite`, and `capSpawn` |
| State | Keep writable runtime state under `/tmp` unless the design adds a new storage service |
| Files | Close file descriptors on every error path |
| TCP serving | Use `poll` for multi-connection long-running services |
| One-shot demos | State clearly when a command handles only one request and exits |
| Health | For HTTP services, provide `/health` when practical |
| Metrics | For HTTP services, provide `/metrics` when useful and cheap |
| Ports | Document guest ports and host forwarding examples |
| Tests | Add a focused QEMU test or host unit test that proves the user-visible workflow |

Readiness marker examples:

```text
httpd: listening on 8080
llmd: serving on 8080
tcpecho: listening on 5555
udpecho: listening on 5555
```

Startup failure marker examples:

```text
service: socket failed
service: bind failed
service: listen failed
service: cannot open config
```

## Native Swift Socket Skeleton

This is the shape of a simple TCP service. Use the checked-in programs for exact
production patterns.

```swift
private let listenPort: UInt16 = 8080

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    let lfd = swiftos_socket_stream()
    if lfd < 0 {
        swiftos_puts("service: socket failed\n")
        return 1
    }
    if swiftos_bind(lfd, listenPort) != 0 {
        swiftos_puts("service: bind failed\n")
        _ = swiftos_close(lfd)
        return 1
    }
    if swiftos_listen(lfd, 8) != 0 {
        swiftos_puts("service: listen failed\n")
        _ = swiftos_close(lfd)
        return 1
    }

    swiftos_puts("service: listening on 8080\n")

    while true {
        let cfd = swiftos_accept(lfd)
        if cfd < 0 {
            swiftos_puts("service: accept failed\n")
            continue
        }
        // Read, write, close. Long-running services should use poll when they
        // need multiple live connections.
        _ = swiftos_close(cfd)
    }
}
```

For long-running TCP services, prefer the `poll` loop in
[userland/httpd.swift](../userland/httpd.swift) or
[userland/llmd.swift](../userland/llmd.swift) over one blocking `accept` plus
one blocking request at a time.

## Build And Test Checklist

Before promoting a new service into the default image:

1. Add the source under `userland/` or the package payload source tree.
2. Add a Makefile build rule with all source dependencies.
3. Stage the binary into the base image or package payload.
4. Document command syntax in [Command Reference](COMMAND_REFERENCE.md).
5. Document service operation in this guide or a linked runbook.
6. Add a focused test that boots QEMU, launches the service, waits for the
   readiness marker, and drives a host client.
7. Run the narrow gate:

```sh
make build base-image
./tests/<service>_test.sh
```

8. Run broader gates before release or when touching shared networking,
   scheduler, VFS, or syscall behavior:

```sh
make test
```

## Known Limits

- There is no general service manager, restart policy, dependency graph, or
  background service registry yet. C5a-C5d only prove a focused
  driver-service supervisor/restart/discovery/device-grant metadata path.
- Services inherit the current login session's capability mask; explicit
  spawn-with-handles is roadmap work.
- `/tmp` is the only writable runtime area and is lost on reboot.
- Package service manifests are documented as future package-manager behavior;
  they are not activated by the target yet.
- The TCP/IP stack and real virtio drivers are still in the kernel. Moving them
  to restartable userland services is tracked in
  [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md).
- Production TLS trust, certificate bundle management, and long-running HTTPS
  policy are not complete.
- IPv6 socket paths exist, but host end-to-end tests can depend on QEMU and host
  platform forwarding behavior.

When these limits change, update this guide, the command reference, the
operations guide, and the related acceptance tests in the same milestone.
