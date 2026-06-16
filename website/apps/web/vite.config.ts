import adapter from '@sveltejs/adapter-node';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	// Pinned away from 5173 — Strapi's admin dev server (apps/cms) binds 5173,
	// which is also SvelteKit's default. Keep the site on its own fixed port.
	server: { port: 5180, strictPort: true },
	preview: { port: 5180, strictPort: true },
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// Node server output — SSR hosting (the "served by swift-os + Node.js" story).
			adapter: adapter()
		})
	]
});
