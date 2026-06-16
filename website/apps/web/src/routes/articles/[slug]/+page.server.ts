import type { PageServerLoad } from './$types';
import { error } from '@sveltejs/kit';
import { getArticle } from '$lib/server/content';
import { renderMarkdown } from '$lib/server/markdown';

export const load: PageServerLoad = async ({ params, fetch }) => {
	const article = await getArticle(params.slug, fetch);
	if (!article) throw error(404, `No such article: ${params.slug}`);
	const bodyHtml = article.bodyHtml ?? (article.bodyMarkdown ? renderMarkdown(article.bodyMarkdown).html : '');
	return { article: { ...article, bodyHtml } };
};
