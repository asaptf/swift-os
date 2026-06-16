import type { PageServerLoad } from './$types';
import { getFaqs } from '$lib/server/content';

export const load: PageServerLoad = async ({ fetch }) => {
	return { faqs: await getFaqs(fetch) };
};
