<script lang="ts">
	import { gloss } from '$lib/glossary';
	import Badge from '$lib/components/Badge.svelte';
	import CodeBlock from '$lib/components/CodeBlock.svelte';
	import Callout from '$lib/components/Callout.svelte';
	import Tabs from '$lib/components/Tabs.svelte';
	import Accordion from '$lib/components/Accordion.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';

	const surfaces = [
		{ v: '--bg', t: 'page' },
		{ v: '--surface', t: 'cards' },
		{ v: '--surface-2', t: 'elevated / hover' },
		{ v: '--surface-3', t: 'chips / inputs' },
		{ v: '--text', t: 'high-emphasis' },
		{ v: '--text-muted', t: 'body' },
		{ v: '--text-dim', t: 'captions' },
		{ v: '--border-strong', t: 'hairlines' }
	];
	const accents = [
		{ v: '--orange-300', t: '#ff8e75' },
		{ v: '--orange-400', t: 'hover' },
		{ v: '--orange-500', t: '#f05138 · the accent', ring: true },
		{ v: '--orange-600', t: 'active' },
		{ v: '--orange-700', t: 'deep' }
	];
	const statuses = [
		{ v: '--ok', t: 'works / success' },
		{ v: '--warn', t: 'active / warning' },
		{ v: '--err', t: 'error' },
		{ v: '--info', t: 'note / info' }
	];

	const dsCode = `$ git clone https://github.com/asaptf/swift-os
$ cd swift-os && make run
# boots in QEMU · AArch64
[ ok ] httpd listening on :80`;

	const faqItems = [
		{ q: 'Is this a Linux clone?', a: 'No. swift-os removes legacy rather than emulating it. There is no Linux ABI and no Unix-compatibility layer.' },
		{ q: 'Why Swift for an OS?', a: 'Embedded Swift gives memory safety and modern ergonomics without a garbage collector or heavy runtime — a good fit for kernel and bare-metal code.' }
	];

	const dsTabs = [
		{ key: 'mac', label: 'macOS' },
		{ key: 'linux', label: 'Linux' },
		{ key: 'uefi', label: 'UEFI' }
	];
	const tabCopy: Record<string, string> = {
		mac: 'Apple Silicon is the primary profile — QEMU runs the AArch64 image natively.',
		linux: 'Linux hosts run the same image under qemu-system-aarch64.',
		uefi: 'Boot via a UEFI loader from a GPT-partitioned image.'
	};
</script>

<Seo
	title="Design system — swift-os"
	description="The swift-os design system: tokens, type scale, color, and components — dark default with a warm light theme."
/>

<main id="main" class="wrap" style="padding-block:var(--sp-8)">
	<header style="max-width:46rem;margin-bottom:var(--sp-8)">
		<span class="eyebrow">Design system</span>
		<h1 style="margin-top:1rem">The system behind the site.</h1>
		<p class="lead" style="margin-top:1rem">
			Apple-grade restraint with a terminal soul: a near-neutral base, one Swift-orange accent used sparingly, a
			humanist sans for prose and a refined mono for everything technical. Toggle the theme in the nav — every
			token below adapts.
		</p>
	</header>

	<!-- COLOR -->
	<section class="ds-sec">
		<h2 class="ds-h">Color</h2>
		<p class="muted ds-lead">Dark is the default. Light is a warm off-white companion. The accent is constant across both; status hues shift to keep WCAG AA contrast.</p>

		<h3 class="ds-sub">Surfaces & text</h3>
		<div class="swatch-grid">
			{#each surfaces as s (s.v)}
				<div class="sw"><span class="sw-chip" style="background:var({s.v})"></span><b>{s.v}</b><i>{s.t}</i></div>
			{/each}
		</div>

		<h3 class="ds-sub">Accent — Swift orange</h3>
		<div class="swatch-grid">
			{#each accents as a (a.v)}
				<div class="sw"><span class="sw-chip" style={`background:var(${a.v})${a.ring ? ';box-shadow:0 0 0 2px var(--accent-tint-strong)' : ''}`}></span><b>{a.v.replace('--', '')}</b><i>{a.t}</i></div>
			{/each}
		</div>

		<h3 class="ds-sub">Status</h3>
		<div class="swatch-grid">
			{#each statuses as s (s.v)}
				<div class="sw"><span class="sw-chip" style="background:var({s.v})"></span><b>{s.v}</b><i>{s.t}</i></div>
			{/each}
		</div>
	</section>

	<!-- TYPE -->
	<section class="ds-sec">
		<h2 class="ds-h">Typography</h2>
		<p class="muted ds-lead">Two families. <strong>Hanken Grotesk</strong> for UI and prose; <strong>JetBrains Mono</strong> for code, terminal output, command names, and micro-labels. Large headings track tight (-0.02em); body breathes at 1.65 line-height.</p>
		<div class="card card-pad-lg">
			<div class="type-row"><span class="type-meta mono">display · 700</span><span class="display" style="font-size:3rem">Boot. Isolate. Serve.</span></div>
			<div class="type-row"><span class="type-meta mono">h1 · 700</span><span class="h1">A real OS in Swift</span></div>
			<div class="type-row"><span class="type-meta mono">h2 · 700</span><span class="h2">What works today</span></div>
			<div class="type-row"><span class="type-meta mono">h3 · 600</span><span class="h3">Capability security</span></div>
			<div class="type-row"><span class="type-meta mono">lead · 400</span><span class="lead">A small trusted core, capability-based isolation, deterministic boot.</span></div>
			<div class="type-row"><span class="type-meta mono">body · 400</span><span>Authority is a token you hold, not a uid you are — no ambient root power, and every privileged action crosses one audited boundary.</span></div>
			<div class="type-row"><span class="type-meta mono">mono · 500</span><span class="mono">root@swift-os:~$ id</span></div>
			<div class="type-row"><span class="type-meta mono">micro-label</span><span class="eyebrow">Embedded Swift · aarch64</span></div>
		</div>
	</section>

	<!-- SPACING / RADIUS / ELEVATION -->
	<section class="ds-sec">
		<h2 class="ds-h">Spacing, radius & elevation</h2>
		<div class="ds-two">
			<div class="card">
				<h3 class="ds-sub" style="margin-top:0">Spacing — 4px grid</h3>
				<div class="spacer-demo"><span style="width:4px"></span><i>1 · 4</i></div>
				<div class="spacer-demo"><span style="width:8px"></span><i>2 · 8</i></div>
				<div class="spacer-demo"><span style="width:16px"></span><i>4 · 16</i></div>
				<div class="spacer-demo"><span style="width:32px"></span><i>6 · 32</i></div>
				<div class="spacer-demo"><span style="width:64px"></span><i>10 · 64</i></div>
			</div>
			<div class="card">
				<h3 class="ds-sub" style="margin-top:0">Radius</h3>
				<div class="radius-row">
					<div><span class="rad" style="border-radius:var(--r-xs)"></span><i class="mono">xs · 5</i></div>
					<div><span class="rad" style="border-radius:var(--r-sm)"></span><i class="mono">sm · 8</i></div>
					<div><span class="rad" style="border-radius:var(--r-md)"></span><i class="mono">md · 12</i></div>
					<div><span class="rad" style="border-radius:var(--r-lg)"></span><i class="mono">lg · 16</i></div>
				</div>
				<h3 class="ds-sub">Elevation</h3>
				<div class="radius-row">
					<div><span class="rad" style="box-shadow:var(--shadow-sm);background:var(--surface-2)"></span><i class="mono">sm</i></div>
					<div><span class="rad" style="box-shadow:var(--shadow-md);background:var(--surface-2)"></span><i class="mono">md</i></div>
					<div><span class="rad" style="box-shadow:var(--shadow-lg);background:var(--surface-2)"></span><i class="mono">lg</i></div>
				</div>
			</div>
		</div>
	</section>

	<!-- BUTTONS -->
	<section class="ds-sec">
		<h2 class="ds-h">Buttons</h2>
		<div class="card card-pad-lg" style="display:flex;flex-wrap:wrap;gap:var(--sp-3);align-items:center">
			<button class="btn btn-primary">Run locally</button>
			<button class="btn btn-secondary">Read the docs</button>
			<button class="btn btn-ghost">GitHub</button>
			<button class="btn btn-primary btn-lg">Large primary</button>
			<button class="btn btn-secondary" disabled style="opacity:.5;cursor:not-allowed">Disabled</button>
			<button class="icon-btn" aria-label="Settings"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="12" r="3" /><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.5-2.4 1a7 7 0 0 0-1.7-1l-.3-2.5h-4l-.3 2.5a7 7 0 0 0-1.7 1l-2.4-1-2 3.5 2 1.5a7 7 0 0 0 0 2l-2 1.5 2 3.5 2.4-1a7 7 0 0 0 1.7 1l.3 2.5h4l.3-2.5a7 7 0 0 0 1.7-1l2.4 1 2-3.5-2-1.5a7 7 0 0 0 .1-1z" /></svg></button>
		</div>
	</section>

	<!-- BADGES -->
	<section class="ds-sec">
		<h2 class="ds-h">Status chips & badges</h2>
		<div class="card card-pad-lg" style="display:flex;flex-wrap:wrap;gap:var(--sp-2);align-items:center">
			<Badge variant="ok" label="Works" />
			<Badge variant="accent" label="Primary" />
			<Badge variant="warn" label="Active hardening" />
			<Badge variant="info" label="Planned" />
			<Badge variant="muted" label="Non-goal" />
			<Badge variant="err" label="Blocked" />
			<span class="proof-pill"><span class="live"></span> Served by swift-os</span>
		</div>
	</section>

	<!-- CODE -->
	<section class="ds-sec">
		<h2 class="ds-h">Code block</h2>
		<p class="muted ds-lead">Filename chrome, syntax tokens, and a copy button that confirms on click. Code surfaces stay dark in both themes.</p>
		<CodeBlock title="Terminal — zsh" code={dsCode} />
	</section>

	<!-- CALLOUTS -->
	<section class="ds-sec">
		<h2 class="ds-h">Callouts</h2>
		<div class="stack">
			<Callout type="note" html="<strong>Note</strong>swift-os targets AArch64 only. There is no x86-64 port, and that is by design." />
			<Callout type="tip" html="<strong>Tip</strong>First login is <code>root</code> / <code>swordfish</code>. Change it before exposing anything." />
			<Callout type="warn" html="<strong>Warning</strong>Writes to <code>/tmp</code> are a tmpfs — they vanish on reboot. Persist deliberately." />
		</div>
	</section>

	<!-- TABS -->
	<section class="ds-sec">
		<h2 class="ds-h">Tabs</h2>
		<div class="card card-pad-lg">
			<Tabs tabs={dsTabs} ariaLabel="Host">
				{#snippet panel(key)}
					<p class="muted" style="font-size:var(--fs-sm)">{tabCopy[key]}</p>
				{/snippet}
			</Tabs>
		</div>
	</section>

	<!-- ACCORDION -->
	<section class="ds-sec">
		<h2 class="ds-h">Accordion</h2>
		<div class="card card-pad-lg"><Accordion items={faqItems} /></div>
	</section>

	<!-- SEARCH -->
	<section class="ds-sec">
		<h2 class="ds-h">Search field</h2>
		<div class="card card-pad-lg" style="max-width:30rem">
			<label class="search">
				<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="7" /><path d="M21 21l-4-4" /></svg>
				<input type="search" placeholder="Search the docs…" aria-label="Search" />
				<span class="k"><span class="kbd">⌘</span> <span class="kbd">K</span></span>
			</label>
		</div>
	</section>

	<!-- GLOSSARY -->
	<section class="ds-sec">
		<h2 class="ds-h">Glossary tooltip</h2>
		<div class="card card-pad-lg">
			<p>Hover or focus the dotted terms: the kernel runs at <span class="gloss" data-gloss="el1" use:gloss>EL1</span>, applications at <span class="gloss" data-gloss="el0" use:gloss>EL0</span>, and the <span class="gloss" data-gloss="mmu" use:gloss>MMU</span> keeps every process isolated. This is how jargon is explained inline, site-wide.</p>
		</div>
	</section>
</main>

<Footer variant="mini" />
