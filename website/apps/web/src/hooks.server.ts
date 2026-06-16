import type { Handle } from '@sveltejs/kit';

/* qemu-wasm uses pthreads → needs SharedArrayBuffer → the page must be
 * cross-origin isolated. We scope COOP/COEP to /try (and the /qemu artifacts)
 * so the rest of the site keeps loading cross-origin resources (fonts) freely.
 *
 * COEP `credentialless` (vs `require-corp`) lets cross-origin no-cors resources
 * load without CORP headers while still granting crossOriginIsolated — so the
 * pinned artifacts can sit on a CDN. Safari support is partial; if you must
 * support it, switch to `require-corp` and serve artifacts same-origin (or with
 * Cross-Origin-Resource-Policy: cross-origin). */
export const handle: Handle = async ({ event, resolve }) => {
	const response = await resolve(event);
	const p = event.url.pathname;
	if (p === '/try' || p.startsWith('/try/') || p.startsWith('/qemu/')) {
		response.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
		response.headers.set('Cross-Origin-Embedder-Policy', 'credentialless');
	}
	return response;
};
