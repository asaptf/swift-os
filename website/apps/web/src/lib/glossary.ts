import type { Action } from 'svelte/action';

/* Inline glossary tooltips, site-wide. Terms are supplied by the layout (from
 * Strapi, with bundled fallbacks). A single shared popup is positioned under
 * the hovered/focused term. */

export type GlossaryTerms = Record<string, string>;

let terms: GlossaryTerms = {};
let pop: HTMLDivElement | null = null;
let hideTimer: ReturnType<typeof setTimeout> | undefined;

export function setGlossaryTerms(t: GlossaryTerms) {
	terms = {};
	for (const k of Object.keys(t)) terms[k.toLowerCase()] = t[k];
}

function ensurePopup(): HTMLDivElement {
	if (pop) return pop;
	pop = document.createElement('div');
	pop.className = 'gloss-pop';
	pop.setAttribute('role', 'tooltip');
	pop.addEventListener('mouseenter', () => clearTimeout(hideTimer));
	pop.addEventListener('mouseleave', hide);
	document.body.appendChild(pop);
	return pop;
}

function show(el: HTMLElement) {
	const key = (el.getAttribute('data-gloss') || el.textContent || '').toLowerCase().trim();
	const def = terms[key];
	if (!def) return;
	const p = ensurePopup();
	p.innerHTML = `<span class="term">${key}</span>${def}`;
	const r = el.getBoundingClientRect();
	p.style.left = Math.max(12, Math.min(r.left, window.innerWidth - 292)) + 'px';
	p.style.top = r.bottom + 8 + 'px';
	p.setAttribute('data-show', 'true');
}

function hide() {
	pop?.setAttribute('data-show', 'false');
}

/** use:gloss on any element carrying a data-gloss key. */
export const gloss: Action<HTMLElement> = (node) => {
	node.setAttribute('tabindex', '0');
	const onEnter = () => {
		clearTimeout(hideTimer);
		show(node);
	};
	const onLeave = () => {
		hideTimer = setTimeout(hide, 120);
	};
	node.addEventListener('mouseenter', onEnter);
	node.addEventListener('mouseleave', onLeave);
	node.addEventListener('focus', onEnter);
	node.addEventListener('blur', hide);
	return {
		destroy() {
			node.removeEventListener('mouseenter', onEnter);
			node.removeEventListener('mouseleave', onLeave);
			node.removeEventListener('focus', onEnter);
			node.removeEventListener('blur', hide);
		}
	};
};
