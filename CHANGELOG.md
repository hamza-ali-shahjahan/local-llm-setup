# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

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

[1.1.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.1.0
[1.0.1]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.0.1
[1.0.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.0.0
