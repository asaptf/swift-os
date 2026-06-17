<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import type { Terminal } from '@xterm/xterm';
	import type { FitAddon } from '@xterm/addon-fit';
	import { liveVmConfigured, browserCanRunVm, WASM_SIZE_MB } from '$lib/qemu/config';
	import { playRecording } from '$lib/qemu/recording';
	import { attachDemoShell } from '$lib/qemu/shell';
	import Icon from './Icon.svelte';
	import type { BootHandle } from '$lib/qemu/boot';

	type Mode = 'idle' | 'loading' | 'live' | 'recording' | 'demo' | 'error';

	let container: HTMLDivElement;
	let term: Terminal | undefined;
	let fit: FitAddon | undefined;
	let mode = $state<Mode>('idle');
	let status = $state('');
	let canLive = $state(false);
	let reason = $state('');
	let bootHandle: BootHandle | null = null;
	let shellDispose: (() => void) | null = null;
	let recAbort = { aborted: false };
	let onResize: (() => void) | undefined;

	const TERM_THEME = {
		background: '#0d0f12',
		foreground: '#e8eaed',
		cursor: '#ff6a4d',
		selectionBackground: 'rgba(240,81,56,0.32)',
		black: '#0d0f12',
		green: '#4ec77f',
		yellow: '#ecb45a',
		red: '#f06a5e',
		blue: '#6ea8fe',
		brightBlack: '#7b828d'
	};

	onMount(async () => {
		const [{ Terminal }, { FitAddon }] = await Promise.all([
			import('@xterm/xterm'),
			import('@xterm/addon-fit')
		]);
		await import('@xterm/xterm/css/xterm.css');

		term = new Terminal({
			fontFamily: "'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, monospace",
			fontSize: 13,
			lineHeight: 1.35,
			cursorBlink: true,
			convertEol: false,
			theme: TERM_THEME,
			rows: 22
		});
		fit = new FitAddon();
		term.loadAddon(fit);
		term.open(container);
		try {
			fit.fit();
		} catch {
			/* container not measured yet */
		}

		canLive = liveVmConfigured() && browserCanRunVm();
		if (!canLive) {
			reason = !liveVmConfigured()
				? 'The pinned WASM build is not wired up yet — showing a recorded boot.'
				: 'This browser is not cross-origin isolated (SharedArrayBuffer unavailable) — showing a recorded boot.';
		}

		onResize = () => {
			try {
				fit?.fit();
			} catch {
				/* ignore */
			}
		};
		window.addEventListener('resize', onResize);
	});

	onDestroy(() => {
		recAbort.aborted = true;
		shellDispose?.();
		bootHandle?.dispose();
		if (onResize) window.removeEventListener('resize', onResize);
		term?.dispose();
	});

	async function startLive() {
		if (!term) return;
		mode = 'loading';
		status = 'Fetching emulator…';
		try {
			const { bootLiveVm } = await import('$lib/qemu/boot');
			bootHandle = await bootLiveVm(term, (s) => (status = s));
			mode = 'live';
			term.focus(); // keyboard goes straight to the guest PTY
		} catch (e) {
			console.error('[try] live VM failed', e);
			reason = 'Could not start the in-browser VM — playing the recorded session instead.';
			await startRecording();
		}
	}

	async function startRecording() {
		if (!term) return;
		recAbort.aborted = true;
		shellDispose?.();
		shellDispose = null;
		recAbort = { aborted: false };
		mode = 'recording';
		term.reset();
		await playRecording(term, recAbort);
		if (recAbort.aborted || !term) return;
		// Hand off to a simulated interactive shell so the keyboard works now.
		mode = 'demo';
		shellDispose = attachDemoShell(term);
	}
</script>

<div class="emu">
	<div class="win">
		<div class="win-bar">
			<span class="win-dots"><i></i><i></i><i></i></span>
			<span class="win-title">
				<Icon name="terminal" size={13} />
				qemu · swift-os 0.4.1 {mode === 'live' ? '(wasm)' : mode === 'demo' ? '(demo shell)' : mode === 'recording' ? '(recording)' : ''}
			</span>
		</div>
		<div class="win-body emu-body">
			<div class="emu-term" bind:this={container}></div>

			{#if mode === 'idle' || mode === 'loading'}
				<div class="emu-gate">
					{#if mode === 'loading'}
						<div class="emu-spin" aria-hidden="true"></div>
						<p class="mono dim" style="font-size:var(--fs-sm)">{status}</p>
					{:else}
						<span class="proof-pill"><span class="live"></span> Boots a real swift-os VM</span>
						<h3 style="margin-top:1rem">Boot swift-os in your browser.</h3>
						{#if canLive}
							<p class="muted" style="font-size:var(--fs-sm);max-width:34rem;margin-top:.5rem">
								Runs <code>qemu-system-aarch64</code> compiled to WebAssembly — a genuine boot, login,
								and shell, entirely client-side. First run downloads {WASM_SIZE_MB}&nbsp;MB.
							</p>
							<div class="emu-actions">
								<button class="btn btn-primary" onclick={startLive}><Icon name="play" size={18} /> Launch swift-os</button>
								<button class="btn btn-ghost" onclick={startRecording}>Watch a recording instead</button>
							</div>
						{:else}
							<p class="muted" style="font-size:var(--fs-sm);max-width:34rem;margin-top:.5rem">{reason}</p>
							<div class="emu-actions">
								<button class="btn btn-primary" onclick={startRecording}><Icon name="play" size={18} /> Launch swift-os</button>
							</div>
						{/if}
					{/if}
				</div>
			{/if}
		</div>
	</div>

	<div class="emu-foot">
		<span class="mono" style="font-size:var(--fs-xs);color:var(--text-dim)">
			{#if mode === 'live'}
				● live VM · type commands — login <code>root</code> / <code>swordfish</code>
			{:else if mode === 'demo'}
				▸ simulated shell — try <code>id</code> · <code>ls -l /</code> · <code>uname -a</code> · <code>help</code>
			{:else if mode === 'recording'}
				▸ playing recorded boot…
			{:else}
				login <code>root</code> / <code>swordfish</code>
			{/if}
		</span>
		{#if mode === 'recording' || mode === 'demo' || mode === 'live'}
			<button class="btn btn-ghost" style="padding:.3rem .7rem;font-size:var(--fs-xs)" onclick={startRecording}>Replay ▸</button>
		{/if}
	</div>
</div>

<style>
	.emu { max-width: 60rem; }
	.emu-body { padding: 0; position: relative; }
	.emu-term { min-height: 440px; padding: var(--sp-3) var(--sp-4); }
	.emu-gate {
		position: absolute;
		inset: 0;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		text-align: center;
		gap: 0.2rem;
		padding: var(--sp-6);
		background: linear-gradient(180deg, rgba(13, 15, 18, 0.86), rgba(13, 15, 18, 0.96));
		backdrop-filter: blur(2px);
	}
	.emu-actions { display: flex; flex-wrap: wrap; gap: var(--sp-3); justify-content: center; margin-top: var(--sp-5); }
	.emu-foot { display: flex; align-items: center; justify-content: space-between; gap: var(--sp-3); margin-top: var(--sp-3); }
	.emu-spin {
		width: 28px; height: 28px; border-radius: 50%;
		border: 2px solid var(--border-strong); border-top-color: var(--accent);
		animation: emu-spin 0.8s linear infinite; margin-bottom: var(--sp-3);
	}
	@keyframes emu-spin { to { transform: rotate(360deg); } }
	@media (prefers-reduced-motion: reduce) { .emu-spin { animation: none; } }
</style>
