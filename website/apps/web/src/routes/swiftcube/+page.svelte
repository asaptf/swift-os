<script lang="ts">
	import { reveal } from '$lib/actions/reveal';
	import Callout from '$lib/components/Callout.svelte';
	import CodeBlock from '$lib/components/CodeBlock.svelte';
	import Footer from '$lib/components/Footer.svelte';
	import Seo from '$lib/components/Seo.svelte';

	let { data } = $props();
	const sc = $derived(data.swiftcube);

	const badgeClass = (v: string) =>
		v === 'accent' ? 'badge-accent' : v === 'ok' ? 'badge-ok' : v === 'warn' ? 'badge-warn' : 'badge-muted';
</script>

<Seo
	title="SwiftCube — a Swift-native cluster orchestrator for swift-os fleets"
	description="SwiftCube orchestrates fleets of swift-os machines without containers. A deployed instance is a kernel-native Cell — content-addressed base, RAM scratch, capability-scoped — so it starts in milliseconds. A simplified-but-complete analogue of Kubernetes, written Swift-everywhere."
/>

<main id="main" class="wrap wrap-wide" style="padding-block:var(--sp-8)">
	<!-- PAGE HEADER -->
	<header style="max-width:54rem;margin-bottom:var(--sp-8)" use:reveal>
		<span class="eyebrow">{sc.eyebrow}</span>
		<h1 style="margin-top:1rem">{@html sc.titleHtml}</h1>
		<p class="lead" style="margin-top:1rem">{@html sc.leadHtml}</p>
		<div style="margin-top:var(--sp-5);display:flex;flex-wrap:wrap;gap:var(--sp-2)">
			{#each sc.badges as b (b.label)}
				<span class="badge {badgeClass(b.variant)}"><span class="dot"></span> {b.label}</span>
			{/each}
		</div>
	</header>

	<!-- 01 · instance = Cell -->
	<section class="fig-block" use:reveal style="border-top:0;padding-top:var(--sp-2)">
		<div class="fig-head"><span class="fig-num">01</span><div><h2 class="fig-title">{sc.coreHeading}</h2><p class="fig-sub">{@html sc.coreSubHtml}</p></div></div>
		<div class="cube-split">
			<div class="cube-prose">
				<p class="muted">{@html sc.coreProseHtml}</p>
				<p class="cube-tagline mono">{sc.cellTagline}</p>
			</div>
			<figure class="fig cell-fig" aria-label="Anatomy of a SwiftCube Cell">
				<div class="cell-head">
					<span class="cell-title mono">◆ Cell — one app instance</span>
					<span class="badge badge-ok"><span class="dot"></span> starts in ms</span>
				</div>
				<div class="cell-parts">
					{#each sc.cellParts as part (part.name)}
						<div class="cell-part"><b class="mono">{part.name}</b><i>{part.desc}</i></div>
					{/each}
				</div>
			</figure>
		</div>
		<div class="removed-strip">
			<span class="removed-label mono">No container runtime · achieved by removal</span>
			<div class="removed-list">
				{#each sc.removed as r (r)}<span class="removed">{r}</span>{/each}
				<span class="removed-arrow mono">→</span>
				<span class="kept mono">{sc.kept}</span>
			</div>
		</div>
	</section>

	<!-- 02 · architecture / topology -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">02</span><div><h2 class="fig-title">{sc.archHeading}</h2><p class="fig-sub">{@html sc.archSubHtml}</p></div></div>
		<figure class="fig topo" aria-label="SwiftCube control-plane topology">
			<div class="topo-band">
				<div class="topo-node node-cli"><span class="nm mono">sctl</span><span class="sub">CLI</span></div>
				<span class="topo-conn mono" aria-hidden="true">── apply / get / watch ──▶</span>
				<div class="topo-node node-cp">
					<span class="nm mono">sctld <span class="x3">×3</span></span>
					<span class="sub">single binary · API + scheduler + reconcilers + LB programmer</span>
					<span class="topo-chip mono">embeds cubestore · Raft quorum</span>
				</div>
			</div>
			<div class="topo-flow" aria-hidden="true">
				<span class="flow-pair mono"><b>desired state</b> ▼</span>
				<span class="flow-pair mono">▲ <b>status</b></span>
			</div>
			<div class="topo-band topo-band-2">
				<div class="topo-node node-lb">
					<span class="topo-conn-in mono" aria-hidden="true">◀── program ── endpoints loop</span>
					<span class="nm mono">external LBs</span>
					<span class="sub">nginx · hetzner · aws</span>
				</div>
				<div class="topo-node node-slet">
					<span class="nm mono">slet</span>
					<span class="sub">node agent · one per node</span>
					<ul class="slet-list">
						<li><span class="sl-k mono">drives Cells</span><span class="sl-v">the instances</span></li>
						<li><span class="sl-k mono">node-proxy</span><span class="sl-v">east-west · virtual service IP</span></li>
						<li><span class="sl-k mono">node-local PV</span><span class="sl-v">on datafs</span></li>
					</ul>
				</div>
			</div>
		</figure>
		<div class="arch-grid">
			<div class="lifecycle">
				<span class="lifecycle-title mono">Request lifecycle · the reconciliation flow</span>
				<ol class="lifecycle-list">
					{#each sc.lifecycle as step, i (i)}
						<li><span class="lc-n mono">{i + 1}</span><span>{@html step}</span></li>
					{/each}
				</ol>
				<p class="lifecycle-foot muted">{@html sc.lifecycleFootHtml}</p>
			</div>
			<div class="callout callout-note arch-callout">
				<div class="co-body">{@html sc.archCalloutHtml}</div>
			</div>
		</div>
	</section>

	<!-- 03 · differentiators -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">03</span><div><h2 class="fig-title">{sc.diffHeading}</h2><p class="fig-sub">{sc.diffLead}</p></div></div>
		<div class="diff-grid">
			{#each sc.differentiators as d (d.tag)}
				<div class="diff-card">
					<span class="diff-tag mono">{d.tag}</span>
					<h3>{d.title}</h3>
					<p class="muted">{@html d.bodyHtml}</p>
					{#if d.bullets}
						<ul class="diff-list">
							{#each d.bullets as b (b)}<li><span class="tick mono">→</span> {b}</li>{/each}
						</ul>
					{/if}
					{#if d.chips}
						<div class="cap-chips">
							{#each d.chips as c (c.label)}<span class={c.off ? 'off' : ''}>{c.label}</span>{/each}
						</div>
					{/if}
				</div>
			{/each}
		</div>
	</section>

	<!-- 04 · manifest -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">04</span><div><h2 class="fig-title">{sc.manifestHeading}</h2><p class="fig-sub">{@html sc.manifestLead}</p></div></div>
		<div class="manifest-row">
			<CodeBlock title="edge-api.yaml" code={sc.manifestYaml} titleIcon={true} />
			<div class="manifest-side">
				<p class="manifest-cmd-label mono">apply it · single node</p>
				<CodeBlock title="sctl — apply" code={`${sc.applyCmd}\n${sc.applyOut}`} copyable={false} />
				<p class="manifest-cmd-label mono" style="margin-top:var(--sp-4)">read state</p>
				<CodeBlock title="sctl — read state" code={`${sc.readCmd}\n${sc.readOut}`} copyable={false} />
				<div style="margin-top:var(--sp-4)"><Callout type="note" html={sc.manifestCalloutHtml} /></div>
			</div>
		</div>
	</section>

	<!-- 05 · components -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">05</span><div><h2 class="fig-title">{sc.componentsHeading}</h2><p class="fig-sub">{sc.componentsLead}</p></div></div>
		<figure class="fig" style="padding:0;overflow:hidden">
			<table class="matrix cube-matrix">
				<thead>
					<tr><th style="width:120px">Component</th><th>What it is</th><th style="width:34%">Kubernetes analogue</th></tr>
				</thead>
				<tbody>
					{#each sc.components as c (c.name)}
						<tr>
							<td><span class="cap-name mono">{c.name}</span></td>
							<td>{@html c.what}<div class="cap-note">{c.note}</div></td>
							<td><span class="mono dim">{c.k8s}</span></td>
						</tr>
					{/each}
				</tbody>
			</table>
		</figure>
		<p class="fig-cap">{@html sc.componentsCapHtml}</p>
	</section>

	<!-- 06 · features -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">06</span><div><h2 class="fig-title">{sc.featuresHeading}</h2><p class="fig-sub">{sc.featuresLead}</p></div></div>
		<div class="feature-grid">
			{#each sc.features as f (f.title)}
				<div class="feature">
					<div class="f-ico">
						{#if f.icon === 'reconcile'}
							<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12a8 8 0 0 1 14-5.3L20 8M20 12a8 8 0 0 1-14 5.3L4 16"></path><path d="M20 4v4h-4M4 20v-4h4"></path></svg>
						{:else if f.icon === 'consistency'}
							<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z"></path><path d="M9.5 12l1.8 1.8L15 10"></path></svg>
						{:else if f.icon === 'rollout'}
							<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 18V6M4 8h7M4 14h11"></path><circle cx="18" cy="8" r="2"></circle><circle cx="20" cy="14" r="2"></circle></svg>
						{:else if f.icon === 'volume'}
							<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="6" rx="7" ry="3"></ellipse><path d="M5 6v6c0 1.7 3.1 3 7 3s7-1.3 7-3V6M5 12v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"></path></svg>
						{:else if f.icon === 'secure'}
							<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="9" rx="2"></rect><path d="M8 11V8a4 4 0 0 1 8 0v3"></path></svg>
						{:else}
							<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"></rect><path d="M9 9h6v6H9zM2 9h2M2 15h2M20 9h2M20 15h2M9 2v2M15 2v2M9 20v2M15 20v2"></path></svg>
						{/if}
					</div>
					<h3>{f.title}</h3>
					<p>{@html f.bodyHtml}</p>
				</div>
			{/each}
		</div>
	</section>

	<!-- 07 · honest framing -->
	<section class="fig-block" use:reveal>
		<div class="fig-head"><span class="fig-num">07</span><div><h2 class="fig-title">{sc.framingHeading}</h2><p class="fig-sub">{@html sc.framingLead}</p></div></div>
		<div class="frame-grid">
			<div>
				<Callout type="tip" html={sc.framingWarnHtml} />
				<div style="margin-top:var(--sp-4)"><Callout type="warn" html={sc.framingTipHtml} /></div>
				<p class="muted" style="margin-top:var(--sp-5);font-size:var(--fs-sm)">{@html sc.scopeHtml}</p>
			</div>
			<div class="ladder">
				<span class="ladder-title mono">{sc.ladderTitle}</span>
				<ol class="ladder-list">
					{#each sc.milestones as m (m.id)}
						<li class="lad" class:active={m.done}><span class="lad-id mono">{m.id}</span><span class="lad-txt">{m.text}</span></li>
					{/each}
				</ol>
			</div>
		</div>
	</section>

	<div class="prevnext" use:reveal>
		<a href="/architecture"><div class="dir">← Back to</div><div class="ttl">Architecture &amp; the Cell model</div></a>
		<a href="/status" class="next"><div class="dir">Check →</div><div class="ttl">What works today</div></a>
	</div>
</main>

<Footer />

<style>
	/* core idea split */
	.cube-split { display: grid; grid-template-columns: 0.95fr 1.05fr; gap: var(--sp-6); align-items: stretch; }
	@media (max-width: 880px){ .cube-split { grid-template-columns: 1fr; } }
	.cube-prose { align-self: center; }
	.cube-prose p { font-size: var(--fs-body); }
	.cube-tagline { margin-top: var(--sp-5); font-size: var(--fs-lead); color: var(--accent); font-weight: 600; letter-spacing: -0.01em; padding-top: var(--sp-4); border-top: 1px solid var(--border); }

	/* cell anatomy */
	.cell-fig { padding: var(--sp-5); }
	.cell-head { display: flex; align-items: center; justify-content: space-between; gap: var(--sp-3); flex-wrap: wrap; padding-bottom: var(--sp-4); margin-bottom: var(--sp-4); border-bottom: 1px dashed var(--border-strong); }
	.cell-title { color: var(--accent); font-size: var(--fs-sm); font-weight: 600; }
	.cell-parts { display: grid; grid-template-columns: 1fr 1fr; gap: var(--sp-3); }
	@media (max-width: 480px){ .cell-parts { grid-template-columns: 1fr; } }
	.cell-part { background: var(--surface-2); border: 1px solid var(--border); border-radius: var(--r-sm); padding: var(--sp-3) var(--sp-4); border-left: 2px solid var(--accent-tint-strong); }
	.cell-part b { display: block; font-size: var(--fs-sm); color: var(--text); }
	.cell-part i { font-style: normal; display: block; font-size: var(--fs-xs); color: var(--text-dim); margin-top: 3px; line-height: 1.4; }

	/* removed strip */
	.removed-strip { margin-top: var(--sp-5); padding: var(--sp-5); border: 1px solid var(--border); border-radius: var(--r-md); background: var(--surface); }
	.removed-label { font-size: var(--fs-micro); text-transform: uppercase; letter-spacing: var(--tracking-label); color: var(--text-dim); display: block; margin-bottom: var(--sp-3); }
	.removed-list { display: flex; flex-wrap: wrap; align-items: center; gap: var(--sp-3); }
	.removed { font-family: var(--font-mono); font-size: var(--fs-xs); padding: .3rem .6rem; border-radius: var(--r-xs); background: var(--muted-chip); color: var(--text-faint); text-decoration: line-through; border: 1px solid var(--border-faint); }
	.removed-arrow { color: var(--text-dim); font-size: var(--fs-body); }
	.kept { font-size: var(--fs-sm); font-weight: 600; padding: .3rem .7rem; border-radius: var(--r-xs); background: var(--ok-tint); color: var(--ok); }

	/* differentiators */
	.diff-grid { display: grid; grid-template-columns: 1fr 1fr; gap: var(--sp-4); }
	@media (max-width: 820px){ .diff-grid { grid-template-columns: 1fr; } }
	.diff-card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg); padding: var(--sp-6); }
	.diff-tag { font-size: var(--fs-micro); text-transform: uppercase; letter-spacing: var(--tracking-label); color: var(--accent); }
	.diff-card h3 { font-size: var(--fs-h4); margin: var(--sp-3) 0 var(--sp-3); }
	.diff-card p { font-size: var(--fs-sm); color: var(--text-muted); }
	.diff-list { list-style: none; padding: 0; margin-top: var(--sp-4); display: flex; flex-direction: column; gap: var(--sp-2); }
	.diff-list li { font-size: var(--fs-sm); color: var(--text-muted); display: flex; gap: var(--sp-2); align-items: baseline; }
	.diff-list .tick { color: var(--accent); flex: none; }
	.cap-chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: var(--sp-4); }
	.cap-chips span { font-family: var(--font-mono); font-size: var(--fs-micro); padding: .25rem .5rem; border-radius: var(--r-xs); background: var(--ok-tint); color: var(--ok); border: 1px solid transparent; }
	.cap-chips span.off { background: var(--muted-chip); color: var(--text-faint); text-decoration: line-through; }

	/* manifest */
	.manifest-row { display: grid; grid-template-columns: 1.35fr 1fr; gap: var(--sp-5); align-items: start; }
	@media (max-width: 880px){ .manifest-row { grid-template-columns: 1fr; } }
	.manifest-cmd-label { font-size: var(--fs-micro); text-transform: uppercase; letter-spacing: var(--tracking-label); color: var(--text-dim); margin-bottom: var(--sp-3); }

	/* components table */
	.cube-matrix { width: 100%; }
	.cube-matrix tbody td:first-child { white-space: nowrap; }
	.cube-matrix .cap-name { color: var(--accent); }
	.cube-matrix tbody td:last-child .mono { font-size: var(--fs-xs); }
	.cap-note { font-size: var(--fs-xs); color: var(--text-dim); margin-top: 4px; }

	/* honest framing */
	.frame-grid { display: grid; grid-template-columns: 1.1fr 0.9fr; gap: var(--sp-6); align-items: start; }
	@media (max-width: 820px){ .frame-grid { grid-template-columns: 1fr; } }
	.ladder { background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-md); padding: var(--sp-5); }
	.ladder-title { font-size: var(--fs-micro); text-transform: uppercase; letter-spacing: var(--tracking-label); color: var(--text-dim); display: block; margin-bottom: var(--sp-4); }
	.ladder-list { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: var(--sp-2); }
	.lad { display: flex; gap: var(--sp-3); align-items: baseline; padding: var(--sp-3) var(--sp-4); border: 1px solid var(--border); border-radius: var(--r-sm); background: var(--surface-2); }
	.lad.active { border-color: var(--accent-tint-strong); background: var(--accent-tint); }
	.lad-id { flex: none; font-size: var(--fs-xs); color: var(--text-dim); width: 48px; }
	.lad.active .lad-id { color: var(--accent); }
	.lad-txt { font-size: var(--fs-sm); color: var(--text-muted); }
	.lad.active .lad-txt { color: var(--text); }

	/* topology diagram */
	.topo { display: flex; flex-direction: column; gap: 0; }
	.topo-band { display: flex; gap: var(--sp-4); align-items: stretch; }
	.topo-band-2 { gap: var(--sp-4); }
	@media (max-width: 760px){ .topo-band, .topo-band-2 { flex-direction: column; align-items: stretch; } }
	.topo-node { background: var(--surface-2); border: 1px solid var(--border); border-radius: var(--r-md); padding: var(--sp-4) var(--sp-5); display: flex; flex-direction: column; gap: 4px; flex: 1; min-width: 0; }
	.topo-node .nm { font-size: var(--fs-body); font-weight: 600; color: var(--text); }
	.topo-node .nm .x3 { color: var(--accent); font-size: var(--fs-sm); }
	.topo-node .sub { font-size: var(--fs-xs); color: var(--text-dim); line-height: 1.45; }
	.node-cli { flex: 0 0 auto; min-width: 120px; justify-content: center; }
	.node-cp { border-left: 2px solid var(--accent-tint-strong); }
	.topo-chip { align-self: flex-start; margin-top: 6px; font-size: var(--fs-micro); padding: .2rem .5rem; border-radius: var(--r-xs); background: var(--accent-tint); color: var(--accent); border: 1px solid var(--accent-tint-strong); }
	.topo-conn { align-self: center; flex: 0 0 auto; color: var(--text-dim); font-size: var(--fs-xs); white-space: nowrap; padding: 0 var(--sp-2); }
	@media (max-width: 760px){ .topo-conn { align-self: flex-start; padding: var(--sp-2) 0; } }
	.topo-flow { display: flex; gap: var(--sp-6); justify-content: center; padding: var(--sp-3) 0; }
	.flow-pair { font-size: var(--fs-xs); color: var(--text-dim); }
	.flow-pair b { color: var(--accent); font-weight: 600; }
	.node-lb { justify-content: center; }
	.topo-conn-in { font-size: var(--fs-micro); color: var(--text-dim); margin-bottom: 4px; }
	.node-slet { border-left: 2px solid var(--accent-tint-strong); }
	.slet-list { list-style: none; padding: 0; margin: var(--sp-3) 0 0; display: flex; flex-direction: column; gap: 6px; }
	.slet-list li { display: flex; flex-wrap: wrap; gap: 6px; align-items: baseline; }
	.slet-list .sl-k { font-size: var(--fs-xs); color: var(--text); }
	.slet-list .sl-v { font-size: var(--fs-micro); color: var(--text-dim); }

	/* architecture: lifecycle + facts */
	.arch-grid { display: grid; grid-template-columns: 1.1fr 0.9fr; gap: var(--sp-6); align-items: start; margin-top: var(--sp-5); }
	@media (max-width: 820px){ .arch-grid { grid-template-columns: 1fr; } }
	.lifecycle { background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-md); padding: var(--sp-5); }
	.lifecycle-title { font-size: var(--fs-micro); text-transform: uppercase; letter-spacing: var(--tracking-label); color: var(--text-dim); display: block; margin-bottom: var(--sp-4); }
	.lifecycle-list { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: var(--sp-3); }
	.lifecycle-list li { display: flex; gap: var(--sp-3); align-items: baseline; font-size: var(--fs-sm); color: var(--text-muted); line-height: 1.5; }
	.lc-n { flex: none; width: 22px; height: 22px; display: inline-flex; align-items: center; justify-content: center; font-size: var(--fs-xs); color: var(--accent); background: var(--accent-tint); border: 1px solid var(--accent-tint-strong); border-radius: var(--r-xs); }
	.lifecycle-foot { margin-top: var(--sp-4); padding-top: var(--sp-4); border-top: 1px solid var(--border); font-size: var(--fs-sm); }
	.arch-callout { align-self: stretch; }

	/* feature grid */
	.feature-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: var(--sp-4); }
	@media (max-width: 820px){ .feature-grid { grid-template-columns: 1fr 1fr; } }
	@media (max-width: 540px){ .feature-grid { grid-template-columns: 1fr; } }
	.feature { background: var(--surface); border: 1px solid var(--border); border-radius: var(--r-lg); padding: var(--sp-5); }
	.feature h3 { font-size: var(--fs-h4); margin: var(--sp-3) 0 var(--sp-2); }
	.feature p { font-size: var(--fs-sm); color: var(--text-muted); }
	.f-ico { width: 40px; height: 40px; display: inline-flex; align-items: center; justify-content: center; color: var(--accent); background: var(--accent-tint); border: 1px solid var(--accent-tint-strong); border-radius: var(--r-md); }
	.f-ico svg { width: 22px; height: 22px; }
</style>
