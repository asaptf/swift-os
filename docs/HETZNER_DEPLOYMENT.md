<!-- SPDX-License-Identifier: Apache-2.0 -->
# Deploying SwiftOS on a Hetzner Cloud ARM VM

Handoff note: how SwiftOS was brought up as the **actual OS** of a Hetzner Cloud
ARM (CAX) server — not as a QEMU guest under Linux. Written so a fresh session
can understand what was done, reproduce it, and continue. Done 2026-06-16; all
changes are on `main` (`ff7c7d2`, `c7ff85e`, `b7fa6d2`, `ac0484e`).

## TL;DR — current state

SwiftOS boots on the bare Hetzner VM and is reachable over SSH:

```
ssh root@138.199.222.99 /bin/id        →  principal=1(root)   (persistent, repeatable)
ssh root@138.199.222.99 /bin/netinfo   →  ipv4 138.199.222.99/32  gw 172.31.1.1 (dhcp)  ready yes
```

- Target server: `swiftos.tech` / `138.199.222.99`, Hetzner Cloud aarch64 VM, **fully wipeable**.
- sshd is **bounded-exec only** (runs `/bin/<tool>`; `/bin/id`, `/bin/echo`, `/bin/netinfo`, …). No interactive shell yet.
- Login key: the operator's `~/.ssh/id_ed25519` (staged into the image as `/etc/ssh/authorized_keys`).
- SwiftOS host key for `known_hosts` (derived from the staged seed):
  `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEaFnBj5Su/fhH1HqYa7Ri/8HECFadpoJWBv55FW5weO`
- Regression gate: `make hetzner-deploy-test`.

## The target hardware (probed from the live VM)

Hetzner Cloud ARM VM = QEMU/KVM with EDK2 (UEFI) firmware. Key facts:

| Aspect | Hetzner VM | What stock SwiftOS assumed |
| --- | --- | --- |
| Firmware/config | **ACPI** (EDK2; RSDP/MADT/MCFG/SPCR/GTDT) | device-tree only (`-M virt,acpi=off`, FDT) |
| virtio transport | **virtio-PCI** over PCIe ECAM @ `0x40_1000_0000` | virtio-mmio only |
| PCI topology | only the **GPU is on bus 0** (`00:01.0`); NIC `01:00.0`, RNG `05:00.0`, SCSI `06:00.0` are **behind PCIe root ports** (`00:02.x`) on non-zero buses | everything on bus 0 |
| Boot disk | virtio-**scsi** (`1af4:1048`), GPT + ESP | virtio-blk on mmio |
| Interrupts | **GICv3** (GICD `0x0800_0000`, GICR `0x080a_0000`) | GICv2 (MMIO GICC) |
| Console | **noVNC graphical only (virtio-gpu)** — no serial tab, no serial input | PL011 serial (matches, but invisible on Hetzner) |
| Net (real) | DHCP gives a `/32` IPv4 + off-link gateway `172.31.1.1` | tested only against QEMU slirp `/24` |
| RAM / CPU | base `0x4000_0000`, ~4 GiB, **2 vCPU** | base `0x4000_0000` (matches) |

The single thing that matched out of the box was the PL011 base address — but the
Hetzner Cloud console is graphical (virtio-gpu), so the serial log is invisible
there anyway.

## How SwiftOS got here: the H-series

`H0–H5` (pre-this-session, already on `main` before today) made the QEMU model of
this VM boot end-to-end:

- **H0** `make hetzner-run` — a local QEMU profile reproducing the VM (AAVMF, GICv3, virtio-pci, virtio-scsi). Found: no FDT in ACPI mode; GICv2 panic; etc.
- **H1** GICv3 driver (dual-path v2/v3) — `kernel/drivers/gic.swift`.
- **H2** PCIe ECAM enumeration + a `VirtioTransport` (mmio|pci) — `kernel/drivers/pci.swift`, `kernel/drivers/virtio_transport.swift`.
- **H3** root FS from a RAM base image loaded by the EFI loader from the ESP (no kernel disk driver) — `boot/efi/loader.c`, `kernel/fs/ramdisk.swift`.
- **H4** virtio-net over PCI + bounded SSH.
- **H5** platform config parsed from ACPI (RSDP→MADT/MCFG/SPCR/GTDT), not FDT — `kernel/arch/aarch64/acpi.swift`.

`H6` (this session) = actually putting it on the metal. It surfaced **four real
bugs** that only appear on the true device model — these are the important part.

## The four bugs found on the real VM (the gold)

The lesson running through all four: **the local tests put every virtio device on
bus 0 and drove the serial console, so they never reproduced the real topology or
the headless/console reality.** Each fix came with a test that *does* reproduce it.

1. **Per-address-space PCI MMU map** (`ff7c7d2`, `kernel/mm/vm.swift`).
   H2 mapped the PCIe ECAM and the 64-bit virtio MMIO window only in the kernel
   boot page tables (`vm_early.c`). `addressSpaceCreate()` rebuilds a fresh page
   table per process but replicated only the low device/RAM blocks. So once
   `/bin/sshd` (an EL0 process) was the current `TTBR0`, the kernel touching the
   NIC BAR in the 64-bit window during TX/RX faulted at translation level 0
   (`ESR 0x96000004`, `FAR 0x80_0000_5000`) → **panic on the first incoming
   connection**. DHCP survived only because it runs early on the boot tables. Fix:
   mirror both device windows (`l1[256]` ECAM, `l0[1]` → 0x80_0000_0000) into
   every address space.

2. **virtio-gpu scanout console + headless boot** (`c7ff85e`, `kernel/drivers/virtio_gpu.swift`, `kernel/drivers/fb.swift`, `kernel/main.swift`).
   Two problems, both because Hetzner's only console is noVNC (virtio-gpu) with no
   serial:
   - SwiftOS is serial-first; `fb.swift` writes a linear framebuffer (works on
     ramfb/GOP where RAM is scanned directly) but **virtio-gpu needs explicit
     `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH`** — so the screen stayed "Display
     output is not active". Wrote a polled virtio-gpu 2D driver over the H2
     PCI transport; `fb.swift` flushes per line + on a throttled timer.
   - The serial boot path runs `/bin/ttydemo` (a **blocking serial read**) BEFORE
     `swos-init` starts sshd. With no serial input, ttydemo blocked forever and
     sshd never started. Fix: a virtio-gpu-only console (server with a display,
     no keyboard) takes the "boot straight into swos-init/services" path,
     skipping the serial demos.

3. **PCIe bridge recursion** (`b7fa6d2`, `kernel/drivers/pci.swift`) — *the actual
   SSH blocker.* `virtioPciFindDevice` scanned only bus 0. On the real VM only the
   GPU is on bus 0; the NIC/RNG/SCSI are behind PCIe root ports on non-zero buses.
   So the NIC was never found → boot log: `net: no virtio-net device attached` →
   `sshd: socket failed`. (The GPU console worked precisely because it *is* on bus
   0.) Fix: enumerate recursively — for each PCI-to-PCI bridge (header type 1 /
   root port), read its secondary bus and descend, scanning all 8 functions of
   multifunction devices (the root ports are functions of device 2). UEFI firmware
   already programmed the bridge bus numbers and BAR windows; we just follow them.

4. **Persistent (supervised) sshd** — a config, not a code change. The default
   `/etc/swos/services` token `sshd` is **single-shot**: `swos-init` forks it once,
   it serves one session, exits, and is not restarted (then `swos-init` execs
   `console-login`). SwiftOS's TCP sends no RST on a closed port, so the *second*
   SSH connection just times out. Fix: build with the `sshd-supervised` token →
   `swos-init` enters its `waitpid` restart loop, restarting sshd after each
   session (and skipping console-login, which is useless without a keyboard). See
   `fixtures/swos/services-supervised`.

### Still open / known
- Hetzner's noVNC keyboard is **USB-HID** (QEMU XHCI); SwiftOS only has
  virtio-input, so you cannot type at the console. Not needed (SSH is the access
  path); a USB stack is a large future driver.
- The regression test's full `/bin/id` round-trip is **best-effort**: under loaded
  TCG with the NIC behind a bridge, the encrypted-auth read sometimes fails
  (`sshd: encrypted auth read failed`) for the hc5 fixture key. This does NOT
  happen on real KVM (full `/bin/id` works there) — likely RX timing / IRQ routing
  for a bridge-behind NIC under TCG. Worth investigating.

## How to build the deploy image

Built in a worktree that has a full `build/` (toolchain: `qemu-system-aarch64`,
`aarch64-elf-gcc`, host `swiftc`, `lld-link`, AAVMF at
`/opt/homebrew/share/qemu/edk2-aarch64-code.fd`). Stage the SSH material once:

```sh
D=build/hetzner-deploy; mkdir -p $D
cp ~/.ssh/id_ed25519.pub $D/authorized_keys          # the login key
build/sshkey seed --out $D/ssh_host_ed25519_seed     # stable SwiftOS host key
build/sshkey known-host --host 138.199.222.99 --seed-file $D/ssh_host_ed25519_seed   # -> known_hosts line
printf 'sshd-supervised\n' > $D/services             # persistent sshd
```

Then build the kernel and the GPT disk. **`make build` MUST be run explicitly
before `make disk`** — `make disk` does NOT rebuild the kernel from a changed
`kernel/` source (it restages a cached `kernel.bin`):

```sh
make build
rm -f build/swift-os.img build/esp/EFI/swift-os/kernel*.bin build/esp/EFI/swift-os/kernel-boot
make disk \
  SSHD_HOST_SEED_FILE=$PWD/build/hetzner-deploy/ssh_host_ed25519_seed \
  SSHD_AUTHORIZED_KEYS_FILE=$PWD/build/hetzner-deploy/authorized_keys \
  SWOS_SERVICES_FILE=$PWD/build/hetzner-deploy/services
# → build/swift-os.img  (≈96 MiB GPT: ESP + BOOTAA64.EFI + kernelA/B + base.img)
```

Note: `base.img` is signed with this worktree's own image-signing seed, so it
must be paired with this worktree's `kernel.elf`. Do not mix images across
worktrees.

### Verify locally before flashing
`build/hetzner-deploy/verify-topo.sh` (and `verify-gpu.sh`, `verify.sh`) boot the
exact GPT image under the **real Hetzner topology** — devices behind
`pcie-root-port`, GPU on bus 0, GICv3, `-smp 2`, serial OUTPUT-ONLY — and run
OpenSSH against it. Always boot a **copy** of the image: a RW boot mutates the
A/B boot-attempt counters in the ESP. The committed gate is `make hetzner-deploy-test`.

## How to flash a server (live-dd)

The VM has no out-of-band disk access for us; we flash from a running Linux on the
same box. Cycle:

1. **Operator restores Linux access** via the Hetzner Cloud Console: reinstall a
   fresh Ubuntu with their `id_ed25519` selected, **or** enable the Rescue System
   *with their SSH key selected* (rescue without a key only offers a generated
   root password). This is required every time, because once SwiftOS is on the
   disk the box is no longer Linux-reachable (and its console keyboard doesn't
   work — USB-HID).
2. **Copy + checksum:**
   ```sh
   scp -P 22 build/swift-os.img root@138.199.222.99:/root/swift-os.img
   ssh -p 22 root@138.199.222.99 sha256sum /root/swift-os.img   # compare to local shasum -a 256
   ```
3. **Flash + reboot** (overwrites `/dev/sda` live, then forces an immediate reboot
   before the running system writes more; the disk is fully replaced so old-FS
   corruption is irrelevant):
   ```sh
   ssh -p 22 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@138.199.222.99 \
     'dd if=/root/swift-os.img of=/dev/sda bs=4M conv=fsync status=none && sync && \
      echo DD-OK-REBOOTING && (reboot -nf || echo b > /proc/sysrq-trigger)'
   ```
   The SSH connection drops on reboot (expected).
4. **Watch the Hetzner noVNC console** — the SwiftOS boot log now renders there
   (virtio-gpu). Look for `net-dhcp OK: lease <ip>`.
5. **Verify SSH** (the SwiftOS host key differs from the Linux one — pin it):
   ```sh
   KH=$(mktemp); echo '138.199.222.99 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEaFnBj5Su/fhH1HqYa7Ri/8HECFadpoJWBv55FW5weO' >$KH
   ssh -p 22 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KH -o IdentitiesOnly=yes \
     -i ~/.ssh/id_ed25519 root@138.199.222.99 /bin/id        # → principal=1(root)
   ssh ... root@138.199.222.99 /bin/netinfo                  # confirm DHCP IP/gateway
   ```

Safety: the server is wipeable, but `dd` is irreversible and the only recovery
channel is the Hetzner Console — confirm the operator is at the console before
flashing.

## Debugging tips
- The Hetzner noVNC console **is** the diagnostic channel now (it shows the
  virtio-gpu boot log). Prefer reading it (screenshot) over hammering the server
  with SSH probe loops.
- Boot log markers worth knowing: `M9 OK: hardware discovered from ACPI`,
  `M2 GIC: GICv3`, `net-dhcp OK: lease …`, `swos-init: supervision active`,
  `sshd: listening on 22`, `sshd: authorized key matched`. Bad signs:
  `net: no virtio-net device attached`, `sshd: socket failed`,
  `panic: unexpected EL1 exception … FAR_EL1=0x80_…` (a PCI MMIO map gap).

## Follow-ups
- Interactive SSH shell / PTY (sshd is bounded-exec only).
- USB-HID keyboard so the noVNC console is usable.
- Investigate the bridge-behind-NIC RX timing under TCG (best-effort in the gate).
- Then: host the website (nginx/Node) on the live server — see the Hetzner
  section of `docs/DEPLOYMENT_GUIDE.md`.
