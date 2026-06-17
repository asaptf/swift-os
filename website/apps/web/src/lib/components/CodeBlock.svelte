<script lang="ts">
	import { terminalHTML } from '$lib/terminal';
	import Icon from './Icon.svelte';

	let {
		title = 'Terminal',
		code = '',
		copyable = true,
		titleIcon = false
	}: { title?: string; code?: string; copyable?: boolean; titleIcon?: boolean } = $props();

	const rendered = $derived(terminalHTML(code));
	let copied = $state(false);

	async function copy() {
		const text = code.replace(/ /g, ' ').trim();
		try {
			await navigator.clipboard.writeText(text);
		} catch {
			const ta = document.createElement('textarea');
			ta.value = text;
			document.body.appendChild(ta);
			ta.select();
			try {
				document.execCommand('copy');
			} catch {
				/* no-op */
			}
			document.body.removeChild(ta);
		}
		copied = true;
		setTimeout(() => (copied = false), 1400);
	}
</script>

<div class="win code-host">
	<div class="win-bar">
		<span class="win-dots"><i></i><i></i><i></i></span>
		<span class="win-title">
			{#if titleIcon}<Icon name="terminal" size={13} />{/if}
			{title}
		</span>
	</div>
	{#if copyable}
		<button class="copy-btn" class:copied onclick={copy}>
			<span>{copied ? 'Copied' : 'Copy'}</span>
		</button>
	{/if}
	<div class="win-body"><pre class="code-block">{@html rendered}</pre></div>
</div>
