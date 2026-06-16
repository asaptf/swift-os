<script lang="ts">
	import Icon from './Icon.svelte';
	import type { DocSection } from '$lib/server/docs';

	let { nav, current = '' }: { nav: DocSection[]; current?: string } = $props();
</script>

<aside class="docs-sidebar" aria-label="Documentation navigation">
	<label class="search" style="margin-bottom:var(--sp-5)">
		<Icon name="search" size={16} />
		<input type="search" placeholder="Search docs…" aria-label="Search documentation" />
		<span class="k"><span class="kbd">⌘</span><span class="kbd">K</span></span>
	</label>

	<div class="path-hub">
		<div class="grp-title" style="padding-left:0">Choose your path</div>
		<a class="path-card" href="/docs/concepts"><b>Newcomer</b><span>Start with concepts</span></a>
		<a class="path-card" href="/docs/architecture"><b>Kernel hacker</b><span>EL1 internals</span></a>
		<a class="path-card" href="/docs/ai-hosting-guide"><b>App developer</b><span>Host & serve</span></a>
	</div>

	{#each nav as group (group.title)}
		<div class="docs-nav-group">
			<div class="grp-title">{group.title}</div>
			{#each group.items as item (item.slug)}
				<a href="/docs/{item.slug}" aria-current={current === item.slug ? 'page' : undefined}>{item.title}</a>
			{/each}
		</div>
	{/each}
</aside>
