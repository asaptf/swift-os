<script lang="ts">
	import { reveal } from '$lib/actions/reveal';
	import Footer from '$lib/components/Footer.svelte';
	import Icon from '$lib/components/Icon.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let { data } = $props();
	const articles = $derived(data.articles);

	const fmtDate = (d?: string) =>
		d ? new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
</script>

<Seo
	title="Articles — swift-os"
	description="Deep dives on swift-os: why Swift for an OS, how it boots, and how it serves HTTP and AI."
/>

<main id="main" class="wrap" style="padding-block:var(--sp-8)">
	<header style="max-width:48rem;margin-bottom:var(--sp-8)" use:reveal>
		<span class="eyebrow">Articles</span>
		<h1 style="margin-top:1rem">Deep dives.</h1>
		<p class="lead" style="margin-top:1rem">Narrative long-form on the design and the experiment — the shareable hooks. Each is a standalone story.</p>
	</header>

	<div class="feature-grid">
		{#each articles as a, i (a.slug)}
			<a class="feature card-hover" href="/articles/{a.slug}" use:reveal={(i % 3) * 60} style="display:flex;flex-direction:column;gap:var(--sp-3)">
				<span class="eyebrow">{a.eyebrow}</span>
				<h3 style="margin:0">{a.title}</h3>
				<p style="flex:1">{a.excerpt}</p>
				<div class="article-meta">
					{#if a.publishedAt}<span>{fmtDate(a.publishedAt)}</span>{/if}
					{#if a.readingMinutes}<span>· {a.readingMinutes} min read</span>{/if}
					<span style="margin-left:auto;color:var(--accent)"><Icon name="arrow" size={15} /></span>
				</div>
			</a>
		{/each}
	</div>
</main>

<Footer variant="mini" />
