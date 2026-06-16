<script lang="ts">
	import { reveal } from '$lib/actions/reveal';
	import Accordion from '$lib/components/Accordion.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';
	import type { Faq } from '$lib/content/types';

	let { data } = $props();
	const faqs = $derived(data.faqs as Faq[]);

	const groups = $derived.by(() => {
		const map = new Map<string, { q: string; a: string }[]>();
		for (const f of faqs) {
			const cat = f.category ?? 'General';
			if (!map.has(cat)) map.set(cat, []);
			map.get(cat)!.push({ q: f.question, a: f.answerHtml });
		}
		return [...map.entries()].map(([title, items]) => ({ title, items }));
	});
</script>

<Seo
	title="FAQ — swift-os"
	description="Common questions about swift-os: what it is, why Swift, how to run it, what persists, multi-core, and Node.js/JVM hosting."
/>

<main id="main" class="wrap wrap-prose" style="padding-block:var(--sp-8);max-width:52rem">
	<header style="margin-bottom:var(--sp-6)" use:reveal>
		<span class="eyebrow">FAQ</span>
		<h1 style="margin-top:1rem">Common questions.</h1>
		<p class="lead" style="margin-top:1rem">Short, honest answers. For the full picture of what works today, see the <a class="prose" style="color:var(--accent)" href="/status">status page</a>.</p>
	</header>

	{#each groups as group, i (group.title)}
		<section use:reveal style="margin-top:var(--sp-6)">
			<h2 class="h3" style="margin-bottom:var(--sp-2)">{group.title}</h2>
			<div class="card card-pad-lg">
				<Accordion items={group.items} openFirst={i === 0} />
			</div>
		</section>
	{/each}
</main>

<Footer variant="mini" />
