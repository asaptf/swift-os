<script lang="ts">
	let { label = 'swift-os home' }: { label?: string } = $props();
</script>

<a href="/" class="brand" aria-label={label}>
	<svg class="mark" viewBox="0 0 28 28" fill="none" aria-hidden="true">
		<rect width="28" height="28" rx="7" fill="#F05138" />
		<path d="M7 9.5l4 4.5-4 4.5" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" />
		<rect x="13.5" y="17.1" width="7.6" height="2.1" rx="1.05" fill="#fff" />
	</svg>
	<span class="word">swift<b>-</b>os</span>
</a>
