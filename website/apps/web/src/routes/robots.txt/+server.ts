import type { RequestHandler } from './$types';
import { env } from '$env/dynamic/public';

/* robots.txt — open to everyone, and explicitly welcoming AI crawlers so the
 * project's docs and story are discoverable by both people and models. */
export const prerender = process.env.ADAPTER === 'static';

export const GET: RequestHandler = ({ url }) => {
	const base = (env.PUBLIC_SITE_URL || url.origin).replace(/\/$/, '');
	const aiBots = [
		'GPTBot',
		'OAI-SearchBot',
		'ChatGPT-User',
		'ClaudeBot',
		'Claude-Web',
		'anthropic-ai',
		'PerplexityBot',
		'Google-Extended',
		'CCBot',
		'Applebot-Extended',
		'cohere-ai'
	];
	const body = [
		'User-agent: *',
		'Allow: /',
		'',
		'# AI crawlers are explicitly welcome.',
		...aiBots.flatMap((ua) => [`User-agent: ${ua}`, 'Allow: /', '']),
		`Sitemap: ${base}/sitemap.xml`,
		''
	].join('\n');

	return new Response(body, {
		headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=3600' }
	});
};
