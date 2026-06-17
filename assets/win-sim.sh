#!/bin/bash
# SIMULATED Windows / PowerShell preview for the README hero GIF.
# This is NOT a real run — we have no Windows machine and the PowerShell path is
# unverified. Every line here is scripted. The banner says exactly that.
esc=$'\033'
RST="${esc}[0m"; BANNER="${esc}[30;43m"; PSC="${esc}[38;5;81m"
GREEN="${esc}[32m"; DIM="${esc}[2m"; BOLD="${esc}[1m"; YEL="${esc}[33m"; GREY="${esc}[90m"
HDR="${esc}[1;38;5;45m"
pause(){ sleep "${1:-0.35}"; }

clear
# --- pane header + always-visible preview banner (both stay pinned: content fits) ---
printf '%s  Windows %s %s· simulated preview%s\n' "$HDR" "$RST" "$DIM" "$RST"
printf '%s PREVIEW · experimental · not yet verified on Windows — help us test %s\n' "$BANNER" "$RST"
echo
printf '%sPS C:\\Users\\you>%s .\\local-llm-setup.ps1 -DryRun\n' "$PSC" "$RST"
pause 0.7
echo
printf '%s==>%s Checking your machine\n' "$BOLD" "$RST"; pause
printf '%s✓%s Platform: windows\n' "$GREEN" "$RST"; pause
printf '%s✓%s Chip: %s(simulated)%s 12-core x64\n' "$GREEN" "$RST" "$DIM" "$RST"; pause
printf '%s✓%s Memory: 32 GB\n' "$GREEN" "$RST"; pause 0.5
echo
printf '%s==>%s Recommended setup\n' "$BOLD" "$RST"; pause
printf '  Tier:     %s14b%s  (sized to your 32 GB of memory)\n' "$BOLD" "$RST"; pause
printf '  Models:   qwen2.5-coder:14b deepseek-r1:14b\n'; pause
printf '  Context:  8192 tokens\n'; pause
printf '  Download: ~19 GB\n'; pause 0.6
echo
printf '%s[PREVIEW]%s these steps are scripted — the Windows\n' "$YEL" "$RST"
printf '%s          path is not yet tested on real hardware.%s\n' "$GREY" "$RST"
pause 2.2
