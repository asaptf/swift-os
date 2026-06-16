<script lang="ts">
	import { reveal } from '$lib/actions/reveal';
	import { countUp, uptime } from '$lib/actions/counter';
	import { gloss } from '$lib/glossary';
	import Icon from '$lib/components/Icon.svelte';
	import Terminal from '$lib/components/Terminal.svelte';
	import CodeBlock from '$lib/components/CodeBlock.svelte';
	import Badge from '$lib/components/Badge.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let { data } = $props();
	const home = $derived(data.home);
	const liveProof = $derived(data.liveProof);

	const description =
		'swift-os is an experimental but real operating system written entirely in Embedded Swift for aarch64. It boots, runs a native Swift userland and an in-kernel TCP/IP stack, serves HTTP, and runs a native Swift AI inference server — try it in your browser.';
	const jsonLd = {
		'@context': 'https://schema.org',
		'@type': 'SoftwareApplication',
		name: 'swift-os',
		applicationCategory: 'OperatingSystem',
		operatingSystem: 'AArch64 (QEMU virt)',
		description,
		programmingLanguage: 'Swift',
		license: 'https://www.apache.org/licenses/LICENSE-2.0',
		codeRepository: 'https://github.com/asaptf/swift-os',
		offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' }
	};
</script>

<Seo title="swift-os — a real operating system, written in Swift" {description} {jsonLd} />

<main id="main">
	<!-- HERO -->
	<section class="hero">
		<div class="hero-grid-bg"></div>
		<div class="wrap wrap-wide hero-inner">
			<div class="hero-head">
				<span class="eyebrow">{home.eyebrow}</span>
				<h1 class="display" style="margin-top:1.2rem">{@html home.titleHtml}</h1>
				<p class="lead hero-sub">{@html home.leadHtml}</p>
				<div class="hero-ctas">
					<a class="btn btn-primary btn-lg" href="/quickstart"><Icon name="play" size={20} /> Run locally</a>
					<a class="btn btn-secondary btn-lg" href="/docs">Read the docs</a>
					<a class="btn btn-ghost btn-lg" href="https://github.com/asaptf/swift-os" target="_blank" rel="noopener">
						<Icon name="github" size={20} /> GitHub
					</a>
					<a class="hero-soon" href="/try" style="text-decoration:none"><Icon name="clock" size={13} /> Try in your browser <span class="badge badge-accent" style="margin-left:.1rem">beta</span></a>
				</div>
			</div>

			<div use:reveal={120}>
				<Terminal />
			</div>
		</div>
	</section>

	<!-- LIVE PROOF -->
	<section class="section-sm">
		<div class="wrap wrap-wide">
			<div class="card card-pad-lg" use:reveal>
				<div class="proof">
					<div>
						<span class="proof-pill"><span class="live"></span> Real HTTP + AI inference</span>
						<h2 class="h3" style="margin-top:1rem">{liveProof.heading}</h2>
						<p class="muted" style="margin-top:.6rem;font-size:var(--fs-sm)">{@html liveProof.body}</p>
						<div style="margin-top:1.25rem">
							<CodeBlock title="boot.log — tail" code={liveProof.bootLog} copyable={true} />
						</div>
						<a class="nav-link" href="/articles/serving-http-and-ai-from-swiftos" style="margin-top:1rem;display:inline-flex;align-items:center;gap:.4em;color:var(--accent);padding-left:0">
							How it serves HTTP &amp; AI <Icon name="arrow" size={15} />
						</a>
					</div>
					<div class="proof-stats">
						{#each liveProof.stats as s (s.label)}
							<div class="proof-stat">
								<div class="label">{s.label}</div>
								{#if s.uptimeSeconds != null}
									<div class="value accent" use:uptime={s.uptimeSeconds}>{s.value}</div>
								{:else if s.countTo != null}
									<div class="value" use:countUp={{ to: s.countTo, suffix: s.suffix ?? '' }}>0</div>
								{:else}
									<div
										class="value"
										class:accent={s.accent}
										style={s.value.includes('<br') ? 'font-size:1.05rem;line-height:1.4' : ''}
									>
										{@html s.value}
									</div>
								{/if}
								<div class="sub mono">{s.sub}</div>
							</div>
						{/each}
					</div>
				</div>
			</div>
		</div>
	</section>

	<!-- FEATURES -->
	<section class="section">
		<div class="wrap wrap-wide">
			<div class="section-head" use:reveal>
				<span class="eyebrow">{home.featuresEyebrow}</span>
				<h2>{home.featuresHeading}</h2>
				<p class="lead">{home.featuresLead}</p>
			</div>
			<div class="feature-grid">
				{#each home.features as f, i (f.title)}
					<div class="feature" use:reveal={(i % 3) * 60}>
						<div class="f-ico"><Icon name={f.icon} size={22} /></div>
						<h3>{f.title}</h3>
						<p>{@html f.bodyHtml}</p>
					</div>
				{/each}
			</div>
		</div>
	</section>

	<!-- ARCHITECTURE PREVIEW -->
	<section class="section-sm">
		<div class="wrap wrap-wide">
			<div class="card card-pad-lg arch-preview-card" use:reveal>
				<div>
					<span class="eyebrow">Architecture</span>
					<h2 class="h2" style="margin-top:.8rem">A clear line between userland and kernel.</h2>
					<p class="muted" style="margin-top:1rem">
						Swift tools run unprivileged at <span class="gloss" data-gloss="el0" use:gloss>EL0</span>. Every
						privileged action crosses a single, audited
						<span class="gloss" data-gloss="syscall" use:gloss>syscall</span> boundary into the kernel at
						<span class="gloss" data-gloss="el1" use:gloss>EL1</span>, which owns the
						<span class="gloss" data-gloss="mmu" use:gloss>MMU</span>, scheduler, network stack, and drivers.
					</p>
					<a class="btn btn-secondary" href="/architecture" style="margin-top:1.5rem">See all diagrams <Icon name="arrow" size={16} /></a>
				</div>
				<div class="archmini">
					<div class="archmini-band el0">
						<span class="archmini-tag">EL0 · userland</span>
						<div class="archmini-chips">
							<span class="archmini-chip">shell</span><span class="archmini-chip">httpd</span><span class="archmini-chip">llmd</span><span class="archmini-chip">id</span>
						</div>
					</div>
					<div class="archmini-sep"><span>syscall boundary</span></div>
					<div class="archmini-band el1">
						<span class="archmini-tag">EL1 · kernel</span>
						<div class="archmini-chips">
							<span class="archmini-chip">scheduler</span><span class="archmini-chip">MMU</span><span class="archmini-chip">TCP/IP</span><span class="archmini-chip">virtio</span>
						</div>
					</div>
				</div>
			</div>
		</div>
	</section>

	<!-- WORKS TODAY TEASER -->
	<section class="section">
		<div class="wrap wrap-wide">
			<div class="section-head center" use:reveal>
				<span class="eyebrow" style="justify-content:center">{home.worksEyebrow}</span>
				<h2>{home.worksHeading}</h2>
				<p class="lead">{home.worksLead}</p>
			</div>
			<div use:reveal style="display:flex;flex-wrap:wrap;gap:var(--sp-2);justify-content:center;max-width:60rem;margin-inline:auto">
				{#each home.worksBadges as b (b.label)}
					<Badge variant={b.variant} label={b.label} />
				{/each}
			</div>
			<div class="center" style="margin-top:var(--sp-6)" use:reveal>
				<a class="btn btn-primary" href="/status">See the full status & roadmap <Icon name="arrow" size={16} /></a>
			</div>
		</div>
	</section>

	<!-- START LEARNING -->
	<section class="section-sm" style="border-top:1px solid var(--border)">
		<div class="wrap wrap-wide">
			<div class="section-head" use:reveal>
				<span class="eyebrow">{home.startEyebrow}</span>
				<h2 class="h3" style="margin-top:.6rem">{home.startHeading}</h2>
			</div>
			<div class="feature-grid">
				{#each home.startCards as c, i (c.title)}
					<a class="feature card-hover" href={c.href} use:reveal={(i % 3) * 60}>
						<h3>{c.title}</h3>
						<p>{@html c.bodyHtml}</p>
					</a>
				{/each}
			</div>
		</div>
	</section>
</main>

<Footer variant="full" hostedNote={liveProof.hostedNote} />
