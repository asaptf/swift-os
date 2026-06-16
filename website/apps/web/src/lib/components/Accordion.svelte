<script lang="ts">
	interface Item {
		q: string;
		a: string; // html
	}
	let { items, openFirst = true }: { items: Item[]; openFirst?: boolean } = $props();
	let openIndex = $state(openFirst ? 0 : -1);
</script>

<div class="acc">
	{#each items as item, i (i)}
		<div class="acc-item" data-open={openIndex === i}>
			<button class="acc-head" aria-expanded={openIndex === i} onclick={() => (openIndex = openIndex === i ? -1 : i)}>
				{item.q}
				<svg class="chev" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6" /></svg>
			</button>
			<div class="acc-body"><div><div class="acc-inner">{@html item.a}</div></div></div>
		</div>
	{/each}
</div>
