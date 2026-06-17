import type { Action } from 'svelte/action';

interface CountOpts {
	to: number;
	decimals?: number;
	suffix?: string;
	prefix?: string;
}

/* Count-up when scrolled into view (eased). Static under reduced motion. */
export const countUp: Action<HTMLElement, CountOpts> = (node, opts) => {
	const rm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	const { to, decimals = 0, suffix = '', prefix = '' } = opts;

	const run = () => {
		if (rm) {
			node.textContent = prefix + to.toFixed(decimals) + suffix;
			return;
		}
		const dur = 1100;
		let t0: number | null = null;
		const frame = (t: number) => {
			if (t0 === null) t0 = t;
			const p = Math.min((t - t0) / dur, 1);
			const eased = 1 - Math.pow(1 - p, 3);
			node.textContent = prefix + (to * eased).toFixed(decimals) + suffix;
			if (p < 1) requestAnimationFrame(frame);
		};
		requestAnimationFrame(frame);
	};

	if (!('IntersectionObserver' in window)) {
		run();
		return;
	}
	const io = new IntersectionObserver(
		(entries) => {
			if (entries[0].isIntersecting) {
				run();
				io.disconnect();
			}
		},
		{ threshold: 0.4 }
	);
	io.observe(node);
	return { destroy: () => io.disconnect() };
};

/* Live uptime ticker: base seconds + elapsed wall-clock, formatted d HH:MM:SS. */
export const uptime: Action<HTMLElement, number> = (node, baseSeconds) => {
	const rm = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
	const start = Date.now();
	const pad = (n: number) => (n < 10 ? '0' : '') + n;
	const fmt = () => {
		let s = (baseSeconds || 0) + Math.floor((Date.now() - start) / 1000);
		const d = Math.floor(s / 86400);
		s -= d * 86400;
		const h = Math.floor(s / 3600);
		s -= h * 3600;
		const m = Math.floor(s / 60);
		s -= m * 60;
		node.textContent = `${d}d ${pad(h)}:${pad(m)}:${pad(s)}`;
	};
	fmt();
	const id = rm ? null : setInterval(fmt, 1000);
	return { destroy: () => id && clearInterval(id) };
};
