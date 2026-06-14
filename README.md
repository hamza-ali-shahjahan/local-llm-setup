# local-llm-setup

**Zero to a running local LLM on your Mac, Linux, or Windows machine — in one command.**

Setting up a local AI model the normal way takes **a dozen manual steps and a pile of decisions**: which runtime, which model, will it fit your RAM, what "quantization" means, how to set a context window, how to test it. Miss one and you're stuck.

This collapses all of it into **one command that asks you nothing it can figure out for itself** — and you don't need to know what any of it means. It checks you have the disk space before downloading, sizes the model to your GPU when you have one, and offers to drop you straight into a chat the moment it's done.

[![ShellCheck](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml)
[![Linux smoke test](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/linux-smoke.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/linux-smoke.yml)
[![Windows smoke test](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/windows-smoke.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/windows-smoke.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS + Linux + Windows](https://img.shields.io/badge/platform-macOS%20%2B%20Linux%20%2B%20Windows-lightgrey.svg)

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

Cloud AI tools can change their rules overnight. Running a capable model on your own machine is cheap insurance — and these days a modern Mac, Linux, or Windows box runs genuinely useful models locally. The hard part has always been the first 30 minutes of setup. This removes them.

## What it does

```
==> Checking your machine
✓ Platform: mac
✓ Chip: Apple M5 Pro
✓ Memory: 24 GB

==> Recommended setup
  Tier:     14b  (sized to your 24 GB of memory)
  Models:   qwen2.5-coder:14b deepseek-r1:14b
  Context:  8192 tokens  (keeps memory use sane)
  Download: ~19 GB  (you have 669 GB free)
```

It then checks you have the disk space, installs Ollama, pulls those models, bakes the context window into ready-to-use `*-8k` variants, runs a live smoke test, and offers to drop you into a chat. On a Linux or Windows box with an NVIDIA GPU you'll also see a `✓ GPU:` line, and the tier is sized to your VRAM instead.

## Quickstart

### First: where do these commands go?

These are **Terminal** commands — they run in your computer's built-in command-line app. Not in a web browser, not in ChatGPT or Claude, not in an IDE's search box. Just the plain Terminal. If you've never opened it, here's how:

**On a Mac**

1. Press **⌘ Command + Spacebar** to open Spotlight search (a search box appears in the middle of the screen).
2. Type **`Terminal`** and press **Return**.
3. A window opens with a line ending in `%` or `$` and a blinking cursor. That's the prompt — it's waiting for you to type. You're in the right place.

**On Linux**

1. Open your applications menu and search for **`Terminal`** (on many desktops **Ctrl + Alt + T** opens it directly).
2. A window opens with a prompt ending in `$`. That's it.

**How to run a command:** copy a command from below, click into the Terminal window, paste it (**⌘ Command + V** on Mac, **Ctrl + Shift + V** on Linux), and press **Return / Enter**. The command runs; when it finishes, the prompt comes back and you can paste the next one.

> New to the terminal? It won't ask "are you sure?" the way apps do — pressing Enter runs the command immediately. That's normal. Everything below is safe, asks before installing anything, and `--dry-run` (further down) shows you the full plan without changing a thing.

### Then: the one command

**The one command — this is the whole thing:**

```bash
./local-llm-setup.sh
```

That single command does everything on the list above: checks your machine, installs the runtime, picks and pulls the right model, tunes the context window, and smoke-tests it — asking nothing it can figure out for itself.

The only thing to do first is get that file onto your machine. It's a good habit to read any script from the internet before running it, so the steps below download it, (optionally) let you read it, then run the one command:

**1. Download the script**

```bash
curl -fsSL https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.sh -o local-llm-setup.sh
```

**2. Read it (optional but encouraged)**

```bash
less local-llm-setup.sh
```

**3. Run the one command**

```bash
chmod +x local-llm-setup.sh   # make it runnable (one time only)
./local-llm-setup.sh          # 👈 THE one command — does all 12 steps
```

Prefer to look before anything happens? Run a no-op preview that changes nothing:

```bash
./local-llm-setup.sh --dry-run
```

### Windows (native — no WSL needed)

Windows has its own one command: [`local-llm-setup.ps1`](local-llm-setup.ps1). It runs Ollama **natively**, so your GPU is used for real — no WSL, no virtual machine. Open **PowerShell** (search the Start menu for it) and follow these steps.

**1. Download the script**

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.ps1 -OutFile local-llm-setup.ps1
```

**2. Read it (optional but encouraged)**

```powershell
notepad local-llm-setup.ps1
```

**3. Allow this one script to run, then run it**

Windows blocks downloaded scripts by default. This line lifts that **for the current window only** (it resets when you close it):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

```powershell
.\local-llm-setup.ps1
```

You should see the same `==> Checking your machine` flow as the screenshot above. Want a no-op preview first?

```powershell
.\local-llm-setup.ps1 -DryRun
```

> If `winget` isn't on your machine, the script downloads the official Ollama installer instead and runs it for you — either way you don't have to find anything yourself.

## What it installs

| Component | What it is | Why |
| --- | --- | --- |
| [Homebrew](https://brew.sh) | Mac package manager | **macOS only**, and only if you don't have it (asks first) |
| [Ollama](https://ollama.com) | Local model runtime | Runs the models. Installed via Homebrew (macOS), the official `ollama.com/install.sh` (Linux), or `winget` / the official installer (Windows) |
| 1–2 models | Coder + reasoning | Chosen automatically from your hardware |

Nothing is hidden and nothing is destructive. Every install asks for confirmation; `--dry-run` (or `-DryRun` on Windows) shows the full plan without touching your system.

## How models are matched to your machine

The tier is sized to whatever will actually run the model well:

- **Got a discrete NVIDIA GPU?** The model lives in its VRAM, so the script sizes to your **VRAM** — the fast path. (Detected on Linux and Windows via `nvidia-smi`.)
- **No GPU** (or Apple silicon, where memory is unified)? It sizes to **system RAM**, leaving the ~4–8 GB of headroom your OS needs.

| Your VRAM / RAM | Tier | Models pulled | Runs like | Download |
| --- | --- | --- | --- | --- |
| ≤ 16 GB | `7b` | `qwen2.5-coder:7b`, `deepseek-r1:7b` | Fast on almost anything | ~10 GB |
| 17–32 GB | `14b` | `qwen2.5-coder:14b`, `deepseek-r1:14b` | The sweet spot | ~19 GB |
| 33–64 GB | `32b` | `qwen2.5-coder:32b`, `deepseek-r1:32b` | Noticeably smarter | ~40 GB |
| 65 GB+ | `70b` | `qwen2.5-coder:32b`, `deepseek-r1:70b` | Workstation-class | ~63 GB |

(GPU sizing uses VRAM bands of ≤8 / ≤16 / ≤32 / >32 GB.) Before downloading, the script checks you have the disk space and **stops early** if you don't — no failing halfway through a 40 GB pull. Override the auto-pick with `--tier 7b|14b|32b|70b` (`-Tier` on Windows).

## Flags

macOS / Linux use `--flag`; Windows PowerShell uses `-Flag`. Same behavior either way.

| macOS / Linux | Windows | Effect |
| --- | --- | --- |
| `--dry-run` | `-DryRun` | Print the full plan; change nothing |
| `--yes`, `-y` | `-Yes` | Accept all defaults, no prompts (unattended) |
| `--tier <t>` | `-Tier <t>` | Force a model tier (`7b`, `14b`, `32b`, `70b`) |
| `--benchmark` | `-Benchmark` | Measure tokens/sec for every installed model |
| `--uninstall` | `-Uninstall` | Remove the models this tool installs (asks first) |
| `--platform <os>` | — | Override OS auto-detect (`mac`, `linux`) |
| `--version` | `-Version` | Print the version and exit |
| `--help`, `-h` | `-Help` | Show usage |

## After setup

```bash
ollama run qwen2.5-coder-14b-8k       # chat with your context-tuned model
ollama list                           # see everything you have
./local-llm-setup.sh --benchmark      # how fast is each model? (tokens/sec)
```

When it finishes, the script also **offers to start a chat for you** — so you can try it the second it's ready.

Point any OpenAI-compatible app, IDE, or agent at it:

- **Base URL:** `http://localhost:11434/v1`
- **API key:** `ollama` (any non-empty string works)
- **Model:** the tag from `ollama list`

Done experimenting? `./local-llm-setup.sh --uninstall` (or `-Uninstall`) removes the models this tool added, and can remove Ollama itself — both ask first.

## Requirements

- **macOS** on Apple silicon (M1 or newer recommended), **Linux** (x86-64 or ARM64), or **Windows 10/11** (native — no WSL)
- On Windows, the script uses `winget` if present, otherwise it downloads the official Ollama installer. WSL2 users can run the Bash script with `--platform linux` instead, but native is recommended.
- ~10–65 GB free disk for models, depending on tier (the script checks first)
- An internet connection for the one-time download

## Contributing

Model tags age as new releases ship. PRs that bump the tier list are welcome — it lives in one place in each script: `tier_models()` in [`local-llm-setup.sh`](local-llm-setup.sh) and `Get-TierModels` in [`local-llm-setup.ps1`](local-llm-setup.ps1). Keep the two in lockstep. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Hamza Ali Shahjahan
