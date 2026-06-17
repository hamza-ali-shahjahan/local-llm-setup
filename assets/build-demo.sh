#!/usr/bin/env bash
# Build the README hero GIF: a side-by-side of two terminal panes.
#
#   LEFT  — "macOS / Linux": a REAL recorded run of ./local-llm-setup.sh --dry-run.
#           Genuine hardware auto-detection and the sized model plan. The only thing
#           stubbed is the CPU brand probe (sysctl), pinned to a representative
#           "M4 chip" so the demo is machine-independent — RAM, the tier maths and
#           every other step are real.
#   RIGHT — "Windows": a SCRIPTED / SIMULATED PowerShell preview (assets/win-sim.sh).
#           We have no Windows machine and the PowerShell path is unverified, so this
#           pane is openly labelled with an always-visible PREVIEW banner.
#
# Pipeline: vhs records each pane to mp4 -> ffmpeg hstacks them -> palette'd GIF.
# Requires: vhs, ffmpeg (both via `brew install vhs ffmpeg`).
#
# Usage (from the repo root):   bash assets/build-demo.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
command -v vhs    >/dev/null || { echo "need vhs (brew install vhs)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "need ffmpeg (brew install ffmpeg)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- sysctl shim: report a representative "M4 chip" for the brand-string probe only;
#     delegate every other key to the real binary so RAM etc. stay genuine. -----------
mkdir -p "$WORK/shim"
cat > "$WORK/shim/sysctl" <<'SHIM'
#!/bin/bash
for a in "$@"; do case "$a" in
  machdep.cpu.brand_string) echo "M4 chip"; exit 0 ;;
esac; done
exec /usr/sbin/sysctl "$@"
SHIM
chmod +x "$WORK/shim/sysctl"
export DEMO_SHIM="$WORK/shim"

# --- left pane: the real installer (M4 via the shim above) -------------------------
# A wrapper that clears, prints the pane header, then runs the real installer. Running
# it from inside the (hidden) wrapper means the wrapper's own `clear` wipes the typed
# command line, so the recording shows a clean header + real output — the same proven
# pattern the Windows pane uses. The header is a caption, not faked installer output.
cat > "$WORK/mac-run.sh" <<RUN
#!/bin/bash
cd "$REPO"
clear
printf '\033[1;38;5;45m  macOS / Linux \033[0m \033[2m· real run\033[0m\n\n'
exec ./local-llm-setup.sh --dry-run
RUN
chmod +x "$WORK/mac-run.sh"

cat > "$WORK/mac.tape" <<TAPE
Output "$WORK/mac.mp4"
Set Shell "bash"
Set FontSize 14
Set Width 700
Set Height 520
Set Padding 22
Set Theme "Catppuccin Mocha"
Hide
Type "export PATH=$DEMO_SHIM:\$PATH" Enter
Type "export PS1='\$ '" Enter
Type "clear" Enter
Type "bash '$WORK/mac-run.sh'" Enter
Sleep 1400ms
Show
Sleep 6000ms
TAPE

# --- right pane: the simulated PowerShell preview ----------------------------------
cat > "$WORK/win.tape" <<TAPE
Output "$WORK/win.mp4"
Set Shell "bash"
Set FontSize 14
Set Width 700
Set Height 520
Set Padding 22
Set Theme "Catppuccin Mocha"
Hide
Type "export PS1='\$ '" Enter
Type "clear" Enter
Type "bash '$REPO/assets/win-sim.sh'" Enter
Sleep 900ms
Show
Sleep 6800ms
TAPE

echo "==> recording macOS / Linux pane (real run)"; vhs "$WORK/mac.tape"
echo "==> recording Windows pane (simulated preview)"; vhs "$WORK/win.tape"

# --- combine: clone-pad the shorter pane, hstack, then palette'd GIF ----------------
echo "==> stacking + encoding GIF"
ffmpeg -y -i "$WORK/mac.mp4" -i "$WORK/win.mp4" \
  -filter_complex "[1:v]tpad=stop_mode=clone:stop_duration=2.1[w];[0:v][w]hstack=inputs=2[v]" \
  -map "[v]" -c:v libx264 -pix_fmt yuv420p "$WORK/combined.mp4"
ffmpeg -y -i "$WORK/combined.mp4" \
  -vf "fps=13,scale=1200:-2:flags=lanczos,palettegen=stats_mode=diff" "$WORK/palette.png"
ffmpeg -y -i "$WORK/combined.mp4" -i "$WORK/palette.png" \
  -lavfi "fps=13,scale=1200:-2:flags=lanczos,paletteuse=dither=bayer:bayer_scale=3" \
  "$REPO/assets/demo.gif"

echo "==> wrote assets/demo.gif"
