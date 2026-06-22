import { getSingle, getCollection } from './strapi';
import {
	defaultHome,
	defaultLiveProof,
	defaultStatus,
	defaultQuickstart,
	defaultGlossary,
	defaultArticles,
	defaultFaqs,
	defaultSwiftcube
} from '$lib/content/defaults';
import type {
	Home,
	LiveProof,
	StatusPage,
	QuickstartPage,
	GlossaryTerm,
	Article,
	Capability,
	RoadmapItem,
	Faq,
	SwiftcubePage
} from '$lib/content/types';

type Fetch = typeof fetch;

const has = (a: unknown[] | null | undefined): a is unknown[] => Array.isArray(a) && a.length > 0;

/* Each loader tries Strapi, then falls back to the bundled defaults — both for
 * the whole object and (where it matters) per-section, so partial CMS coverage
 * still renders a complete page. */

export async function getHome(fetchFn: Fetch): Promise<Home> {
	const data = await getSingle<Partial<Home>>('home', fetchFn);
	if (!data) return defaultHome;
	return {
		...defaultHome,
		...data,
		features: has(data.features) ? (data.features as Home['features']) : defaultHome.features,
		worksBadges: has(data.worksBadges) ? (data.worksBadges as Home['worksBadges']) : defaultHome.worksBadges,
		startCards: has(data.startCards) ? (data.startCards as Home['startCards']) : defaultHome.startCards
	};
}

export async function getLiveProof(fetchFn: Fetch): Promise<LiveProof> {
	const data = await getSingle<Partial<LiveProof>>('live-proof', fetchFn);
	if (!data) return defaultLiveProof;
	return {
		...defaultLiveProof,
		...data,
		stats: has(data.stats) ? (data.stats as LiveProof['stats']) : defaultLiveProof.stats
	};
}

export async function getStatus(fetchFn: Fetch): Promise<StatusPage> {
	const [page, caps, road] = await Promise.all([
		getSingle<Partial<StatusPage>>('status-page', fetchFn),
		getCollection<Capability>('capabilities', fetchFn, { sort: 'order:asc' }),
		getCollection<RoadmapItem>('roadmap-items', fetchFn, { sort: 'order:asc' })
	]);
	return {
		...defaultStatus,
		...(page ?? {}),
		capabilities: has(caps) ? (caps as Capability[]) : defaultStatus.capabilities,
		roadmap: has(road) ? (road as RoadmapItem[]) : defaultStatus.roadmap,
		nonGoals: has(page?.nonGoals) ? (page!.nonGoals as StatusPage['nonGoals']) : defaultStatus.nonGoals,
		coverage: has(page?.coverage) ? (page!.coverage as StatusPage['coverage']) : defaultStatus.coverage
	};
}

export async function getQuickstart(fetchFn: Fetch): Promise<QuickstartPage> {
	const data = await getSingle<Partial<QuickstartPage>>('quickstart-page', fetchFn);
	if (!data || !has(data.tracks)) return defaultQuickstart;
	return { ...defaultQuickstart, ...data, tracks: data.tracks as QuickstartPage['tracks'] };
}

export async function getGlossary(fetchFn: Fetch): Promise<Record<string, string>> {
	const terms = await getCollection<GlossaryTerm>('glossary-terms', fetchFn);
	const list = has(terms) ? (terms as GlossaryTerm[]) : defaultGlossary;
	const map: Record<string, string> = {};
	for (const t of list) if (t.key) map[t.key.toLowerCase()] = t.definition;
	return map;
}

// Strapi stores the article body as `body` (markdown) and date as `date`;
// normalize to the Article shape the pages expect.
type RawArticle = Partial<Article> & { body?: string; date?: string };
function mapArticle(a: RawArticle): Article {
	return {
		slug: a.slug ?? '',
		title: a.title ?? '',
		eyebrow: a.eyebrow ?? '',
		excerpt: a.excerpt ?? '',
		readingMinutes: a.readingMinutes,
		publishedAt: a.publishedAt ?? a.date,
		bodyMarkdown: a.bodyMarkdown ?? a.body,
		bodyHtml: a.bodyHtml
	};
}

export async function getArticles(fetchFn: Fetch): Promise<Article[]> {
	const arts = await getCollection<RawArticle>('articles', fetchFn, { sort: 'date:desc' });
	return has(arts) ? (arts as RawArticle[]).map(mapArticle) : defaultArticles;
}

export async function getArticle(slug: string, fetchFn: Fetch): Promise<Article | null> {
	const arts = await getCollection<RawArticle>('articles', fetchFn, { 'filters[slug][$eq]': slug });
	if (has(arts)) return mapArticle((arts as RawArticle[])[0]);
	return defaultArticles.find((a) => a.slug === slug) ?? null;
}

export async function getFaqs(fetchFn: Fetch): Promise<Faq[]> {
	const faqs = await getCollection<Faq>('faqs', fetchFn, { sort: 'order:asc' });
	return has(faqs) ? (faqs as Faq[]) : defaultFaqs;
}

export async function getSwiftcube(fetchFn: Fetch): Promise<SwiftcubePage> {
	const data = await getSingle<Partial<SwiftcubePage>>('swiftcube-page', fetchFn);
	if (!data) return defaultSwiftcube;
	return {
		...defaultSwiftcube,
		...data,
		badges: has(data.badges) ? (data.badges as SwiftcubePage['badges']) : defaultSwiftcube.badges,
		cellParts: has(data.cellParts) ? (data.cellParts as SwiftcubePage['cellParts']) : defaultSwiftcube.cellParts,
		removed: has(data.removed) ? (data.removed as string[]) : defaultSwiftcube.removed,
		lifecycle: has(data.lifecycle) ? (data.lifecycle as string[]) : defaultSwiftcube.lifecycle,
		differentiators: has(data.differentiators) ? (data.differentiators as SwiftcubePage['differentiators']) : defaultSwiftcube.differentiators,
		components: has(data.components) ? (data.components as SwiftcubePage['components']) : defaultSwiftcube.components,
		features: has(data.features) ? (data.features as SwiftcubePage['features']) : defaultSwiftcube.features,
		milestones: has(data.milestones) ? (data.milestones as SwiftcubePage['milestones']) : defaultSwiftcube.milestones
	};
}
