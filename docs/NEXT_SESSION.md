# Plan for the next session

Working notes for picking up swift-os development. Authoritative milestone history lives in
`docs/NOTES.md`; this file is the short-lived "where we are / what to do next" scratchpad.

## Where we are (2026-06-04)

- **M0–M9 — DONE.** Boot, MMU, scheduler, syscalls, VFS, newlib, busybox `sh`, and the M9 HAL
  (runtime hardware discovery from the device tree).
- **M10 — DONE.** UEFI boot: the PE loader (`boot/efi/`) stages the embedded kernel, `ExitBootServices`,
  and jumps in. Boots to busybox **from a real GPT disk image under QEMU+AAVMF, no `-kernel`**.
  `make disk` / `make disk-run`; `tests/uefi_boot_test.sh` in `make test`.
- **M10.5 — IN PROGRESS, blocked on VirtualBox.**
  - The VirtualBox ARM machine model is captured (RAM `0x0800_0000`, PL011 `0xFFDD_F000`, GIC
    `0xFCD3_0000`, no graphics console) — see `docs/VIRTUALBOX.md`.
  - A `BOARD=virtualbox` kernel variant exists (relinked at `0x0808_0000`, VBox HAL defaults, VBox RAM/MMIO
    map, explicit PL011 enable). **Verified end-to-end under QEMU UEFI** (`make BOARD=virtualbox disk-run`).
  - **Blocker:** VirtualBox's ARM EFI does not launch `\EFI\BOOT\BOOTAA64.EFI` from our GPT/ESP — no
    output at all on real VBox, so the port is unconfirmed there. This is a VBox-side boot problem,
    independent of the kernel.
- **M11 — IN PROGRESS.** M11a done: packed base-image format (`SWOSBASE`), host packer
  (`tools/basepack.swift`, `make base-image` → `build/base.img`), `tests/base_image_test.swift`.
  **M11b — DONE (2026-06-05):** HAL discovers the virtio-mmio bank from the DTB; a polled virtio 1.0 MMIO
  block driver (`kernel/drivers/virtio_blk.c`) reads 512-byte sectors. Boot probe reads sector 0 and
  verifies the `SWOSBASE` magic; `tests/virtio_blk_test.sh` in `make test`.
  **M11c — DONE (2026-06-05):** the read-only VFS is backed by extents into the disk image (parses
  `SWOSBASE` at `vfsInit`, reads file spans via `virtio_blk_read_range`), with the static literals kept as
  a fallback when no packed disk is attached. `tests/vfs_disk_test.sh` (unique-marker image) in `make test`.
  **M11d — DONE (2026-06-05):** `make base-image` stages real ELFs under `/bin`; `exec.swift` loads
  `/bin/*` from the packed image. **`user_blob.S` removed** (kernel image ~1.4 MiB → ~208 KiB); every boot
  medium now attaches `build/base.img` and `virtio_blk_init` picks the `SWOSBASE` disk. `tests/disk_exec_test.sh`
  proves busybox and `/bin/ps` execute from disk. **M11 fully complete (a–d).**
- **Off critical path (done opportunistically):** EFI GOP framebuffer console + virtio-input keyboard +
  graphical QEMU target; a blinking block cursor with arrow-key/Home/End/Delete line editing in the tty
  (kernel-side, since busybox editing is off); documented direction for an own-Swift sans-IO network stack.

Sanity check at session start:
```sh
make test                          # BOARD=qemu — all green
make BOARD=virtualbox disk-run     # VBox-variant kernel boots under QEMU UEFI
```

## Recommended focus: M11 (autonomous, on the critical path)

Track A (VirtualBox) needs a GUI hypervisor and the user's machine; Track B (M11) can be done entirely
here and advances the roadmap. **Prioritize M11.**

### M11b — virtio-blk driver — DONE (2026-06-05)
- HAL parses the `virtio,mmio` bank from the DTB (base/stride/count → `platform.virtioMmio*`).
- `kernel/drivers/virtio_blk.c`: polled virtio 1.0 MMIO driver, feature negotiation, one request
  virtqueue, synchronous 512-byte sector reads via a header/data/status descriptor chain.
- `tests/virtio_blk_test.sh`: attaches `build/base.img`, reads sector 0, verifies the `SWOSBASE` magic.
- Watch for M11c: the test (and any disk-backed boot) needs the **modern** virtio-mmio transport —
  pass `-global virtio-mmio.force-legacy=false`; the driver only speaks v2 (version register == 2).

### M11c — serve the read-only base FS from disk — DONE (2026-06-05)
- Dedicated disk: attach the packed image as its own virtio-blk device (a `SWOSBASE` magic at sector 0
  selects the disk path; a non-packed disk, e.g. the UEFI GPT, falls back to literals).
- `vfsInit` parses the `SWOSBASE` header/entries off disk and backs the read-only vnodes with extents
  (`diskOffset`/`dataLen`); `vfsRead` reads spans via `virtio_blk_read_range`. `/tmp` tmpfs unchanged.
- Acceptance met: `ls /`, `cat /etc/motd`, `echo` read **from disk** — `tests/vfs_disk_test.sh` proves it
  with a unique marker image. The driver needs the modern transport (`virtio-mmio.force-legacy=false`).

### M11d — disk-first executable lookup + drop the embedded blob — DONE (2026-06-05)
- `make base-image` stages busybox, Swift `ps`, and the demo ELFs into `/bin` in the packed base image.
- `exec.swift` resolves `/bin/*` through the mounted `SWOSBASE` tree, reading each ELF into a reusable PMM
  buffer (2 MiB, physically contiguous). `main.swift` demos + the shell launcher load from disk too.
- **`kernel/user/user_blob.S` removed** along with the embedded ELF symbols in `io.h`: the kernel image
  dropped from ~1.4 MiB to ~208 KiB. Every boot medium now ships a packed base image:
  - `virtio_blk_init` scans all block devices and **selects the one whose sector 0 is `SWOSBASE`**, so a
    medium can carry both a boot disk (GPT/ESP) and the base image.
  - All QEMU launches (`make run`, the `-kernel` tests, UEFI `disk-run`/`uefi_boot_test`, `run-gfx`) attach
    `build/base.img` as a second modern virtio-blk disk (`virtio-mmio.force-legacy=false`).
- `tests/disk_exec_test.sh` proves busybox + `/bin/ps` execute from disk; all 11 suites green.

## Track A: unblock M10.5 (when VirtualBox is available)

The kernel side is ready; the problem is VBox firmware not launching our EFI app. Investigate VBox-side,
roughly in order of likelihood:
1. **EFI shell manual launch.** Boot the VM to the UEFI shell, `map` to list filesystems, then run
   `FS0:\EFI\BOOT\BOOTAA64.EFI` manually. If it launches, the issue is the boot *policy*, not the image.
2. **Persisted boot entry.** The removable-media fallback may be disabled/cleared (the NVRAM-delete
   workaround also clears boot entries). Add a real `Boot####` entry pointing at the ESP file (via the
   EFI shell `bcfg`, or a VBox NVRAM tool) and set BootOrder.
3. **Storage controller.** Try attaching the VDI to a different controller (virtio-scsi vs NVMe vs AHCI);
   the firmware's auto-boot may only scan some.
4. **ESP/GPT spec quirks.** Confirm the ESP partition type GUID, and try FAT16 vs FAT32; some firmwares
   are picky.
5. **Fallback artifact.** If disk boot stays stubborn, try an **EFI ISO** (El Torito) — optical EFI boot
   is sometimes more reliable on preview firmware.

Decision to make: **timebox** this. VirtualBox ARM is a developer preview; if it will not launch our
loader after the above, keep **QEMU+AAVMF as the reference UEFI target** and mark VBox best-effort (this
was the original M10.5 stance). Do not let it block M11→M13.

Needed from the user for Track A: the VM's `Logs/VBox.log`, and the result of the EFI-shell manual launch
(step 1) — those determine whether this is solvable from our side at all.

## M12

M12 is now underway.

- **M12a — DONE (2026-06-05):** kernel process entries carry a `principal`/`session`/capability mask,
  top-level processes get the boot console context, children inherit it through `spawn`/`fork`, and
  `execve` preserves it. `SYS_SECURITY_INFO` (31) exposes the current context for EL0 introspection.
  `/bin/identitydemo` validates boot context + fork inheritance during `boot_test.sh`.
- **M12b — DONE (2026-06-05):** identity store `/etc/swos/passwd` in the base image
  (`name:principal:session:caps:password:shell`) with a compat `/etc/passwd` view. New privileged
  `SYS_LOGIN` (32) replaces the caller's security context, gated on `capConsole` so only the boot/login
  context can use it. `/bin/console-login` reads the store, prompts login/password, authenticates, calls
  `login()` to adopt the principal/session/caps, and `execve`'s the shell (which inherits the context).
  `tests/console_login_test.sh` rejects a wrong password and logs in as `user` (principal 2, caps 14).
- **Next: M12c/d** — wire `console-login` into the boot path as the init program (replace the direct
  busybox launch), and move toward password hashing. Then **M13**: permission enforcement on the VFS,
  checked against the capability mask now carried by every process.

After M12, per `docs/NOTES.md`: **M13** starts permission enforcement on the VFS.

## Watch-outs / loose ends

- `build/busybox.elf` and the newlib sysroot are expensive and **gitignored** — never `make clean` without
  a follow-up `make newlib && make busybox` (or use `run_in_virtual_box.sh`, which rebuilds them).
- Two board targets now exist; keep `make test` (BOARD=qemu) green and re-verify `BOARD=virtualbox`
  builds after any boot/HAL/linker change.
- The loader still **embeds** the kernel rather than reading it from the ESP; fine until the image grows
  or M11 makes on-disk loading natural — revisit then.
