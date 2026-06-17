# swift-os website

The public website for **swift-os** — an experimental but real operating system
written entirely in Embedded Swift for `aarch64`.

It is a **server-rendered (SSR) SvelteKit** frontend backed by a **Strapi v5
CMS**, built to the dark / Swift-orange / monospace design system handed off from
Claude Design.

```
website/
├── apps/
│   ├── web/          SvelteKit (SSR via adapter-node) — the site
│   └── cms/          Strapi v5 (SQLite) — the content backend
├── scripts/dev.mjs   runs both together with prefixed output
├── PLAN.md           original product plan
└── DESIGN_PROMPT.md  the design brief
```

## Content model — hybrid

Following the plan, content is split between the CMS and the repo:

| Source | What |
| --- | --- |
| **Strapi** | Marketing pages (Home, Live-proof), Status (capability matrix, roadmap, non-goals, gates), Quickstart, Glossary, Articles, FAQ. Editable without a deploy. |
| **Repo `docs/*.md`** | The ~50 technical docs — ingested at request time by the docs reader, single source of truth. No duplication. |

The frontend always renders: every CMS fetch is best-effort and falls back to a
bundled copy of the content (`apps/web/src/lib/content/defaults.ts`), so the site
works even if Strapi is down. The Strapi seed (`apps/cms/src/seed-data.ts`) mirrors
those defaults, so a fresh database renders identically to the design.

## Prerequisites

- Node.js 20–24

## Quickstart

```bash
# from website/ — install both apps
npm run install:all

# run CMS + web together
npm run dev
```

- **Site:** <http://localhost:5180>
- **CMS admin:** <http://localhost:1337/admin>

On first run Strapi creates its SQLite database (`apps/cms/.tmp/data.db`),
**seeds** the swift-os content, and grants the public role read access — so the
REST API is immediately populated. Create your Strapi admin user the first time
you open the admin URL.

> **Ports:** the site is pinned to **5180**. Strapi's admin dev server uses
> `5173` (SvelteKit's usual default), so the site is deliberately moved off it —
> opening `:5173` shows the Strapi admin, not the site.

### Run them separately

```bash
npm run dev:cms     # Strapi develop  (:1337, admin bundler on :5173)
npm run dev:web     # SvelteKit dev   (:5180)
```

## Configuration

`apps/web/.env` (see `.env.example`):

| Var | Default | Purpose |
| --- | --- | --- |
| `STRAPI_URL` | `http://localhost:1337` | CMS REST base (server-side). |
| `STRAPI_TOKEN` | _(empty)_ | Optional read token; not needed with the seeded public read. |
| `DOCS_DIR` | `../../../docs` | Path to `swift-os/docs`, resolved from `apps/web`. |
| `PUBLIC_REPO_URL` | swift-os GitHub | Used for "Edit on GitHub" links. |

## Pages

`/` landing · `/status` · `/quickstart` · `/docs` + `/docs/[slug]` (three-pane
reader over the repo docs) · `/architecture` (infographics) · `/design` (the
design-system sheet) · `/articles` + `/articles/[slug]` · `/faq`.

## Design system

Tokens and components are ported verbatim from the Claude Design handoff:

- `src/lib/styles/{tokens,components,site-chrome,pages}.css` — dark default +
  warm light theme, one Swift-orange accent, Hanken Grotesk + JetBrains Mono.
- `src/lib/components/` — Nav, Footer, Terminal (animated boot/login), CodeBlock
  (copy + terminal highlighting), Callout, Tabs, Accordion, Badge, Icon, …
- Behaviors as Svelte actions: `reveal`, `countUp`/`uptime`, `scrollspy`,
  `gloss` (inline glossary tooltips). All honor `prefers-reduced-motion`.

## Build & deploy

```bash
npm run build        # builds cms admin + web (Node server in apps/web/build)
npm run start:cms    # strapi start
npm run start:web    # node apps/web/build  (set STRAPI_URL to the live CMS)
```

The web app uses `@sveltejs/adapter-node`, producing a plain Node server — which
is exactly the launch hosting story ("served by swift-os + Node.js"). For
production, point `DATABASE_CLIENT=postgres` in the CMS env and set `STRAPI_URL`
in the web env to the deployed CMS.
