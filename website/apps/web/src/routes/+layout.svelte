<script lang="ts">
	import '$lib/styles/tokens.css';
	import '$lib/styles/components.css';
	import '$lib/styles/site-chrome.css';
	import '$lib/styles/pages.css';
	import '$lib/styles/highlight.css';

	import { setGlossaryTerms } from '$lib/glossary';
	import Nav from '$lib/components/Nav.svelte';
	import favicon from '$lib/assets/favicon.svg';

	let { children, data } = $props();

	// Keep the shared glossary tooltip terms in sync with CMS-loaded data.
	$effect(() => {
		if (data?.glossary) setGlossaryTerms(data.glossary);
	});
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<a
	href="#main"
	class="btn btn-secondary"
	style="position:absolute;left:-999px;top:8px;z-index:1500;"
	onfocus={(e) => (e.currentTarget.style.left = '8px')}
	onblur={(e) => (e.currentTarget.style.left = '-999px')}>Skip to content</a
>

<Nav />

{@render children()}
