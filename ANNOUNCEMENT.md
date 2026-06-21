# 📣 The local builder can now SEE

`local-llm-setup` turns one command into a private, on-device AI dev environment: Ollama + the
right coder/reasoner models for your machine, plus a Lovable/Bolt-style app builder with live
preview — running **100% locally**. No cloud, no API keys, no per-token bill.

The latest releases give that builder **eyes**.

## ✨ What's new

### One-click vision model
Open **🧩 Capabilities** in the builder and click **Install** on the vision model — it streams the
download with a live progress bar and flips to **✓ Installed** on its own. No terminal. Clear,
colour-coded status now shows exactly what's installed and usable *right now*.

### The vision-critique clone loop
Cloning a website used to be **structural only** — the builder read the page into a text digest
(palette, fonts, sections, copy) and rebuilt from that. Accurate, but blind to pixels.

Now, with a vision model installed, every clone gets a **visual pass**: the builder screenshots
**your clone beside the original**, a local vision model (`qwen2.5vl:7b`) names the visual gaps —
layout, spacing, colour, typography, missing sections — and the coder applies them and re-renders,
keeping the highest-scoring version. It's the lever past the text-only plateau, and it runs
entirely on your machine.

## 🔒 Why it matters
Everything stays on your hardware — no prompt leaves your laptop — and the builder can now look at
a real site and improve its own work toward it.

## 🚀 Try it
One command (macOS / Linux / Windows) — see the [README](README.md). Then open the builder, click
**🧩 Capabilities → Install vision model**, and ask it to `clone <your-favourite-site>`.

> **Honest note:** these are local 7B/14B models — expect *meaningfully close*, not pixel-perfect,
> and the vision loop adds a couple of minutes per clone (it swaps models per round on 24 GB). The
> win: genuinely useful, genuinely private, genuinely yours.

*Details and the implementation gotchas: [docs/vision-model.md](docs/vision-model.md). Full history: [CHANGELOG.md](CHANGELOG.md).*
