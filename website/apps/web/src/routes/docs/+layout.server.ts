import type { LayoutServerLoad } from './$types';
import { getDocNav } from '$lib/server/docs';

export const load: LayoutServerLoad = async () => {
	return { nav: await getDocNav() };
};
