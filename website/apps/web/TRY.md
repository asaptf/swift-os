# Try in your browser — in-browser QEMU (WASM)

The `/try` page boots a **real swift-os AArch64 VM in the browser**:
`qemu-system-aarch64` compiled to WebAssembly (the [ktock/qemu-wasm](https://github.com/ktock/qemu-wasm)
toolchain), emulating the same `-M virt` machine as `make run`, with the guest
serial console wired to an xterm.js terminal. No backend.

Until the pinned artifacts are wired up, `/try` plays a faithful **recorded**
boot/login and then hands off to a **simulated interactive shell** (clearly
labelled "demo") so the keyboard works immediately — `id`, `uname -a`,
`ls -l /`, `cat /etc/motd`, `ps`, `help`, with line editing and history. It also
falls back to this on browsers that aren't cross-origin isolated.

Keyboard input in the **live** VM is real: `xterm-pty` gives a bidirectional
PTY, so keystrokes go straight to the guest serial console. The demo shell
(`src/lib/qemu/shell.ts`) is a fixed-command stand-in, not a real OS.

## Pieces

| File | Role |
| --- | --- |
| `src/routes/try/+page.svelte` | The page. |
| `src/lib/components/Emulator.svelte` | xterm.js terminal, gate UI, live ↔ recorded state machine. |
| `src/lib/qemu/config.ts` | Artifact URLs (from `PUBLIC_QEMU_WASM_*`) + the QEMU args (mirror of the Makefile's `QEMU_FLAGS`). |
| `src/lib/qemu/boot.ts` | Loads the WASM module, wires the guest TTY to xterm via `xterm-pty`. |
| `src/lib/qemu/recording.ts` | The recorded fallback session. |
| `src/hooks.server.ts` | COOP/COEP on `/try` (+ `/qemu`) for SharedArrayBuffer. |
| `.github/workflows/website-qemu-wasm.yml` (repo root) | Builds + pins the bundle. |

## How the artifacts are built (CI)

`make build base-image build/virt.dtb` produces the guest (`kernel.elf`,
`base.img`, `virt.dtb`). The CI workflow then builds `qemu-system-aarch64` with
Emscripten and packages the guest into the Emscripten FS under `/pack` via
`file_packager.py`, yielding the bundle:

```
qemu-system-aarch64.js   qemu-system-aarch64.wasm
qemu-system-aarch64.worker.js   qemu-system-aarch64.data   manifest.json
```

The QEMU args in `config.ts` reference these packaged paths (`/pack/kernel.elf`,
`/pack/base.img`, `/pack/virt.dtb`) — keep them in sync with the Makefile.

## Enabling the live VM

Point the web app at a published bundle and pin its version:

```bash
# apps/web/.env  (same-origin example: drop the bundle into static/qemu/)
PUBLIC_QEMU_WASM_BASE=/qemu
PUBLIC_QEMU_WASM_VERSION=<git-sha-from-manifest>
PUBLIC_QEMU_WASM_SIZE_MB=~30
```

With `PUBLIC_QEMU_WASM_BASE` set **and** the browser cross-origin isolated, the
gate offers **Boot swift-os**; otherwise it offers the recorded boot.

## Cross-origin isolation (required for the live VM)

qemu-wasm uses pthreads → `SharedArrayBuffer` → the document must be
**cross-origin isolated**. `hooks.server.ts` sets, scoped to `/try` and `/qemu`:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: credentialless
```

`credentialless` (rather than `require-corp`) keeps cross-origin no-cors
resources — e.g. the Google-hosted fonts — loading while still granting
`crossOriginIsolated`. Trade-off: Safari's support for `credentialless` is
partial. For broad Safari support, switch to `require-corp` and serve the bundle
same-origin (or with `Cross-Origin-Resource-Policy: cross-origin`), and
self-host the fonts.

> Scope matters: the headers are applied **only** to `/try` and `/qemu`, so the
> rest of the site is unaffected.

## Performance & honesty

WebAssembly has no native JIT, so qemu-wasm runs a WASM-compiled interpreter
(TCI) and JITs hot translation blocks to WebAssembly modules at runtime — slower
than native QEMU, but swift-os is tiny so the boot is tolerable. The VM is
ephemeral: the read-only `base.img` and the tmpfs `/tmp` reset on every boot.
The page is explicit that it's experimental and that local `make run` is faster.
