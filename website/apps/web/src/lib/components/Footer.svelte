<script lang="ts">
	import Brand from './Brand.svelte';
	let { variant = 'full', hostedNote = 'Embedded Swift · aarch64 · Apache-2.0' }: {
		variant?: 'full' | 'mini';
		hostedNote?: string;
	} = $props();
</script>

{#if variant === 'full'}
	<footer class="footer">
		<div class="wrap wrap-wide">
			<div class="footer-grid">
				<div>
					<Brand />
					<p class="muted" style="font-size:var(--fs-sm);margin-top:1rem;max-width:24rem">
						An experimental but real operating system written entirely in Embedded Swift for aarch64.
					</p>
				</div>
				<div>
					<h5>Learn</h5>
					<ul>
						<li><a href="/quickstart">Quickstart</a></li>
						<li><a href="/try">Try in your browser</a></li>
						<li><a href="/docs">Documentation</a></li>
						<li><a href="/architecture">Architecture</a></li>
						<li><a href="/status">What works today</a></li>
					</ul>
				</div>
				<div>
					<h5>Project</h5>
					<ul>
						<li><a href="https://github.com/asaptf/swift-os" target="_blank" rel="noopener">GitHub</a></li>
						<li><a href="/status#roadmap">Roadmap</a></li>
						<li><a href="/articles">Articles</a></li>
						<li><a href="/design">Design system</a></li>
					</ul>
				</div>
				<div>
					<h5>More</h5>
					<ul>
						<li><a href="/faq">FAQ</a></li>
						<li><a href="/articles">Deep dives</a></li>
						<li><a href="https://github.com/asaptf/swift-os">Contribute</a></li>
					</ul>
				</div>
			</div>
			<div class="footer-bottom">
				<span class="footer-hosted">
					<span class="proof-pill" style="padding:.25rem .7rem .25rem .45rem"><span class="live"></span> {hostedNote}</span>
				</span>
				<span class="muted" style="font-size:var(--fs-xs)">© 2026 swift-os · not affiliated with Apple Inc.</span>
			</div>
		</div>
	</footer>
{:else}
	<footer class="footer">
		<div class="wrap wrap-wide">
			<div class="footer-bottom" style="border:0;margin:0;padding:0">
				<span class="footer-hosted">
					<span class="proof-pill" style="padding:.25rem .7rem .25rem .45rem"><span class="live"></span> {hostedNote}</span>
				</span>
				<span class="muted" style="font-size:var(--fs-xs)">© 2026 swift-os</span>
			</div>
		</div>
	</footer>
{/if}
