<script lang="ts">
	import { reveal } from '$lib/actions/reveal';
	import { countUp } from '$lib/actions/counter';
	import Badge from '$lib/components/Badge.svelte';
	import CodeBlock from '$lib/components/CodeBlock.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let { data } = $props();
	const status = $derived(data.status);

	const phases = [
		{ key: 'done', label: 'Done', variant: 'ok' as const, tick: '✓', color: 'var(--ok)' },
		{ key: 'active', label: 'Active', variant: 'warn' as const, tick: '◐', color: 'var(--warn)' },
		{ key: 'planned', label: 'Planned', variant: 'info' as const, tick: '○', color: 'var(--info)' }
	];
	const byPhase = (p: string) => status.roadmap.filter((r) => r.phase === p);
</script>

<Seo
	title="Status — what works today · swift-os"
	description="An honest, color-coded view of what swift-os does today: capability matrix, roadmap, non-goals, and the acceptance gates in make test."
/>

<main id="main" class="wrap" style="padding-block:var(--sp-8)">
	<header style="max-width:48rem;margin-bottom:var(--sp-8)" use:reveal>
		<span class="eyebrow">{status.eyebrow}</span>
		<h1 style="margin-top:1rem">{status.heading}</h1>
		<p class="lead" style="margin-top:1rem">{@html status.lead}</p>
		<div style="display:flex;flex-wrap:wrap;gap:var(--sp-4);margin-top:var(--sp-5);align-items:center">
			<span class="proof-pill"><span class="live"></span> {status.build}</span>
			<span class="mono dim" style="font-size:var(--fs-xs)">{status.updated}</span>
		</div>
	</header>

	<!-- Legend -->
	<div class="legend" use:reveal>
		<Badge variant="ok" label="Works" />
		<Badge variant="accent" label="Primary path" />
		<Badge variant="warn" label="Active hardening" />
		<Badge variant="muted" label="Non-goal" />
	</div>

	<!-- Capability matrix -->
	<section style="margin-top:var(--sp-6)" use:reveal>
		<div class="card" style="padding:0;overflow:hidden">
			<div style="overflow-x:auto">
				<table class="matrix">
					<thead>
						<tr><th style="min-width:200px">Capability</th><th>Status</th><th style="min-width:220px">Notes</th></tr>
					</thead>
					<tbody>
						{#each status.capabilities as c (c.name)}
							<tr>
								<td><div class="cap-name">{c.name}</div><div class="cap-note">{c.note}</div></td>
								<td><Badge variant={c.variant} label={c.status} /></td>
								<td class="dim" style="font-size:var(--fs-sm)">{c.detail}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		</div>
	</section>

	<!-- Roadmap -->
	<section id="roadmap" style="margin-top:var(--sp-10)">
		<div class="section-head" use:reveal>
			<span class="eyebrow">Roadmap</span>
			<h2 style="margin-top:.6rem">Done, in flight, and planned.</h2>
		</div>
		<div class="roadmap">
			{#each phases as p, i (p.key)}
				<div class="road-col" use:reveal={i * 80}>
					<h4><Badge variant={p.variant} label={p.label} /></h4>
					<ul class="road-list">
						{#each byPhase(p.key) as item (item.label)}
							<li class="road-item"><span class="tick" style="color:{p.color}">{p.tick}</span> {@html item.label}</li>
						{/each}
					</ul>
				</div>
			{/each}
		</div>
	</section>

	<!-- Non-goals / philosophy -->
	<section style="margin-top:var(--sp-10)">
		<div class="card card-pad-lg" use:reveal style="border-left:3px solid var(--accent)">
			<span class="eyebrow">Known limitations & non-goals</span>
			<h2 class="h3" style="margin-top:.8rem;margin-bottom:1rem">What we won't do is part of the design.</h2>
			<div class="nongoals">
				{#each status.nonGoals as g (g.title)}
					<div><h4>{g.title}</h4><p class="muted" style="font-size:var(--fs-sm)">{@html g.body}</p></div>
				{/each}
			</div>
		</div>
	</section>

	<!-- Test coverage -->
	<section style="margin-top:var(--sp-10)">
		<div class="section-head" use:reveal>
			<span class="eyebrow">Acceptance gates</span>
			<h2 style="margin-top:.6rem">Every claim above is a test.</h2>
			<p class="lead" style="margin-top:.8rem">These gates run on each commit in CI under QEMU. A red gate blocks the merge.</p>
		</div>
		<div class="coverage" use:reveal>
			{#each status.coverage as cov (cov.label)}
				<div class="cov-stat">
					<div class="cov-num" class:accent={cov.accent} use:countUp={{ to: cov.to, decimals: cov.decimals ?? 0, suffix: cov.suffix ?? '' }}>0</div>
					<div class="cov-label mono">{cov.label}</div>
				</div>
			{/each}
		</div>
		<div style="margin-top:var(--sp-5)">
			<CodeBlock title="make test · acceptance" code={status.testLog} copyable={true} />
		</div>
	</section>
</main>

<Footer variant="mini" />
