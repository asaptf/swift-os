import type { PageServerLoad } from './$types';
import { getSwiftcube } from '$lib/server/content';

export const load: PageServerLoad = async ({ fetch }) => {
	return { swiftcube: await getSwiftcube(fetch) };
};
