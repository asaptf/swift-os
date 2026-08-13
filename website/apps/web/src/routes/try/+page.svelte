<script lang="ts">
	import { reveal } from '$lib/actions/reveal';
	import { gloss } from '$lib/glossary';
	import Emulator from '$lib/components/Emulator.svelte';
	import Callout from '$lib/components/Callout.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Icon from '$lib/components/Icon.svelte';
	import Seo from '$lib/components/Seo.svelte';
	import { liveVmConfigured } from '$lib/qemu/config';

	// Until a pinned WASM bundle is published, this page plays a recorded boot —
	// the copy has to say so rather than promise a live VM.
	const live = liveVmConfigured();
</script>

<Seo
	title="Try swift-os in your browser"
	description="Boot swift-os in your browser — qemu-system-aarch64 compiled to WebAssembly, emulating the same AArch64 machine as a local run. No install, no backend."
/>

<main id="main" class="wrap wrap-wide" style="padding-block:var(--sp-8)">
	<header style="max-width:48rem;margin-bottom:var(--sp-6)" use:reveal>
		<span class="eyebrow">Try it · in your browser</span>
		<h1 style="margin-top:1rem">Boot swift-os — no install.</h1>
		{#if live}
			<p class="lead" style="margin-top:1rem">
				This runs <code>qemu-system-aarch64</code> compiled to <span class="gloss" data-gloss="embedded swift" use:gloss>WebAssembly</span>,
				emulating the same <code>-M virt</code> machine as <code>make run</code> — a genuine boot to a Swift login
				prompt, entirely client-side. Log in with <code>root</code> / <code>swordfish</code>.
			</p>
		{:else}
			<p class="lead" style="margin-top:1rem">
				The in-browser VM runs <code>qemu-system-aarch64</code> compiled to
				<span class="gloss" data-gloss="embedded swift" use:gloss>WebAssembly</span>, emulating the same
				<code>-M virt</code> machine as <code>make run</code>. The pinned WASM bundle is not published yet, so
				this page currently plays a <strong>recording</strong> of that boot and then hands off to a simulated
				shell. To drive the real thing today, <a href="/quickstart">run it locally</a> — it is three
				<code>make</code> commands.
			</p>
		{/if}
	</header>

	<div use:reveal>
		<Emulator />
	</div>

	<div use:reveal style="margin-top:var(--sp-6);max-width:60rem">
		<Callout type="note" html="<strong>Experimental</strong>In-browser emulation has no JIT, so it runs through a WASM-compiled interpreter with hot paths JITed to WebAssembly — slower than native QEMU, but swift-os is tiny. The VM is ephemeral: the read-only base image and the tmpfs <code>/tmp</code> reset on every boot. For full speed, run it locally." />
	</div>

	<section class="section-sm">
		<div class="section-head" use:reveal><span class="eyebrow">How this works</span><h2 class="h3" style="margin-top:.6rem">{live ? 'A real VM, not a recording.' : 'How the in-browser VM works.'}</h2></div>
		<div class="feature-grid" use:reveal>
			<div class="feature">
				<div class="f-ico"><Icon name="cube" size={22} /></div>
				<h3>Pinned image</h3>
				<p>CI builds the swift-os kernel + signed <code>base.img</code> and packages them into the emulator. The same artifact you'd boot locally.</p>
			</div>
			<div class="feature">
				<div class="f-ico"><Icon name="chip" size={22} /></div>
				<h3>QEMU → WASM</h3>
				<p><code>qemu-system-aarch64</code> built with Emscripten, hot translation blocks JITed to WebAssembly. Threads need a cross-origin-isolated page.</p>
			</div>
			<div class="feature">
				<div class="f-ico"><Icon name="swift" size={22} /></div>
				<h3>Serial → terminal</h3>
				<p>The guest's serial console is wired straight to an xterm.js terminal — keystrokes in, kernel output back.</p>
			</div>
		</div>
	</section>

	<div class="prevnext" use:reveal>
		<a href="/quickstart"><div class="dir">← Faster</div><div class="ttl">Run it locally</div></a>
		<a href="/architecture" class="next"><div class="dir">Then →</div><div class="ttl">How swift-os boots</div></a>
	</div>
</main>

<Footer variant="mini" />
