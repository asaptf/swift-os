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

/* ---- SwiftCube page ----
 * The companion cluster-orchestrator page. Editable prose + structured lists
 * live in the CMS; the topology and Cell-anatomy diagrams stay in the Svelte
 * component (like /architecture), since they are layout, not copy. */

export interface SwiftcubeBadge {
	label: string;
	variant: StatusVariant;
}

export interface SwiftcubeCellPart {
	name: string; // e.g. "base image"
	desc: string; // e.g. "read-only · content-addressed · deduplicated"
}

export interface SwiftcubeDiff {
	tag: string; // e.g. "01 · substrate"
	title: string;
	bodyHtml: string;
	bullets?: string[]; // optional "→" list
	chips?: { label: string; off?: boolean }[]; // optional capability chips
}

export interface SwiftcubeComponent {
	name: string; // sctl, sctld, cubestore, slet
	what: string; // html
	note: string; // sub-note under the name cell
	k8s: string; // Kubernetes analogue
}

export interface SwiftcubeMilestone {
	id: string; // SC0 … SC9
	text: string;
	done: boolean;
}

export interface SwiftcubePage {
	eyebrow: string;
	titleHtml: string;
	leadHtml: string;
	badges: SwiftcubeBadge[];
	// 01 · instance = Cell
	coreHeading: string;
	coreSubHtml: string;
	coreProseHtml: string;
	cellTagline: string;
	cellParts: SwiftcubeCellPart[];
	removed: string[];
	kept: string;
	// 02 · architecture / lifecycle
	archHeading: string;
	archSubHtml: string;
	lifecycle: string[]; // html steps
	lifecycleFootHtml: string;
	archCalloutHtml: string;
	// 03 · differentiators
	diffHeading: string;
	diffLead: string;
	differentiators: SwiftcubeDiff[];
	// 04 · manifest
	manifestHeading: string;
	manifestLead: string;
	manifestYaml: string;
	applyCmd: string;
	applyOut: string;
	readCmd: string;
	readOut: string;
	manifestCalloutHtml: string;
	// 05 · components
	componentsHeading: string;
	componentsLead: string;
	components: SwiftcubeComponent[];
	componentsCapHtml: string;
	// 06 · features
	featuresHeading: string;
	featuresLead: string;
	features: Feature[];
	// 07 · honest framing
	framingHeading: string;
	framingLead: string;
	framingWarnHtml: string;
	framingTipHtml: string;
	scopeHtml: string;
	ladderTitle: string;
	milestones: SwiftcubeMilestone[];
}
