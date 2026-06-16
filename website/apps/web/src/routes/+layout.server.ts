import type { LayoutServerLoad } from './$types';
import { getGlossary } from '$lib/server/content';

// Glossary terms power the inline tooltips site-wide.
export const load: LayoutServerLoad = async ({ fetch }) => {
	const glossary = await getGlossary(fetch);
	return { glossary };
};
