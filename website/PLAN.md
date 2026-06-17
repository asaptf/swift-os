# swift-os website — plan

> **Stack update (superseded):** the original "Astro + Starlight (static)" decision
> below was changed during implementation to **SvelteKit (SSR) + Strapi (CMS)**,
> per the project owner. Docs are still ingested from `../docs` as the single
> source of truth; marketing/status/glossary/FAQ/articles now live in Strapi.
> The implemented site is in `apps/` — see [README.md](README.md). The sitemap,
> aesthetic, features, and tone notes below still apply.

The public website for the swift-os project. It tells the story of the OS,
gives beginner-friendly instructions to run it locally, and provides a
first-class reader for the project's documentation.

This is a **host-side / web** artifact, separate from the OS itself. It does not
follow the OS milestone workflow in the root `CLAUDE.md`; it has its own build.

## Goals

1. **Tell the story.** swift-os is an experiment — a full OS written in Embedded
   Swift — but a real, working one. The site itself is served by a swift-os
   server running Node.js (the hosting narrative below).
2. **Make it runnable by anyone.** Clear, beginner-friendly instructions: what
   QEMU is, how to install prerequisites, download, build, boot, and log in.
3. **Read the docs comfortably.** A polished documentation reader over the ~50
   markdown files already in `docs/` — sidebar nav, search, table of contents,
   prev/next, syntax highlighting.
4. **Responsive.** Works well on phone, tablet, and desktop.

## Decisions (settled)

- **Stack:** Astro + Starlight (static output; docs-reader features built in).
- **Language:** English (matches all project docs and comments).
- **Docs reader:** auto-ingest **all** markdown from `../docs/`, grouped into
  sections — no content duplication, single source of truth.
- **Hosting narrative:** the site is served by a swift-os server running Node.js.
  (Node.js hosting is a Phase 2 goal; this becomes literally true by launch.
  swift-os's own `/bin/httpd` static server is a real, shippable fallback story.)

## Aesthetic

Aligned with the project's stated value — *efficient, reliable minimalism*.

- Minimal, terminal-flavored, monospace accents.
- Swift-orange accent on a neutral (light/dark) base; dark default.
- No visual clutter; content-first; fast to load (fits the "lightweight" ethos).
- An animated terminal on the landing page replaying boot + login.

## Sitemap

| Page | Purpose | Source material |
| --- | --- | --- |
| **Home / Landing** | The hook: an OS written entirely in Swift. "Experiment, but it works." Live note that the page is served by swift-os. Key facts (tiny kernel, capability isolation, fast boot). CTAs: *Run it* / *Read the docs*. | `README.md`, `PHILOSOPHY.md` |
| **The Experiment / About** | Story, philosophy, why Swift, what works today and what is honestly still future. | `PHILOSOPHY.md`, `README.md` status section |
| **Quickstart — run it locally** | Beginner-friendly, step-by-step: what QEMU is, install prerequisites, get the code, build, `make run`, first login (`root`/`swordfish`). Two tracks: "try fast" and "full build". Copy buttons, callouts. | `GETTING_STARTED.md`, `INSTALLATION_GUIDE.md`, `README.md` build section |
| **Installation profiles** | Profile chooser beyond the quickstart: Direct QEMU (serial), UEFI/GPT, Graphical, VirtualBox ARM — each with full steps and a "which should I pick?" guide. | `INSTALLATION_GUIDE.md`, `VIRTUALBOX.md` |
| **Examples & demos** | Copy-paste, reproducible workflows: "run an HTTP server in a minute", networking, packages, AI hosting. Distinct from the Gallery (which is visuals). | `EXAMPLES.md`, `APPLICATION_COOKBOOK.md` |
| **Glossary** | Beginner term dictionary (kernel, EL0/EL1, base image, tmpfs, principal, capability, package payload, …). | `CONCEPTS.md` |
| **Learn / Concepts** | Friendly explainer articles for non-experts: what a kernel is, EL0/EL1, MMU isolation, capabilities, the two-tier filesystem, packages, services. Rewritten approachably, with diagrams. | `CONCEPTS.md` (rewritten), `ARCHITECTURE.md` |
| **Architecture** | Visual diagrams: EL0/EL1 stack, boot flow, repository map. | `ARCHITECTURE.md`, `README.md` |
| **Documentation (reader)** | All ~50 docs, grouped, searchable, with TOC + prev/next + "edit on GitHub". | auto-ingested `docs/*.md` |
| **Status — what works today** | Honest, concrete trust page: a capability **matrix** (Works / Primary / Active hardening / Non-goal), phase roadmap with done/active/planned badges, an explicit **Known limitations / non-goals** block (framed as philosophy, not weakness), and a **Test coverage** block surfacing the real acceptance gates (`make test`, SMP smoke/readiness, `c5-*`, package/network/boot assertions) as a credibility signal. | `README.md` roadmap + non-goals, `RISK_REMEDIATION_ROADMAP.md`, `TESTING_GUIDE.md` |
| **Articles (deep dives)** | Narrative long-form posts — the shareable hooks. Each is a standalone story. Seed set: *Why Swift for an OS?* (manifesto), *How SwiftOS boots*, *Serving this website from SwiftOS*, *Writing native Swift userland tools*, *Building a TCP/IP stack in Swift*. | `PHILOSOPHY.md`, `ARCHITECTURE.md`, `NETWORKING_GUIDE.md`, `DEVELOPER_GUIDE.md` |
| **Command tour** | Beginner walk-through of one real session (login → `id` → `ls -l /` → `cat /etc/motd` → make a tmpfs file → `top`) with plain-language annotations beside each step ("you logged in as principal 1", "base FS is read-only", "/tmp vanishes on reboot"). | `GETTING_STARTED.md`, `COMMAND_REFERENCE.md` |
| **Syscall & capability map** | Interactive cheat-sheet: the swift-os syscall table and capability bits / handle rights as a browsable, searchable visual reference. | `API_REFERENCE.md`, `CAPABILITIES.md` |
| **Gallery / demos** | Screenshots and terminal recordings of real demos: boot + login, `httpd`, `llmd` inference, package install. | captured from `make run` / demos |
| **Community / Contribute** | How to contribute, test, and develop; links to GitHub issues/PRs. About the project, not its authors. | `DEVELOPER_GUIDE.md`, `TESTING_GUIDE.md`, `PORTING_GUIDE.md` |
| **Downloads** *(conditional)* | Pre-built artifacts (kernel/disk images), if the project decides to publish them. Omit otherwise. | `RELEASE_NOTES.md`, release artifacts |
| **FAQ** | Common questions. | `FAQ.md` |

## Docs reader — ingestion approach

- A content collection / loader pulls `../docs/*.md` at build time.
- Group docs into sidebar sections (Overview, Getting Started, Concepts,
  Guides, Reference, Packages, Internals/Notes). A small mapping table assigns
  each file to a section + nice title + order; unmapped files land in a catch-all
  so nothing is silently dropped.
- **Role-based entry hub:** a docs landing that offers persona "tracks"
  (first-time operator, administrator, developer, AI hosting, …) mirroring the
  role map in `DOCUMENTATION.md`, in addition to the flat sectioned sidebar.
- Rewrite relative links (`docs/FOO.md`, `ports/README.md`) to site routes.
- Keep code fences, tables, and headings; generate per-page TOC from headings.

## Features checklist

- [ ] Responsive layout + mobile nav (hamburger, slide-in sidebar)
- [ ] Dark / light theme toggle (dark default)
- [ ] Full-text search across docs (Starlight built-in / Pagefind)
- [ ] Syntax highlighting + copy-to-clipboard on code blocks
- [ ] Sidebar + right-hand TOC + prev/next in docs
- [ ] "Edit on GitHub" links
- [ ] Animated terminal boot demo on landing
- [ ] Architecture diagrams
- [ ] Status badges on roadmap
- [ ] "Live proof" widget on landing — served by the swift-os host itself:
      "Served by SwiftOS" badge, kernel build / commit hash, uptime, current
      profile (QEMU / AArch64 / Node.js / HTTP), a boot-log snippet, and a
      "How this website is hosted" link to the deep-dive article
- [ ] Tabbed Quickstart by host/profile (macOS Apple Silicon = primary;
      Linux = if/when supported; UEFI boot; QEMU networking; VirtualBox ARM)
- [ ] Glossary tooltips — inline hover definitions for jargon across the site
- [ ] Interactive syscall + capability-bit map (browsable, searchable)
- [ ] Screenshots / terminal recordings of real demos (boot, httpd, llmd, pkg)
- [ ] SEO + Open Graph / Twitter card meta (important for HN / Reddit sharing)
- [ ] RSS feed for releases / updates
- [ ] Privacy-first analytics (optional, no third-party tracking)
- [ ] Beginner / advanced content tags where a page spans both levels

## Build & deploy

- `npm` workspace under `website/`. `npm run dev` / `npm run build` →
  static output in `website/dist/`.
- Output is plain static files — directly servable by Node.js (the launch
  hosting story) or by swift-os `/bin/httpd`.
- CI/preview deploy can mirror to a conventional static host during development.

## Proposed work phases

1. **Scaffold** — Astro + Starlight project, theme tokens, layout, nav shell,
   responsive + dark mode. Placeholder pages so the skeleton is navigable.
2. **Docs reader** — ingest `../docs`, section mapping, link rewriting, search.
3. **Authored pages** — Landing (with live-proof widget), About, Quickstart,
   Installation profiles, Learn, Glossary, Architecture, Status (matrix +
   limitations + test coverage), Command tour, FAQ.
4. **Articles** — the deep-dive posts, starting with *Why Swift for an OS?* and
   *Serving this website from SwiftOS*.
5. **Polish** — terminal animation, diagrams, copy buttons, glossary tooltips,
   SEO/OG meta, RSS, performance pass, final responsive QA.
6. **Deploy** — build, wire hosting (Node.js server narrative).
7. **Stretch** — in-browser WASM QEMU demo; prebuilt Downloads page once
   release artifacts exist.

## Stretch / future features (part of the design)

- **"Try in browser" (WASM-compiled QEMU)** — run swift-os directly in the
  browser so visitors can boot, log in, and poke at it with zero local setup.
  A large, separate effort (emulator toolchain, image delivery, performance),
  so it ships after the base site — but it is an explicit design goal, not a
  rejected idea. The landing and demo pages should leave a natural slot for it
  ("Try it in your browser" CTA next to "Run locally").

## Considered & rejected

- **Alternative stacks (Tailwind / React / Next.js / Hugo / VitePress / Nextra)**
  — evaluated and set aside. Astro + Starlight already provides responsive
  layout, dark mode, search, sidebar, and TOC out of the box; custom styling is
  layered on top without pulling in a heavier framework.

## Tone & accuracy notes

- **Experimental, but real** is the through-line: "not a Linux clone, not a Unix
  compatibility exercise — a working research OS in Embedded Swift you can build,
  boot, poke at, and read." Ambitious but honest; the *Status* page carries the
  honesty so the landing can be confident.
- **The 30-second test.** The landing must answer four questions fast: *What is
  it?* / *Does it really work?* / *How do I run it?* / *Where do I read more?*
- **Node.js hosting article must reconcile with public docs.** Public README
  lists Node.js/JVM hosting as Phase 2 forward work, while confirmed network
  tools today are `/bin/httpd`, `tcpget`, `tcpecho`, `udpecho`, `nslookup`,
  `llmd`. The "Serving this website from SwiftOS" article should be explicit
  about what is live vs experimental (e.g. "Node.js hosting runs on an
  experimental deployment branch; public-repo docs may lag the live deploy").
- **Downloads honesty.** No GitHub Releases exist yet → lead with "clone and
  build from source"; do not imply a stable prebuilt image. The Downloads page
  stays conditional until real release artifacts (`swift-os.img`, `base.img`,
  checksums, release notes) are published.

## Open items / to confirm later

- Domain / final hosting target.
- Whether to mirror docs into the repo or read live from `../docs` only at build.
- Visual identity details (logo / wordmark for swift-os).
