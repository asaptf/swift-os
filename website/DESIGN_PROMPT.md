# Claude Design prompt — swift-os website

Paste the block below into Claude Design. It is self-contained.

---

## Brief

Design a **AAA-class marketing + documentation website** for **swift-os**, an
experimental-but-real operating system written entirely in **Embedded Swift**
for `aarch64`. The bar is a flagship product site — the polish, restraint, and
confidence of **Apple's product pages** — fused with a quiet technical,
terminal-flavored soul. Premium, calm, exceptionally readable, with **clear
infographics** and **subtle, purposeful motion**. Fully **responsive
(mobile-first)** and **accessible**.

This is a site about the *project*, not its author.

## What swift-os is (use for accurate copy)

A full, modern OS in Embedded Swift, valuing *efficient, reliable minimalism* — a
small trusted core, capability-based isolation, fast deterministic boot, signed
immutable images. It is **not** a Linux clone and not a Unix-compatibility
exercise; it removes legacy rather than emulating it. It boots on QEMU AArch64,
isolates processes with the MMU, runs a native Swift userland, has an in-kernel
TCP/IP stack and its own HTTP server, a capability/principal security model, and
a package system. Flagship profile: application & AI hosting.

**The hook:** most hobby OSes stop at "Hello from the kernel." swift-os runs a
real userland, networking, and tools — and *this very website is served from
swift-os itself* (a swift-os host running Node.js).

**Tone:** experimental, but real. Ambitious yet honest. Never overclaim — an
explicit "what works today" status page carries the honesty so the rest of the
site can be confident.

## Audience

Swift / embedded / OS-dev engineers and enthusiasts, plus curious newcomers who
do not know OS internals. Every page must work for a smart non-expert: explain
jargon, never condescend.

## The 30-second test (drives the landing)

A first-time visitor must get four answers fast, in this order:
1. **What is it?** An experimental OS written in Embedded Swift.
2. **Does it really work?** Yes — it boots, runs userland + networking + tools,
   and serves this site.
3. **How do I run it?** clone → install tools → `make run`.
4. **Where do I read more?** Docs, organized by role.

## Visual language (Apple-inspired, technical soul)

- **Restraint over decoration.** Generous whitespace, strong typographic
  hierarchy, one idea per section, large confident headlines, short body copy.
  Let content breathe; never crowd.
- **Color:** dark theme as default, with an equally polished light theme.
  Near-neutral base (true blacks/greys in dark; warm off-whites in light). A
  single **Swift-orange** accent (`#F05138`-family) used sparingly for emphasis,
  links, and key CTAs. Avoid gradients-as-noise; if gradients appear, keep them
  subtle and physical (Apple-like soft depth), never garish.
- **Typography:** a clean humanist/system sans for UI and prose (SF Pro / Inter
  feel); a refined **monospace** (SF Mono / JetBrains Mono feel) for code,
  terminal output, command names, and small technical labels. Large, airy line
  spacing in long-form reading.
- **Surfaces & depth:** soft, low-contrast elevation; hairline borders; gentle
  rounded corners; tasteful frosted/blur on sticky nav. No heavy drop shadows.
- **Imagery:** crisp terminal recordings/screenshots framed in clean device-free
  "window" chrome; vector infographics over photos.

## Motion (subtle, never gratuitous)

- Quiet scroll-reveal (fade + small translate) as sections enter; staggered for
  groups of cards. Short, eased, ~200–400ms.
- A hero **animated terminal** that types a real boot + login sequence
  (`swift-os login: root` → `id` → output), looping calmly.
- Micro-interactions: button/press states, copy-to-clipboard confirmation,
  tab/accordion transitions, animated status counters on the live-proof widget.
- Infographics may animate *once* on enter (e.g. a packet flowing through the
  network stack), then rest. No parallax carnival, no autoplay video walls.
- **Always respect `prefers-reduced-motion`** — degrade to instant, static.

## Pages to design (priority order)

1. **Landing.** Hero: bold one-line statement + animated terminal + three CTAs
   (*Run locally*, *Read the docs*, *GitHub*), and a slot for a future *Try in
   your browser* CTA. Below: a **"Live proof"** widget (served by SwiftOS:
   "Served by SwiftOS" badge, kernel build / commit hash, uptime, current
   profile QEMU·AArch64·Node.js·HTTP, a boot-log snippet, "How this is hosted"
   link). Then a compact **feature grid** (Minimalism, Capability security,
   Native Swift userland, Networking + HTTP, AI hosting, Immutable images), an
   **architecture preview**, a "what works today" teaser, and a "start learning"
   row. Keep it short and confident.
2. **Status — what works today.** A credibility page: a clean **capability
   matrix** (rows: AArch64 boot, QEMU virt, UEFI/GPT, Swift userland,
   filesystem, networking, HTTP server, packages, SMP, Linux ABI, Docker, x86-64
   — columns/labels: Works / Primary / Active hardening / Non-goal, with calm
   color-coded chips), a **roadmap** (done / active / planned badges), a
   **Known limitations / non-goals** block (framed as philosophy), and a
   **Test coverage** block surfacing real acceptance gates.
3. **Quickstart / Run locally.** Beginner-first, step-by-step, **tabbed by
   host/profile** (macOS Apple Silicon = primary; Linux = if/when supported;
   UEFI; QEMU networking; VirtualBox ARM). Numbered steps, copy-button code
   blocks, callouts, expected-output panels. A first-login card (`root` /
   `swordfish`).
4. **Documentation reader.** Three-pane docs layout: left sidebar (sectioned +
   a **role-based "choose your path"** hub), center prose with excellent reading
   measure and typography, right-hand page TOC. Sticky search, prev/next,
   "edit on GitHub", code highlighting + copy. This must feel best-in-class for
   long reading — think Stripe/Apple docs quality.
5. **Learn / Concepts + Glossary.** Friendly explainer cards/articles (what is a
   kernel, EL0/EL1, MMU isolation, capabilities, the two-tier filesystem, why
   Embedded Swift). Inline **glossary tooltips** for jargon site-wide.
6. **Architecture (infographics).** A set of clean vector diagrams (see below).
7. **Articles (deep dives).** Editorial long-form layout — large hero, refined
   reading column, pull quotes. Seed: *Why Swift for an OS?*, *How SwiftOS
   boots*, *Serving this website from SwiftOS*.
8. **Command tour.** A two-column beginner walkthrough: a real terminal session
   on one side, plain-language annotations aligned to each step on the other.
9. **FAQ**, **Community / Contribute**, conditional **Downloads**.

## Infographics to design (vector, on-brand, animatable-once)

- **Boot flow:** firmware/QEMU → UEFI loader → kernel → init → login.
- **EL0/EL1 stack:** userland Swift tools · syscall boundary · kernel
  subsystems, with the privilege line clearly drawn.
- **Two-tier filesystem:** signed read-only `base.img` + writable `/tmp` tmpfs
  (with "vanishes on reboot" motif).
- **Networking:** virtio-net → in-kernel TCP/IP stack → `/bin/httpd`, with an
  optional animated packet traversal.
- **Security model:** principal → capability mask → handle rights (not uid==0).
- **Package system:** `.swpkg` → package store → signed static repository.

Make these legible at a glance, labeled, and equally clear in light/dark.

## Components / design system

Deliver tokens + components: color tokens (light/dark), type scale, spacing
scale, radius/elevation; nav (sticky, blurred, responsive with mobile drawer),
buttons/CTAs, code block (with copy + filename chrome), callout/admonition
(note/warning/tip), status chip/badge, tabs, accordion, capability-matrix table,
card grid, sidebar + TOC, search field, footer (license, GitHub, "Hosted by
SwiftOS itself + Node.js").

## Responsive & accessibility (required)

- Mobile-first; graceful from 320px to ultrawide. Sidebar collapses to a drawer;
  multi-column infographics restack vertically; tabs remain usable on touch.
- WCAG AA contrast in both themes; visible focus states; full keyboard nav;
  semantic landmarks; alt text for diagrams; `prefers-reduced-motion` honored.
- Performance is part of the aesthetic: lightweight, fast first paint, minimal
  JS (the real site is static — Astro + Starlight). Don't design anything that
  demands a heavy SPA framework.

## Deliverables

High-fidelity mockups for the priority pages (desktop + mobile), the component
library, design tokens, and the infographic set — in both dark (default) and
light themes. Where possible, produce clean, semantic **HTML/CSS** that maps
onto a static Astro + Starlight build.

## Do / don't

- **Do:** restraint, hierarchy, whitespace, honest confidence, crisp vector
  infographics, calm motion, superb readability.
- **Don't:** stock-photo hero clutter, neon gradients, bouncing animations,
  autoplay video, marketing fluff, overclaiming, tiny low-contrast text, or
  anything that buries the four 30-second answers.
