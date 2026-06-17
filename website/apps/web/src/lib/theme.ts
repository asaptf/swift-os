/* Theme handling — dark default, light companion, persisted in localStorage.
 * The no-flash bootstrap lives in app.html; this only handles user toggles. */

const THEME_KEY = 'swiftos-theme';
export type Theme = 'dark' | 'light';

export function currentTheme(): Theme {
	if (typeof document === 'undefined') return 'dark';
	return document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
}

function syncToggles(t: Theme) {
	document.querySelectorAll<HTMLElement>('[data-theme-toggle]').forEach((b) => {
		b.setAttribute('aria-label', t === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
		b.setAttribute('aria-pressed', String(t === 'light'));
	});
}

export function applyTheme(t: Theme) {
	document.documentElement.setAttribute('data-theme', t);
	try {
		localStorage.setItem(THEME_KEY, t);
	} catch {
		/* ignore private-mode storage errors */
	}
	syncToggles(t);
}

export function toggleTheme() {
	applyTheme(currentTheme() === 'dark' ? 'light' : 'dark');
}
