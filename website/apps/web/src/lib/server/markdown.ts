import { Marked, type Tokens } from 'marked';
import { markedHighlight } from 'marked-highlight';
import hljs from 'highlight.js';
import { env } from '$env/dynamic/private';

const REPO = (env.PUBLIC_REPO_URL || 'https://github.com/asaptf/swift-os').replace(/\/$/, '');

export interface TocEntry {
	id: string;
	text: string;
	depth: number;
}

function slugify(text: string, used: Map<string, number>): string {
	const base = text
		.toLowerCase()
		.replace(/<[^>]+>/g, '')
		.replace(/[^\w\s-]/g, '')
		.trim()
		.replace(/\s+/g, '-');
	const n = used.get(base) ?? 0;
	used.set(base, n + 1);
	return n === 0 ? base || 'section' : `${base}-${n}`;
}

/* Rewrite repo-relative links:
 *  - docs/*.md (or a bare FOO.md) → the /docs/<slug> reader route
 *  - any other relative path (source files, dirs, non-docs .md) → GitHub blob
 *  Absolute site paths (/foo) and external/anchor/mailto links pass through. */
function rewriteHref(href: string): string {
	if (/^(https?:)?\/\//.test(href) || href.startsWith('#') || href.startsWith('mailto:')) return href;

	const md = href.match(/(?:^|\/)([A-Za-z0-9_]+)\.md(#.*)?$/);
	const inDocs = /(^|\/)docs\//.test(href);
	if (md && (!href.includes('/') || inDocs)) {
		return `/docs/${md[1].toLowerCase().replace(/_/g, '-')}${md[2] ?? ''}`;
	}

	// Any other relative link points at a repo file/dir — send it to GitHub.
	if (!href.startsWith('/')) {
		const clean = href.replace(/^\.\//, '').replace(/^(\.\.\/)+/, '').split('#')[0];
		return `${REPO}/blob/main/${clean}`;
	}
	return href;
}

export interface RenderedDoc {
	html: string;
	toc: TocEntry[];
}

/** Render a markdown document to design-styled HTML plus a heading TOC.
 *  A fresh Marked instance per call keeps heading collection concurrency-safe. */
export function renderMarkdown(md: string): RenderedDoc {
	const toc: TocEntry[] = [];
	const used = new Map<string, number>();

	const marked = new Marked(
		markedHighlight({
			emptyLangClass: 'hljs',
			langPrefix: 'hljs language-',
			highlight(code, lang) {
				try {
					if (lang && hljs.getLanguage(lang)) return hljs.highlight(code, { language: lang }).value;
				} catch {
					/* fall through to auto */
				}
				try {
					return hljs.highlightAuto(code).value;
				} catch {
					return code;
				}
			}
		})
	);

	marked.use({
		gfm: true,
		breaks: false,
		renderer: {
			heading({ tokens, depth }: Tokens.Heading) {
				const text = this.parser.parseInline(tokens);
				const id = slugify(text, used);
				if (depth >= 2 && depth <= 3) toc.push({ id, text: text.replace(/<[^>]+>/g, ''), depth });
				return `<h${depth} id="${id}">${text}</h${depth}>\n`;
			},
			link({ href, title, tokens }: Tokens.Link) {
				const text = this.parser.parseInline(tokens);
				const t = title ? ` title="${title}"` : '';
				const url = rewriteHref(href);
				const ext = /^https?:\/\//.test(url) ? ' target="_blank" rel="noopener"' : '';
				return `<a href="${url}"${t}${ext}>${text}</a>`;
			}
		}
	});

	const html = marked.parse(md, { async: false }) as string;
	return { html, toc };
}
