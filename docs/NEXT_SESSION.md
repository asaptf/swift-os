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
- **M12c — DONE (2026-06-05):** `console-login` is the boot **init** program. `main.swift`'s `runInit`
  starts `/bin/console-login` instead of busybox; every session begins by authenticating, then `execve`'s
  the shell with the adopted context; init restarts the prompt when a session exits. The `-kernel`/UEFI
  tests authenticate (root/swordfish) after the M7 Ctrl-C; `boot_test` TIMEOUT raised to 45s.
- **M12d — DONE (2026-06-05):** passwords are **SHA-256 hashed**, not plaintext. The store field is now
  `salt$sha256hex` (per-user salt; `hash = SHA-256(salt+password)`), and `console-login` carries a
  self-contained Swift SHA-256 (FIPS 180-4) to verify. `console_login_test` still rejects a wrong password
  and logs in with the real one.
## M13 — VFS capability enforcement

- **M13a — DONE (2026-06-05):** `vfsOpen` now checks the running process's capability mask
  (`processCurrentCaps`): reading needs `capFsRead`, writing/creating (tmpfs) needs `capTmpWrite`; a
  capless principal gets `EACCES`. The open-time check covers read/getdents (you cannot open a file or
  directory to read/list it without `capFsRead`). A `guest` principal (caps = `capSpawn` only) was added
  to the identity store; `tests/cap_enforce_test.sh` logs in as guest and asserts `echo` (a builtin) works
  while `cat /etc/motd` and `ls /` are denied. root/user (which hold `capFsRead`) are unaffected.
- **M13b — DONE (2026-06-05):** the path-based tmpfs mutations (`unlink`/`mkdir`/`rmdir`/`rename`) now also
  require `capTmpWrite` (they bypass `vfsOpen`); `ftruncate`/`write` were already covered via the
  writable-fd check. Closes the namespace-mutation gap left by M13a.
- **M13c — DONE (2026-06-05):** per-file ownership + a real `ls -l` view. Each vnode carries an
  `owner` principal and `mode`; disk nodes take them from the SWOSBASE image (bumped to **format v2**,
  which now uses the entry's mode + a new owner field), and tmpfs nodes are stamped with the creating
  principal. The kernel `kstat` widened 16→24 bytes (mode/uid/size/gid/nlink); `newlib_syscalls.c`
  translates into newlib's `struct stat` (so the kernel never hardcodes that ABI). busybox `ls -l`
  resolves owner/group names via compat `getpwuid`/`getgrgid` reading `/etc/passwd` + the new
  `/etc/group` (`FEATURE_LS_USERNAME`/`FEATURE_LS_SORTFILES`/`MKDIR` enabled — **busybox rebuild
  required**). Also fixed a latent open-flag ABI bug: `_open` now translates newlib's BSD `O_CREAT`/
  `O_TRUNC` into the kernel ABI, so busybox file creation (and `vi`'s save) actually works.
  `tests/ls_l_test.sh`: root sees root-owned base files; a `user` session's `mkdir /tmp/d` is owned by
  user.
- **Shell redirection + `fcntl` — DONE (2026-06-05):** `echo > file`, `>>`, and pipe-into-redirect now
  work and the interactive shell survives them. `SYS_FCNTL` (34) → `vfsFcntl` handles
  `F_DUPFD`/`F_DUPFD_CLOEXEC`/`F_GETFD`/`F_SETFD`/`F_GETFL` with a per-fd close-on-exec flag honored at
  `execve`; a strong `fcntl` in compat/stubs.c overrides newlib's ENOSYS stub. The M13c revert's root
  cause was that `F_DUPFD_CLOEXEC`=14 (≠ `F_DUPFD`=0) fell through to a `return 0`, so ash closed stdin;
  the `default` case now returns an error. `tests/redirect_test.sh` proves it; `vi_test` hardened to a
  clean-line check.
- **Next (M13 follow-ups):** enforce on the write/read syscalls (not just open) once contexts can
  change mid-fd; a host-side ownership manifest for non-root *base* files; real mtimes/clock;
  `chown`/`chmod`; richer principals. (A stronger password KDF also remains a later refinement.)
- **Native Swift `/bin/ls` — DONE (2026-06-05):** pure-Swift `ls`/`ls -l` (`userland/ls.swift`) over a
  new getdents/stat bridge, resolving owner/group names from `/etc/passwd`+`/etc/group`. Invoked by
  absolute path (`/bin/ls`) so the busybox standalone shell execs it; bare `ls` stays busybox.
  `tests/swift_ls_test.sh`. First step of "more Swift userland utilities".
- **Bigger arcs:** own-Swift sans-IO network stack; native Swift apps on swift-os; more Swift utilities
  (e.g. `cat`/`echo`/`pwd` in Swift, then retire those busybox applets).

## Post-roadmap (M0–M13 done) — going down the list

- **`/bin/id` — DONE (2026-06-05):** Swift userland tool printing the kernel security context
  (`principal=N(name) session=M caps=0xHEX`) via `security_info`; resolves the name from
  `/etc/swos/passwd` when `capFsRead` is held, else prints just the numbers (graceful under enforcement).
  Asserted in `busybox_test` (root → `principal=1(root) … caps=0x1f`) and `cap_enforce_test`
  (guest → `principal=3 … caps=0x2`, no name).
- Remaining list to work through in order: (1) own-Swift sans-IO network stack; (2) native Swift apps
  on swift-os; (3) more Swift userland utilities. (M13c finished file ownership + `ls -l`; the only
  M13 follow-ups left are write/read-time enforcement, a base-owner manifest, clock/mtimes, and
  chown/chmod.)

## Watch-outs / loose ends

- `build/busybox.elf` and the newlib sysroot are expensive and **gitignored** — never `make clean` without
  a follow-up `make newlib && make busybox` (or use `run_in_virtual_box.sh`, which rebuilds them).
- Two board targets now exist; keep `make test` (BOARD=qemu) green and re-verify `BOARD=virtualbox`
  builds after any boot/HAL/linker change.
- The loader still **embeds** the kernel rather than reading it from the ESP; fine until the image grows
  or M11 makes on-disk loading natural — revisit then.
