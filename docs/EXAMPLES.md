# SwiftOS Examples

These examples are complete, current workflows for the checked-in system. They
are written as operator and developer recipes, not as future design notes.

Prerequisite for all guest examples:

```sh
make build base-image build/virt.dtb
make run
```

At boot, complete the tty demo, log in as `root` with password `swordfish`, and
run the guest commands shown below.

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

Note: this is package overlay P2. Target-side install/remove commands are future
work.

## 10. Run The Native Swift LLM Demo

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

## 11. Serve LLM Completions Over TCP

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
- The serial log includes `llmd: model int8 Q8_0 GS=32` and `llmd: served`.

Equivalent automated check:

```sh
./tests/llm_serve_test.sh
```

## 12. Exercise The Swift REPL Demos

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

## 13. Validate UEFI Boot

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

## 14. Run The Full Gate

Host:

```sh
make test
```

The full gate builds the kernel, base image, package fixture, model artifacts,
host-side unit tests, and many QEMU acceptance tests. For day-to-day work, run a
targeted test first, then `make test` before merging a milestone.
