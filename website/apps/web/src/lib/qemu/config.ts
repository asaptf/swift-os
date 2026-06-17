import { env } from '$env/dynamic/public';

/* In-browser QEMU (WASM) configuration.
 *
 * The emulator artifacts (qemu-system-aarch64.{js,wasm,worker.js,data}) are
 * built and pinned in CI from the ktock/qemu-wasm toolchain; the swift-os image
 * (kernel.elf + base.img + virt.dtb) is packaged into the `.data` archive under
 * /pack via Emscripten's file_packager. See apps/web/TRY.md. */

/** Base URL the pinned artifacts are served from (same-origin by default). */
export const WASM_BASE = (env.PUBLIC_QEMU_WASM_BASE || '').replace(/\/$/, '');

/** Pinned artifact version, appended as ?v= for cache-busting. */
export const WASM_VERSION = env.PUBLIC_QEMU_WASM_VERSION || '';

/** Approx total download, shown on the gate (override per pinned build). */
export const WASM_SIZE_MB = env.PUBLIC_QEMU_WASM_SIZE_MB || '~30';

/** True when a real in-browser VM can be offered (artifacts configured). */
export const liveVmConfigured = () => WASM_BASE.length > 0;

/** The ES6 module entry for the aarch64 system emulator. */
export const qemuModuleUrl = () =>
	`${WASM_BASE}/qemu-system-aarch64.js${WASM_VERSION ? `?v=${WASM_VERSION}` : ''}`;

/* QEMU command line — mirrors the repo's `make run` (Makefile QEMU_FLAGS), with
 * the packaged guest artifacts addressed under Emscripten's virtual FS (/pack). */
export const QEMU_ARGS = [
	'-M', 'virt',
	'-cpu', 'cortex-a72',
	'-m', '256M',
	'-nographic',
	'-global', 'virtio-mmio.force-legacy=false',
	'-device', 'loader,file=/pack/virt.dtb,addr=0x4FF00000,force-raw=on',
	'-drive', 'file=/pack/base.img,format=raw,if=none,id=swosbase,readonly=on',
	'-device', 'virtio-blk-device,drive=swosbase',
	'-kernel', '/pack/kernel.elf'
];

/** Browser must be cross-origin isolated (COOP/COEP) with SharedArrayBuffer for
 *  qemu-wasm's pthreads. Without it we fall back to the recorded session. */
export function browserCanRunVm(): boolean {
	return (
		typeof SharedArrayBuffer !== 'undefined' &&
		typeof globalThis.crossOriginIsolated !== 'undefined' &&
		globalThis.crossOriginIsolated === true
	);
}
