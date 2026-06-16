import type { PageServerLoad } from './$types';
import { error } from '@sveltejs/kit';
import { loadDoc } from '$lib/server/docs';

export const load: PageServerLoad = async ({ params }) => {
	const doc = await loadDoc(params.slug);
	if (!doc) throw error(404, `No such doc: ${params.slug}`);
	return { doc };
};
