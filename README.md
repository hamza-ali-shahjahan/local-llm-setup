# local-llm-setup

**Zero to a running local LLM on your Mac, in one command.**

One script detects your hardware, picks models that actually fit your RAM, installs the [Ollama](https://ollama.com) runtime, downloads the right models, sets a sane context window, and runs a smoke test so you *know* it works. Built for someone doing this for the very first time — no prior knowledge assumed.

[![ShellCheck](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

---

## Why

Cloud AI tools can disappear with a single policy change. Running a capable model on your own machine is cheap insurance — and these days a modern Mac runs genuinely useful models locally. The hard part is the first 30 minutes of setup. This script removes them.

## What it does

```
==> Checking your Mac
✓ Chip: Apple M5 Pro
✓ Memory: 24 GB unified

==> Recommended setup for 24 GB
  Tier:    14b  (best fit for your memory)
  Models:  qwen2.5-coder:14b deepseek-r1:14b
  Context: 8192 tokens  (keeps RAM use sane)
```

It then installs Ollama, pulls those models, bakes the context window into ready-to-use `*-8k` variants, and runs a live smoke test.

## Quickstart

It's a good habit to read any script from the internet before running it. These steps let you do exactly that:

**1. Download the script**

```bash
curl -fsSL https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.sh -o local-llm-setup.sh
```

**2. Read it (optional but encouraged)**

```bash
less local-llm-setup.sh
```

**3. Make it executable and run it**

```bash
chmod +x local-llm-setup.sh
./local-llm-setup.sh
```

Prefer to look before anything happens? Run a no-op preview that changes nothing:

```bash
./local-llm-setup.sh --dry-run
```

## What it installs

| Component | What it is | Why |
| --- | --- | --- |
| [Homebrew](https://brew.sh) | Mac package manager | Only if you don't already have it (asks first) |
| [Ollama](https://ollama.com) | Local model runtime | Runs the models; fully scriptable |
| 1–2 models | Coder + reasoning | Chosen automatically from your RAM |

Nothing is hidden and nothing is destructive. Every install asks for confirmation; `--dry-run` shows the full plan without touching your system.

## How models are matched to your Mac

macOS itself needs ~6–8 GB of headroom, so the tier is picked from your total unified memory:

| Your RAM | Tier | Models pulled | Runs like |
| --- | --- | --- | --- |
| ≤ 16 GB | `7b` | `qwen2.5-coder:7b`, `deepseek-r1:7b` | Fast on any recent Mac |
| 17–32 GB | `14b` | `qwen2.5-coder:14b`, `deepseek-r1:14b` | The sweet spot |
| 33–64 GB | `32b` | `qwen2.5-coder:32b`, `deepseek-r1:32b` | Noticeably smarter |
| 65 GB+ | `70b` | `qwen2.5-coder:32b`, `deepseek-r1:70b` | Workstation-class |

Override the auto-pick with `--tier 7b|14b|32b|70b`.

## Flags

| Flag | Effect |
| --- | --- |
| `--dry-run` | Print the full plan; change nothing |
| `--yes`, `-y` | Accept all defaults, no prompts (unattended) |
| `--tier <t>` | Force a model tier (`7b`, `14b`, `32b`, `70b`) |
| `--help`, `-h` | Show usage |

## After setup

```bash
ollama run qwen2.5-coder:14b          # chat in the terminal
ollama list                           # see everything you have
```

Point any OpenAI-compatible app, IDE, or agent at it:

- **Base URL:** `http://localhost:11434/v1`
- **API key:** `ollama` (any non-empty string works)
- **Model:** the tag from `ollama list`

## Requirements

- macOS on Apple silicon (M1 or newer recommended)
- ~10–40 GB free disk for models (depends on tier)
- An internet connection for the one-time download

## Contributing

Model tags age as new releases ship. PRs that bump the tier list in [`local-llm-setup.sh`](local-llm-setup.sh) are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Hamza Ali Shahjahan
