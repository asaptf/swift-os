import { env } from '$env/dynamic/private';

/* Thin Strapi v5 REST client. Server-only. Every call is best-effort: on any
 * failure (CMS down, content type missing, network) it returns null so callers
 * fall back to bundled defaults and the site always renders. */

const BASE = (env.STRAPI_URL || 'http://localhost:1337').replace(/\/$/, '');
const TOKEN = env.STRAPI_TOKEN || '';

type Fetch = typeof fetch;

async function request<T>(path: string, params: Record<string, string>, fetchFn: Fetch): Promise<T | null> {
	const qs = new URLSearchParams(params).toString();
	const url = `${BASE}/api/${path}${qs ? `?${qs}` : ''}`;
	try {
		const res = await fetchFn(url, {
			headers: TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}
		});
		if (!res.ok) return null;
		const json = (await res.json()) as { data?: T };
		return (json.data ?? null) as T | null;
	} catch {
		return null;
	}
}

/** Fetch a single-type entry (flattened fields). */
export function getSingle<T>(name: string, fetchFn: Fetch, params: Record<string, string> = {}): Promise<T | null> {
	return request<T>(name, { populate: '*', ...params }, fetchFn);
}

/** Fetch a collection (returns an array, or null on failure). */
export function getCollection<T>(
	name: string,
	fetchFn: Fetch,
	params: Record<string, string> = {}
): Promise<T[] | null> {
	return request<T[]>(name, { 'pagination[pageSize]': '100', populate: '*', ...params }, fetchFn);
}

export const strapiBase = BASE;
