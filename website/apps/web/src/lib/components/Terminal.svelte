<script lang="ts">
	import { onMount } from 'svelte';

	let { title = 'qemu · swift-os · aarch64' }: { title?: string } = $props();
	let screen: HTMLDivElement;

	interface Step {
		t?: string;
		c?: string;
		d?: number;
		type?: string;
		prompt?: boolean;
		tcls?: string;
	}

	const SEQ: Step[] = [
		{ t: 'QEMU · virt · aarch64-cortex-a72', c: 't-comment', d: 260 },
		{ t: 'UEFI: loading \\EFI\\BOOT\\BOOTAA64.EFI ...', c: 't-dim', d: 220 },
		{ t: '[ ok ] swift-os kernel (Embedded Swift, signed)', c: 't-ok', d: 200 },
		{ t: '[ ok ] MMU enabled · EL1 · 256 MiB', c: 't-ok', d: 140 },
		{ t: '[ ok ] virtio-net up · DHCPv4 10.0.2.15/24', c: 't-ok', d: 140 },
		{ t: '[ ok ] mounted base.img (ro) + /tmp (tmpfs)', c: 't-ok', d: 140 },
		{ t: '[ ok ] httpd listening on :8080', c: 't-ok', d: 140 },
		{ t: '[ ok ] llmd ready · POST /completion', c: 't-ok', d: 200 },
		{ t: '', c: '', d: 120 },
		{ t: 'swift-os login: ', c: 't-dim', type: 'root', d: 520 },
		{ t: 'Password: ', c: 't-dim', type: '••••••••', d: 360 },
		{ t: '', c: '', d: 120 },
		{ t: 'Welcome to swift-os, root', c: 't-dim', d: 220 },
		{ prompt: true, type: 'id', d: 500 },
		{ t: 'session: principal=1 session=1 caps=63', c: 't-cmd', d: 200 },
		{ prompt: true, type: 'netinfo', d: 500 },
		{ t: 'ipv4 10.0.2.15/24  gw 10.0.2.2  dns 10.0.2.3', c: 't-cmd', d: 200 },
		{ prompt: true, type: 'tcpget 127.0.0.1 8080', tcls: 't-str', d: 600 },
		{ t: 'HTTP/1.1 200 OK · served by swift-os httpd', c: 't-cmd', d: 240 },
		{ prompt: true, type: '', d: 1600 }
	];

	const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
	const promptPrefix = () => '<span class="t-prompt">root@swift-os</span><span class="t-dim">:~$</span> ';

	onMount(() => {
		const RM = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
		let lines: string[] = [];
		let idx = 0;
		let alive = true;

		function render(activeTyped: string | null, showCaret: boolean) {
			let html = lines.join('');
			if (activeTyped != null) html += activeTyped;
			if (showCaret) html += '<span class="term-caret"></span>';
			screen.innerHTML = html;
			screen.scrollTop = screen.scrollHeight;
		}

		function typeText(prefixHtml: string, text: string, cls: string, done: () => void) {
			let i = 0;
			(function tick() {
				if (!alive) return;
				const typed = `<span class="term-line">${prefixHtml}<span class="${cls || 't-cmd'}">${esc(text.slice(0, i))}</span></span>`;
				render(typed, true);
				if (i < text.length) {
					i++;
					setTimeout(tick, 38 + Math.random() * 30);
				} else {
					lines.push(`<span class="term-line">${prefixHtml}<span class="${cls || 't-cmd'}">${esc(text)}</span></span>`);
					done();
				}
			})();
		}

		function next() {
			if (!alive) return;
			if (idx >= SEQ.length) {
				setTimeout(() => {
					lines = [];
					idx = 0;
					render(null, true);
					setTimeout(next, 400);
				}, 2600);
				return;
			}
			const s = SEQ[idx++];
			if (s.prompt) {
				if (s.type) typeText(promptPrefix(), s.type, s.tcls || 't-cmd', () => setTimeout(next, s.d || 200));
				else {
					lines.push(`<span class="term-line">${promptPrefix()}</span>`);
					render(null, true);
					setTimeout(next, s.d || 200);
				}
			} else if (s.type != null) {
				typeText(`<span class="${s.c}">${esc(s.t || '')}</span>`, s.type, 't-cmd', () => setTimeout(next, s.d || 200));
			} else {
				lines.push(`<span class="term-line"><span class="${s.c}">${esc(s.t || '')}</span></span>`);
				render(null, true);
				setTimeout(next, s.d || 160);
			}
		}

		if (RM) {
			SEQ.forEach((s) => {
				if (s.prompt) lines.push(`<span class="term-line">${promptPrefix()}<span class="t-cmd">${esc(s.type || '')}</span></span>`);
				else if (s.type != null) lines.push(`<span class="term-line"><span class="${s.c}">${esc(s.t || '')}</span><span class="t-cmd">${esc(s.type)}</span></span>`);
				else lines.push(`<span class="term-line"><span class="${s.c}">${esc(s.t || '')}</span></span>`);
			});
			render(null, false);
			return;
		}

		const startTimer = setTimeout(next, 200);
		return () => {
			alive = false;
			clearTimeout(startTimer);
		};
	});
</script>

<div class="term-wrap">
	<div class="win">
		<div class="win-bar">
			<span class="win-dots"><i></i><i></i><i></i></span>
			<span class="win-title">
				<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 17l6-6-6-6M12 19h8" /></svg>
				{title}
			</span>
		</div>
		<div class="win-body">
			<div class="terminal-screen" bind:this={screen} aria-label="Animated boot and login session" role="img"></div>
		</div>
	</div>
</div>
