# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project aims to
follow [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/hamza-ali-shahjahan/local-llm-setup/releases/tag/v1.0.0
