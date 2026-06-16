import type { PageServerLoad } from './$types';
import { getStatus } from '$lib/server/content';

export const load: PageServerLoad = async ({ fetch }) => {
	return { status: await getStatus(fetch) };
};
