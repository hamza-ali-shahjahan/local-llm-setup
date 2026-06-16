# local-llm-setup

**Zero to a running local LLM on your Mac, Linux, or Windows machine — in one command.**

Setting up a local AI model the normal way takes **a dozen manual steps and a pile of decisions**: which runtime, which model, will it fit your RAM, what "quantization" means, how to set a context window, how to test it. Miss one and you're stuck.

This collapses all of it into **one command that asks you nothing it can figure out for itself** — and you don't need to know what any of it means. It checks you have the disk space before downloading, sizes the model to your GPU when you have one, and — the moment it's done — offers to open a chat in your browser and set up AI in your editor.

[![ShellCheck](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/shellcheck.yml)
[![Linux smoke test](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/linux-smoke.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/linux-smoke.yml)
[![Windows smoke test](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/windows-smoke.yml/badge.svg)](https://github.com/hamza-ali-shahjahan/local-llm-setup/actions/workflows/windows-smoke.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS + Linux + Windows](https://img.shields.io/badge/platform-macOS%20%2B%20Linux%20%2B%20Windows-lightgrey.svg)

<p align="center">
  <img src="assets/demo.gif" alt="local-llm-setup auto-detecting the machine and recommending a model plan sized to its memory" width="760">
</p>

<p align="center"><em>One command reads your hardware and proposes a model plan that fits — shown here as a <code>--dry-run</code>, so nothing is installed or downloaded.</em></p>

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

## Why

Cloud AI tools can change their rules overnight. Running a capable model on your own machine is cheap insurance — and these days a modern Mac, Linux, or Windows box runs genuinely useful models locally. The hard part has always been the first 30 minutes of setup. This removes them.

---

## Quick Start

**Find your machine below and jump straight to its one command — that's the whole setup.**

### ➡️ &nbsp; [🍎 macOS / 🐧 Linux](#-macos--linux) &nbsp;·&nbsp; [🪟 Windows ⚠️ *experimental*](#-windows)

> **macOS / Linux is the tested, primary path.** The Windows one-command exists but is **⚠️ experimental — not yet tested on a real Windows machine** (see the note in the [Windows section](#-windows) below).

> These commands run in your computer's built-in command app (**Terminal** on Mac/Linux, **PowerShell** on Windows) — **not** in a web browser, ChatGPT, Claude, or an IDE search box. Each section below tells you exactly which app to open and where to find it.

---

## 🍎🐧 macOS / Linux

### The one command

Paste this into your **Terminal** and press Return. It downloads the script next to you and runs it — checking your machine, installing the runtime, pulling the right model, and smoke-testing it. **It asks before installing anything.**

```bash
curl -fsSL https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.sh -o local-llm-setup.sh && bash local-llm-setup.sh
```

**New to the Terminal? Here's how to open it:**

- **Mac:** press **⌘ Command + Spacebar**, type **`Terminal`**, press **Return**.
- **Linux:** open your apps menu and search **`Terminal`** (on most desktops **Ctrl + Alt + T** opens it directly).

A window opens with a prompt ending in `%` or `$` and a blinking cursor — that's it waiting for you. To paste the command: **⌘ Command + V** (Mac) or **Ctrl + Shift + V** (Linux), then press Return.

<details>
<summary><b>Rather see the full plan first, without changing anything?</b></summary>

This downloads the script and prints exactly what it *would* do — no installs, no downloads, nothing touched:

```bash
curl -fsSL https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.sh -o local-llm-setup.sh && bash local-llm-setup.sh --dry-run
```
</details>

<details>
<summary><b>Rather read the script line by line before running it? (encouraged)</b></summary>

```bash
# 1. Download it
curl -fsSL https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.sh -o local-llm-setup.sh

# 2. Read it (press q to quit)
less local-llm-setup.sh

# 3. Run it
bash local-llm-setup.sh
```
</details>

### What it does

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

It then checks you have the disk space, installs Ollama, pulls those models, bakes the context window into ready-to-use `*-8k` variants, runs a live smoke test, and offers to open a browser chat + set up your editor. On a Linux box with an NVIDIA GPU you'll also see a `✓ GPU:` line, and the tier is sized to your VRAM instead.

### What it installs

| Component | What it is | Why |
| --- | --- | --- |
| [Homebrew](https://brew.sh) | Mac package manager | **macOS only**, and only if you don't have it (asks first) |
| [Ollama](https://ollama.com) | Local model runtime | Runs the models. Installed via Homebrew (macOS) or the official `ollama.com/install.sh` (Linux) |
| 1–2 models | Coder + reasoning | Chosen automatically from your hardware |

Nothing is hidden and nothing is destructive. Every install asks for confirmation; `--dry-run` shows the full plan without touching your system.

---

## 🪟 Windows

> ⚠️ **Experimental — not yet tested on a real Windows machine.** The PowerShell installer is provided as-is; please [report issues](https://github.com/hamza-ali-shahjahan/local-llm-setup/issues). The macOS / Linux path above is the tested, primary one — if you're on Windows and something breaks, your reports are what will make this path solid.

Windows has its own one command, [`local-llm-setup.ps1`](local-llm-setup.ps1). It's **designed to** run Ollama **natively**, so your GPU is used for real — no WSL, no virtual machine.

### The one command

Paste this into **PowerShell** and press Enter. It downloads the script, allows it to run **for this window only** (Windows blocks downloaded scripts by default), and runs it. **It asks before installing anything.**

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.ps1 -OutFile local-llm-setup.ps1; Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; .\local-llm-setup.ps1
```

**New to PowerShell? Here's how to open it:**

Click **Start**, type **`PowerShell`**, and click **Windows PowerShell**. A blue window opens with a prompt ending in `>`. To paste the command: **Ctrl + V** (or right-click the window), then press Enter.

> If `winget` isn't on your machine, the script downloads the official Ollama installer instead and runs it for you — either way you don't have to find anything yourself.

<details>
<summary><b>Rather see the full plan first, without changing anything?</b></summary>

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.ps1 -OutFile local-llm-setup.ps1; Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; .\local-llm-setup.ps1 -DryRun
```
</details>

<details>
<summary><b>Rather read the script before running it? (encouraged)</b></summary>

```powershell
# 1. Download it
Invoke-WebRequest -Uri https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.ps1 -OutFile local-llm-setup.ps1

# 2. Read it (opens in Notepad)
notepad local-llm-setup.ps1

# 3. Allow this one script to run for the current window, then run it
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\local-llm-setup.ps1
```
</details>

### What it does

```
==> Checking your machine
[ok] Platform: windows
[ok] Chip: AMD Ryzen 7 7800X3D
[ok] Memory: 32 GB
[ok] GPU: NVIDIA GeForce RTX 4070 (12 GB VRAM)

==> Recommended setup
  Tier:     14b  (sized to your 12 GB GPU — the fast path)
  Models:   qwen2.5-coder:14b deepseek-r1:14b
  Context:  8192 tokens  (keeps memory use sane)
  Download: ~19 GB  (you have 400 GB free)
```

It then checks you have the disk space, installs Ollama **natively** (via `winget`, or the official installer if `winget` isn't present), starts the Ollama service on `localhost:11434`, pulls those models, bakes the context window into ready-to-use `*-8k` variants, runs a live smoke test, and offers to open a browser chat + set up your editor. With a discrete NVIDIA GPU you'll see a `[ok] GPU:` line (detected via `nvidia-smi`), the GPU is used for real — no WSL — and the tier is sized to your VRAM instead of system RAM.

### What it installs

| Component | What it is | Why |
| --- | --- | --- |
| [Ollama](https://ollama.com) | Local model runtime | Runs the models **natively** via `winget` (`Ollama.Ollama`), or the official `OllamaSetup.exe` from ollama.com if `winget` is absent. No WSL — your GPU is used for real |
| 1–2 models | Coder + reasoning | Chosen automatically from your hardware (VRAM if you have an NVIDIA GPU, else RAM) |
| `*-8k` context variants | Ready-to-use models | Baked locally with `ollama create` so the context window is pre-set |

Nothing is hidden and nothing is destructive. Every install asks for confirmation; `-DryRun` shows the full plan without touching your system. (Python is **not** installed — it's optional, and only used to auto-serve the browser chat and the `-Agent` tools if you already have it.)

> **Got an NVIDIA GPU?** To confirm it's really using the GPU, follow [docs/verify-windows-gpu.md](docs/verify-windows-gpu.md) — a ~5-minute check.

---

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
| `--lean` | `-Lean` | Also bake a minimal-code "ponytail" coder variant (see below) |
| `--chat` | `-Chat` | Open the local app **builder** in your browser (chat + live preview) |
| `--editor` | `-Editor` | Set up Continue in VS Code / Cursor for your local models |
| `--agent` | `-Agent` | Builder **+ approve-to-run tools** (runs commands you OK; opt-in, needs Python) |
| `--benchmark` | `-Benchmark` | Measure tokens/sec for every installed model |
| `--uninstall` | `-Uninstall` | Remove the models this tool installs (asks first) |
| `--platform <os>` | — | Override OS auto-detect (`mac`, `linux`) |
| `--version` | `-Version` | Print the version and exit |
| `--help`, `-h` | `-Help` | Show usage |

## Lean coder (ponytail) — optional `--lean`

Pass `--lean` (`-Lean` on Windows) and the script bakes an extra coder variant — `qwen2.5-coder-14b-lean` — with a "write the minimum code" system prompt. It walks the model down a ladder before it writes anything: *does this need to exist? → standard library? → platform feature? → can it be one line? → only then, minimal code.*

This matters most **on a local model**: less generated code means fewer output tokens, faster responses, and more room in your tight context window. In a side-by-side on the same prompt, the lean variant wrote **~45% fewer lines** than the plain model — and cleaner code.

```bash
ollama run qwen2.5-coder-14b-lean     # the minimal-code coder
```

The system prompt is adapted from [ponytail](https://github.com/DietrichGebert/ponytail) (MIT) — *"the best code is the code you never wrote."*

## Use it: a builder, your editor, and (optionally) tools

Running the model is only half of "useful". When setup finishes it **offers to set these up for you** — or run them anytime.

**💬 Build apps in your browser** — a local, Lovable-style **app builder**: chat on the left, a **live preview** on the right.

```bash
./local-llm-setup.sh --chat          # -Chat on Windows
```

Ask it to *"build me a stopwatch"* and it renders + runs in a sandboxed iframe (with a **Code** tab + **Download**). It works with **any code-writing model** — a builder prompt makes the model emit one self-contained HTML file. Also: a **history sidebar** (past builds) and Claude-Code-style scroll (scroll up mid-generation without getting yanked down). Served from `localhost`, which Ollama allows by default, so the page can reach your model but Ollama is **not** exposed to the web.

Under the hood it works like the tools that inspired it: it **picks the right model for each request** (⚡ Auto — a coder to build, a reasoner to explain), **plans before it builds**, **fixes its own runtime errors**, shows the work as **traceable tasks** (not raw code scrolling past), and keeps each chat as its own isolated project. With **agent mode** on it can also **clone a real website** — inspect its live palette, fonts and layout, rebuild it, then **score** how close the result is. See [how that compares to Claude Code and Lovable](#how-we-compare--and-where-were-honestly-behind) below.

**🧩 AI inside your editor** — installs [Continue](https://continue.dev) in VS Code / Cursor and points it at your local models:

```bash
./local-llm-setup.sh --editor        # -Editor on Windows
```

Then open your editor → the Continue icon in the sidebar → pick a "(local)" model. Chat, edit, and "apply" all run on your machine.

**🤖 Agent mode (opt-in)** — adds **real, approve-to-run tools**: the model can run shell commands and write files, so it can build multi-file things, not just single-page apps.

```bash
./local-llm-setup.sh --agent         # -Agent on Windows  (needs Python)
```

Every action waits for you to click **Approve**, and everything happens inside a workspace folder (`~/.local-llm-setup/workspace`), on `localhost` only. It's **off by default and consented** because an approved command runs with your full permissions — see the safety notes in [CHANGELOG.md](CHANGELOG.md).

## How we compare — and where we're honestly behind

This project exists to bring **[Claude Code](https://www.anthropic.com/claude-code)**- and **[Lovable](https://lovable.dev)**-style building to a **100% local, free, private** stack. We are **not at parity yet** — and the honest thing is to show exactly where. **Every ❌ below is a public to-do, not a secret, and we're committed to closing them.**

What you trade that gap *for*: it runs entirely on your machine, costs nothing, works offline, and your code never leaves the building.

| Tool capability | **local-llm-setup** | Claude Code | Lovable |
|---|:---:|:---:|:---:|
| Build & edit code | ✅ | ✅ | ✅ |
| Live preview | ✅ | ✅ | ✅ |
| Plan before building | ✅ | ✅ | ✅ |
| Run commands / terminal | ✅ | ✅ | ⚠️ |
| Read / write files | ✅ | ✅ | ✅ |
| Self-repair runtime errors | ✅ | ✅ | ✅ |
| Self-correcting "owns its mistakes" voice | ✅ | ✅ | ⚠️ |
| Fetch & inspect a web page | ✅ | ✅ | ✅ |
| Extract a site's palette & fonts | ✅ | ✅ | ✅ |
| **Clone a real website** | ✅ | ✅ | ✅ |
| Auto-pick the model per request | ✅ ⚡ | ❌ | ❌ |
| Screenshot a page | ⚠️ | ✅ | ✅ |
| Visual / fidelity self-check | ⚠️ | ✅ | ✅ |
| Web search | ❌ | ✅ | ⚠️ |
| Image generation | ❌ | ⚠️ | ✅ |
| Multi-file projects | ❌ | ✅ | ✅ |
| Backend / database / auth | ❌ | ⚠️ | ✅ |
| One-click deploy | ❌ | ✅ | ✅ |
| Git / repo sync | ❌ | ✅ | ✅ |
| **Runs 100% local & offline** | ✅ | ❌ | ❌ |
| **Free — no subscription** | ✅ | ❌ | ❌ |
| **Your code never leaves your machine** | ✅ | ❌ | ❌ |

<sub>✅ have it · ⚠️ partial, best-effort, or a different approach · ❌ not yet — building toward it</sub>

**Where we're behind, and committed to closing:** multi-file projects, web search, image generation, a backend/database, one-click deploy, and Git sync. Two honest caveats on the ⚠️s:

- **Visual check is _structural_, not pixel-perfect.** We score a clone's palette, fonts and sections against the real page — local coder models aren't vision-capable yet, so we measure the design tokens rather than "looking" at the screenshot. It's the more *actionable* signal for a code model, but it isn't the same thing.
- **Screenshots are best-effort** — we reuse an already-installed Chrome/Chromium (no extra dependency) and degrade gracefully if none is found.

The roadmap toward parity lives in [`docs/PRD-local-builder-v2-tools-and-goals.md`](docs/PRD-local-builder-v2-tools-and-goals.md). **Issues and PRs that turn a ❌ into a ✅ are exactly what this project is for.**

## After setup

```bash
ollama run qwen2.5-coder-14b-8k       # chat with your context-tuned model in the terminal
ollama list                           # see everything you have
./local-llm-setup.sh --benchmark      # how fast is each model? (tokens/sec)
```

Point any OpenAI-compatible app, IDE, or agent at it directly:

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
