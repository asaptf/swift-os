<script lang="ts">
	import type { StatusVariant } from '$lib/content/types';
	let { variant = 'ok', label, dot = true }: { variant?: StatusVariant; label: string; dot?: boolean } = $props();
</script>

<span class="badge badge-{variant}">
	{#if dot}<span class="dot"></span>{/if}
	{label}
</span>
