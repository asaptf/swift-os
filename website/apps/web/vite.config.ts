import adapterNode from '@sveltejs/adapter-node';
import adapterStatic from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// ADAPTER=static → fully prerendered static output (no Node/Strapi at runtime;
// content comes from the bundled defaults + build-time docs ingest).
// Otherwise → Node SSR (live Strapi). Both write to build/.
const adapter =
	process.env.ADAPTER === 'static' ? adapterStatic({ fallback: '404.html' }) : adapterNode();

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
			// Don't fail the static build on the odd doc link to a repo path that
			// isn't a site route — warn instead (matches SSR behaviour).
			prerender: { handleHttpError: 'warn', handleMissingId: 'warn' },
			adapter
		})
	]
});
