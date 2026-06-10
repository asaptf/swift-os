# SwiftOS Examples

These examples are complete, current workflows for the checked-in system. They
are written as operator and developer recipes, not as future design notes.

Prerequisite for all guest examples:

```sh
make build base-image build/virt.dtb
make run
```

At boot, complete the interactive TTY smoke prompt, log in as `root` with
password `swordfish`, and run the guest commands shown below.

## 1. Confirm A Healthy Boot

Guest:

```sh
id
cat /etc/motd
ls -l /
ps
top -b -n 2 -d 1
```

Expected signals:

- `id` shows `principal=1(root)` and `caps=0x3f`.
- `/etc/motd` prints the welcome text.
- `/bin`, `/etc`, `/tmp`, and `/www` are visible.
- `top` renders two frames and returns to the shell.

Verification:

```sh
./tests/boot_test.sh
./tests/top_test.sh
```

## 2. Use `/tmp` As Scratch Space

Guest:

```sh
mkdir /tmp/demo
echo first >/tmp/demo/log.txt
echo second >>/tmp/demo/log.txt
cat /tmp/demo/log.txt
wc /tmp/demo/log.txt
chmod 600 /tmp/demo/log.txt
chown 2 /tmp/demo/log.txt
ls -l /tmp/demo/log.txt
rm /tmp/demo/log.txt
rmdir /tmp/demo
```

This exercises tmpfs creation, append redirection, readback, metadata changes,
and cleanup. The data is gone after reboot.

Verification:

```sh
./tests/swift_fileops_test.sh
```

## 3. Compare Account Capabilities

Guest:

```sh
id
exit
```

Log in as `user` / `swordfish`:

```sh
id
cat /etc/motd
echo ok >/tmp/user-write.txt
/bin/nslookup example.com
```

The filesystem commands should work; the network command should fail because
`user` does not have `capNet`.

Log in as `guest` / `guest`:

```sh
id
cat /etc/motd
```

The read should fail because `guest` has only spawn authority in the seeded
image.

Verification:

```sh
./tests/console_login_test.sh
./tests/cap_enforce_test.sh
```

## 4. Serve Static Files Over HTTP

Host:

```sh
make build base-image build/virt.dtb

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

Guest:

```sh
/bin/httpd
```

Host:

```sh
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/hello.txt
curl http://127.0.0.1:8080/sub/
curl -i http://127.0.0.1:8080/nope
```

Expected:

- `/` returns `/www/index.html`.
- `/hello.txt` returns plain text.
- `/sub/` returns a generated directory listing.
- `/nope` returns `404`.

Equivalent automated check:

```sh
./tests/httpd_test.sh
```

## 5. Run TCP Echo

Host boot command: use the network profile with TCP host forwarding:

```text
hostfwd=tcp:127.0.0.1:5555-:5555
```

Guest:

```sh
/bin/tcpecho
```

Host:

```sh
printf 'hello tcp\n' | nc -w8 127.0.0.1 5555
```

Expected host output:

```text
hello tcp
```

`tcpecho` exits after one accepted connection. Run it again for another
round-trip.

Equivalent automated check:

```sh
./tests/tcp_echo_test.sh
```

## 6. Run UDP Echo

Host boot command: use the network profile with UDP host forwarding:

```text
hostfwd=udp:127.0.0.1:5555-:5555
```

Guest:

```sh
/bin/udpecho
```

Host:

```sh
printf 'hello udp' | nc -u -w2 127.0.0.1 5555
```

Expected host output:

```text
hello udp
```

Equivalent automated check:

```sh
./tests/udp_echo_test.sh
```

## 7. Make A Guest-Initiated TCP Request

Boot QEMU with virtio-net attached. On the host, start a simple listener:

```sh
printf 'srv-reply\n' | nc -l 5555
```

Guest:

```sh
/bin/tcpget 10.0.2.2 5555
```

Expected guest output includes:

```text
tcpget: connected
tcpget: got
srv-reply
```

`10.0.2.2` is the QEMU slirp host alias.

Equivalent automated check:

```sh
./tests/tcp_connect_test.sh
```

## 8. Resolve DNS

Boot with virtio-net attached.

Guest:

```sh
/bin/nslookup example.com
```

With the default path, the resolver uses QEMU slirp DNS at `10.0.2.3`. Test
fixtures may pass an explicit server and port.

Equivalent automated check:

```sh
./tests/dns_test.sh
```

## 9. Boot A Package Payload Overlay

Host:

```sh
make build base-image build/virt.dtb package-fixture

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkghello-payload.img,format=raw,if=none,id=swospkg0,readonly=on \
  -device virtio-blk-device,drive=swospkg0 \
  -kernel build/kernel.elf
```

Guest:

```sh
ls -l /usr/bin
/usr/bin/pkghello
```

Expected:

```text
pkghello: hello from package overlay
```

Equivalent automated check:

```sh
make package-overlay-test
```

This is the direct read-only package overlay path. Local install and repository
install use a writable package-store image instead.

## 10. Install A Package From A Signed Repository Fixture

Host:

```sh
make build base-image build/virt.dtb
make package-repo-fixture
make package-local-install-fixture
make package-repo-install-test
```

The automated test starts a host HTTP server, boots QEMU with virtio-net and a
writable package-store image, then drives this guest flow:

```sh
pkg update http://10.0.2.2:<port>/good/aarch64/current
pkg search pkghello
pkg info pkghello
pkg install pkghello
/usr/bin/pkghello
```

Expected signals:

- `pkg update` accepts the signed `catalog.signed`.
- `pkg search pkghello` and `pkg info pkghello` show `pkghello-1.0.0_1`.
- `pkg install pkghello` downloads the content-addressed `.swpkg`, verifies its
  SHA-256, and activates the package-store generation.
- `/usr/bin/pkghello` prints `pkghello: hello from package overlay`.

Equivalent automated check:

```sh
make package-repo-install-test
```

## 11. Install Source-Built Packages From A Static-Host Fixture

The current ports fixture cross-builds Lua, zlib, bzip2, pcre2, nginx, and
sqlite, packages ca-certificates and tzdata, publishes them into one signed seed
repository, copies that repository into a static-hostable web root, and proves
that the guest can install from the hosted layout.

Host:

```sh
make ports-static-host-publish
make package-static-host-repo-install-test
make ports-hosted-url-verify-test
make package-static-host-dns-repo-install-test
```

The automated test serves `build/ports-static-host-root`, injects the default
repository URL into the base image, attaches a writable package-store image, and
drives this guest flow:

```sh
pkg update
pkg search lua
pkg search zlib
pkg search bzip2
pkg search ca-certificates
pkg search pcre2
pkg search tzdata
pkg search nginx
pkg search sqlite
pkg install lua
pkg install zlib
pkg install bzip2
pkg install ca-certificates
pkg install pcre2
pkg install tzdata
pkg install nginx
pkg install sqlite
/usr/bin/lua -e 'print(21 * 2)'
echo static-host-ok > /tmp/zlib.txt
/usr/bin/minigzip /tmp/zlib.txt
/usr/bin/minigzip -d /tmp/zlib.txt.gz
cat /tmp/zlib.txt
echo bzip2-static-host-ok | /usr/bin/bzip2 -c | /usr/bin/bzip2 -dc
cat /usr/share/bzip2/swiftos-bzip2.version
cat /usr/share/certs/swiftos-ca-bundle.version
echo nginx-lighttpd > /tmp/pcre2.txt
/usr/bin/pcre2grep 'nginx|lighttpd' /tmp/pcre2.txt
cat /usr/share/zoneinfo/swiftos-tzdata.version
/usr/sbin/nginx -v
cat /usr/share/nginx/swiftos-nginx.version
/usr/bin/sqlite3 -batch -noheader -cmd '.mode list' :memory: 'select 6*7;'
cat /usr/share/sqlite/swiftos-sqlite.version
```

Expected signals:

- `pkg update` accepts the static-hosted signed catalog.
- `pkg search lua`, `pkg search zlib`, `pkg search bzip2`,
  `pkg search ca-certificates`, `pkg search pcre2`, and `pkg search sqlite`
  find the current seed packages.
- `pkg install lua`, `pkg install zlib`, `pkg install ca-certificates`,
  `pkg install bzip2`, `pkg install pcre2`, `pkg install tzdata`,
  `pkg install nginx`, and `pkg install sqlite` activate all eight packages.
- Lua evaluates the expression and prints `42`; `minigzip` round-trips
  `/tmp/zlib.txt` and prints `static-host-ok` after decompression; bzip2
  round-trips `bzip2-static-host-ok`; the CA marker prints
  `curl-ca-bundle 2026-05-14 121 certificates`; `pcre2grep` prints
  `nginx-lighttpd`; tzdata, nginx, and SQLite print their package
  markers; SQLite prints `42` in list mode.

Equivalent automated check:

```sh
make package-static-host-repo-install-test
make package-static-host-dns-repo-install-test
```

## 12. Run The Native Swift LLM Demo

Host:

```sh
make model
make base-image
make run
```

Guest:

```sh
/bin/llm
```

Shorter run:

```sh
/bin/llm "Once upon a time" 16
```

Expected output includes:

```text
llm: stories260K
llm: generating
--- output ---
...
llm: done
```

Equivalent automated check:

```sh
./tests/llm_run_test.sh
```

## 13. Serve LLM Completions Over TCP

Host:

```sh
make model
make base-image

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

Guest:

```sh
/bin/llmd
```

Host:

```sh
curl http://127.0.0.1:8080/health
curl -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl http://127.0.0.1:8080/metrics
```

Expected signals:

- `/health` includes `ok model dim=288` for the default Q8_0 `stories15M`
  serving bundle.
- `/completion` returns generated story text from the quantized model.
- `/metrics` includes `requests`, `tokens_total`, `last_ttft_ms`, and
  `last_tok_s`.
- The serial log includes `llmd: generation 2 rejected (model size/sha256 mismatch)`,
  `llmd: bundle stories15M generation 1 verified (ed25519+sha256)`,
  `llmd: model int8 Q8_0 GS=32`, and `llmd: served`.

Equivalent automated check:

```sh
./tests/llm_serve_test.sh
```

## 14. Exercise The Swift REPL Demos

Guest:

```sh
calc
```

Inside `calc`:

```text
2+3*4
x = 10
x*x
:sum
:mem
:q
```

Guest:

```sh
kv
```

Inside `kv`, use its prompt to set, list, and reduce in-memory values. Both
programs exercise Swift `String`, `Array`, `Dictionary`, ARC, and the userland
allocator.

Automated checks:

```sh
./tests/calc_test.sh
./tests/kv_test.sh
```

## 15. Validate UEFI Boot

Host:

```sh
make disk base-image
make disk-run
```

Automated checks:

```sh
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

Use this path before claiming firmware, disk-image, or VirtualBox-related
changes are healthy.

## 16. Run The Driver-Service Device-Metadata Smoke

Guest:

```sh
/bin/drvsvcdemo
```

Expected serial markers:

```text
drvsvc: C5a supervisor starting
drvsvc: generation 1 ready
drvsvc: generation 1 event
drvsvc: generation 1 stopped
drvsvc: generation 2 ready
drvsvc: generation 2 event
drvsvc: C5c device manifest matched
drvsvc: C5d virtio-input metadata discovered
drvsvc: C5c discovery exhausted
drvsvc: C5b device grant claimed
drvsvc: C5c virtio-input grant matched
drvsvc: C5b device grant moved
drvinputd: C5b device grant accepted
drvinputd: C5c virtio-input grant accepted
drvsvc: C5b device busy while service owns grant
drvsvc: generation 2 stopped
drvsvc: C5b device grant reclaimed
drvsvc: C5c virtio-input grant reclaimed
C5a OK: restartable driver service recovered over IPC
C5b OK: opaque device handle transferred and released
C5c OK: virtio-input device grant discovered and matched
C5d OK: virtio input discovery metadata surfaced
C5e OK: device authority withheld until explicit handoff
```

This proves the current restartable service shape, virtio-input discovery
metadata, opaque device-grant transfer, and withheld hardware authority. It is
still metadata-only authority: C5e does not hand MMIO, IRQ, DMA, or real
virtio-input queue ownership to userland. A broad headless boot without a QEMU
keyboard device exercises the same lifecycle through the `pseudo-input.0`
fallback and emits
`C5c OK: device discovery manifest matched pseudo input`.

Equivalent automated check:

```sh
make c5-device-authority-test
```

The automated gate boots with `-smp 4`, attaches a QEMU virtio keyboard, and
checks the same serial markers.
`make c5-device-discovery-test` and `make c5-device-handle-test` remain
compatible aliases.

## 17. Run The Full Gate

Host:

```sh
make test
```

The full gate builds the kernel, base image, package fixture, model artifacts,
host-side unit tests, and many QEMU acceptance tests. For day-to-day work, run a
targeted test first, then `make test` before merging a milestone.

Verification:

```sh
make test
```
