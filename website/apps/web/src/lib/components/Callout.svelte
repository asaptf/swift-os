<script lang="ts">
	import Icon from './Icon.svelte';
	import type { Snippet } from 'svelte';

	let {
		type = 'note',
		html,
		children
	}: { type?: 'note' | 'tip' | 'warn'; html?: string; children?: Snippet } = $props();

	const iconName = $derived(type === 'tip' ? 'tip' : type === 'warn' ? 'warn' : 'note');
</script>

<div class="callout callout-{type}">
	<Icon name={iconName} size={20} />
	<div class="co-body">
		{#if html}{@html html}{:else if children}{@render children()}{/if}
	</div>
</div>
