# Verifying GPU acceleration on Windows + NVIDIA

The Windows script ([`local-llm-setup.ps1`](../local-llm-setup.ps1)) sizes the model to your
NVIDIA **VRAM** and runs Ollama **natively**, so a discrete GPU does the heavy lifting.

CI can only *dry-run* the script on GPU-less runners, and the maintainer's dogfood machine is an
Apple-silicon Mac — so the GPU **detection + sizing logic is verified** (see below), but the one
thing left to confirm on real hardware is that Ollama actually **offloads inference to the GPU**.
This page is a ~5-minute check anyone with an NVIDIA Windows box can run.

> **Logic already verified (2026-06-14):** running the real `.ps1` under PowerShell with a
> simulated `nvidia-smi` picks the right tier at every VRAM band — 8 GB → `7b`, 12 GB → `14b`,
> 23 GB → `32b`, 47 GB → `70b`, and a sub-6 GB card correctly falls back to system-RAM sizing.
> What remains is purely the real-hardware acceleration step.

## Prerequisites

- Windows 10 or 11 with an NVIDIA GPU
- Up-to-date NVIDIA drivers (so the `nvidia-smi` command works)

## Steps

**1. Open PowerShell.** Click **Start**, type **`PowerShell`**, press **Enter**. A window opens with a `>` prompt.

**2. Confirm Windows sees the GPU.** Type and press Enter:

```powershell
nvidia-smi
```

You should see a table with your GPU's name and a **Memory** column (e.g. `24564MiB`).
*If you get "not recognized"* → install/repair the NVIDIA drivers from [nvidia.com/drivers](https://www.nvidia.com/Download/index.aspx), then retry.

**3. Download the script, allow it for this window, and preview it (no changes yet).**

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/hamza-ali-shahjahan/local-llm-setup/main/local-llm-setup.ps1 -OutFile local-llm-setup.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\local-llm-setup.ps1 -DryRun
```

**✅ Check 1 — detection + sizing.** In the dry-run output you should see **both**:

```
✓ GPU: <your card> (NN GB VRAM)
  Tier:     32b  (sized to your NN GB GPU — the fast path)
```

That confirms VRAM-based sizing on real hardware. (The exact tier depends on your VRAM — see the band table above.)

**4. Do the real run.**

```powershell
.\local-llm-setup.ps1
```

Accept the plan. It installs Ollama natively, pulls the models, and runs a smoke test that prints something like `eval rate: NN tokens/s`.

**✅ Check 2 — the GPU is actually doing the work.** Open a **second** PowerShell window and run:

```powershell
nvidia-smi -l 1
```

Then, in the first window, chat with the model (`ollama run <model-from-ollama-list>`) and watch the second window. You should see:

- an **`ollama`** process listed under *Processes* holding GPU memory, and
- **GPU-Util %** jumping during generation.

That's the proof the model is running on the GPU, not the CPU.

## What to capture (optional, to share back)

- the `✓ GPU:` and `Tier:` lines from Check 1,
- the smoke-test `eval rate` (tokens/sec),
- one `nvidia-smi` snapshot showing the `ollama` process on the GPU.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `nvidia-smi` not recognized | Install/repair NVIDIA drivers, reboot, retry. |
| "running scripts is disabled on this system" | Re-run the `Set-ExecutionPolicy -Scope Process …` line (it only affects the current window). |
| `winget` not found | Nothing to do — the script auto-downloads the official Ollama installer. |
| GPU-Util stays at 0 % during generation | Check Ollama's server log for CUDA detection; make sure the model fits in VRAM — try a smaller tier with `.\local-llm-setup.ps1 -Tier 7b`. |

## Reference numbers

For scale: on the dogfood machine (Apple M5 Pro / 24 GB unified memory) `qwen2.5-coder:14b` (Q4)
runs at **~25.7 tok/s**. A comparable NVIDIA GPU with enough VRAM to hold the model should be in
the same ballpark or faster.
