<script lang="ts">
	import { reveal } from '$lib/actions/reveal';
	import Tabs from '$lib/components/Tabs.svelte';
	import Callout from '$lib/components/Callout.svelte';
	import CodeBlock from '$lib/components/CodeBlock.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let { data } = $props();
	const qs = $derived(data.quickstart);
	const tabs = $derived(qs.tracks.map((t) => ({ key: t.key, label: t.label, icon: t.icon })));
	const track = (key: string) => qs.tracks.find((t) => t.key === key);
</script>

<Seo
	title="Quickstart — run swift-os locally"
	description="Clone, cross-build the toolchain once, and make run. Boot swift-os in QEMU on Apple Silicon — first login root / swordfish. Or try it in your browser."
/>

<main id="main" class="wrap wrap-prose" style="padding-block:var(--sp-8);max-width:54rem">
	<header style="margin-bottom:var(--sp-6)" use:reveal>
		<span class="eyebrow">{qs.eyebrow}</span>
		<h1 style="margin-top:1rem">{qs.heading}</h1>
		<p class="lead" style="margin-top:1rem">{@html qs.leadHtml}</p>
	</header>

	<div use:reveal style="margin-bottom:var(--sp-6)">
		<Callout type="note" html={qs.needHtml} />
	</div>

	<div use:reveal>
		<Tabs tabs={tabs} ariaLabel="Choose your host">
			{#snippet panel(key)}
				{@const t = track(key)}
				{#if t}
					{#if t.steps}
						<div class="steps" style="margin-top:var(--sp-5)">
							{#each t.steps as step (step.title)}
								<div class="step">
									<div class="step-body">
										<h3>{step.title}</h3>
										{#if step.bodyHtml}<p class="muted">{@html step.bodyHtml}</p>{/if}
										{#if step.command}
											<CodeBlock title={step.commandTitle ?? 'Terminal'} code={step.command} />
										{/if}
										{#if step.expected}
											<p class="dim" style="font-size:var(--fs-sm)">Expected output:</p>
											<CodeBlock title={step.expectedTitle ?? 'qemu · swift-os'} code={step.expected} copyable={false} />
										{/if}
										{#if step.callout}
											<div style="margin-top:var(--sp-3)"><Callout type={step.callout.type} html={step.callout.html} /></div>
										{/if}
									</div>
								</div>
							{/each}
						</div>
						{#if t.footWarnHtml}
							<div style="margin-top:var(--sp-6)"><Callout type="warn" html={t.footWarnHtml} /></div>
						{/if}
					{:else}
						{#if t.calloutType}
							<div style="margin-top:var(--sp-5)"><Callout type={t.calloutType} html={t.noteHtml ?? ''} /></div>
						{:else if t.noteHtml}
							<p class="muted" style="margin-top:var(--sp-5)">{@html t.noteHtml}</p>
						{/if}
						{#if t.command}
							<div style="margin-top:var(--sp-4)">
								<CodeBlock title={t.commandTitle ?? 'Terminal'} code={t.command} />
							</div>
						{/if}
					{/if}
				{/if}
			{/snippet}
		</Tabs>
	</div>

	<div class="prevnext" use:reveal>
		<a href="/docs"><div class="dir">← Next</div><div class="ttl">Read the documentation</div></a>
		<a href="/architecture" class="next"><div class="dir">Then →</div><div class="ttl">Understand the architecture</div></a>
	</div>
</main>

<Footer variant="mini" />
