import { qemuModuleUrl, QEMU_ARGS, WASM_BASE, WASM_VERSION } from './config';
import type { Terminal } from '@xterm/xterm';

/* Loads the pinned qemu-system-aarch64 WASM module and boots swift-os, wiring
 * the guest serial console to the xterm.js terminal via xterm-pty.
 *
 * The precise Module contract (the `pty` hand-off) matches the ktock/qemu-wasm
 * build, which links xterm-pty's emscripten-pty.js. See apps/web/TRY.md. */

export interface BootHandle {
	dispose(): void;
}

export async function bootLiveVm(
	term: Terminal,
	onStatus: (s: string) => void
): Promise<BootHandle> {
	const { openpty } = await import('xterm-pty');
	const { master, slave } = openpty();
	// xterm-pty's master addon targets the legacy `xterm` types; structurally
	// compatible with @xterm/xterm's addon interface.
	term.loadAddon(master as unknown as Parameters<Terminal['loadAddon']>[0]);

	onStatus('Fetching emulator…');
	// Emscripten ES6 module (built with -sEXPORT_ES6=1); default export is the factory.
	const mod = (await import(/* @vite-ignore */ qemuModuleUrl())) as {
		default: (opts: Record<string, unknown>) => Promise<{ exit?: () => void }>;
	};

	onStatus('Booting swift-os…');
	const v = WASM_VERSION ? `?v=${WASM_VERSION}` : '';
	const instance = await mod.default({
		arguments: QEMU_ARGS,
		// xterm-pty's emscripten-pty.js reads Module.pty and binds the guest TTY to it.
		pty: slave,
		locateFile: (path: string) => `${WASM_BASE}/${path}${v}`,
		printErr: (s: string) => console.warn('[qemu]', s),
		onAbort: (reason: unknown) => console.error('[qemu] abort', reason)
	});

	return {
		dispose() {
			try {
				instance?.exit?.();
			} catch {
				/* module may not expose exit; the worker is torn down on navigation */
			}
		}
	};
}
