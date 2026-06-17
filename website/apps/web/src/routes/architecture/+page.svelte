<script lang="ts">
	import { onMount } from 'svelte';
	import { reveal } from '$lib/actions/reveal';
	import { gloss } from '$lib/glossary';
	import Badge from '$lib/components/Badge.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let netFig: HTMLDivElement;

	function runPacket() {
		if (!netFig) return;
		if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
		netFig.classList.remove('run');
		void netFig.offsetWidth; // reflow to restart the animation
		netFig.classList.add('run');
	}

	onMount(() => {
		if (!netFig) return;
		if ('IntersectionObserver' in window) {
			const io = new IntersectionObserver(
				(e) => {
					if (e[0].isIntersecting) {
						runPacket();
						io.disconnect();
					}
				},
				{ threshold: 0.4 }
			);
			io.observe(netFig);
			return () => io.disconnect();
		}
		runPacket();
	});
</script>

<Seo
	title="Architecture — swift-os"
	description="Vector diagrams of how swift-os works: boot flow, the EL0/EL1 privilege stack, the three-tier storage model, networking, the capability security model, and the package system."
/>

<main id="main" class="wrap wrap-wide" style="padding-block:var(--sp-8)">
	<header style="max-width:48rem;margin-bottom:var(--sp-8)" use:reveal>
		<span class="eyebrow">Architecture</span>
		<h1 style="margin-top:1rem">How swift-os is put together.</h1>
		<p class="lead" style="margin-top:1rem">
			Six diagrams, from power-on to package install. Each is legible at a glance and reads the same in light or
			dark. Hover the <span class="gloss" data-gloss="capability" use:gloss>dotted</span> terms for a plain-language definition.
		</p>
	</header>

	<!-- 1. BOOT FLOW -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">01</span><div><h2 class="fig-title">Boot flow</h2><p class="fig-sub">From QEMU firmware to a Swift login prompt — deterministic, signed, under a second.</p></div></div>
		<figure class="fig" aria-label="Boot flow: QEMU firmware to UEFI loader to kernel to init to login">
			<div class="flow">
				<div class="flow-node"><span class="fn-ico">⚡</span><b>Firmware</b><i>QEMU virt</i></div>
				<span class="flow-arrow" aria-hidden="true"></span>
				<div class="flow-node"><span class="fn-ico">▣</span><b>UEFI loader</b><i>BOOTAA64.EFI</i></div>
				<span class="flow-arrow" aria-hidden="true"></span>
				<div class="flow-node accent"><span class="fn-ico">◆</span><b>Kernel</b><i>verify · MMU on</i></div>
				<span class="flow-arrow" aria-hidden="true"></span>
				<div class="flow-node"><span class="fn-ico">⊞</span><b>init</b><i>mount · net up</i></div>
				<span class="flow-arrow" aria-hidden="true"></span>
				<div class="flow-node"><span class="fn-ico">›_</span><b>login</b><i>EL0 shell</i></div>
			</div>
			<figcaption class="fig-cap">The image signature is checked before the kernel runs; a failed check halts the boot rather than continuing.</figcaption>
		</figure>
	</section>

	<!-- 2. EL0/EL1 STACK -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">02</span><div><h2 class="fig-title">The privilege stack</h2><p class="fig-sub">Userland Swift tools at <span class="gloss" data-gloss="el0" use:gloss>EL0</span>; the kernel at <span class="gloss" data-gloss="el1" use:gloss>EL1</span>. One audited line between them.</p></div></div>
		<figure class="fig" aria-label="EL0 userland over a syscall boundary over the EL1 kernel">
			<div class="stack-fig">
				<div class="stack-band band-el0">
					<span class="band-label">EL0 · userland · unprivileged</span>
					<div class="band-row">
						<span class="block">shell</span><span class="block">httpd</span><span class="block">llmd</span><span class="block">id</span><span class="block">pkg</span>
					</div>
				</div>
				<div class="priv-line"><span>syscall boundary — the only way in</span></div>
				<div class="stack-band band-el1">
					<span class="band-label accent">EL1 · kernel · privileged</span>
					<div class="band-row">
						<span class="block solid">scheduler</span><span class="block solid">MMU / VM</span><span class="block solid">TCP/IP</span><span class="block solid">virtio drivers</span><span class="block solid">capabilities</span>
					</div>
				</div>
				<div class="hw-band">hardware · aarch64 · cortex-a72</div>
			</div>
			<figcaption class="fig-cap">Code at EL0 cannot touch hardware or another process's memory. It must ask the kernel, which decides.</figcaption>
		</figure>
	</section>

	<!-- 3. THREE-TIER STORAGE -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">03</span><div><h2 class="fig-title">Three-tier storage</h2><p class="fig-sub">A signed read-only base, a volatile RAM scratch tier, and a persistent <code>/data</code> disk that survives reboot.</p></div></div>
		<figure class="fig" aria-label="Read-only signed base image, a volatile tmpfs at /tmp, and a persistent datafs at /data">
			<div class="fs-fig">
				<div class="fs-tier ro">
					<div class="fs-tier-head"><Badge variant="ok" label="read-only · signed" /></div>
					<b class="mono">base.img</b>
					<ul class="fs-list"><li>/bin · /lib · /etc</li><li>kernel + userland</li><li>cryptographically verified</li></ul>
				</div>
				<div class="fs-union" aria-hidden="true"><span>union mount</span></div>
				<div class="fs-tier rw">
					<div class="fs-tier-head"><Badge variant="warn" label="writable · volatile" /></div>
					<b class="mono">/tmp <span class="dim">(tmpfs)</span></b>
					<ul class="fs-list"><li>logs · caches · scratch</li><li>lives in RAM</li><li class="vanish">↻ vanishes on reboot</li></ul>
				</div>
				<div class="fs-union" aria-hidden="true"><span>data disk</span></div>
				<div class="fs-tier rw">
					<div class="fs-tier-head"><Badge variant="ok" label="writable · persistent" /></div>
					<b class="mono">/data <span class="dim">(datafs)</span></b>
					<ul class="fs-list"><li>databases · app state</li><li>on a virtio-blk disk</li><li>✓ survives reboot · fsync</li></ul>
				</div>
			</div>
			<figcaption class="fig-cap">Every boot starts from the same known-good image. <code>/tmp</code> is scratch that vanishes on reboot; anything you write to <code>/data</code> persists — SQLite there is crash-safe via <code>fsync</code>.</figcaption>
		</figure>
	</section>

	<!-- 4. NETWORKING -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">04</span><div><h2 class="fig-title">Networking path</h2><p class="fig-sub">A packet's journey: the wire to the HTTP handler, entirely inside swift-os.</p></div></div>
		<figure class="fig" aria-label="virtio-net to in-kernel TCP/IP stack to bin httpd">
			<div class="net-fig" bind:this={netFig}>
				<div class="net-track" aria-hidden="true"><span class="packet"></span></div>
				<div class="net-node"><span class="nn-tag mono">NIC</span><b>virtio-net</b><i>frames in/out</i></div>
				<span class="net-arrow" aria-hidden="true"></span>
				<div class="net-node accent"><span class="nn-tag mono">EL1</span><b>TCP/IP stack</b><i>IPv4 · TCP · DHCP</i></div>
				<span class="net-arrow" aria-hidden="true"></span>
				<div class="net-node"><span class="nn-tag mono">EL0</span><b>/bin/httpd</b><i>routes · responds</i></div>
			</div>
			<figcaption class="fig-cap">The stack lives in the kernel; <code>httpd</code> runs unprivileged and only holds a <code>net:bind</code> capability. <button class="btn btn-ghost" style="padding:.2rem .5rem;font-size:var(--fs-xs)" onclick={runPacket}>Replay packet ▸</button></figcaption>
		</figure>
	</section>

	<!-- 5. SECURITY MODEL -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">05</span><div><h2 class="fig-title">Capability security</h2><p class="fig-sub">Authority is a token you hold — not a uid you are.</p></div></div>
		<figure class="fig" aria-label="Principal holds a capability mask which grants handle rights">
			<div class="sec-fig">
				<div class="sec-node"><span class="sec-tag mono">who</span><b>Principal</b><i>e.g. httpd process</i></div>
				<span class="sec-arrow" aria-hidden="true">holds ▸</span>
				<div class="sec-node accent"><span class="sec-tag mono">what</span><b>Capability mask</b>
					<div class="cap-chips"><span>net:bind</span><span>fs:read</span><span class="off">fs:write</span><span class="off">proc:spawn</span></div>
				</div>
				<span class="sec-arrow" aria-hidden="true">grants ▸</span>
				<div class="sec-node"><span class="sec-tag mono">on</span><b>Handle rights</b><i>bind :80 · read /www</i></div>
			</div>
			<figcaption class="fig-cap">Greyed rights are <em>not</em> held — so even a compromised <code>httpd</code> cannot write the disk or spawn processes. There is no <code>uid==0</code> shortcut.</figcaption>
		</figure>
	</section>

	<!-- 6. PACKAGE SYSTEM -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">06</span><div><h2 class="fig-title">Package system</h2><p class="fig-sub">Signed artifacts from a static repository into a verified store.</p></div></div>
		<figure class="fig" aria-label="swpkg artifact from signed static repository into the package store">
			<div class="flow">
				<div class="flow-node"><span class="fn-ico mono">{'{ }'}</span><b>.swpkg</b><i>signed artifact</i></div>
				<span class="flow-arrow" aria-hidden="true"></span>
				<div class="flow-node"><span class="fn-ico">▤</span><b>static repo</b><i>immutable · signed index</i></div>
				<span class="flow-arrow" aria-hidden="true"></span>
				<div class="flow-node accent"><span class="fn-ico">✓</span><b>verify</b><i>signature + hash</i></div>
				<span class="flow-arrow" aria-hidden="true"></span>
				<div class="flow-node"><span class="fn-ico">⊟</span><b>package store</b><i>content-addressed</i></div>
			</div>
			<figcaption class="fig-cap">Installs are reproducible: the same package name + version always resolves to the same verified bytes.</figcaption>
		</figure>
	</section>

	<div class="prevnext" use:reveal>
		<a href="/docs"><div class="dir">← Read</div><div class="ttl">Concepts & documentation</div></a>
		<a href="/status" class="next"><div class="dir">Check →</div><div class="ttl">What works today</div></a>
	</div>
</main>

<Footer variant="mini" />
