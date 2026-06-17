import { readFile, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { env } from '$env/dynamic/private';
import { renderMarkdown, type TocEntry } from './markdown';

/* Docs reader — single source of truth is the repo's docs/*.md. We map the
 * important files into sidebar sections; everything else lands in a catch-all
 * so nothing is silently dropped. */

const DOCS_DIR = path.resolve(process.cwd(), env.DOCS_DIR || '../../../docs');
const REPO = env.PUBLIC_REPO_URL || 'https://github.com/asaptf/swift-os';

interface DocMeta {
	section: string;
	title: string;
	order: number;
}

// Curated mapping (file stem in UPPER_SNAKE → section + nice title + order).
const MAP: Record<string, DocMeta> = {
	GETTING_STARTED: { section: 'Get started', title: 'Getting started', order: 1 },
	INSTALLATION_GUIDE: { section: 'Get started', title: 'Installation guide', order: 2 },
	USER_GUIDE: { section: 'Get started', title: 'User guide', order: 3 },
	EXAMPLES: { section: 'Get started', title: 'Examples & demos', order: 4 },

	CONCEPTS: { section: 'Concepts', title: 'Core concepts', order: 1 },
	PHILOSOPHY: { section: 'Concepts', title: 'Philosophy', order: 2 },
	ARCHITECTURE: { section: 'Concepts', title: 'Architecture', order: 3 },
	CAPABILITIES: { section: 'Concepts', title: 'Capabilities', order: 4 },

	NETWORKING_GUIDE: { section: 'Guides', title: 'Networking', order: 1 },
	AI_HOSTING_GUIDE: { section: 'Guides', title: 'AI hosting', order: 2 },
	APPLICATION_COOKBOOK: { section: 'Guides', title: 'Application cookbook', order: 3 },
	SECURITY_GUIDE: { section: 'Guides', title: 'Security', order: 4 },
	SERVICE_GUIDE: { section: 'Guides', title: 'Services', order: 5 },
	DEPLOYMENT_GUIDE: { section: 'Guides', title: 'Deployment', order: 6 },
	ADMINISTRATION_GUIDE: { section: 'Guides', title: 'Administration', order: 7 },
	OPERATIONS_GUIDE: { section: 'Guides', title: 'Operations', order: 8 },
	OBSERVABILITY_GUIDE: { section: 'Guides', title: 'Observability', order: 9 },
	PERFORMANCE_GUIDE: { section: 'Guides', title: 'Performance', order: 10 },
	DEVELOPER_GUIDE: { section: 'Guides', title: 'Developer guide', order: 11 },
	PORTING_GUIDE: { section: 'Guides', title: 'Porting', order: 12 },
	TESTING_GUIDE: { section: 'Guides', title: 'Testing', order: 13 },

	API_REFERENCE: { section: 'Reference', title: 'API reference', order: 1 },
	COMMAND_REFERENCE: { section: 'Reference', title: 'Command reference', order: 2 },
	CONFIGURATION_REFERENCE: { section: 'Reference', title: 'Configuration', order: 3 },
	HOST_TOOL_REFERENCE: { section: 'Reference', title: 'Host tools', order: 4 },
	COMPATIBILITY_GUIDE: { section: 'Reference', title: 'Compatibility', order: 5 },
	TROUBLESHOOTING: { section: 'Reference', title: 'Troubleshooting', order: 6 },
	FAQ: { section: 'Reference', title: 'FAQ', order: 7 },
	SUPPORT_GUIDE: { section: 'Reference', title: 'Support', order: 8 },

	PACKAGE_GUIDE: { section: 'Packages', title: 'Package guide', order: 1 },
	PACKAGE_MANAGEMENT: { section: 'Packages', title: 'Package management', order: 2 },
	PACKAGE_ECOSYSTEM_GOAL: { section: 'Packages', title: 'Ecosystem goal', order: 3 },
	SWPKG_FORMAT: { section: 'Packages', title: '.swpkg format', order: 4 },
	PKGREPO_FORMAT: { section: 'Packages', title: 'Repo format', order: 5 },
	PKGSTORE_FORMAT: { section: 'Packages', title: 'Store format', order: 6 },

	BASE_IMAGE: { section: 'Internals & notes', title: 'Base image', order: 1 },
	UPDATE_GUIDE: { section: 'Internals & notes', title: 'Updates', order: 2 },
	LOGGING: { section: 'Internals & notes', title: 'Logging', order: 3 },
	RISK_REMEDIATION_ROADMAP: { section: 'Internals & notes', title: 'Risk & roadmap', order: 4 },
	RELEASE_NOTES: { section: 'Internals & notes', title: 'Release notes', order: 5 },
	NOTES: { section: 'Internals & notes', title: 'Engineering notes', order: 6 }
};

const SECTION_ORDER = ['Get started', 'Concepts', 'Guides', 'Reference', 'Packages', 'Internals & notes', 'More'];
const ACRONYMS = new Set(['AI', 'API', 'SMP', 'UEFI', 'GPT', 'TCP', 'IP', 'HTTP', 'HTTPS', 'OS', 'VM', 'EL0', 'EL1']);

export const docSlug = (stem: string) => stem.toLowerCase().replace(/_/g, '-');
const slugToStem = (slug: string) => slug.toUpperCase().replace(/-/g, '_');

function prettify(stem: string): string {
	const words = stem.split('_');
	return words
		.map((w, i) => {
			if (ACRONYMS.has(w)) return w;
			const lower = w.toLowerCase();
			return i === 0 ? lower.charAt(0).toUpperCase() + lower.slice(1) : lower;
		})
		.join(' ');
}

export interface DocLink {
	slug: string;
	title: string;
}
export interface DocSection {
	title: string;
	items: DocLink[];
}

let cache: { sections: DocSection[]; flat: DocLink[] } | null = null;

async function index() {
	if (cache) return cache;
	if (!existsSync(DOCS_DIR)) {
		cache = { sections: [], flat: [] };
		return cache;
	}
	const files = (await readdir(DOCS_DIR)).filter((f) => f.endsWith('.md'));
	// Skip meta/working docs that aren't reader content.
	const SKIP = new Set(['DOCUMENTATION', 'NEXT_SESSION', 'SMP_STATE_AUDIT', 'PACKAGE_MANAGER_IMPLEMENTATION_PLAN', 'PACKAGE_MANAGER_SESSION_PROMPTS', 'PACKAGE_BUILD_AUTOMATION', 'UPDATE_STORE', 'SERVER_SOFTWARE_CATALOG']);

	const grouped = new Map<string, { meta: DocMeta; slug: string }[]>();
	for (const f of files) {
		const stem = f.replace(/\.md$/, '');
		if (SKIP.has(stem)) continue;
		const meta = MAP[stem] ?? { section: 'More', title: prettify(stem), order: 100 };
		if (!grouped.has(meta.section)) grouped.set(meta.section, []);
		grouped.get(meta.section)!.push({ meta, slug: docSlug(stem) });
	}

	const sections: DocSection[] = [];
	for (const name of SECTION_ORDER) {
		const arr = grouped.get(name);
		if (!arr) continue;
		arr.sort((a, b) => a.meta.order - b.meta.order || a.meta.title.localeCompare(b.meta.title));
		sections.push({ title: name, items: arr.map((x) => ({ slug: x.slug, title: x.meta.title })) });
	}
	const flat = sections.flatMap((s) => s.items);
	cache = { sections, flat };
	return cache;
}

export async function getDocNav(): Promise<DocSection[]> {
	return (await index()).sections;
}

/** Every doc slug on disk (including ones not surfaced in the nav) — used by the
 *  static build to prerender all reachable /docs/* pages. */
export async function getAllDocSlugs(): Promise<string[]> {
	if (!existsSync(DOCS_DIR)) return [];
	const files = await readdir(DOCS_DIR);
	return files.filter((f) => f.endsWith('.md')).map((f) => docSlug(f.replace(/\.md$/, '')));
}

export interface LoadedDoc {
	slug: string;
	title: string;
	html: string;
	toc: TocEntry[];
	prev: DocLink | null;
	next: DocLink | null;
	githubUrl: string;
	section: string;
}

export async function loadDoc(slug: string): Promise<LoadedDoc | null> {
	const stem = slugToStem(slug);
	const file = path.join(DOCS_DIR, `${stem}.md`);
	if (!existsSync(file)) return null;

	const raw = await readFile(file, 'utf-8');
	const { html, toc } = renderMarkdown(raw);

	const { flat } = await index();
	const i = flat.findIndex((d) => d.slug === slug);
	const meta = MAP[stem];
	const title = meta?.title ?? (raw.match(/^#\s+(.+)$/m)?.[1] ?? prettify(stem));

	return {
		slug,
		title,
		html,
		toc,
		prev: i > 0 ? flat[i - 1] : null,
		next: i >= 0 && i < flat.length - 1 ? flat[i + 1] : null,
		githubUrl: `${REPO}/blob/main/docs/${stem}.md`,
		section: meta?.section ?? 'More'
	};
}

export const docsAvailable = () => existsSync(DOCS_DIR);
