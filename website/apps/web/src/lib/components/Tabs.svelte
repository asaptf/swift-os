<script lang="ts">
	import type { Snippet } from 'svelte';
	import Icon from './Icon.svelte';

	interface Tab {
		key: string;
		label: string;
		icon?: string | null;
	}
	let {
		tabs,
		ariaLabel = 'Tabs',
		panel
	}: { tabs: Tab[]; ariaLabel?: string; panel: Snippet<[string]> } = $props();

	let selected = $state(tabs[0]?.key);
	let buttons: HTMLButtonElement[] = $state([]);

	function onKey(e: KeyboardEvent, i: number) {
		let n = -1;
		if (e.key === 'ArrowRight') n = (i + 1) % tabs.length;
		if (e.key === 'ArrowLeft') n = (i - 1 + tabs.length) % tabs.length;
		if (n >= 0) {
			e.preventDefault();
			selected = tabs[n].key;
			buttons[n]?.focus();
		}
	}
</script>

<div class="tabs">
	<div class="tablist" role="tablist" aria-label={ariaLabel}>
		{#each tabs as t, i (t.key)}
			<button
				class="tab"
				role="tab"
				id="tab-{t.key}"
				aria-controls="panel-{t.key}"
				aria-selected={selected === t.key}
				tabindex={selected === t.key ? 0 : -1}
				bind:this={buttons[i]}
				onclick={() => (selected = t.key)}
				onkeydown={(e) => onKey(e, i)}
			>
				{#if t.icon}<Icon name={t.icon} size={15} />{/if}
				{t.label}
			</button>
		{/each}
	</div>
	<div class="tabpanel" role="tabpanel" id="panel-{selected}" aria-labelledby="tab-{selected}">
		{@render panel(selected)}
	</div>
</div>
