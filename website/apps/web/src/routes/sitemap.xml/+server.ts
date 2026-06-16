import type { RequestHandler } from './$types';
import { getDocNav } from '$lib/server/docs';
import { getArticles } from '$lib/server/content';

/* Dynamic sitemap covering authored pages, every ingested doc, and articles. */
export const prerender = false;

const STATIC_PATHS = ['/', '/status', '/quickstart', '/try', '/architecture', '/docs', '/design', '/articles', '/faq'];

export const GET: RequestHandler = async ({ url, fetch }) => {
	const [nav, articles] = await Promise.all([getDocNav(), getArticles(fetch)]);
	const docPaths = nav.flatMap((g) => g.items.map((i) => `/docs/${i.slug}`));
	const articlePaths = articles.map((a) => `/articles/${a.slug}`);

	const paths = [...STATIC_PATHS, ...docPaths, ...articlePaths];
	const seen = new Set<string>();
	const urls = paths
		.filter((p) => (seen.has(p) ? false : (seen.add(p), true)))
		.map((p) => {
			const priority = p === '/' ? '1.0' : p.startsWith('/docs/') ? '0.6' : '0.8';
			return `  <url><loc>${url.origin}${p}</loc><changefreq>weekly</changefreq><priority>${priority}</priority></url>`;
		})
		.join('\n');

	const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;

	return new Response(body, {
		headers: { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=3600' }
	});
};
