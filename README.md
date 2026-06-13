# local-llm-setup

**Zero to a running local LLM on your Mac or Linux machine — in one command.**

Setting up a local AI model the normal way takes **a dozen manual steps and a pile of decisions**: which runtime, which model, will it fit your RAM, what "quantization" means, how to set a context window, how to test it. Miss one and you're stuck.

This collapses all of it into **one command that asks you nothing it can figure out for itself** — and you don't need to know what any of it means.

[![ShellCheck](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS + Linux](https://img.shields.io/badge/platform-macOS%20%2B%20Linux-lightgrey.svg)

### From 12 steps to 1

| Setting it up by hand | This script |
| --- | --- |
| 1. Research runtimes (Ollama? LM Studio? llama.cpp?) | ✅ handled |
| 2. Install and configure one | ✅ handled |
| 3. Check how much RAM you have | ✅ auto-detected |
| 4. Work out which model size fits | ✅ auto-picked |
| 5. Learn what "quantization" is | ✅ not your problem |
| 6. Choose a quant level (Q4? Q5?) | ✅ chosen for you |
| 7. Find the exact model tag | ✅ handled |
| 8. Download the model | ✅ handled |
| 9. Figure out the context window | ✅ handled |
| 10. Configure it without blowing up RAM | ✅ tuned for your RAM |
| 11. Start the runtime | ✅ handled |
| 12. Test that it actually works | ✅ live smoke test |

**12 steps and 5+ judgment calls → 1 command, 0 required decisions.** Built for someone doing this for the very first time — no prior knowledge assumed.

---

## Why

Cloud AI tools can change their rules overnight. Running a capable model on your own machine is cheap insurance — and these days a modern Mac or Linux box runs genuinely useful models locally. The hard part has always been the first 30 minutes of setup. This removes them.

## What it does

```
==> Checking your machine
✓ Platform: mac
✓ Chip: Apple M5 Pro
✓ Memory: 24 GB

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
| [Homebrew](https://brew.sh) | Mac package manager | **macOS only**, and only if you don't have it (asks first) |
| [Ollama](https://ollama.com) | Local model runtime | Runs the models; on Linux it's installed via the official `ollama.com/install.sh` |
| 1–2 models | Coder + reasoning | Chosen automatically from your RAM |

Nothing is hidden and nothing is destructive. Every install asks for confirmation; `--dry-run` shows the full plan without touching your system.

## How models are matched to your machine

Your OS needs ~4–8 GB of headroom, so the tier is picked from your total memory (unified memory on Apple silicon):

| Your RAM | Tier | Models pulled | Runs like |
| --- | --- | --- | --- |
| ≤ 16 GB | `7b` | `qwen2.5-coder:7b`, `deepseek-r1:7b` | Fast on almost anything |
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
| `--platform <os>` | Override OS auto-detect (`mac`, `linux`) — e.g. inside WSL2 |
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

- **macOS** on Apple silicon (M1 or newer recommended), or **Linux** (x86-64 or ARM64)
- On Windows, run it inside [WSL2](https://learn.microsoft.com/windows/wsl/install) and pass `--platform linux`
- ~10–40 GB free disk for models (depends on tier)
- An internet connection for the one-time download

## Contributing

Model tags age as new releases ship. PRs that bump the tier list in [`local-llm-setup.sh`](local-llm-setup.sh) are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Hamza Ali Shahjahan
