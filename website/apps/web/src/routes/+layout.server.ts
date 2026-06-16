import type { LayoutServerLoad } from './$types';
import { getGlossary } from '$lib/server/content';

// For the static build (ADAPTER=static) prerender every route at build time;
// for the Node build, render per-request so live Strapi content stays live.
export const prerender = process.env.ADAPTER === 'static';

// Glossary terms power the inline tooltips site-wide.
export const load: LayoutServerLoad = async ({ fetch }) => {
	const glossary = await getGlossary(fetch);
	return { glossary };
};
