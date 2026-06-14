---
name: Bug report
about: Something didn't work during setup
title: "[bug] "
labels: bug
---

**What happened**
A clear description of the problem.

**Your machine**
- OS (macOS / Linux distro / Windows 10/11):
- Which script (`local-llm-setup.sh` or `local-llm-setup.ps1`):
- Chip / CPU (e.g. Apple M5 Pro; Linux: `lscpu` "Model name"; Windows: shown in the script's output):
- GPU, if any (e.g. NVIDIA RTX 4070 — `nvidia-smi`):
- Total RAM (macOS: `sysctl hw.memsize` · Linux: `grep MemTotal /proc/meminfo` · Windows: shown in the script's output):

**Script output**
Paste the relevant output. Running with `--dry-run` (`-DryRun` on Windows) and pasting that helps too.

**What you expected instead**
