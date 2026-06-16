import type { PageServerLoad } from './$types';
import { getHome, getLiveProof } from '$lib/server/content';

export const load: PageServerLoad = async ({ fetch }) => {
	const [home, liveProof] = await Promise.all([getHome(fetch), getLiveProof(fetch)]);
	return { home, liveProof };
};
