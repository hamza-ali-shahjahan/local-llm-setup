# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

## [1.19.0] — 2026-06-22

### Added
- **A polished light mode — with a header toggle.** The builder chrome now ships a refined **dark**
  theme *and* a new **light** theme; flip between them with the ☾/☀ button in the top-right. Your
  choice is **remembered** (`localStorage`) and applied *before first paint*, so there's no flash on
  reload.

### Changed
- **The whole chrome is now a CSS design-token system.** The ~50 hardcoded colours scattered through
  the UI became a clean set of semantic CSS variables (`--bg`, `--surface`, `--text`, `--accent`,
  `--border`, semantic `--ok/--warn/--danger`, shadows…), with a full light-theme override. The
  **refined blue accent (`#2b6cff`)** is kept across both themes; near-duplicate greys were
  consolidated so the palette reads more consistently even in dark. Subtle interactive polish:
  smoother button transitions and an accent-tinted border on hover.
- Pure frontend change — no backend, no new dependencies, still a single offline HTML file.

## [1.18.0] — 2026-06-21

### Added
- **Install models straight from Capabilities — it's now a real install hub.** Every coder +
  reasoner tier your machine can run gets a one-click **⬇ Install** button (with its download size),
  alongside the existing one-click vision install. It does the *proper* job — pulls each base model,
  then creates its context-tuned alias (`num_ctx 8192`) exactly like the installer (e.g.
  `qwen2.5-coder:32b` → `qwen2.5-coder-32b-8k`) — so the models match a fresh setup and the builder
  picks them up immediately. Unrunnable tiers stay locked ("Needs more RAM"); installed ones show ✓.
  The auto-install-at-setup flow is unchanged — this just lets you add or upgrade a tier from the UI.

## [1.17.1] — 2026-06-21

### Changed
- **Capabilities shows the real model name on every entry**, in a clean muted line — not just on
  the vision row. Each tier now reads e.g. `qwen2.5-coder:14b · deepseek-r1:14b`, and the vision row
  is simply **Vision model** + `qwen2.5vl:7b`, so the whole list looks uniform.
- **The model picker refreshes itself after a vision install**, so the vision model (`qwen2.5vl`,
  badged "Sees images") shows up in the **⚡ Auto** dropdown immediately — no page reload needed.

## [1.17.0] — 2026-06-21

### Added / Changed
- **Sharper clones via headroom-style token compression + forcing.** The render-based inspect used
  to hand the coder a bloated dump of design tokens (every font-size, duplicate colours, raw
  spacing) — which a local 14B mostly drops on the floor. Now the digest is **compressed at the
  source** (dedup, cap, round px like `18.52px → 18px`, drop low-signal spacing), so every
  tool-output and clone spec built from it is lean; and the clone spec **forces the few high-signal
  tokens** — exact corner radii, the key box-shadow, and the type scale — as *must-implement*
  values. Leaner input, used instead of ignored. (Directly targets the fonts/tokens gap.)
- **16k context for clones** (up from 8k) — the full render-based spec *and* a complete HTML file
  now both fit, so the coder stops truncating on complex pages (the cause of thin, low-scoring
  first passes).
- **More vision-critique rounds** — 3 by default, 4 in Goal mode (up from 2) — so the visual pass
  keeps closing gaps.

## [1.16.2] — 2026-06-21

### Fixed
- **Agent mode no longer dumps code into the chat for web-app work.** With the Agent toggle on, a
  follow-up to a build or clone (e.g. *"that missed things — improve it"*) was routed into the raw
  tool loop, which emits `<fetch>`/`<extract>`/`<write>` and streams raw HTML into the chat instead
  of rendering it in the preview. The agent loop is now reserved for genuine tool tasks (shell,
  multi-file, backend, install); every web-app **build, edit, clone, or question** keeps its normal
  path — preview or answer — even with Agent on. (Extends the v1.12.2 clone carve-out to follow-ups
  and edits, so a power toggle never overrides task-correct routing.)

## [1.16.1] — 2026-06-21

### Fixed
- **Smooth task spinner (for real this time).** The "working" spinner jittered because the build
  bubble re-renders ~15×/s while streaming, recreating the spinner and restarting its rotation at
  0° each time. It's now a clean ring anchored to the page clock (a negative `animation-delay`), so
  a freshly-rendered spinner resumes mid-spin instead of snapping back — a continuous, smooth spin.
- **"View plan" now expands.** Clicking *Planned the build → view plan* opened nothing: the toggle
  read the `<details>` open state before the browser flipped it, set the wrong value, and the next
  repaint re-collapsed it. The toggle is deterministic now, so the plan the local model wrote
  actually shows.

### Changed
- **A clone never ends below its best.** Across the structural and vision refine rounds, the
  builder now keeps the **highest-scoring** version it produced and restores it at the end — so a
  weak refine round can't regress the result you're shown.

## [1.16.0] — 2026-06-21

### Added
- **One-click vision-model install** — the 🧩 Capabilities modal now has a real **⬇ Install**
  button for the vision model (`qwen2.5vl:7b`). It streams Ollama's download with a live progress
  bar and flips to **✓ Installed** on its own (with a "copy command" fallback and a Retry on
  error). No terminal needed.
- **Vision-critique clone loop** — once a vision model is installed, website clones get a visual
  pass: the builder screenshots your clone beside the original, a local vision model names the
  visual gaps (layout, spacing, colour, typography, missing sections), and the coder applies them
  and re-renders — ending on a fresh critique so the score matches what's on screen. Surfaces a
  👀 **Vision check** card (visual score + the fixes). New `--agent` endpoint `visioncritique`;
  the **Vision-critique clone loop** capability flips from *Soon* to **Live** when the model and
  the agent server are present. Falls back invisibly to the structural clone if no vision model is
  installed. New guide: [`docs/vision-model.md`](docs/vision-model.md).

### Changed
- **Clear, worded status in Capabilities** — models and capabilities now show colour-coded pills
  (**✓ Installed / Not installed / Needs more RAM / Soon**, and **Live / Inactive** for
  capabilities) instead of two near-identical green dots, so you can tell at a glance what you can
  actually use right now.

## [1.15.2] — 2026-06-21

### Changed
- **Plain-English Capabilities wording** — a locked model now reads *"needs ~48 GB of memory —
  more than your 24 GB, so it won't run here"* (and runnable ones say *"fits your 24 GB"*),
  instead of the confusing *"your 0 GB can't hold it."*

### Fixed
- **Smoother task spinner** — the rotating "working" indicator was a hard-seam border ring that
  looked like it glitched at one point; it's now a smooth gradient ring, slowed slightly.

## [1.15.1] — 2026-06-21

### Changed
- **Capabilities button moved next to the model picker** (was top-right, easy to miss).
- **The Capabilities modal is now live** — it polls every ~3s while open, so it reflects the
  agent server coming up or a model being pulled (e.g. the vision model) in real time, re-reading
  the installed-model list each tick.

### Fixed
- **No more false "0 GB — can't hold it" locks when the modal can't reach the detection endpoint**
  (e.g. an older running server). It degrades gracefully — shows what's installed plus a clear
  "re-run `--agent` to refresh the server" note, instead of locking every model.

## [1.15.0] — 2026-06-21

**Capabilities modal** — a 🧩 Capabilities button that shows, for *your* machine, what you can run, what's installed vs available to add, and what's coming.

### Added
- **Hardware-aware Capabilities modal.** A new **🧩 Capabilities** button (top-right) opens a
  modal that detects your machine — RAM, GPU/VRAM, OS → model tier, via a new
  `/api/agent/system` endpoint (stdlib-only, best-effort, graceful) — and shows an honest matrix:
  each model tier (7B / 14B / 32B / 70B) and the vision model marked **✅ active** (installed),
  **🟢 available** (your machine can run it, not installed — with the exact `ollama pull` to add
  it), or **🔒 needs more memory**; the live capabilities (cloning, fidelity score, Goal mode,
  agent tools) as active; and the roadmap (vision-critique loop, multi-file, web search,
  backend, deploy) as **🛠 coming soon**. So a first-timer sees exactly what they get on their
  specs — and what they're one step away from unlocking.

## [1.14.0] — 2026-06-21

**Higher-fidelity cloning** — render-based inspection on by default, a focused clone spec, and a fairer fidelity score. On disrupt.com this lifted the honest structural score from ~32% to ~46%.

### Added
- **Render-based site inspection, on by default.** `--agent` now sets up Playwright (in a
  dedicated venv) and runs the tool server from it, so cloning observes the *rendered* page —
  real computed palette (incl. brand accents like disrupt's tan), background images, real fonts,
  motion — instead of just raw HTML. Best-effort: if Playwright can't install, it falls back to
  the stdlib inspect + system-Chrome screenshots, so the server always starts.

### Changed
- **Focused clone spec.** The clone instruction now leads with the high-fidelity, achievable
  details (exact colours *with role hints*, the real brand fonts, section order, real copy +
  images) and drops the low-signal dump (font-size lists, spacing, per-element hover diffs) — an
  exhaustive spec overflowed the local 14B and it dropped most of it. Result: it reproduces the
  structure now (disrupt sections 54% → 100%).
- **Fairer fidelity score.** Palette/fonts are graded against the *dominant* colours/fonts (the
  few that define the look + what the focused spec feeds the model), not every minor overlay
  colour — matching the 16th subtle rgba doesn't move fidelity. *(This re-baselines clone scores
  — fairer, not inflated.)* On disrupt, palette 19% → 38%, fonts 14% → 25%.
- **Net:** disrupt.com clone fidelity **~32% → ~46%** (honest, structural). Higher *visual*
  fidelity is the next lever (a local vision model).

## [1.13.3] — 2026-06-21

### Fixed
- **Cleaner fonts when cloning a site.** The inspected font list was polluted with font *sizes*
  (`18`, `20`, `8.07` — from `--font-size-*` CSS variables), icon fonts (`webflow-icons`,
  fontawesome…) and CSS keywords (`unset`), and variable-font names came through unloadable
  (`Geist Variablefont Wght`). Now it's the real, loadable font names (`Geist`, `Source Serif`),
  so a clone can actually match the original's typography instead of trying to use "18" as a font.

## [1.13.2] — 2026-06-21

### Fixed
- **Reopening a chat now restores the whole story, not just the last message.** The goal card,
  the suggestion, the fidelity/coverage scores, the plan, the "refined the clone" steps and the
  verdict are rendered cards — they were never saved, so a reload showed only the raw model
  messages. The full visible transcript is now persisted per chat and restored on reopen, so the
  thinking, the decisions, and the scores all come back.

## [1.13.1] — 2026-06-21

### Changed
- **Clearer Goal messaging.** The Goal info tooltip + the clone suggestion no longer read as
  clone-only (Goal now works for any build), and the "needs --agent" note is disambiguated:
  Goal runs on the built-in **agent server** (already on whenever the toggle is enabled) and
  does **not** require the separate **Agent toggle**.

## [1.13.0] — 2026-06-21

**Goal mode grows beyond cloning** — it's now a general measurable-quality engine, not a clone tool.

### Added
- **Goal mode works for any build, not just clones.** Goal mode is built around a *scorer*; until
  now the only scorer was structural clone-fidelity, so the iterate-to-target loop only fired for
  clones. This adds a second scorer — **requirements coverage** — so Goal mode can forge a measurable
  goal for *any* build, then **build → grade which requirements are actually implemented (strict,
  model-graded) → feed the missing ones back → rebuild → re-grade**, until it hits the target or
  plateaus. *(Verified: "build a stopwatch with start/stop/reset and lap times" with Goal on → forged
  an auto-scored goal → built a working stopwatch → scored 100% coverage (4/4) → "Goal reached",
  logged.)* The forge picks the scorer automatically — clone → fidelity, a build with checkable
  requirements → coverage, a pure taste call → an honest "by inspection". Every run is still logged
  to `goal_runs.jsonl`.
- **Goal is suggested for multi-part builds,** not only clones — when a request has several
  requirements, the auto-recommend nudge offers Goal mode (iterate until complete).

### Changed
- The Goal info tooltip + nudges now describe the broader purpose — *"pin a measurable goal you
  approve, then iterate toward the target"* — rather than framing Goal as clone-only.

## [1.12.2] — 2026-06-21

### Fixed
- **Turning Agent on no longer breaks website cloning.** Agent mode used to route *everything* —
  including a clone request — into the raw approve-to-run tool loop, which is built for
  shell / multi-file tasks, not web building. On a clone it would fire model-driven `<inspect>`
  calls whose results got truncated, loop on "incomplete, retry", burn through the context, and
  dump a half-written HTML block in chat **with no preview**. Now a clone (and Goal mode) always
  uses the build/clone path — inspect → build → score → **live preview** — regardless of the
  Agent toggle; the raw tool loop is reserved for genuinely non-web tasks. *(Verified: an
  Agent-on clone of example.com now renders and scores 82%, with zero agent-loop artifacts.)*

### Added
- **Auto-recommend the right mode.** When a request would clearly benefit from a mode that's off,
  the builder offers it inline before running — *"🎯 This looks like a site clone — turn on Goal
  mode to set a fidelity target and iterate to it?"* for a clone, or *"🤖 … turn on Agent for
  shell + file tools"* for a multi-file / backend task — with **Turn on & continue · Continue
  without · Don't suggest again**. The powerful modes now find the user instead of hiding in a
  toggle. Nothing is forced; the safe defaults are unchanged.

## [1.12.1] — 2026-06-21

### Changed
- **The Agent + Goal toggles are now centered in the nav bar, each with an info icon.** They
  used to sit far to the right where a new user would miss them; now they're front-and-centre,
  and each has a hover **ⓘ** that explains in plain English what the mode does — and that it
  needs `--agent` — so the builder's most powerful modes are discoverable without prior
  knowledge. The header degrades gracefully at narrower widths.

## [1.12.0] — 2026-06-21

**Goal Mode** — the builder can turn a request into a *measurable goal*, get your
agreement, then pursue it on its own and log what it learns.

### Added
- **🎯 Goal Mode (a new builder toggle).** When on, a build/clone request first **forges a
  measurable goal** — the reasoner writes a capability statement, an exact metric + target,
  ≥2 numeric evals, an acceptance rule, non-goals, and two hard-won checks (*pin the metric*
  and *feasibility / ceiling*) — shows it as a card, and **waits for you to Agree** (or
  Adjust / Skip). Nothing autonomous runs before you agree.
- **Pursue + an honest verdict.** On Agree it pursues the goal — for a clone that's the
  existing build → score → iterate-to-target loop, now driven by *your* agreed target — and
  ends with a straight verdict: reached, or **plateaued at a ceiling** with the lever that
  would raise it named (a vision model for visual fidelity). It never fakes a number: the
  structural metric can't be gamed by a blank page, and goals with no automatic scorer
  (e.g. "make it feel premium") are flagged *by inspection* and degrade to a plain build.
- **A learning / limits log.** Every pursued goal is appended to
  `~/.local-llm-setup/goal_runs.jsonl` (capability, metric, every round's score, reached vs.
  ceiling) via a new `goallog` tool — so the setup *maps what it can and can't reach* over
  time rather than guessing. Read it back at `GET /api/agent/goalruns`.
- Verified end-to-end on the live builder (forge → agree → pursue → plateau-at-68% honest
  ceiling → logged). New offline tests in `tests/test_goal_log.py` cover the log (round-trip
  with a stamped timestamp, running count, malformed-line tolerance, limit, missing file).

## [1.11.1] — 2026-06-20

### Added
- **Clones match the page's theme (dark vs light).** Before building a clone, the builder
  takes a quick screenshot of the real page and measures its brightness (in-browser via
  canvas — no extra dependency), then tells the coder to use a dark or light treatment to
  match. Fixes the common case where a clone of a dark site (e.g. a near-black homepage)
  came out white. Verified: on a dark target the clone now renders dark (brightness ~214 →
  ~26, close to the real ~4) and the colour match jumps to ~90%. The eval harness measures
  the same theme so the improvement is tracked.

## [1.11.0] — 2026-06-20

Clones use the **real images** now, and there's an **objective fidelity eval** behind it.

### Added
- **Real-image cloning.** When recreating a page, the clone spec now feeds the inspected
  page's **actual `<img>` URLs** (and, when a headless render is available, its CSS
  **background-image** URLs) to the coder — with `picsum` only as a fallback. So a clone
  uses the site's own imagery instead of placeholders. The `<img>` path works everywhere
  (it comes from the stdlib parse, no extra deps); background images need the optional
  render and degrade gracefully. *(Verified: the URLs are hotlinkable and render in the clone.)*
- **`tools/clone_eval.py` — an autonomous clone-fidelity eval harness.** Screenshots the
  real page and each clone (full-page) and scores **visual** similarity — *edge-structure +
  layout + colour, with a blank-guard so a near-empty page can't game a high score by
  matching the background colour* — alongside the structural score, logging every run. Runs
  in a self-contained venv (`~/.local-llm-setup/.eval-venv`, Pillow + numpy). This is the
  objective measure behind the goal/iterate loop.

### Internal
- `inspect` surfaces a `bg_images` list (real CSS background-image URLs) when rendering.

## [1.10.1] — 2026-06-18

### Fixed
- **Cloning now recognizes the URL you'd actually type.** The clone trigger required a
  full `https://…` URL, so `www.disrupt.com` or a bare `disrupt.com` silently fell back to
  "build from imagination". It now accepts full URLs, `www.` hosts and bare domains
  (normalizing to `https://`), while still ignoring real filenames like `index.html`.
- **"clone …" works even with the Agent toggle on.** A clone request is now detected before
  the Agent/Auto branch, so flipping Agent on no longer bypasses the observe-then-build flow.

## [1.10.0] — 2026-06-17

Cloning gets **real depth**. Until now `inspect`/`extract` did a raw HTTP GET and
parsed the source HTML — so a JavaScript-rendered site (most modern marketing
pages) came back as an empty shell, and the only design signal was palette + fonts.
Now, when a headless browser is present, the page is **rendered first** and the
builder reads the page the way a human's browser sees it.

### Added
- **Render-based inspection (Phase 1).** `inspect`/`extract`/`score` now drive
  Playwright's headless Chromium — `goto(networkidle)` then read the **rendered DOM**
  and **computed styles**. JS-built sites (React/Next/Vue/etc.) finally read: real
  headings, sections, the colours/fonts that actually paint. Same SSRF guard as the
  raw fetch; falls back to the stdlib HTML fetch when no browser is available.
- **Motion + tokens + states (Phase 2).** The digest now carries a **type scale, corner
  radii, box-shadows and spacing**, the **motion language** (CSS `@keyframes`,
  animations, transitions), **hover interaction states** (computed-style deltas on the
  top interactive elements), **responsive breakpoint** signals (390/768/1280) and a
  **framework guess** (Tailwind/Bootstrap/Next/React/Vue/Alpine). All of it is fed into
  the clone build spec, so the coder reproduces the animations and feel, not just colours.
- **Fidelity scores motion + tokens (Phase 3).** `score` now weights motion overlap and
  design-token overlap alongside palette/fonts/sections/copy, and reports
  `motion_match`, `token_match` and `missing_animations`. The self-correct loop uses
  these to tell the model exactly which animations/tokens to add. A clone that drops the
  page's animations can no longer score 100%.

### Tested
- New `tests/test_clone_depth.py` (10 tests, offline + headless): proves a JS-rendered
  fixture reads only via the browser path (the raw parse is blind to it), that motion /
  tokens / hover states / breakpoints are captured, and that fidelity docks a partial
  clone for missing animations. Full suite: **29 tests green**.

## [1.9.1] — 2026-06-17

Polish on the v1.9.0 stylesheet extraction so the palette and fonts a clone is
built from (and scored against) are clean on complex sites.

### Fixed
- **Palette normalization** — alpha-suffixed hex (`#rrggbbaa`, `#rgba`) is collapsed to
  its base colour, so opacity variants no longer flood the palette and the real,
  most-used colours surface (e.g. tailwindcss.com now shows its actual brand blues).
- **Font extraction** — CSS-variable references are resolved (a var's inline fallback is
  kept, bare vars dropped), `@font-face` and `--font-*` definitions are read for real font
  names, and auto-generated "… Fallback" faces are filtered out. tailwindcss.com now yields
  `inter`, `source`, `plexMono`, `ubuntuMono` instead of `var(--font-inter)` noise.

## [1.9.0] — 2026-06-17

Makes cloning work on **real sites**, not just pages with inline styles. Found by
kicking the tires: most modern sites keep their colours and fonts in **external
stylesheet files**, which the page digest wasn't reading — so palette/fonts came
back empty on real sites.

### Changed
- **`inspect` / `extract` now fetch and parse linked stylesheets.** The page's
  `<link rel="stylesheet">` files are fetched (same SSRF guard — public hosts only,
  capped to a few sheets at 600 KB each, 8 s timeouts) and their CSS feeds the palette
  and font extraction. Real example: tailwindcss.com went from **0 → 16 colours / 8
  fonts**, Hacker News from **0 → 12 colours / 2 fonts**. This is what powers cloning,
  fidelity scoring, and the iterate loop on actual websites.
- `inspect` now reports `stylesheets_parsed`.

### Known polish (next)
- A few extracted tokens can be noisy (CSS-variable font references, alpha-suffixed
  hex) — to be normalized in a later pass.

## [1.8.0] — 2026-06-17

The clone now **improves itself toward a target**. After a clone, the builder scores
it, and if it's below the bar it feeds the exact gaps back to the coder, rebuilds, and
re-scores — so you watch the fidelity number climb instead of hand-holding each fix.

### Added
- **Iterate-to-target clone loop.** After the first clone + fidelity score, if it's under
  the target (75%) the builder automatically: lists the missing colours/fonts/sections →
  asks the coder to close exactly those gaps → rebuilds → re-scores. Bounded to a couple of
  rounds, and it stops early once it hits the target **or** a round stops improving. The
  chat shows the climb live — e.g. *"Refined the clone (round 1) · 40% → 75%"* and a
  *"Clone fidelity: 75% (↑ from 40%)"* card. Verified live end-to-end.

This is step one of the goal-driven loop in
[`docs/PRD-local-builder-v2-tools-and-goals.md`](docs/PRD-local-builder-v2-tools-and-goals.md);
an explicit `/goal` command + a write-a-goal skill are the planned next step.

## [1.7.0] — 2026-06-17

The builder can now **check its own work**: a clone is scored against the real page,
so "is this a good clone?" becomes a number with named gaps — the foundation for a
goal-driven, iterate-to-target loop.

### Added
- **Clone fidelity score** (`<score>` / shown automatically after a clone). Compares the
  rebuild to the original page on **palette, fonts, section coverage and copy** → a 0–100
  score plus the actionable deltas (e.g. *"unused original colours: #eee, #348"*). It is a
  **structural** diff, not pixel/perceptual — local coder/reasoner models aren't vision-
  capable, so the harness measures the design tokens instead of "looking" at the image.
- **Screenshot** (`<screenshot url>`). Renders a page via an **already-installed** headless
  Chrome/Chromium and captures a PNG — **no new dependency**; if no browser is found it
  degrades gracefully (screenshots simply unavailable). Shown inline in the Terminal pane.
- `inspect` now also accepts raw `{html}` (not just a URL), so a built page can be digested
  and scored without a round-trip.

### Changed
- `ping` reports the available tools and whether a headless browser was found.

### Notes
- Screenshot is **best-effort**: verified to find Chrome, but headless capture depends on the
  local browser/OS and was not exercised on every platform.

Gives the local agent **real tools** — so it can *observe the world and check its
work*, the way Claude Code and Lovable do — and a voice that **owns its mistakes**.
The headline: it can now **clone a real website** by looking at it, not guessing.

### Added
- **Web tools (stdlib only — no new dependencies).** The agent server gains four
  read-only tools, callable by the model:
  - `<inspect url>` — a structured digest of any public page: title, sections, headings,
    links, images, the **real colour palette and font families**.
  - `<extract url>` — just a page's design tokens (palette + fonts).
  - `<fetch url>` — a page's raw HTML.
  - `<read path>` — read a workspace file.
- **Website cloning.** Ask the builder to *"clone &lt;url&gt;"* and it **inspects the real
  page first**, then builds to its actual palette, fonts, sections and copy — rendered
  live in the preview. Observe-then-build instead of invent.
- **Self-correcting voice.** The agent narrates like a careful engineer: states intent,
  checks each result, and when something's wrong **names what + why + the fix** before
  redoing it — and never claims success without checking.

### Security
- The new network tool is **SSRF-guarded**: http/https only, **public hosts only**
  (loopback / private / link-local / cloud-metadata IPs are rejected, including on
  redirects), 15 s timeout, 2 MB cap. Bound to `127.0.0.1`, origin-locked as before.
- Read-only tools (read/fetch/inspect/extract) run directly; **mutating** tools
  (run/write) still require per-action approval in the UI.

### Changed
- `LLM_AGENT_PORT` env var overrides the agent server port (default `8765`).

## [1.5.0] — 2026-06-17

Makes the builder feel like a real tool, not a toy — it **plans before it builds**,
**picks its own model**, **fixes its own mistakes**, and shows you the work the way
Claude Code does. The honest trade-off (local models are weaker than frontier) is
handled by harness taste, not by hoping the model is smart.

### Added
- **Auto model routing.** A new **⚡ Auto** mode (default) picks the best model for
  each request — a coder to build, a reasoner to explain — so you never have to choose.
  The picker is now an override, with models **ranked + badged** by capability and role
  ("Best for building", "Reasoner", "Fastest").
- **Plan-first builds.** For a non-trivial build, a reasoner first writes a short, concrete
  **spec**, then the coder builds to it — shown as a collapsible "view plan" card. A rich
  spec is what stops a small model needing hand-holding.
- **Self-repair.** Every preview reports its own runtime errors; the builder **auto-fixes
  them** (up to two silent rounds) before handing it to you.
- **Traceable task tracker.** Activity shows in the chat as honest **queued → in-progress →
  done** steps (never "done" while still working); the **code streams live** into the Code
  pane as it's written.
- **Per-project isolation.** Each chat is its own project — its own preview, code and build
  state. A build in one no longer bleeds into another; a background build shows a status dot.
- **Markdown in chat** — headings, lists, bold/italic/code/links now render (no more raw `###`).

### Changed
- **Composer redesign** — one clean input, a **Stop** button while generating, comfortable hit
  area, clearer hint.
- **Stronger design system** — dark-theme tokens; the Tailwind + shadcn config is now injected
  even when the model adds its *own* Tailwind CDN (a common cause of blank previews); hero/section
  layout guidance so backgrounds don't collapse.
- **Preview** renders via a blob URL with a **Refresh** button and a loading state.

### Fixed
- Blank previews when the model used design tokens without loading the config.
- Scroll jank while streaming (re-renders are throttled) and the misplaced "jump to latest" button.
- The "view plan" card collapsing on its own mid-build.

### Internal
- `tools/bake.py` — a marker-driven, byte-verified baker that splices the dogfooded builder into
  both installer scripts, so the embedded copies can never drift again.

## [1.4.0] — 2026-06-14

Turns `--chat` into a local **app builder** (Lovable / Bolt-style) and adds an
opt-in **agent** mode with real, approve-to-run tools.

### Added
- **Builder + live preview.** `--chat` / `-Chat` is now a split view: chat on the
  left, a **live preview** on the right. Ask it to build a web app (a stopwatch, a
  to-do list) and it renders + runs in a sandboxed iframe — plus a **Code** tab and
  **Download**. A builder system prompt makes the model emit one self-contained HTML
  file, so it works with **any code-writing model** (no function-calling required).
- **Chat history sidebar** — past builds saved to `localStorage`; click to revisit.
- **Claude-Code-style scroll** — sticks to the bottom only when you're already there,
  so you can scroll up mid-generation (with a "jump to latest" button).
- **`--agent` / `-Agent` (opt-in, consented).** Launches a tiny local **tool server**
  (Python) so the model can **run shell commands and write files** — but only inside a
  workspace folder (`~/.local-llm-setup/workspace`), bound to `127.0.0.1`, CORS-locked
  to the page, and **only after you click Approve** for each action (output shown in a
  Terminal tab). Off by default; needs Python.

### Security
- The agent tool server binds only to `127.0.0.1`, rejects requests from any other web
  origin (a website you visit can't drive it), confines file writes to the workspace,
  and times commands out at 30s. Approval is per-command — that's the guardrail (an
  *approved* command still runs unrestricted), which is exactly why agent mode is opt-in.

## [1.3.0] — 2026-06-14

The "zero to *useful* in one command" release. After the model is running, the
script can now open a **chat in your browser** and wire up your **editor** — no
Docker, no extra runtime, on every OS.

### Added
- **`--chat` / `-Chat`** — generate a self-contained chat page and open it in your
  browser, served from `localhost` (which Ollama allows by default, so there's no
  Docker, no extra install, and Ollama is **not** exposed to the wider web). A
  ChatGPT-style UI: model picker, streaming replies, code blocks. Mac/Linux serve
  it via `python3`; Windows serves it via Python if present, otherwise points you
  at the native Ollama app. Run it standalone anytime or accept the prompt after setup.
- **`--editor` / `-Editor`** — install the **Continue** extension in VS Code / Cursor
  and write `~/.continue/config.yaml` pointed at your local context-tuned models
  (chat + edit + apply), so AI coding inside your editor works immediately.
- Both are offered interactively at the end of setup ("Open a chat now? Set up your
  editor?") and listed in the post-setup tips.

### Changed
- The post-setup prompt now leads with the **browser chat + editor** instead of the
  bare terminal REPL (the `ollama run` path is still documented).

## [1.2.0] — 2026-06-14

### Added
- **`--lean` / `-Lean`** — optionally bake a minimal-code coder variant
  (`<coder>-<size>-lean`, e.g. `qwen2.5-coder-14b-lean`) with a "ponytail"
  system prompt that steers the model to the simplest solution (YAGNI → stdlib
  → platform feature → one line). Especially valuable on a local model: less
  code = fewer output tokens, faster, and more room in the context window. In a
  side-by-side on `qwen2.5-coder:14b`, the lean variant wrote ~45% fewer lines
  for the same task. System prompt adapted from
  [ponytail](https://github.com/DietrichGebert/ponytail) (MIT). `--uninstall`
  removes the lean variants too.

## [1.1.1] — 2026-06-14

### Fixed
- **Context-variant names now keep the model size, so they can't collide.** The
  baked variant was named `qwen2.5-coder-8k` (the `:14b` was stripped), so running
  the script at a different tier later would silently overwrite the earlier tier's
  variant — and it disagreed with the README, which already documented
  `qwen2.5-coder-14b-8k`. Both scripts now produce `qwen2.5-coder-14b-8k`, and a
  single helper (`ctx_alias` / `Get-CtxAlias`) is the one source of the name so it
  can't drift again. `--uninstall` removes both the new and the legacy names.
- **`--uninstall` now actually matches the context variants.** `ollama create`
  tags a variant `:latest`, so `ollama list` prints `…-8k:latest` while the tool
  compared against the bare `…-8k` — meaning the baked variants were never
  matched (or removed) before. Both scripts now strip the implicit `:latest`
  when matching, so uninstall (and the "prefer the tuned variant for chat" step)
  see them.

## [1.1.0] — 2026-06-14

Makes this the "one command for anyone, anywhere" tool: native Windows support,
GPU-aware sizing, and the safety + exploration touches a first-timer actually
needs. Backward compatible — every existing flag behaves exactly as before.

### Added
- **Native Windows support** via a new [`local-llm-setup.ps1`](local-llm-setup.ps1)
  — no WSL required. Installs Ollama through `winget` (or the official installer
  if `winget` is absent), so a discrete GPU is used natively. Mirrors the Bash
  script's flow, prompts, dry-run, and resume-retry downloads. Flags: `-Yes`,
  `-DryRun`, `-Tier`, `-Benchmark`, `-Uninstall`, `-Version`, `-Help`.
- **GPU-aware model sizing.** When a dedicated NVIDIA GPU is present (Linux +
  Windows, via `nvidia-smi`), the tier is sized to **VRAM** — the fast path —
  instead of system RAM. A 16 GB-RAM box with a 24 GB GPU now gets `32b`, not `7b`.
- **Disk-space preflight.** The script estimates the tier's download size, shows
  it next to your free space, and **stops before downloading** if the drive can't
  fit it — no more failing halfway through a 40 GB pull.
- **"Start chatting now?" prompt.** After the smoke test, an interactive run
  offers to drop you straight into `ollama run`, pointed at your context-tuned model.
- **`--benchmark`** (`-Benchmark`): report tokens/sec for every installed model.
- **`--uninstall`** (`-Uninstall`): cleanly remove the models this tool installs
  (and, if you want, Ollama itself) — both gated behind a confirmation.
- **`--version`** (`-Version`): print the version and exit.
- CI: a real `windows-latest` parse + dry-run smoke test, alongside the existing
  Linux one.
- A **demo GIF** in the README (a real `--dry-run`) showing the live hardware
  detection and sized model plan. Reproducible via [`assets/demo.tape`](assets/demo.tape).

### Changed
- Bumped `actions/checkout` to `v5` across all workflows (Node 24).

### Fixed
- **`--help` no longer dumps the whole file.** It printed every `#`-prefixed
  line, including internal section dividers; now it prints only the header doc block.
- Removed a couple of stray literal `\n` sequences in `say` output (the smoke-test
  and benchmark intros) that printed as backslash-n instead of a newline.

## [1.0.1] — 2026-06-14

Hardening from the first real end-to-end run on an M5 Pro (24 GB). The happy
path worked, but a live install surfaced one real bug and a cluster of
real-world download issues the dry-run could never catch.

### Fixed
- **Context-window variants are now actually created.** `ollama create` was
  called with `-f -` (Modelfile via stdin), which current Ollama (0.30.x)
  rejects with `no Modelfile or safetensors files found` — so the promised
  `*-8k` models were silently never built. Now writes a temp Modelfile and
  passes its path.
- `ollama --version` no longer leaks a "could not connect" warning into the
  "already installed" line when the server is down.

### Changed
- **Resilient downloads.** `ollama pull` now runs through a resume-retry loop
  (Ollama keeps the partial data, so retries continue) — a transient `EOF` no
  longer strands the run. After repeated failures it prints a clear remedy:
  re-run to resume, or clear the partial blob and start that model fresh.
- **Persistent server on macOS.** Starts Ollama via `brew services` so it
  survives the script exiting, instead of an in-script `ollama serve &` that
  died with the process.
- **Faster, quieter install** via `HOMEBREW_NO_AUTO_UPDATE=1`.
- Pull progress is suppressed on non-TTY runs (unattended/CI) so the progress
  bar no longer floods logs with ANSI redraws.
- Sets expectations up front that large pulls can take 30+ min and are safe to re-run.

## [1.0.0] — 2026-06-14

First public release.

### Added
- One-command local LLM setup: auto-detects OS + hardware, picks RAM-appropriate
  models, installs the Ollama runtime, pulls models, bakes in a sane context
  window, and runs a live smoke test.
- **macOS** support (Apple silicon) via `sysctl` + Homebrew.
- **Linux** support (x86-64 / ARM64) via `/proc/meminfo` + the official
  `ollama.com/install.sh` installer.
- OS auto-detection with a `--platform mac|linux` override (e.g. for WSL2).
- Flags: `--dry-run` (no-op preview), `--yes` (unattended), `--tier`, `--platform`, `--help`.
- Model tiers from 7B to 70B selected automatically by available memory.
- CI: ShellCheck lint + a real `ubuntu-latest` dry-run smoke test.
- Full community profile: README, MIT license, CONTRIBUTING, CODE_OF_CONDUCT,
  SECURITY, issue + PR templates.

[1.4.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.4.0
[1.3.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.3.0
[1.2.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.2.0
[1.1.1]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.1.1
[1.1.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.1.0
[1.0.1]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.0.1
[1.0.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.0.0
