import type { PageServerLoad, EntryGenerator } from './$types';
import { error } from '@sveltejs/kit';
import { getArticle } from '$lib/server/content';
import { renderMarkdown } from '$lib/server/markdown';
import { defaultArticles } from '$lib/content/defaults';

export const prerender = process.env.ADAPTER === 'static';

// Prerender the bundled articles. (To also bake CMS-only articles, run the
// static build with Strapi reachable and extend this list from getArticles.)
export const entries: EntryGenerator = () => defaultArticles.map((a) => ({ slug: a.slug }));

export const load: PageServerLoad = async ({ params, fetch }) => {
	const article = await getArticle(params.slug, fetch);
	if (!article) throw error(404, `No such article: ${params.slug}`);
	const bodyHtml = article.bodyHtml ?? (article.bodyMarkdown ? renderMarkdown(article.bodyMarkdown).html : '');
	return { article: { ...article, bodyHtml } };
};
