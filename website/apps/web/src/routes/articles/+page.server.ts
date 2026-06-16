import type { PageServerLoad } from './$types';
import { getArticles } from '$lib/server/content';

export const load: PageServerLoad = async ({ fetch }) => {
	return { articles: await getArticles(fetch) };
};
