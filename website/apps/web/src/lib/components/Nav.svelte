<script lang="ts">
	import { page } from '$app/state';
	import { toggleTheme } from '$lib/theme';
	import Brand from './Brand.svelte';
	import Icon from './Icon.svelte';

	const links = [
		{ href: '/status', label: 'Status' },
		{ href: '/quickstart', label: 'Quickstart' },
		{ href: '/docs', label: 'Docs' },
		{ href: '/architecture', label: 'Architecture' },
		{ href: '/swiftcube', label: 'SwiftCube' },
		{ href: '/design', label: 'Design' }
	];

	let open = $state(false);
	const current = (href: string) =>
		page.url.pathname === href || (href !== '/' && page.url.pathname.startsWith(href + '/'));
</script>

<svelte:window onkeydown={(e) => { if (e.key === 'Escape') open = false; }} />

<header class="nav">
	<div class="nav-inner">
		<Brand />
		<nav class="nav-links" aria-label="Primary">
			{#each links as l (l.href)}
				<a class="nav-link" href={l.href} aria-current={current(l.href) ? 'page' : undefined}>{l.label}</a>
			{/each}
		</nav>
		<div class="nav-right">
			<button class="icon-btn" data-theme-toggle aria-label="Switch theme" onclick={toggleTheme}>
				<Icon name="sun" size={19} />
			</button>
			<a class="icon-btn" href="https://github.com/asaptf/swift-os" aria-label="GitHub repository" target="_blank" rel="noopener">
				<Icon name="github" size={19} />
			</a>
			<a class="btn btn-primary nav-cta" href="/quickstart">
				<span class="nav-cta-text">Run locally</span>
				<Icon name="arrow" size={16} />
			</a>
			<button
				class="icon-btn nav-burger"
				aria-label="Open menu"
				aria-expanded={open}
				aria-controls="drawer"
				onclick={() => (open = !open)}
			>
				<Icon name="burger" size={19} />
			</button>
		</div>
	</div>
</header>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div class="drawer" id="drawer" data-open={open} onclick={(e) => { if ((e.target as HTMLElement).closest('a')) open = false; }}>
	{#each links as l (l.href)}
		<a href={l.href}>{l.label}</a>
	{/each}
	<a class="btn btn-primary" href="/quickstart">Run locally</a>
</div>
