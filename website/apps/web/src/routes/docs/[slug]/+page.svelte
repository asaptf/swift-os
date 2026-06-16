<script lang="ts">
	import DocsSidebar from '$lib/components/DocsSidebar.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Icon from '$lib/components/Icon.svelte';
	import Seo from '$lib/components/Seo.svelte';
	import { scrollspy } from '$lib/actions/scrollspy';

	let { data } = $props();
	const nav = $derived(data.nav);
	const doc = $derived(data.doc);
</script>

<Seo title={`${doc.title} — swift-os docs`} description={`swift-os documentation: ${doc.title} (${doc.section}).`} />

<div class="wrap wrap-wide" style="padding-block:var(--sp-6)">
	{#key doc.slug}
		<div class="docs-shell">
			<DocsSidebar {nav} current={doc.slug} />

			<main id="main" class="prose" style="max-width:none">
				<div class="dim mono" style="font-size:var(--fs-xs);display:flex;gap:.5rem;align-items:center">
					Docs <span>/</span> {doc.section} <span>/</span> <span style="color:var(--text-muted)">{doc.title}</span>
				</div>

				{@html doc.html}

				<div class="prevnext">
					{#if doc.prev}
						<a href="/docs/{doc.prev.slug}"><div class="dir">← Back</div><div class="ttl">{doc.prev.title}</div></a>
					{:else}
						<span></span>
					{/if}
					{#if doc.next}
						<a href="/docs/{doc.next.slug}" class="next"><div class="dir">Next →</div><div class="ttl">{doc.next.title}</div></a>
					{/if}
				</div>

				<p class="dim" style="font-size:var(--fs-xs);margin-top:var(--sp-5);display:flex;align-items:center;gap:.4rem">
					<Icon name="github" size={13} />
					<a href={doc.githubUrl} target="_blank" rel="noopener">Edit this page on GitHub</a>
				</p>
			</main>

			{#if doc.toc.length}
				<aside class="docs-toc" use:scrollspy aria-label="On this page">
					<div class="toc-title">On this page</div>
					{#each doc.toc as t (t.id)}
						<a href="#{t.id}" style={t.depth === 3 ? 'padding-left:calc(var(--sp-3) + 10px)' : ''}>{t.text}</a>
					{/each}
				</aside>
			{/if}
		</div>
	{/key}
</div>

<Footer variant="mini" />
