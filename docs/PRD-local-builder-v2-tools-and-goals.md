# PRD — Local Builder v2: Real Tools, Website Cloning & Goal-Driven Self-Improvement

**Status:** draft v0.1 · **Owner:** Hamza · **Date:** 2026-06-17
**Builds on:** [PRD-local-builder.md](PRD-local-builder.md) (the three modes + the harness).
**One-liner:** Give the local agent the *same kind of tools* Lovable / Claude Code / Codex have — fetch, scrape, inspect, run, diff — so it can do real tasks (starting with **cleanly cloning a real website's homepage**), and wrap it in a **goal + eval loop** that proves capability and improves itself. All one-shot public via the repo.

---

## 1. The capability bar (how we know it's "smart")

> **North-star eval:** Given `https://disrupt.com/`, the builder reproduces that homepage — layout, palette, fonts, sections, imagery — closely enough that a human says *"yeah, that's the page."*

This is the honest acceptance test. Today's builder *generates from imagination*; a capable builder **observes the real page and reconstructs it**. The gap isn't model IQ — it's **missing tools + no feedback loop**. Lovable/Claude/Codex feel smart largely because they can *look at the world and check their work*. We give the local agent the same.

---

## 2. Why tools, not a bigger model

A 14B asked to "clone disrupt.com" hallucinates, because it can't *see* the site. Give it the page's real DOM, colors, fonts, and structure as input, and the same 14B reconstructs faithfully — it's now a transcription task, not an invention task. **Tools convert "invent it" into "transcribe it,"** which is exactly where small models are strong (the same lesson as baking in the design system). The model supplies structure; the tools supply ground truth.

---

## 3. The toolbelt (parity with the big tools)

| Capability | Lovable/Claude/Codex have | We add (local, sandboxed) |
|---|---|---|
| **Fetch a URL** | ✅ | `fetch_url(url)` → HTML (server-side, no CORS limit) |
| **Parse / scrape** | ✅ | `inspect_site(url)` → **BeautifulSoup** + a headless render: DOM tree, text, links, asset URLs |
| **Extract design** | ✅ (vision) | `extract_design(url)` → **palette** (dominant colors), **fonts** (font-family stack), spacing/radius, section outline, hero image |
| **See the result** | ✅ (screenshot) | `screenshot(html)` → render in headless Chromium → PNG |
| **Check the work** | ✅ | `visual_diff(a,b)` → similarity score + per-region deltas (clone vs original) |
| **Files** | ✅ | `read/write/list` in the project dir (have `write`, add read/list) |
| **Run commands** | ✅ | `run(cmd)` — approve-to-run (have it) |
| **Search the web** | ✅ | `web_search(q)` (optional, P2) |

All server-side in `agent-server.py` (Python already has the ecosystem: `requests`, `beautifulsoup4`, `Pillow`, optional `playwright`). **127.0.0.1-bound, origin-locked, approve-to-run, workspace-confined** — the existing posture extends cleanly.

> **Shipped (2026-06-17):** `screenshot` is now a robust headless capture — **Playwright's managed Chromium** as the primary path (installed on demand), with a **system-Chrome subprocess fallback** so the zero-dependency install still degrades usefully. A new **`gitsync`** tool turns a generated project into a real local git repo (`git init` + sensible `.gitignore` + commit) and exports a `.zip` that includes the `.git` history; pushing to a remote stays user-credentialed (the tool prints the `git push` command, never runs it). Both are covered by deterministic, offline stress tests under [`tests/`](../tests) — run `tools/test.sh`. Element + full-page capture are first-class on the Playwright path.

---

## 4. The clone pipeline (the headline workflow)

A traceable, tool-using task — every step visible in the chat (Claude-Code style), artifacts in the panes:

```
1. Fetch        fetch_url(disrupt.com)            → raw HTML            [✓ Fetched the page]
2. Inspect      inspect_site()                    → DOM, sections,     [✓ Mapped 7 sections]
                                                    assets, links
3. Extract      extract_design()                  → palette, fonts,    [✓ Palette: #0B0B0F …; Font: Inter]
                                                    layout, hero img
4. Spec         reasoner writes a build spec      → concrete plan       [✓ Planned the rebuild]
                from the extracted facts
5. Build        coder builds to the spec +        → HTML                [◐ Writing the page · N lines]
                real tokens (not invented)
6. Render       preview + screenshot              → PNG                 [✓ Rendered]
7. Diff         visual_diff(clone, original)      → score 0–100         [✓ 82% match]
8. Iterate      if score < target: feed the       → fixes               [◐ Closing the gap (round 2)]
                biggest deltas back, goto 5
```

Steps 7–8 are the **eval loop made visible** — the same mechanism that powers /goal (below). The user watches the score climb. This is "lean back and watch the show."

---

## 5. Goal-driven development (the `/goal` system)

The user's ask: *"set the right /goal command and eval and test cases to ensure we build it right."* Two pieces:

### 5a. `/goal` — a goal is a capability + its evals
A **goal** is not a vibe; it's a measurable capability statement plus the tests that prove it:

```
goal: clone-a-homepage
capability: "Given a public homepage URL, reproduce it faithfully."
evals:
  - url: https://disrupt.com/        target: visual_diff ≥ 80, palette match ≥ 90%, all hero+nav+sections present
  - url: https://linear.app/         target: visual_diff ≥ 75
acceptance: every eval passes its target on a fresh run
```

`/goal` runs the evals, scores them, shows a **pass/fail scorecard**, and — when something fails — captures *why* (the deltas) as the next work item. It turns "make it good" into a closed loop with a number.

### 5b. A skill for **writing** goals
Most goals are written badly (unmeasurable). A `write-a-goal` skill enforces the good shape: a concrete capability statement, ≥2 real test cases with **numeric targets**, an acceptance rule, and a non-goals list. (Mirrors how `/spec` works, but for capabilities + evals rather than features.)

### 5c. Self-improvement
The loop: **define goal → run evals → fail → the failing deltas become the build backlog → fix → re-run → pass.** The agent improves *against the eval*, not against a guess. The disrupt.com clone is the first goal; its eval is §4 step 7.

---

## 6. One-shot public (the actual deliverable)

> *"one shot, literal one shot, then lean back and watch the show."*

Everything above ships **inside the repo** so a brand-new user runs **one command** and gets the whole thing — models, builder, tools, goals:

- `local-llm-setup.sh --build` → detects hardware, pulls the right models, starts Ollama, installs the Python tool deps (`beautifulsoup4`, `Pillow`, optional `playwright`), launches the agent+builder, opens the browser. Zero further choices (Auto picks models).
- Cross-platform parity (`.sh` + `.ps1`), fresh-clone tested, CI-green — per the existing release discipline.
- **Gating reality:** *none of v1's routing/spec/self-repair/markdown work reaches a new user until it's baked into these scripts and released.* That bake+release is **P0 before any of v2** (see §8).

---

## 7. Architecture

- **Tools live in `agent-server.py`** as new endpoints (`/api/agent/fetch`, `/inspect`, `/extract`, `/screenshot`, `/diff`), each returning structured JSON the builder feeds to the model. Reuses the CORS-lock + approve-to-run + workspace confinement.
- **Headless render** (screenshot/diff) via `playwright` (chromium) — an optional dep; degrade gracefully to "no visual diff" if absent so the one-command install never hard-fails.
- **Tool protocol:** extend the existing `<run>`/`<write>` text-tool convention with `<fetch url>`, `<inspect url>`, etc. — still text-based, still any-model, still approve-to-run for anything that touches the system.
- **The model routes:** reasoner plans the rebuild from extracted facts; coder transcribes; the diff loop drives iteration.

---

## 8. Phasing (recommendation: stabilize first, then build the cloner)

**P0 — make v1 real for new users (this is "what you need atm").** Bake routing + plan-spec + self-repair + markdown + composer/scroll/plan fixes into `--build` in both scripts; fresh-clone test; cut a release. *Until this lands, a new clone gets none of it.* **Recommended first — it's literally your stated need.**

**P1 — the toolbelt + clone pipeline.** `fetch_url`, `inspect_site`, `extract_design`; the §4 pipeline through step 6 (build from real tokens). Ship the first visible "cloned a page" win.

**P2 — the eval loop + `/goal`.** `screenshot` + `visual_diff`; `/goal` scorecard; the disrupt.com goal with numeric targets; the `write-a-goal` skill; iterate-to-target.

**P3 — breadth.** `web_search`, more goals, export (PDF/zip/repo), PersonalDispatch for phone, extract builder into its own public repo.

---

## 9. Honest limits

- **"Pixel-perfect" is not the bar; "that's the page" is.** Even frontier tools approximate. A 14B + tools gets *close and recognizable*; the diff score sets honest expectations.
- **Some sites resist** (heavy JS, auth walls, anti-scraping). The pipeline degrades to "best effort from what we could fetch" and says so — never a silent fake.
- **`playwright`/Chromium is a real dependency.** Keep it optional so the one-command install stays robust; visual-diff is an enhancement, not a gate.
- **Respect the source:** clone for learning/inspiration; don't ship someone's site as your own. A note in the UI.

---

## 10. Success criteria

- A new user runs **one command** and, with zero model-picking, asks *"clone disrupt.com"* and **watches** fetch → extract → build → diff → a recognizable result.
- `/goal clone-a-homepage` returns a **scorecard with real numbers** that improve across rounds.
- It all lives in the **public repo**, fresh-clone tested, nothing leaving the machine.
