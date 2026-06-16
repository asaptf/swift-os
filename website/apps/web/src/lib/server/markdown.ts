import { Marked, type Tokens } from 'marked';
import { markedHighlight } from 'marked-highlight';
import hljs from 'highlight.js';

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

/** Rewrite intra-repo doc links (FOO.md, ./FOO.md, docs/FOO.md) to site routes. */
function rewriteHref(href: string): string {
	if (/^(https?:)?\/\//.test(href) || href.startsWith('#') || href.startsWith('mailto:')) return href;
	const m = href.match(/(?:^|\/)([A-Z0-9_]+)\.md(#.*)?$/i);
	if (m) return `/docs/${m[1].toLowerCase().replace(/_/g, '-')}${m[2] ?? ''}`;
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
