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
- **M11 — STARTED.** M11a done: packed base-image format (`SWOSBASE`), host packer (`tools/basepack.swift`,
  `make base-image` → `build/base.img`), and `tests/base_image_test.swift`. No kernel-side disk reading yet.
- **Off critical path (done opportunistically):** EFI GOP framebuffer console + virtio-input keyboard +
  graphical QEMU target; documented direction for an own-Swift sans-IO network stack (future).

Sanity check at session start:
```sh
make test                          # BOARD=qemu — all green
make BOARD=virtualbox disk-run     # VBox-variant kernel boots under QEMU UEFI
```

## Recommended focus: M11 (autonomous, on the critical path)

Track A (VirtualBox) needs a GUI hypervisor and the user's machine; Track B (M11) can be done entirely
here and advances the roadmap. **Prioritize M11.**

### M11b — virtio-blk driver
- Discover the virtio-mmio block device via the M9 HAL (parse `virtio,mmio` nodes from the DTB; QEMU
  `virt` exposes them — add their reg/IRQ to `Platform`).
- Minimal virtio 1.0 MMIO block driver: feature negotiation, one virtqueue, synchronous read of 512-byte
  sectors. Single-threaded blocking reads are fine for a read-only base.
- Test: read sector 0 of an attached disk and verify known bytes.

### M11c — serve the read-only base FS from disk
- Attach `build/base.img` to QEMU as a second virtio-blk disk (simplest), or place it in a partition of
  the GPT image and read by LBA offset. Decide and record (a dedicated disk is simplest first).
- Parse the `SWOSBASE` header/entries in the kernel (mirror `tools/basepack.swift`, keep it tiny — the
  format is little-endian by design). Back the read-only VFS vnodes with extents into the disk image
  instead of the static Swift literals in `kernel/vfs/vfs.swift`.
- Keep `/tmp` tmpfs unchanged.
- Acceptance: `ls /`, `cat /etc/motd`, `echo` work with files read **from disk**, not kernel literals.

### M11d — move busybox + demos off the embedded blob (stretch)
- Pack `build/busybox.elf` and the demo ELFs into the base image; have `exec.swift` resolve `/bin/*` from
  disk. Drop `kernel/user/user_blob.S`. This is the real payoff (kernel image shrinks, FS is the source).
- Watch: ELF loading currently reads from an in-memory blob; it must read from the packed base extents.

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

## After M11

Per `docs/NOTES.md` roadmap: **M12** (capability/principal core + login) → **M13** (permission enforcement
on the VFS). M12 wants the identity store in the base image — which M11 makes available on disk, so the
ordering is right.

## Watch-outs / loose ends

- `build/busybox.elf` and the newlib sysroot are expensive and **gitignored** — never `make clean` without
  a follow-up `make newlib && make busybox` (or use `run_in_virtual_box.sh`, which rebuilds them).
- Two board targets now exist; keep `make test` (BOARD=qemu) green and re-verify `BOARD=virtualbox`
  builds after any boot/HAL/linker change.
- The loader still **embeds** the kernel rather than reading it from the ESP; fine until the image grows
  or M11 makes on-disk loading natural — revisit then.
