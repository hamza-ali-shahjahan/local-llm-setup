# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

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

[1.3.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.3.0
[1.2.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.2.0
[1.1.1]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.1.1
[1.1.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.1.0
[1.0.1]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.0.1
[1.0.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.0.0
