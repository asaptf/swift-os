/* Content shapes shared by the SvelteKit pages. These map onto the Strapi
 * content types (apps/cms) and onto the bundled defaults used as fallback. */

export type StatusVariant = 'ok' | 'accent' | 'warn' | 'info' | 'muted' | 'err';

export interface CtaLink {
	label: string;
	href: string;
}

export interface Feature {
	icon: string; // key into the icon set rendered by the component
	title: string;
	bodyHtml: string;
}

export interface WorksBadge {
	label: string;
	variant: StatusVariant;
}

export interface StartCard {
	title: string;
	bodyHtml: string;
	href: string;
}

export interface Home {
	eyebrow: string;
	titleHtml: string;
	leadHtml: string;
	featuresEyebrow: string;
	featuresHeading: string;
	featuresLead: string;
	features: Feature[];
	worksEyebrow: string;
	worksHeading: string;
	worksLead: string;
	worksBadges: WorksBadge[];
	startEyebrow: string;
	startHeading: string;
	startCards: StartCard[];
}

export interface ProofStat {
	label: string;
	value: string;
	sub: string;
	accent?: boolean;
	uptimeSeconds?: number;
	countTo?: number;
	suffix?: string;
}

export interface LiveProof {
	heading: string;
	body: string;
	bootLog: string;
	hostedNote: string;
	stats: ProofStat[];
}

export interface Capability {
	name: string;
	note: string;
	status: string; // display label e.g. "Works"
	variant: StatusVariant;
	detail: string;
}

export interface RoadmapItem {
	phase: 'done' | 'active' | 'planned';
	label: string; // may contain inline <code>
}

export interface NonGoal {
	title: string;
	body: string;
}

export interface CoverageStat {
	to: number;
	decimals?: number;
	suffix?: string;
	label: string;
	accent?: boolean;
}

export interface StatusPage {
	eyebrow: string;
	heading: string;
	lead: string; // html
	build: string;
	updated: string;
	capabilities: Capability[];
	roadmap: RoadmapItem[];
	nonGoals: NonGoal[];
	coverage: CoverageStat[];
	testLog: string;
}

export interface QuickstartStep {
	title: string;
	bodyHtml?: string;
	command?: string; // terminal block (highlighted by pattern)
	commandTitle?: string;
	expected?: string; // expected-output terminal block
	expectedTitle?: string;
	callout?: { type: 'note' | 'tip' | 'warn'; html: string };
}

export interface QuickstartTrack {
	key: string;
	label: string;
	icon?: 'apple' | null;
	steps?: QuickstartStep[];
	noteHtml?: string; // simple tracks: a callout + a single command
	command?: string;
	commandTitle?: string;
	calloutType?: 'note' | 'tip' | 'warn';
	footWarnHtml?: string;
}

export interface QuickstartPage {
	eyebrow: string;
	heading: string;
	leadHtml: string;
	needHtml: string;
	tracks: QuickstartTrack[];
}

export interface GlossaryTerm {
	key: string;
	definition: string;
}

export interface Article {
	slug: string;
	title: string;
	eyebrow: string;
	excerpt: string;
	bodyHtml?: string;
	bodyMarkdown?: string;
	publishedAt?: string;
	readingMinutes?: number;
}

export interface Faq {
	question: string;
	answerHtml: string;
	category?: string;
}
