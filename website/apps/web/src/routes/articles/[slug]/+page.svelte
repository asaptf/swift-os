<script lang="ts">
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let { data } = $props();
	const a = $derived(data.article);

	const jsonLd = $derived({
		'@context': 'https://schema.org',
		'@type': 'TechArticle',
		headline: a.title,
		description: a.excerpt,
		...(a.publishedAt ? { datePublished: a.publishedAt } : {}),
		author: { '@type': 'Organization', name: 'swift-os' },
		about: 'swift-os — an operating system in Embedded Swift'
	});

	const fmtDate = (d?: string) =>
		d ? new Date(d).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
</script>

<Seo title={`${a.title} — swift-os`} description={a.excerpt} type="article" {jsonLd} />

<main id="main" class="wrap wrap-prose" style="padding-block:var(--sp-8)">
	<header style="margin-bottom:var(--sp-6)">
		<span class="eyebrow">{a.eyebrow}</span>
		<h1 class="h1" style="margin-top:1rem">{a.title}</h1>
		<p class="lead" style="margin-top:1rem">{a.excerpt}</p>
		<div class="article-meta" style="margin-top:var(--sp-4)">
			{#if a.publishedAt}<span>{fmtDate(a.publishedAt)}</span>{/if}
			{#if a.readingMinutes}<span>· {a.readingMinutes} min read</span>{/if}
		</div>
	</header>

	<hr class="divider" style="margin-block:var(--sp-6)" />

	<article class="prose">{@html a.bodyHtml}</article>

	<div class="prevnext">
		<a href="/articles"><div class="dir">← All</div><div class="ttl">Articles</div></a>
		<a href="/docs" class="next"><div class="dir">Next →</div><div class="ttl">Documentation</div></a>
	</div>
</main>

<Footer variant="mini" />
