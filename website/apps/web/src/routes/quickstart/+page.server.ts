import type { PageServerLoad } from './$types';
import { getQuickstart } from '$lib/server/content';

export const load: PageServerLoad = async ({ fetch }) => {
	return { quickstart: await getQuickstart(fetch) };
};
