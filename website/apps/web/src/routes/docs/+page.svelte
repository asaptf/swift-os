<script lang="ts">
	import DocsSidebar from '$lib/components/DocsSidebar.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Callout from '$lib/components/Callout.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let { data } = $props();
	const nav = $derived(data.nav);
</script>

<Seo
	title="Documentation — swift-os"
	description="swift-os documentation, ingested straight from the repo: concepts, the kernel, userland, networking, the security model, packages, and AI hosting."
/>

<div class="wrap wrap-wide" style="padding-block:var(--sp-6)">
	<div class="docs-shell" style="grid-template-columns:260px minmax(0,1fr)">
		<DocsSidebar {nav} />

		<main id="main" class="prose" style="max-width:none">
			<div class="dim mono" style="font-size:var(--fs-xs)">Docs / Overview</div>
			<h1 style="margin-top:var(--sp-3)">Documentation</h1>
			<p class="lead">
				A reader over the project's docs, ingested straight from the repository — single source of truth. Pick a
				path on the left, or jump straight into a section below. No prior OS-internals knowledge assumed; jargon
				is explained inline.
			</p>

			{#if nav.length === 0}
				<Callout type="warn" html="<strong>No docs found</strong>The reader ingests Markdown from the repo's <code>docs/</code> directory. Set <code>DOCS_DIR</code> in the web app's environment if it lives elsewhere." />
			{:else}
				{#each nav as group (group.title)}
					<h2>{group.title}</h2>
					<div class="doc-card-grid">
						{#each group.items as item (item.slug)}
							<a class="feature card-hover" href="/docs/{item.slug}" style="display:block">
								<h3 style="font-size:var(--fs-body);margin:0">{item.title}</h3>
							</a>
						{/each}
					</div>
				{/each}
			{/if}
		</main>
	</div>
</div>

<Footer variant="mini" />
