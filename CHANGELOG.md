# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

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
