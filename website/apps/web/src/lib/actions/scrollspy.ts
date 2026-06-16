import type { Action } from 'svelte/action';

/* TOC scrollspy: highlights the link for the section currently in view.
 * Applied to the TOC container; reads its in-page anchors. */
export const scrollspy: Action<HTMLElement> = (node) => {
	const links = Array.from(node.querySelectorAll<HTMLAnchorElement>('a[href^="#"]'));
	const map = new Map<string, HTMLAnchorElement>();
	for (const a of links) {
		const id = a.getAttribute('href')!.slice(1);
		if (document.getElementById(id)) map.set(id, a);
	}
	if (map.size === 0 || !('IntersectionObserver' in window)) return;

	const io = new IntersectionObserver(
		(entries) => {
			for (const en of entries) {
				if (en.isIntersecting) {
					links.forEach((l) => l.classList.remove('active'));
					map.get((en.target as HTMLElement).id)?.classList.add('active');
				}
			}
		},
		{ rootMargin: '-20% 0px -70% 0px' }
	);
	for (const id of map.keys()) io.observe(document.getElementById(id)!);
	return { destroy: () => io.disconnect() };
};
