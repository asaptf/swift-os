import type { PageServerLoad, EntryGenerator } from './$types';
import { error } from '@sveltejs/kit';
import { loadDoc, getAllDocSlugs } from '$lib/server/docs';

export const prerender = process.env.ADAPTER === 'static';

// Enumerate every doc so the static build prerenders them all (including ones
// reachable only via intra-doc links, not just the sidebar nav).
export const entries: EntryGenerator = async () => {
	return (await getAllDocSlugs()).map((slug) => ({ slug }));
};

export const load: PageServerLoad = async ({ params }) => {
	const doc = await loadDoc(params.slug);
	if (!doc) throw error(404, `No such doc: ${params.slug}`);
	return { doc };
};
