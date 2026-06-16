import type { Action } from 'svelte/action';

/* Scroll-reveal (fade + small translate). Honors prefers-reduced-motion and
 * never strands content invisible in no-scroll environments. */
export const reveal: Action<HTMLElement, number | undefined> = (node, delay = 0) => {
	const rm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	node.classList.add('reveal');

	if (rm || !('IntersectionObserver' in window)) {
		node.classList.add('in');
		return;
	}

	const io = new IntersectionObserver(
		(entries) => {
			entries.forEach((en) => {
				if (en.isIntersecting) {
					setTimeout(() => node.classList.add('in'), delay);
					io.unobserve(node);
				}
			});
		},
		{ rootMargin: '0px 0px -8% 0px', threshold: 0.08 }
	);
	io.observe(node);

	// Safety net: reveal after a few seconds regardless.
	const safety = setTimeout(() => node.classList.add('in'), 2800);

	return {
		destroy() {
			io.disconnect();
			clearTimeout(safety);
		}
	};
};
