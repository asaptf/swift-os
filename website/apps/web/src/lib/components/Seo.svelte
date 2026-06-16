<script lang="ts">
	import { page } from '$app/state';
	import { env } from '$env/dynamic/public';

	/* Per-page SEO: title, description, canonical, Open Graph + Twitter card, and
	 * optional JSON-LD structured data (rich, crawlable signal for search and AI
	 * crawlers). Absolute URLs use PUBLIC_SITE_URL when set (needed for the
	 * prerendered static build); otherwise they derive from the request URL. */
	const siteBase = (env.PUBLIC_SITE_URL || '').replace(/\/$/, '');
	let {
		title,
		description,
		type = 'website',
		jsonLd = null,
		noindex = false
	}: {
		title: string;
		description: string;
		type?: 'website' | 'article';
		jsonLd?: unknown;
		noindex?: boolean;
	} = $props();

	const url = $derived((siteBase || page.url.origin) + page.url.pathname);
</script>

<svelte:head>
	<title>{title}</title>
	<meta name="description" content={description} />
	<link rel="canonical" href={url} />

	<meta property="og:type" content={type} />
	<meta property="og:title" content={title} />
	<meta property="og:description" content={description} />
	<meta property="og:url" content={url} />
	<meta property="og:site_name" content="swift-os" />

	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content={title} />
	<meta name="twitter:description" content={description} />

	{#if noindex}<meta name="robots" content="noindex, nofollow" />{/if}
	{#if jsonLd}
		{@html '<script type="application/ld+json">' + JSON.stringify(jsonLd) + '<' + '/script>'}
	{/if}
</svelte:head>
