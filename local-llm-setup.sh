#!/usr/bin/env bash
#
# local-llm-setup.sh — Zero-to-running local LLM in one command (macOS + Linux).
#
# Auto-detects your OS and hardware (including an NVIDIA GPU, if present), picks
# models that actually fit your machine, checks you have the disk space, installs
# the Ollama runtime, downloads the right models, sets a sane context window, and
# runs a smoke test so you KNOW it works — then offers a browser chat + editor.
#
# Designed for someone doing this for the very first time. No prior knowledge
# assumed. Nothing destructive — it only installs Ollama + the models you OK.
#
# Windows users: a native PowerShell version lives next to this file as
# local-llm-setup.ps1 (no WSL needed). See the README.
#
# Usage:
#   ./local-llm-setup.sh                  # interactive, recommended
#   ./local-llm-setup.sh --yes            # accept all defaults, no prompts
#   ./local-llm-setup.sh --dry-run        # show what it WOULD do, change nothing
#   ./local-llm-setup.sh --tier 14b       # force a model tier (7b|14b|32b|70b)
#   ./local-llm-setup.sh --platform linux # override OS auto-detect (mac|linux)
#   ./local-llm-setup.sh --lean           # also bake a minimal-code "ponytail" coder variant
#   ./local-llm-setup.sh --chat           # open a local chat in your browser (no extra installs)
#   ./local-llm-setup.sh --editor         # set up Continue in VS Code / Cursor for your local models
#   ./local-llm-setup.sh --agent          # builder + approve-to-run tools (runs commands you OK)
#   ./local-llm-setup.sh --benchmark      # measure tokens/sec for installed models
#   ./local-llm-setup.sh --uninstall      # remove the models this tool installs
#   ./local-llm-setup.sh --version        # print the version and exit
#   ./local-llm-setup.sh --help
#
set -euo pipefail
VERSION="1.15.1"

# ----------------------------------------------------------------------------
# Pretty output (degrades gracefully if the terminal has no color)
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

say()   { printf "%s\n" "$*"; }
step()  { printf "\n${BOLD}${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$*"; }
err()   { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
ask()   { # ask "Question?" default(y/n) -> returns 0 for yes
  local q="$1" def="${2:-y}" reply
  $ASSUME_YES && { say "${DIM}${q} [auto-yes]${RESET}"; return 0; }
  read -r -p "$(printf "${CYAN}?${RESET} %s [%s] " "$q" "$def")" reply || true
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}
run() { # run a command, honoring --dry-run
  if $DRY_RUN; then printf "${DIM}[dry-run] %s${RESET}\n" "$*"; else eval "$@"; fi
}
# Pull a model, resuming through transient network drops (Ollama keeps the
# partial data, so retrying continues where it left off). Quiet on non-TTY
# (unattended/CI) so the progress bar doesn't flood logs with ANSI redraws.
pull_with_retry() {
  local model="$1" max="${2:-8}" i
  for (( i=1; i<=max; i++ )); do
    if [[ -t 1 ]]; then
      ollama pull "$model" && return 0
    else
      ollama pull "$model" >/dev/null 2>&1 && return 0
    fi
    warn "Download of $model interrupted (attempt $i/$max) — resuming in ${i}s..."
    sleep "$i"
  done
  return 1
}

# ----------------------------------------------------------------------------
# Args
# ----------------------------------------------------------------------------
ASSUME_YES=false
DRY_RUN=false
FORCE_TIER=""
FORCE_OS=""
LEAN=false
MODE="setup"   # setup | benchmark | uninstall
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)    ASSUME_YES=true ;;
    --dry-run)   DRY_RUN=true ;;
    --tier)      FORCE_TIER="${2:-}"; shift ;;
    --platform)  FORCE_OS="${2:-}"; shift ;;
    --lean)      LEAN=true ;;
    --chat)      MODE="chat" ;;
    --editor)    MODE="editor" ;;
    --agent)     MODE="agent" ;;
    --benchmark) MODE="benchmark" ;;
    --uninstall) MODE="uninstall" ;;
    --version|-V) echo "local-llm-setup ${VERSION}"; exit 0 ;;
    --help|-h)
      # Print only the header doc block (lines 2.. up to the first non-comment),
      # not every '# ----' divider scattered through the file.
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Model tiers — edit these as new models ship. Tags are Ollama model names.
# Each tier lists: a coder model and a reasoning model (this user's two jobs).
# ----------------------------------------------------------------------------
tier_models() {
  case "$1" in
    7b)  echo "qwen2.5-coder:7b deepseek-r1:7b" ;;
    14b) echo "qwen2.5-coder:14b deepseek-r1:14b" ;;
    32b) echo "qwen2.5-coder:32b deepseek-r1:32b" ;;
    70b) echo "qwen2.5-coder:32b deepseek-r1:70b" ;;
    *)   echo "" ;;
  esac
}
# Rough on-disk size (GB) of a tier's two models at Ollama's default quant.
# The context-tuned *-Nk variants reuse the same content-addressed blobs, so
# they add no meaningful disk — these numbers are the real download footprint.
tier_disk_gb() {
  case "$1" in
    7b)  echo 10 ;;
    14b) echo 19 ;;
    32b) echo 40 ;;
    70b) echo 63 ;;
    *)   echo 0 ;;
  esac
}
CTX=8192   # default context window — big enough for real work, light on RAM
CHAT_DIR="${HOME}/.local-llm-setup/chat"   # where the bundled chat page is written
CHAT_PORT=8765                              # localhost port the chat page is served on
AGENT_PY="${HOME}/.local-llm-setup/agent-server.py"   # the optional --agent tool server
AGENT_VENV="${HOME}/.local-llm-setup/.agent-venv"     # venv holding Playwright -> render-based cloning

# Name of the context-tuned variant for a model tag, e.g.
#   qwen2.5-coder:14b  ->  qwen2.5-coder-14b-8k
# The size is kept in the name on purpose: running the script at a different
# tier later (say 7b) then won't silently overwrite an earlier tier's variant.
ctx_alias() { echo "${1/:/-}-$((CTX/1024))k"; }

# Name of the optional --lean (ponytail) variant for a coder model, e.g.
#   qwen2.5-coder:14b  ->  qwen2.5-coder-14b-lean
lean_alias() { echo "${1/:/-}-lean"; }

# Write a Modelfile (path $1) for a lean coder variant of model $2: the tuned
# context window plus a minimal-code system prompt adapted from ponytail
# (https://github.com/DietrichGebert/ponytail, MIT). Steering the model to the
# simplest solution pays off most on a small local model — less code means
# fewer tokens, faster output, and more room in the context window.
write_lean_modelfile() {
  { printf 'FROM %s\nPARAMETER num_ctx %s\nSYSTEM """' "$2" "$CTX"
    cat <<'PONYTAIL'
You are a lazy senior developer. Lazy means efficient, not careless. The best code is the code never written.

Before writing any code, stop at the first rung that holds:
1. Does this need to be built at all? (YAGNI)
2. Does the standard library already do this? Use it.
3. Does a native platform feature cover it? Use it.
4. Does an already-installed dependency solve it? Use it.
5. Can this be one line? Make it one line.
6. Only then: write the minimum code that works.

Rules:
- No abstractions that weren't explicitly requested. No new dependency if avoidable. No boilerplate.
- Deletion over addition. Boring over clever. Fewest files possible.
- Mark intentional simplifications with a `ponytail:` comment naming any ceiling and upgrade path.
Not lazy about: input validation at trust boundaries, error handling, security, accessibility, anything explicitly requested.
PONYTAIL
    printf '"""\n'
  } > "$1"
}

# Installed model names, with the implicit ":latest" tag stripped. `ollama
# create` tags a variant ":latest", so `ollama list` prints e.g.
# "qwen2.5-coder-14b-8k:latest" — stripping it lets our bare names match
# (and `ollama rm <bare>` still removes the ":latest" copy).
installed_models() { ollama list 2>/dev/null | awk 'NR>1{print $1}' | sed 's/:latest$//'; }

# ----------------------------------------------------------------------------
# 1. Detect the OS (auto, unless --platform forces it), then the hardware
# ----------------------------------------------------------------------------
OS="${FORCE_OS:-}"
if [[ -z "$OS" ]]; then
  case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux)  OS="linux" ;;
    *)      OS="$(uname -s)" ;;
  esac
fi
if [[ "$OS" != "mac" && "$OS" != "linux" ]]; then
  err "Unsupported platform: ${OS}"
  say "  Supported: macOS (mac) and Linux (linux)."
  say "  On Windows, run this inside WSL2, then pass: --platform linux"
  exit 1
fi

# OS-specific bits, isolated to two functions. Everything below them is shared.
detect_chip() {
  if [[ "$OS" == "mac" ]]; then
    local c; c="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
    [[ -z "$c" ]] && c="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/{print $2; exit}')"
    [[ -z "$c" ]] && c="Unknown CPU"
    echo "$c"
  else
    local c; c="$(lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}')"
    [[ -z "$c" ]] && c="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$c" ]] && c="$(uname -m) CPU"
    echo "$c"
  fi
}
detect_ram_gb() {
  if [[ "$OS" == "mac" ]]; then
    local b; b="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    echo $(( b / 1024 / 1024 / 1024 ))
  else
    local kb; kb="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
    echo $(( kb / 1024 / 1024 ))
  fi
}
# Detect a dedicated NVIDIA GPU's VRAM (GB). Sets GPU_NAME + GPU_VRAM_GB.
# Apple silicon shares one unified memory pool (already covered by RAM), and
# AMD/Intel GPUs vary too much to size reliably here — both fall back to RAM.
GPU_NAME=""
GPU_VRAM_GB=0
detect_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  local line; line="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
  [[ -z "$line" ]] && return 0
  GPU_NAME="$(echo "$line" | awk -F', *' '{print $1}')"
  local mb; mb="$(echo "$line" | awk -F', *' '{print $2}')"
  [[ "$mb" =~ ^[0-9]+$ ]] && GPU_VRAM_GB=$(( mb / 1024 ))
}
# Free disk (GB) on the filesystem that holds Ollama's models, walking up to
# the nearest existing parent if ~/.ollama doesn't exist yet. 0 means unknown.
free_disk_gb() {
  local d="${OLLAMA_MODELS:-$HOME/.ollama}"
  while [[ ! -d "$d" && "$d" != "/" ]]; do d="$(dirname "$d")"; done
  local kb; kb="$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || { echo 0; return; }
  echo $(( kb / 1024 / 1024 ))
}

step "Checking your machine"
CHIP="$(detect_chip)"
RAM_GB="$(detect_ram_gb)"
detect_gpu
ok "Platform: ${BOLD}${OS}${RESET}"
ok "Chip: ${BOLD}${CHIP}${RESET}"
ok "Memory: ${BOLD}${RAM_GB} GB${RESET}"
[[ -n "$GPU_NAME" ]] && ok "GPU: ${BOLD}${GPU_NAME}${RESET} (${GPU_VRAM_GB} GB VRAM)"

# ----------------------------------------------------------------------------
# Maintenance modes (--benchmark / --uninstall): these act on what's already
# installed and exit, so they run before the setup recommendation below.
# ----------------------------------------------------------------------------
# Every model this tool can install, across all tiers, plus the context-tuned
# variant it bakes for each — used by --uninstall to know what's "ours".
all_managed_models() {
  local t m
  for t in 7b 14b 32b 70b; do
    for m in $(tier_models "$t"); do
      echo "$m"
      echo "$(ctx_alias "$m")"            # current naming, e.g. qwen2.5-coder-14b-8k
      echo "${m%%:*}-$((CTX/1024))k"      # legacy pre-1.1.1 naming, e.g. qwen2.5-coder-8k
      [[ "$m" == *coder* ]] && echo "$(lean_alias "$m")"   # optional --lean variant
    done
  done | sort -u
}

do_benchmark() {
  step "Benchmark — tokens/sec for your installed models"
  command -v ollama >/dev/null 2>&1 || { err "Ollama isn't installed yet. Run setup first."; exit 1; }
  local models; models="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
  [[ -z "$models" ]] && { err "No models installed yet. Run ./local-llm-setup.sh first."; exit 1; }
  say "  ${DIM}Each model writes one short sentence; we report its generation rate.${RESET}"
  say ""
  printf "  ${BOLD}%-34s %s${RESET}\n" "MODEL" "EVAL RATE"
  local m rate
  for m in $models; do
    if $DRY_RUN; then say "${DIM}[dry-run] benchmark $m${RESET}"; continue; fi
    rate="$(ollama run "$m" --verbose "Write one sentence about the sea." 2>&1 \
            | awk -F': +' '/^[[:space:]]*eval rate/{print $2; exit}')"
    printf "  %-34s %s\n" "$m" "${rate:-n/a}"
  done
  ok "Done."
}

do_uninstall() {
  step "Uninstall — removing the models this tool installs"
  command -v ollama >/dev/null 2>&1 || { ok "Ollama isn't installed — nothing to do."; exit 0; }
  local installed=() m
  while IFS= read -r m; do
    installed_models | grep -qx "$m" && installed+=("$m")
  done < <(all_managed_models)
  if (( ${#installed[@]} == 0 )); then
    ok "None of this tool's models are installed — nothing to remove."
  else
    say "  These models will be removed:"
    for m in "${installed[@]}"; do say "    ${DIM}-${RESET} $m"; done
    if $DRY_RUN; then
      for m in "${installed[@]}"; do say "${DIM}[dry-run] ollama rm $m${RESET}"; done
    elif ask "Remove the ${#installed[@]} model(s) above?" n; then
      for m in "${installed[@]}"; do
        if ollama rm "$m" >/dev/null 2>&1; then ok "Removed $m"; else warn "Could not remove $m"; fi
      done
    else
      say "  Left models in place."
    fi
  fi
  if ask "Also uninstall the Ollama runtime itself?" n; then
    if $DRY_RUN; then
      say "${DIM}[dry-run] uninstall the Ollama runtime${RESET}"
    elif [[ "$OS" == "mac" ]] && command -v brew >/dev/null 2>&1; then
      run "brew services stop ollama"; run "brew uninstall ollama"
      ok "Ollama runtime removed."
    else
      warn "Automatic runtime removal isn't wired up on Linux."
      say "  Official steps: ${DIM}https://github.com/ollama/ollama/blob/main/docs/linux.md#uninstall${RESET}"
    fi
  fi
  ok "Uninstall complete."
}

# ----------------------------------------------------------------------------
# Chat + editor helpers (used by --chat / --editor and offered after setup)
# ----------------------------------------------------------------------------
# Open a URL in the default browser (degrades to printing it).
open_url() {
  if [[ "$OS" == "mac" ]]; then open "$1" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 || true
  else say "  Open this in your browser:  ${BOLD}$1${RESET}"; fi
}

# Write the self-contained local chat page to $1. It talks to Ollama's local
# API; served from localhost (which Ollama allows by default) it needs no
# Docker and no extra install, and does NOT expose Ollama to the wider web.
write_chat_html() {
  cat > "$1" <<'CHATHTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Local LLM Builder</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body { margin: 0; display: flex; flex-direction: column; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0d1017; color: #e6e6e6; overflow: hidden; }

  header { flex: none; display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; gap: 12px; padding: 10px 16px; border-bottom: 1px solid #1e2430; background: #11151d; }
  .hgroup { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .hright { justify-self: end; }
  /* Capabilities modal */
  .modal-bg { position: fixed; inset: 0; z-index: 100; background: rgba(0,0,0,.62); display: flex; align-items: center; justify-content: center; padding: 24px; }
  .modal-bg[hidden] { display: none; }
  .modal { background: #11151d; border: 1px solid #2a3140; border-radius: 14px; max-width: 720px; width: 100%; max-height: 86vh; display: flex; flex-direction: column; box-shadow: 0 24px 64px rgba(0,0,0,.6); }
  .modal h3 { margin: 0; padding: 15px 20px; border-bottom: 1px solid #1e2430; font-size: 15px; color: #cfe3ff; display: flex; align-items: center; gap: 9px; flex: none; }
  .modal .mclose { margin-left: auto; background: #1a2230; border: 1px solid #2a3140; color: #c7d0dd; border-radius: 7px; width: 28px; height: 28px; cursor: pointer; font-size: 16px; line-height: 1; }
  .modal .mbody { padding: 14px 20px 20px; overflow-y: auto; }
  .sysline { background: #0f131b; border: 1px solid #20283a; border-radius: 10px; padding: 11px 13px; font-size: 13px; color: #b6c0cf; line-height: 1.5; }
  .sysline b { color: #aef0c4; font-weight: 600; }
  .caph { font-size: 11px; text-transform: uppercase; letter-spacing: .05em; color: #5b6472; margin: 18px 0 4px; }
  .caprow { display: flex; align-items: flex-start; gap: 11px; padding: 9px 0; border-top: 1px solid #161c28; }
  .caprow .st { flex: none; width: 18px; text-align: center; font-size: 14px; }
  .caprow .cn { flex: 1; min-width: 0; }
  .caprow .cn b { color: #dbe6f2; font-weight: 600; font-size: 13.5px; }
  .caprow .cn div { font-size: 12px; margin-top: 2px; }
  .caprow .cn .sub { color: #6b7787; }
  .caprow .cn .act { color: #7fd0ff; }
  .caprow .cn .act code, .sysline code { background: #0a0d13; border: 1px solid #2a3140; border-radius: 4px; padding: 1px 5px; font-size: 11.5px; }
  .caprow.locked { opacity: .5; }
  .caplegend { font-size: 11.5px; color: #5b6472; margin-top: 18px; padding-top: 12px; border-top: 1px solid #1e2430; line-height: 1.7; }
  header h1 { font-size: 14px; margin: 0; font-weight: 600; color: #cfe3ff; display: flex; align-items: center; gap: 8px; white-space: nowrap; }
  header .dot { width: 8px; height: 8px; border-radius: 50%; background: #2ecc71; box-shadow: 0 0 8px #2ecc71; flex: none; }
  .grow { flex: 1; }
  .tbtn { background: #161b26; color: #c7d0dd; border: 1px solid #2a3140; border-radius: 8px; padding: 6px 12px; font-size: 13px; cursor: pointer; }
  .tbtn:hover { background: #1c2433; }
  .tbtn:disabled { opacity: .45; cursor: default; }
  .toggle { display: flex; align-items: center; gap: 7px; font-size: 13px; color: #aab4c4; cursor: pointer; user-select: none; }
  .toggle input { display: none; }
  .toggle .sw { width: 34px; height: 19px; border-radius: 19px; background: #2a3140; position: relative; transition: background .15s; }
  .toggle .sw::after { content: ""; position: absolute; width: 15px; height: 15px; border-radius: 50%; background: #cfd6e0; top: 2px; left: 2px; transition: left .15s; }
  .toggle input:checked + .sw { background: #2b6cff; }
  .toggle input:checked + .sw::after { left: 17px; }
  /* centered toggle cluster in the nav bar, each with an info icon + hover explainer */
  .toggles { display: flex; align-items: center; gap: 22px; justify-self: center; }
  .togwrap { display: flex; align-items: center; gap: 6px; }
  .info { position: relative; display: inline-flex; align-items: center; justify-content: center; width: 16px; height: 16px; border-radius: 50%; border: 1px solid #3a4456; color: #8a95a5; font: italic 700 11px/1 Georgia, "Times New Roman", serif; cursor: help; user-select: none; flex: none; }
  .info:hover, .info:focus { color: #cfe3ff; border-color: #2b6cff; outline: none; }
  .info .tip { position: absolute; top: calc(100% + 9px); left: 50%; transform: translateX(-50%); width: 252px; background: #141923; border: 1px solid #2a3f63; border-radius: 9px; padding: 10px 12px; font: 400 12px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: #c2cedd; box-shadow: 0 14px 32px rgba(0,0,0,.55); opacity: 0; visibility: hidden; transition: opacity .12s ease; z-index: 60; text-align: left; pointer-events: none; }
  .info .tip b { color: #cfe3ff; font-weight: 600; }
  .info .tip code { background: #0d1017; border: 1px solid #2a3140; border-radius: 4px; padding: 0 4px; font-size: 11px; }
  .info .tip::before { content: ""; position: absolute; bottom: 100%; left: 50%; transform: translateX(-50%); border: 6px solid transparent; border-bottom-color: #2a3f63; }
  .info:hover .tip, .info:focus .tip { opacity: 1; visibility: visible; }

  .picker { position: relative; }
  .picker-btn { display: flex; align-items: center; gap: 8px; max-width: 230px; background: #0d1017; color: #e6e6e6; border: 1px solid #2a3140; border-radius: 8px; padding: 6px 10px; font-size: 13px; cursor: pointer; }
  .picker-btn .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .picker-btn .caret { color: #7d8694; font-size: 10px; flex: none; }
  .menu { position: absolute; top: calc(100% + 6px); right: 0; z-index: 40; margin: 0; padding: 6px; list-style: none; min-width: 230px; max-height: 60vh; overflow-y: auto; background: #141923; border: 1px solid #2a3140; border-radius: 10px; box-shadow: 0 14px 34px rgba(0,0,0,.55); }
  .menu[hidden] { display: none; }
  .menu li { padding: 8px 10px 8px 26px; border-radius: 6px; cursor: pointer; font-size: 13px; white-space: nowrap; position: relative; }
  .menu li:hover { background: #1c2636; }
  .menu li.sel { color: #7fd0ff; }
  .menu li.sel::before { content: "\2713"; position: absolute; left: 9px; top: 9px; }
  .menu { min-width: 270px; }
  .menu li.auto, .menu li.model { white-space: normal; padding: 9px 10px 9px 26px; }
  .menu li.sep { padding: 8px 10px 3px 10px; font-size: 10.5px; text-transform: uppercase; letter-spacing: .05em; color: #4d5765; cursor: default; }
  .menu li.sep:hover { background: transparent; }
  .menu .mtop { display: flex; align-items: center; gap: 7px; }
  .menu .mname { font-weight: 500; }
  .menu .msub { font-size: 11.5px; color: #6b7787; margin-top: 2px; }
  .menu .mbadge { font-size: 10px; font-weight: 600; color: #9fc2ff; background: #1a2740; border: 1px solid #2a3f63; border-radius: 5px; padding: 1px 6px; }
  .menu li.auto .mbadge { color: #aef0c4; background: #14271c; border-color: #2a5a3c; }

  main { flex: 1; display: flex; min-height: 0; }

  /* history sidebar */
  .sidebar { flex: none; width: 212px; display: flex; flex-direction: column; min-height: 0; background: #0b0e14; border-right: 1px solid #1e2430; }
  .sidebar.collapsed { display: none; }
  .sbhead { flex: none; display: flex; align-items: center; gap: 8px; padding: 10px 12px; }
  .sbhead .t { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: #6b7787; }
  .newbtn { margin-left: auto; background: #1a2230; color: #cfe3ff; border: 1px solid #2a3140; border-radius: 7px; padding: 4px 9px; font-size: 12px; cursor: pointer; }
  .chatlist { flex: 1; overflow-y: auto; padding: 0 8px 10px; }
  .chatlist .item { display: flex; align-items: center; gap: 6px; padding: 8px 9px; border-radius: 8px; cursor: pointer; color: #b6c0cf; font-size: 13px; }
  .chatlist .item:hover { background: #141a24; }
  .chatlist .item.on { background: #182236; color: #e6e6e6; }
  .chatlist .item .ttl { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chatlist .item .sdot { flex: none; width: 7px; height: 7px; border-radius: 50%; background: #2b6cff; box-shadow: 0 0 7px #2b6cff; animation: bpulse 1s ease-in-out infinite; }
  .chatlist .item .del { opacity: 0; color: #6b7787; font-size: 15px; }
  .chatlist .item:hover .del { opacity: 1; }
  .chatlist .empty2 { color: #4d5765; font-size: 12px; padding: 10px 9px; }

  .chat { flex: 0 0 42%; min-width: 320px; display: flex; flex-direction: column; min-height: 0; border-right: 1px solid #1e2430; position: relative; }
  .workspace { flex: 1; display: flex; flex-direction: column; min-height: 0; min-width: 0; background: #0a0d13; }

  #log { flex: 1; overflow-y: auto; padding: 20px 18px; position: relative; }
  .msg { display: flex; gap: 11px; margin: 0 0 20px; }
  .msg .who { flex: none; width: 28px; height: 28px; border-radius: 7px; font-size: 12px; display: flex; align-items: center; justify-content: center; font-weight: 700; }
  .msg.user .who { background: #2b4a78; color: #dbe9ff; }
  .msg.bot .who { background: #1d3a2a; color: #aef0c4; }
  .msg .body { padding-top: 4px; word-wrap: break-word; min-width: 0; flex: 1; }
  .msg .body pre { background: #0a0d13; border: 1px solid #1e2430; border-radius: 8px; padding: 11px 13px; overflow-x: auto; white-space: pre; }
  .msg .body code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
  .msg .body :not(pre) > code { background: #1a1f29; padding: 1px 5px; border-radius: 4px; }
  /* markdown formatting in chat bubbles */
  .msg .body p { margin: 0 0 10px; }
  .msg .body > *:last-child, .msg .body p:last-child { margin-bottom: 0; }
  .msg .body .mdh { font-weight: 600; color: #dbe6f2; margin: 14px 0 6px; line-height: 1.3; }
  .msg .body .mdh:first-child { margin-top: 2px; }
  .msg .body .mdh1 { font-size: 17px; }
  .msg .body .mdh2 { font-size: 15.5px; }
  .msg .body .mdh3, .msg .body .mdh4, .msg .body .mdh5, .msg .body .mdh6 { font-size: 14px; color: #c2cedd; }
  .msg .body ul, .msg .body ol { margin: 4px 0 10px; padding-left: 22px; }
  .msg .body li { margin: 3px 0; }
  .msg .body li::marker { color: #6b7787; }
  .msg .body a { color: #7fd0ff; }
  .msg .body strong { color: #e6edf5; }
  .msg .body hr { border: 0; border-top: 1px solid #1e2430; margin: 12px 0; }
  .codecard { background: #0a0d13; border: 1px solid #233; border-radius: 8px; padding: 10px 12px; color: #9fb3c8; font-size: 13px; }
  .codecard b { color: #cfe3ff; }
  .building { display: inline-flex; align-items: center; gap: 9px; background: #11151d; border: 1px solid #2a3a52; border-radius: 9px; padding: 9px 13px; color: #aab8c8; font-size: 13px; }
  .building .bdot, .wsbuild .bdot { width: 9px; height: 9px; border-radius: 50%; background: #2b6cff; animation: bpulse 1s ease-in-out infinite; flex: none; }
  .building .bmeta { color: #5b6472; }
  .wsbuild { position: absolute; inset: 0; z-index: 6; display: flex; align-items: center; justify-content: center; gap: 11px; background: #0a0d13; color: #8a95a5; font-size: 14px; }
  .tabbtn { margin-left: auto; background: transparent; border: 1px solid #2a3140; color: #8a95a5; border-radius: 7px; padding: 5px 11px; font-size: 12.5px; cursor: pointer; }
  .tabbtn:hover { background: #1a2230; color: #e6e6e6; }
  .wsload { position: absolute; inset: 0; z-index: 7; display: flex; align-items: center; justify-content: center; gap: 10px; background: rgba(10,13,19,.82); color: #8a95a5; font-size: 13px; }
  .wsload .spin { width: 18px; height: 18px; border: 2px solid #2a3140; border-top-color: #2b6cff; border-radius: 50%; animation: spin .7s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  @keyframes bpulse { 0%, 100% { opacity: .3; transform: scale(.75); } 50% { opacity: 1; transform: scale(1); } }
  /* traceable task list (Claude-Code style): honest queued -> active -> done */
  .tasks { display: flex; flex-direction: column; gap: 8px; background: #0f131b; border: 1px solid #20283a; border-radius: 10px; padding: 11px 13px; }
  .tk { display: flex; align-items: center; gap: 9px; font-size: 13px; }
  .tk .tki { flex: none; width: 15px; height: 15px; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; }
  .tk-queued { color: #5b6472; }
  .tk-queued .tki::before { content: "\25CB"; color: #4d5765; font-size: 12px; }
  .tk-active { color: #cfe3ff; }
  .tk-active .tki { border: 2px solid #243049; border-top-color: #2b6cff; border-radius: 50%; animation: spin .7s linear infinite; }
  .tk-done { color: #b6c0cf; }
  .tk-done .tki::before { content: "\2713"; color: #2ecc71; font-weight: 700; font-size: 13px; }
  .tk-fail .tki::before { content: "\2715"; color: #ff7a7a; font-weight: 700; }
  .tk .meta { color: #5b6472; }
  /* plan-first card: the spec the reasoner wrote, collapsible */
  .plan { background: #0f131b; border: 1px solid #20283a; border-radius: 10px; padding: 9px 13px; margin-bottom: 9px; }
  .plan > summary { display: flex; align-items: center; justify-content: space-between; cursor: pointer; list-style: none; }
  .plan > summary::-webkit-details-marker { display: none; }
  .plan > summary .tk { font-size: 13px; }
  .plan .planhint { font-size: 11px; color: #5b6472; }
  .plan[open] .planhint::after { content: " \25B2"; }
  .plan:not([open]) .planhint::after { content: " \25BC"; }
  .plan .planbody { white-space: pre-wrap; color: #9fb0c4; font-size: 12.5px; line-height: 1.5; margin-top: 9px; padding-top: 9px; border-top: 1px solid #1b2233; }
  .think { color: #7d8694; font-style: italic; border-left: 2px solid #2a3140; padding-left: 10px; margin: 6px 0; }
  .approve { background: #11151d; border: 1px solid #33405a; border-radius: 10px; padding: 11px 13px; margin-top: 6px; }
  .approve .lbl { font-size: 12px; color: #8a95a5; margin-bottom: 6px; }
  .approve pre { margin: 0 0 9px; background: #0a0d13; border: 1px solid #1e2430; border-radius: 7px; padding: 9px 11px; overflow-x: auto; color: #d6e2ef; font-family: ui-monospace, Menlo, monospace; font-size: 12.5px; white-space: pre-wrap; }
  .approve .btns { display: flex; gap: 8px; }
  .approve button { border: 0; border-radius: 7px; padding: 6px 14px; font-size: 13px; font-weight: 600; cursor: pointer; }
  .approve .ok { background: #2b6cff; color: #fff; }
  .approve .no { background: #2a3140; color: #c7d0dd; }
  .approve.done .btns { display: none; }
  .approve.done .lbl::after { content: " — done"; color: #2ecc71; }
  /* Goal Mode: the forged goal card + its agree / adjust / skip gate */
  .goal { background: #0f131b; border: 1px solid #2a3f63; border-radius: 11px; padding: 13px 15px; margin: 2px 0; }
  .goal h4 { margin: 0 0 7px; font-size: 13.5px; color: #cfe3ff; display: flex; align-items: center; gap: 7px; }
  .goal .cap { color: #dbe6f2; font-size: 13.5px; margin-bottom: 10px; }
  .goal .grid { display: grid; grid-template-columns: auto 1fr; gap: 5px 12px; font-size: 12.5px; align-items: start; }
  .goal .k { color: #6b7787; white-space: nowrap; }
  .goal .v { color: #b6c0cf; white-space: pre-wrap; }
  .goal .v b { color: #7fd0ff; font-weight: 600; }
  .goal .verdict { margin-top: 10px; padding-top: 9px; border-top: 1px solid #1b2233; font-size: 12px; color: #9fb0c4; line-height: 1.5; }
  .goal .verdict b { color: #c2cedd; }
  .goal .gbadge { font-size: 10px; font-weight: 600; color: #aef0c4; background: #14271c; border: 1px solid #2a5a3c; border-radius: 5px; padding: 1px 6px; }
  .goal .gbadge.warn { color: #e8b84b; background: #271f12; border-color: #5a4a2a; }
  .goal .gbtns { display: flex; gap: 8px; margin-top: 12px; flex-wrap: wrap; }
  .goal .gbtns button { border: 0; border-radius: 7px; padding: 6px 13px; font-size: 13px; font-weight: 600; cursor: pointer; }
  .goal .gbtns .ok { background: #2b6cff; color: #fff; }
  .goal .gbtns .adj { background: #2a3140; color: #c7d0dd; }
  .goal .gbtns .skip { background: transparent; color: #8a95a5; border: 1px solid #2a3140; }
  .goal .adjbox { display: none; margin-top: 10px; }
  .goal .adjbox.on { display: block; }
  .goal .adjbox textarea { width: 100%; box-sizing: border-box; background: #0a0d13; color: #e6e6e6; border: 1px solid #2a3140; border-radius: 7px; padding: 8px 10px; font: inherit; font-size: 12.5px; resize: vertical; min-height: 48px; }
  .goal.locked .gbtns, .goal.locked .adjbox { display: none; }
  .goal.agreed { border-color: #2a5a3c; }
  .goal.skipped { border-color: #2a3140; opacity: .85; }

  .empty { min-height: 70%; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; color: #5b6472; }
  .empty h2 { color: #aab4c4; font-weight: 600; margin: 0 0 6px; }
  .empty .ex { margin-top: 14px; font-size: 13px; }
  .empty .ex span { color: #7fd0ff; cursor: pointer; border-bottom: 1px dashed #2a4a5a; }
  .jump { position: absolute; right: 20px; bottom: 92px; z-index: 8; background: #1c2433; border: 1px solid #2a3140; color: #c7d0dd; border-radius: 20px; padding: 6px 13px; font-size: 12px; cursor: pointer; box-shadow: 0 6px 18px rgba(0,0,0,.45); }
  .jump:hover { background: #243049; }
  .jump[hidden] { display: none; }

  .composer { flex: none; border-top: 1px solid #1e2430; background: #11151d; padding: 12px 16px 14px; }
  .inrow { display: flex; gap: 10px; align-items: flex-end; background: #0d1017; border: 1px solid #2a3140; border-radius: 13px; padding: 7px 7px 7px 4px; transition: border-color .15s; }
  .inrow:focus-within { border-color: #2b6cff; }
  textarea { flex: 1; resize: none; background: transparent; color: #e6e6e6; border: 0; border-radius: 10px; padding: 9px 10px; font: inherit; line-height: 1.45; min-height: 40px; max-height: 184px; }
  textarea::placeholder { color: #5b6472; }
  textarea:focus, .picker-btn:focus { outline: none; }
  button.send { flex: none; align-self: stretch; min-height: 38px; padding: 0 18px; background: #2b6cff; color: #fff; border: 0; border-radius: 9px; font-weight: 600; cursor: pointer; transition: background .15s; }
  button.send:hover { background: #3b78ff; }
  button.send.stop { background: #d6453f; }
  button.send.stop:hover { background: #e1554f; }
  button.send:disabled { opacity: .5; cursor: default; }
  .hint { color: #5b6472; font-size: 11.5px; text-align: center; margin-top: 8px; }
  .hint b { color: #7d8694; font-weight: 600; }

  .tabs { flex: none; display: flex; align-items: center; gap: 4px; padding: 8px 12px; border-bottom: 1px solid #1e2430; }
  .tab { background: transparent; border: 0; color: #8a95a5; padding: 6px 12px; border-radius: 7px; font-size: 13px; cursor: pointer; }
  .tab.on { background: #1a2230; color: #e6e6e6; }
  .wsbody { flex: 1; min-height: 0; position: relative; }
  #preview { width: 100%; height: 100%; border: 0; background: #fff; display: block; }
  #codeview, #termview { position: absolute; inset: 0; margin: 0; overflow: auto; padding: 14px 16px; white-space: pre-wrap; word-break: break-word; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
  #codeview { color: #cdd6e0; }
  #termview { color: #b8c6d0; background: #07090d; }
  #termview .cmd { color: #7fd0ff; }
  #termview .err { color: #ff9b9b; }
  .wsempty { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; color: #4d5765; gap: 8px; }
  .wsempty b { color: #8a95a5; font-weight: 600; }
  .hidden { display: none !important; }

  @media (max-width: 920px) { header { gap: 8px; } .toggles { gap: 12px; } .hgroup { gap: 8px; } }
  @media (max-width: 980px) { .sidebar { width: 0; display: none; } }
  @media (max-width: 860px) { main { flex-direction: column; } .chat { flex: 1 1 50%; min-width: 0; border-right: 0; border-bottom: 1px solid #1e2430; } .workspace { flex: 1 1 50%; } }
</style>
</head>
<body>
  <header>
    <div class="hgroup">
      <button class="tbtn" id="sbToggle" title="Toggle history">&#9776;</button>
      <h1><span class="dot" id="dot"></span> Local LLM Builder</h1>
      <div class="picker">
        <button class="picker-btn" id="pickerBtn" type="button"><span class="name" id="pickerName">Loading...</span><span class="caret">&#9660;</span></button>
        <ul class="menu" id="menu" hidden></ul>
      </div>
      <button class="tbtn" id="capBtn" title="What your machine can run + what you can add">&#129513; Capabilities</button>
    </div>
    <div class="toggles">
      <span class="togwrap">
        <label class="toggle" id="agentLabel" title="Let the model run commands + write files (asks before each)"><input type="checkbox" id="agentChk"><span class="sw"></span> Agent</label>
        <span class="info" tabindex="0" role="button" aria-label="What does Agent mode do?">i<span class="tip"><b>Agent mode</b> lets the model use real tools — run terminal commands, write files, fetch &amp; <b>clone websites</b> — asking your <b>approval</b> before anything changes your computer. Off by default for safety. Needs the <code>--agent</code> server.</span></span>
      </span>
      <span class="togwrap">
        <label class="toggle" id="goalLabel" title="Goal Mode: forge a measurable goal, agree to it, then pursue it (build &rarr; score &rarr; iterate) and log what it learns"><input type="checkbox" id="goalChk"><span class="sw"></span> &#127919; Goal</label>
        <span class="info" tabindex="0" role="button" aria-label="What does Goal mode do?">i<span class="tip"><b>Goal mode</b> turns your request into a <b>measurable goal you approve</b>, then builds, scores and <b>iterates toward the target</b> on its own — logging what it learns. Works for <b>any build</b> (it iterates to a <b>requirements-coverage</b> target) and is especially strong at <b>cloning a real site</b> (a fidelity&nbsp;%). Runs on the built-in agent server — you do <b>not</b> need the Agent toggle on.</span></span>
      </span>
    </div>
    <div class="hgroup hright">
      <button class="tbtn" id="dlBtn" title="Download the current app you've built as an .html file" disabled>Download</button>
    </div>
  </header>

  <main>
    <aside class="sidebar" id="sidebar">
      <div class="sbhead"><span class="t">Chats</span><button class="newbtn" id="newBtn">+ New</button></div>
      <div class="chatlist" id="chatlist"></div>
    </aside>

    <section class="chat">
      <div id="log">
        <div class="empty" id="empty">
          <h2>Build something — runs on your machine</h2>
          <div>Describe an app and watch it appear in the preview. 100% local.</div>
          <div class="ex">Try: <span data-ex="Build me a stopwatch with start, stop, and reset.">a stopwatch</span> &middot; <span data-ex="Build a to-do list that saves to localStorage.">a to-do list</span> &middot; <span data-ex="Build a tip calculator.">a tip calculator</span></div>
        </div>
      </div>
      <button class="jump" id="jump" hidden>Jump to latest &darr;</button>
      <div class="composer">
        <div class="inrow">
          <textarea id="input" rows="1" placeholder="Describe an app to build, or ask anything&hellip;"></textarea>
          <button class="send" id="send">Send</button>
        </div>
        <div class="hint" id="hint"><b>Enter</b> to send &middot; <b>Shift+Enter</b> for a new line</div>
      </div>
    </section>

    <section class="workspace">
      <div class="tabs">
        <button class="tab on" id="tabPreview" data-tab="preview">Preview</button>
        <button class="tab" id="tabCode" data-tab="code">Code</button>
        <button class="tab" id="tabTerm" data-tab="term">Terminal</button>
        <button class="tabbtn" id="refreshBtn" title="Reload the preview">&#8635; Refresh</button>
      </div>
      <div class="wsbody">
        <iframe id="preview" sandbox="allow-scripts allow-forms allow-modals allow-popups"></iframe>
        <pre id="codeview" class="hidden"></pre>
        <pre id="termview" class="hidden"></pre>
        <div class="wsempty" id="wsempty"><b>No app yet</b><div>Ask the model to build something &mdash; it'll render here, live.</div></div>
        <div class="wsbuild hidden" id="wsbuild"><span class="bdot"></span> Building the app&hellip;</div>
        <div class="wsload hidden" id="wsload"><span class="spin"></span> Loading preview&hellip;</div>
      </div>
    </section>
  </main>

  <!-- Design system for generated apps. Lives in an INERT <template> (never a JS
       string), so an embedded </script> can never close the page's own script. -->
  <div class="modal-bg" id="capModal" hidden>
    <div class="modal">
      <h3>&#129513; Capabilities <button class="mclose" id="capClose" title="Close">&times;</button></h3>
      <div class="mbody" id="capBody"></div>
    </div>
  </div>

  <template id="designHead"><style>
:root{--background:0 0% 100%;--foreground:222 47% 11%;--card:0 0% 100%;--card-foreground:222 47% 11%;--popover:0 0% 100%;--popover-foreground:222 47% 11%;--primary:222 47% 11%;--primary-foreground:210 40% 98%;--secondary:210 40% 96%;--secondary-foreground:222 47% 11%;--muted:210 40% 96%;--muted-foreground:215 16% 47%;--accent:210 40% 96%;--accent-foreground:222 47% 11%;--destructive:0 84% 60%;--destructive-foreground:210 40% 98%;--border:214 32% 91%;--input:214 32% 91%;--ring:222 47% 11%;--radius:0.6rem;}
.dark{--background:222 47% 6%;--foreground:210 40% 98%;--card:222 47% 9%;--card-foreground:210 40% 98%;--popover:222 47% 9%;--popover-foreground:210 40% 98%;--primary:210 40% 98%;--primary-foreground:222 47% 11%;--secondary:217 33% 17%;--secondary-foreground:210 40% 98%;--muted:217 33% 17%;--muted-foreground:215 20% 65%;--accent:217 33% 17%;--accent-foreground:210 40% 98%;--destructive:0 63% 31%;--destructive-foreground:210 40% 98%;--border:217 33% 20%;--input:217 33% 20%;--ring:212 27% 84%;}
*{border-color:hsl(var(--border));}
body{background:hsl(var(--background));color:hsl(var(--foreground));font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
</style>
<script src="https://cdn.tailwindcss.com"></script>
<script>tailwind.config={theme:{extend:{colors:{border:"hsl(var(--border))",input:"hsl(var(--input))",ring:"hsl(var(--ring))",background:"hsl(var(--background))",foreground:"hsl(var(--foreground))",primary:{DEFAULT:"hsl(var(--primary))",foreground:"hsl(var(--primary-foreground))"},secondary:{DEFAULT:"hsl(var(--secondary))",foreground:"hsl(var(--secondary-foreground))"},destructive:{DEFAULT:"hsl(var(--destructive))",foreground:"hsl(var(--destructive-foreground))"},muted:{DEFAULT:"hsl(var(--muted))",foreground:"hsl(var(--muted-foreground))"},accent:{DEFAULT:"hsl(var(--accent))",foreground:"hsl(var(--accent-foreground))"},card:{DEFAULT:"hsl(var(--card))",foreground:"hsl(var(--card-foreground))"}},borderRadius:{xl:"calc(var(--radius) + 4px)",lg:"var(--radius)",md:"calc(var(--radius) - 2px)",sm:"calc(var(--radius) - 4px)"}}}};</script></template>

  <!-- Self-repair: a tiny error-catcher injected into every preview. Reports runtime
       errors back to the builder so it can fix them. Inert <template> -> safe. -->
  <template id="errHook"><script>
(function(){
  function R(k,m){try{parent.postMessage({__llmbuilder:1,kind:k,msg:String(m).slice(0,400)},"*");}catch(e){}}
  addEventListener("error",function(e){R("error",(e.message||"Script error")+(e.filename?" @ "+String(e.filename).split("/").pop()+":"+e.lineno:""));});
  addEventListener("unhandledrejection",function(e){R("error","Unhandled promise rejection: "+((e.reason&&e.reason.message)||e.reason||""));});
})();
</script></template>

<script>
const API = "http://localhost:11434";
const AGENT_URL = location.origin;   // the page is served by the agent server (when present)
const BUILDER_SYSTEM =
  "You are a local web-app builder, like Lovable or v0, running on the user's machine. " +
  "Tailwind CSS and a shadcn-style design system are ALREADY loaded in the preview, so use Tailwind utility " +
  "classes freely — do NOT add the Tailwind CDN or a tailwind config yourself. Lean on the design tokens for a " +
  "clean, modern look: bg-background / text-foreground, bg-card, text-muted-foreground, border, rounded-lg / rounded-xl, " +
  "For a DARK theme, add class=\"dark\" to the <html> tag — the tokens switch to dark automatically (keep using bg-background / bg-card / text-foreground). " +
  "For a coloured accent (e.g. purple, emerald), use a literal Tailwind class on the key elements, like bg-purple-600 / hover:bg-purple-700 on buttons. " +
  "generous padding, and subtle shadows (shadow-sm / shadow-md). When specific real image URLs are provided (e.g. when cloning a page), use those EXACT urls; otherwise use https://picsum.photos/seed/NAME/W/H " +
  "(e.g. https://picsum.photos/seed/hero/1600/900) which always loads. " +
  "When text sits OVER an image, always keep it legible: put the image in a relative container with the text above it, " +
  "and add a dark overlay (e.g. an absolute inset div with bg-black/50) or a gradient behind the text. " +
  "Give a hero or any section with a background image a REAL height (e.g. min-h-[70vh] or min-h-screen) and make the " +
  "image an absolute inset-0 w-full h-full object-cover layer BEHIND a relative z-10 content container — never a plain " +
  "flex child sized with h-full (that collapses to nothing). Always set explicit text colours (e.g. text-white on dark heroes). " +
  "Make it responsive and polished — real spacing, a clear visual hierarchy, hover states on buttons. " +
  "Respond with ONE complete HTML file in a single ```html code block (write any extra CSS/JS inline). " +
  "Put a one-line description before the code — and if you're correcting a previous version, say plainly in that line what was wrong and what you changed. When asked for a change, output the FULL updated file again. " +
  "For non-build questions, answer normally.";
const AGENT_SYSTEM =
  "You are a local coding agent on the user's machine, working inside a sandboxed workspace folder. " +
  "You have these tools — output EXACTLY ONE per turn, then STOP and wait for my <result>:\n" +
  "<run>shell command</run>  — run a command in the workspace\n" +
  "<write path=\"rel/path\">\nfile contents\n</write>  — write a workspace file\n" +
  "<read path=\"rel/path\">  — read a workspace file\n" +
  "<fetch url=\"https://...\">  — fetch a public web page's raw HTML\n" +
  "<inspect url=\"https://...\">  — a STRUCTURED digest of a page. When a headless browser is present it RENDERS the page (so JavaScript-built sites read correctly), returning title, sections, headings, links, images, the real computed colour palette + fonts, the type scale / radii / shadows, the motion (CSS @keyframes + animations + transitions), hover states, responsive breakpoints and a framework guess\n" +
  "<extract url=\"https://...\">  — a page's design tokens (palette, fonts, type scale, radii, shadows, spacing) plus its motion and framework\n" +
  "<screenshot url=\"https://...\">  — render a page in a headless browser (Playwright's managed Chromium, installed on demand) and capture a PNG\n" +
  "<gitsync path=\".\" message=\"...\">  — turn the workspace project into a real local git repo (git init + .gitignore + commit) and export a .zip with the .git history. Pushing to GitHub stays yours to do (your own token).\n" +
  "To CLONE or recreate a real website, FIRST <inspect url=\"...\"> to observe its real structure, palette, fonts, design tokens AND its animations/hover states — never invent them — then write the page to match those exact colours, fonts, sections, tokens and motion. " +
  "Use the result to decide the next step. " +
  "Narrate like a careful engineer thinking out loud: before each tool call, say in ONE short line what you're about to do and why. " +
  "After each <result>, ASSESS it honestly — if it failed, came back empty, or looks wrong, name the problem AND why in one line, say how you'll fix it, then do the fix. " +
  "Examples of the voice: \"That command errored — no such file; let me list the directory first.\"  \"My regex undercounted (caught 3 of ~25 files) so that result can't be trusted; let me parse each block independently instead.\"  \"My first parse mangled the multi-line input — let me handle it properly.\" " +
  "Never claim something worked without checking the result. Own mistakes plainly — no bravado, no pretending it was fine. " +
  "When the task is fully done, reply normally with NO tool tags. Keep commands safe and scoped to the workspace.";
// The "plan first" brain: a reasoner turns a short ask into a concrete build spec
// the coder then implements. This is what removes the handholding.
const SPEC_SYSTEM =
  "You are a senior product engineer planning a single-page web app for a fast local coder model to build. " +
  "Given the user's request, write a SHORT, concrete build spec — no code, no preamble. Use this exact shape:\n" +
  "Title: <one line>\n" +
  "Features:\n- <bullet>\n- <bullet> (the key interactions/behaviours)\n" +
  "Sections: <the main UI blocks, top to bottom>\n" +
  "States: <empty / loading / error / active states that matter>\n" +
  "Style: <one line — modern, clean, shadcn-like; mention accent colour + layout>\n" +
  "Be specific and opinionated so nothing is left ambiguous. Keep it under ~14 lines total. Do not write HTML.";
// Goal Mode's "forge" brain: turn a request into a measurable, REACHABLE goal as JSON,
// banking the write-a-goal discipline — pin the exact metric + feasibility-check the target.
const GOAL_SPEC_SYSTEM =
  "You convert a build request into a MEASURABLE, REACHABLE goal, then output ONLY a JSON object — no prose, no markdown fence, nothing before or after. " +
  "Exact shape:\n" +
  '{"capability":"one sentence — given X the app does Y, concrete and observable",' +
  '"metric":{"name":"the single thing measured","how":"how it is computed / what reports it","target":<integer 40-85 or null>},' +
  '"evals":["a concrete test with a number","a second concrete test with a number"],' +
  '"acceptance":"when it is done",' +
  '"nonGoals":["what this explicitly is NOT"],' +
  '"checkA":"the dumbest output that could score high, and the guard that stops it",' +
  '"checkB":"is the target reachable for a local 14B coder? if not, the reachable target and the lever that raises the ceiling"}\n' +
  "When the request clones/recreates a real web page, the metric is STRUCTURAL clone fidelity (palette + fonts + sections + headings + motion + tokens, 0-100, from the scorer) — target around 75. " +
  "A local 14B rebuilding from a text digest cannot match pixels (visual fidelity plateaus ~30%): never set a high visual target, and name 'a vision model' as the lever for visual gains. " +
  "At least 2 evals, each with a number. Keep every field to one short sentence. Output JSON ONLY.";

const el = id => document.getElementById(id);
const log = el("log"), empty = el("empty"), input = el("input"), sendBtn = el("send");
const dot = el("dot"), hint = el("hint"), jump = el("jump");
const pickerBtn = el("pickerBtn"), pickerName = el("pickerName"), menu = el("menu");
const preview = el("preview"), codeview = el("codeview"), termview = el("termview"), wsempty = el("wsempty"), wsbuild = el("wsbuild"), wsload = el("wsload"), refreshBtn = el("refreshBtn");
const tabPreview = el("tabPreview"), tabCode = el("tabCode"), tabTerm = el("tabTerm"), dlBtn = el("dlBtn");
const sidebar = el("sidebar"), chatlist = el("chatlist"), agentChk = el("agentChk"), agentLabel = el("agentLabel");
const goalChk = el("goalChk"), goalLabel = el("goalLabel");
const capBtn = el("capBtn"), capModal = el("capModal"), capClose = el("capClose"), capBody = el("capBody");

let messages = [], busy = false, currentModel = "", currentApp = "", stick = true, buildingApp = false;
let currentId = newId(), agentReady = false;
let abortCtl = null;                 // aborts the in-flight generation (Stop button)
let pendingBuild = null;             // { body, lines } awaiting the preview's load event
let buildSpec = "", repairHtml = ""; // plan spec + repair status; the prefix is rebuilt live each paint
let planOpen = false;                // is the plan card expanded? persisted across streaming repaints
let goalActive = false, goalTarget = 0, goalMeta = null, goalRounds = [];  // Goal Mode: the agreed goal under pursuit + its per-round scores
const buildingIds = new Set();       // project ids generating right now -> sidebar status dot
// model routing: Auto picks the best brain per task; the picker is an override
let autoMode = true;
let models = [];                     // [{ name, params, role, lean }]
let bestCoder = "", bestReasoner = "", fastest = "";
function newId() { return "c" + Math.random().toString(36).slice(2, 9); }

/* ---------- model index + routing ---------- */
function parseParams(name) { const m = name.match(/(\d+(?:\.\d+)?)\s*b\b/i); return m ? parseFloat(m[1]) : 0; }
function parseRole(name) {
  if (/r1|reason|qwq|\bo1\b|think/i.test(name)) return "reasoner";
  if (/coder|code|starcoder|codestral|codellama/i.test(name)) return "coder";
  return "general";
}
// prefer: more params, then more context (8k), then a full (non-lean) coder
function coderScore(m) { return m.params * 100 + (/8k/i.test(m.name) ? 5 : 0) + (m.lean ? -1 : 0); }
function indexModels(names) {
  models = names.map(n => ({ name: n, params: parseParams(n), role: parseRole(n), lean: /lean/i.test(n) }));
  const coders = models.filter(m => m.role === "coder").sort((a, b) => coderScore(b) - coderScore(a));
  const reasoners = models.filter(m => m.role === "reasoner").sort((a, b) => b.params - a.params);
  const generals = models.filter(m => m.role === "general").sort((a, b) => b.params - a.params);
  bestCoder = (coders[0] || generals[0] || models[0] || {}).name || "";
  bestReasoner = (reasoners[0] || {}).name || "";
  fastest = [...models].sort((a, b) => a.params - b.params)[0]?.name || "";
}
// Route a prompt to the right brain + decide whether to plan first.
// Key rule: once an app is on screen, treat requests as EDITS to it (the Lovable
// model) — even ones containing build-ish words like "make" or "design" — unless
// the user clearly asks to start fresh. A new app belongs in a new chat.
function route(text) {
  const t = text.toLowerCase();
  const reasonRe = /\b(explain|why|how (does|do|to)|what (is|are|s)|compare|difference|pros and cons|analy|reason|architecture|should i|recommend|best way)\b/;
  const hasBuildWord = /\b(build|make|create|add|change|page|app|component|section|button|form|design|style|colou?r|layout)\b/;
  const newAppRe = /\b(start over|from scratch|scratch|rebuild|new (app|page|project|website|site|design|one|build)|different (app|page|thing)|instead build|build a new|another (app|page)|scrap (it|this))\b/;
  const trivial = text.length < 28 && !/\b(with|that|and|including|plus|featuring|like)\b/i.test(t);
  const hasApp = !!currentApp;
  // clone intent: a recreate verb + a URL — full (https://…), www.…, or a bare domain
  // (disrupt.com), normalised to https://. Skip things that are really filenames (index.html).
  const urlM = text.match(/(?:https?:\/\/)?(?:www\.)?[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.[a-z]{2,24}(?:\/[^\s)"'<>]*)?/i);
  const looksLikeFile = urlM && !/^https?:\/\//i.test(urlM[0]) && /^[^/]*\.(html?|css|jsx?|tsx?|json|py|md|txt|png|jpe?g|gif|svg|webp|sh|ya?ml|xml|csv|zip|pdf|lock|log)(?:[/?#]|$)/i.test(urlM[0]);
  const cloneIntent = /\b(clone|recreate|replicate|reproduce|rebuild|copy|mimic|inspired by|like (this|the)|same as)\b/.test(t);
  if (urlM && !looksLikeFile && cloneIntent && agentReady) {
    let u = urlM[0]; if (!/^https?:\/\//i.test(u)) u = "https://" + u;
    return { kind: "build", model: bestCoder, plan: false, cloneUrl: u };
  }
  // a clear non-build question -> the reasoner answers (with or without an app)
  if (reasonRe.test(t) && !hasBuildWord.test(t)) return { kind: "reason", model: bestReasoner || bestCoder, plan: false };
  // app already on screen -> iterate on it (fast, no re-plan), unless they ask to start fresh
  if (hasApp && !newAppRe.test(t)) return { kind: "edit", model: bestCoder, plan: false };
  // no app yet (or an explicit new build) -> build; plan first unless it's a trivial one-liner
  return { kind: "build", model: bestCoder, plan: !!bestReasoner && !trivial };
}
// Turn an inspect() digest into a concrete build spec — the REAL palette, fonts,
// sections and copy from the page, so the coder transcribes it instead of inventing.
// Measure the real page's overall theme (dark vs light) from a small screenshot, so the
// clone matches it instead of defaulting to the light design system.
async function pageTheme(url) {
  try {
    const j = await (await fetch(AGENT_URL + "/api/agent/screenshot", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url, width: 1024, height: 768 }), signal: abortCtl && abortCtl.signal })).json();
    if (!j.ok || !j.dataurl) return null;
    const img = new Image();
    await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = j.dataurl; });
    const c = document.createElement("canvas"); c.width = 64; c.height = 48;
    const ctx = c.getContext("2d"); ctx.drawImage(img, 0, 0, 64, 48);
    const px = ctx.getImageData(0, 0, 64, 48).data;
    let s = 0; for (let i = 0; i < px.length; i += 4) s += (px[i] + px[i + 1] + px[i + 2]) / 3;
    const bright = s / (px.length / 4);
    return { brightness: Math.round(bright), theme: bright < 110 ? "dark" : "light" };
  } catch (e) { if (e.name === "AbortError") throw e; return null; }
}
// Turn a digest into a FOCUSED clone spec. A local 14B can't implement an exhaustive dump of
// every token/animation/state — it drops most of it. So lead with the high-fidelity, achievable
// dimensions (exact colours WITH roles, the real brand fonts, structure, real copy + images),
// cut the low-signal noise (font-size lists, spacing, per-element hover diffs, framework), and
// tell it plainly these are the priority. Focused input is what the model actually reproduces.
function cloneSpecFromDigest(d) {
  const L = ["Recreate this web page as ONE self-contained, responsive HTML file: " + (d.title || d.url) + ".",
             "Fidelity to the ORIGINAL is the goal — use its EXACT colours, fonts, section order and copy below. Implement EVERY colour and font listed; they are the highest-priority detail, not suggestions."];
  if (d.theme === "dark") L.push("Theme: DARK — near-black background throughout (add class=\"dark\" to <html>; bg-zinc-950 / bg-black on body + sections) with light text. Never a white page.");
  else if (d.theme === "light") L.push("Theme: light background, dark text.");
  if (d.description) L.push("Tagline: " + d.description);
  // PALETTE — the most-prominent colours with role guidance (the single biggest fidelity lever).
  const pal = (d.palette || []).slice(0, 6);
  if (pal.length) L.push("EXACT colours — use ALL of these (most prominent first): " + pal.join(", ")
    + ". Use the dominant ones as page/section backgrounds and the brightest/most-saturated as the accent on buttons + highlights.");
  // FONTS — the 1-2 real brand fonts (skip generic families), loaded from Google Fonts.
  const brand = (d.fonts || []).filter(f => !/^(sans-serif|serif|monospace|system-ui|ui-|arial|helvetica|times|georgia|courier|tahoma|verdana)/i.test(f));
  const useFonts = (brand.length ? brand : (d.fonts || [])).slice(0, 2);
  if (useFonts.length) L.push("EXACT fonts (load from Google Fonts; use site-wide): " + useFonts.join(" + "));
  // STRUCTURE + real copy.
  if (d.sections && d.sections.length) L.push("Sections, top to bottom (" + d.sections.length + " total): " + d.sections.map(s => s.tag + (s.id ? "#" + s.id : "")).slice(0, 14).join(" › "));
  if (d.headings && d.headings.length) L.push("Real headings/copy to reuse verbatim:\n" + d.headings.slice(0, 12).map(h => "• " + h.text).join("\n"));
  if (d.nav_links && d.nav_links.length) { const nav = d.nav_links.map(l => l.text).filter(Boolean).slice(0, 8); if (nav.length) L.push("Nav items: " + nav.join(" · ")); }
  // REAL images.
  const imgs = (d.images || []).map(im => (im && im.src) || im).filter(Boolean);
  const bgs = d.bg_images || [];
  if (imgs.length || bgs.length) {
    L.push("Use the page's REAL image URLs (NOT picsum) in the matching spots:");
    if (bgs.length) L.push("Hero / section background images: " + bgs.slice(0, 4).join("  ·  "));
    if (imgs.length) L.push("<img> sources in order: " + imgs.slice(0, 8).join("  ·  "));
    L.push("If a real image 404s, fall back to https://picsum.photos/seed/NAME/W/H.");
  } else if (d.counts && d.counts.images) {
    L.push("~" + d.counts.images + " images — use https://picsum.photos/seed/NAME/W/H placeholders.");
  }
  // Light polish note — NOT an exhaustive token/motion dump (that's what overflowed the model).
  const t = d.tokens || {}, m = d.motion || {}, polish = [];
  if (t.radii && t.radii.length) polish.push("corner radius ~" + t.radii.slice(0, 2).join("/"));
  if ((m.animations || []).length || (m.transitions || []).length) polish.push("subtle entrance animations + hover transitions like the original");
  if (polish.length) L.push("Polish: " + polish.join("; ") + ".");
  L.push("Match the layout, spacing and visual hierarchy closely. Output ONE complete responsive HTML file.");
  return L.join("\n");
}
// human label for a model: "qwen2.5-coder · 14B · Coder"
function roleTag(r) { return r === "coder" ? "Coder" : r === "reasoner" ? "Reasoner" : "General"; }
function badgeFor(name) {
  if (name === bestCoder) return "Best for building";
  if (name === bestReasoner) return "Best for reasoning";
  if (name === fastest && models.length > 1) return "Fastest";
  return "";
}
function refreshPickerName() {
  pickerName.textContent = autoMode ? "⚡ Auto" : currentModel;
}

/* ---------- model picker ---------- */
async function loadModels() {
  try {
    const names = ((await (await fetch(API + "/api/tags")).json()).models || []).map(m => m.name).sort();
    if (!names.length) throw new Error("no models");
    indexModels(names);
    currentModel = bestCoder || names[0];   // fallback target when Auto resolves or is overridden
    autoMode = true;
    renderPicker();
    refreshPickerName();
  } catch (e) {
    pickerName.textContent = "no models";
    dot.style.background = "#e74c3c"; dot.style.boxShadow = "0 0 8px #e74c3c";
    hint.textContent = "Can't reach Ollama at localhost:11434 - is it running? (try: ollama list)";
  }
}
function renderPicker() {
  menu.innerHTML = "";
  // Auto option (default)
  const auto = document.createElement("li");
  auto.className = "auto" + (autoMode ? " sel" : "");
  auto.innerHTML = '<div class="mtop">⚡ Auto <span class="mbadge">Recommended</span></div><div class="msub">Picks the best model for each request</div>';
  auto.addEventListener("click", () => { autoMode = true; refreshPickerName(); renderPicker(); menu.hidden = true; });
  menu.appendChild(auto);
  const sep = document.createElement("li"); sep.className = "sep"; sep.textContent = "Or pick one"; menu.appendChild(sep);
  // models ranked by capability
  const ranked = [...models].sort((a, b) => (b.role === "coder") - (a.role === "coder") || b.params - a.params);
  for (const m of ranked) {
    const li = document.createElement("li");
    li.className = "model" + (!autoMode && m.name === currentModel ? " sel" : "");
    li.dataset.model = m.name;
    const badge = badgeFor(m.name);
    li.innerHTML = '<div class="mtop"><span class="mname"></span>' + (badge ? '<span class="mbadge">' + badge + '</span>' : '') + '</div><div class="msub">' + (m.params ? m.params + "B · " : "") + roleTag(m.role) + '</div>';
    li.querySelector(".mname").textContent = m.name;
    li.addEventListener("click", () => { autoMode = false; currentModel = m.name; refreshPickerName(); renderPicker(); menu.hidden = true; });
    menu.appendChild(li);
  }
}
pickerBtn.addEventListener("click", e => { e.stopPropagation(); menu.hidden = !menu.hidden; });
document.addEventListener("click", e => { if (!menu.contains(e.target) && e.target !== pickerBtn) menu.hidden = true; });
document.addEventListener("keydown", e => { if (e.key === "Escape") menu.hidden = true; });

/* ---------- agent server detection ---------- */
async function detectAgent() {
  try {
    const r = await fetch(AGENT_URL + "/api/agent/ping", { method: "GET" });
    agentReady = r.ok;
  } catch (e) { agentReady = false; }
  if (!agentReady) {
    agentChk.checked = false; agentChk.disabled = true;
    agentLabel.title = "Agent tools need the agent server: run  ./local-llm-setup.sh --agent";
    agentLabel.style.opacity = ".5";
    goalChk.checked = false; goalChk.disabled = true;
    goalLabel.title = "Goal Mode needs the agent server: run  ./local-llm-setup.sh --agent";
    goalLabel.style.opacity = ".5";
  }
}

/* ---------- chat rendering ---------- */
function escapeHtml(s) { return s.replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c])); }
function mdInline(s) {
  s = escapeHtml(s);
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*([^*]+?)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*])\*([^*\n]+?)\*(?!\*)/g, "$1<em>$2</em>");
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s;
}
// Markdown -> HTML for chat prose: headings, bullet/numbered lists, paragraphs,
// inline bold/italic/code/links. A passthrough token (@@Bn@@) on its own line is
// emitted raw, so pre-built blocks (app card, think aside) survive untouched.
function renderMd(src) {
  const lines = String(src).split("\n");
  const out = []; let list = null, para = [];
  const flushPara = () => { if (para.length) { out.push("<p>" + para.join("<br>") + "</p>"); para = []; } };
  const closeList = () => { if (list) { out.push("</" + list + ">"); list = null; } };
  for (const raw of lines) {
    const line = raw.replace(/\s+$/, ""); let m;
    if (/^@@B\d+@@$/.test(line.trim())) { flushPara(); closeList(); out.push(line.trim()); continue; }
    if (!line.trim()) { flushPara(); closeList(); continue; }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flushPara(); closeList(); out.push("<hr>"); continue; }
    if (m = line.match(/^\s*(#{1,6})\s+(.*)$/)) { flushPara(); closeList(); out.push('<div class="mdh mdh' + m[1].length + '">' + mdInline(m[2].replace(/\s*#+\s*$/, "")) + "</div>"); continue; }
    if (m = line.match(/^\s*[-*+]\s+(.*)$/)) { flushPara(); if (list !== "ul") { closeList(); out.push("<ul>"); list = "ul"; } out.push("<li>" + mdInline(m[1]) + "</li>"); continue; }
    if (m = line.match(/^\s*\d+[.)]\s+(.*)$/)) { flushPara(); if (list !== "ol") { closeList(); out.push("<ol>"); list = "ol"; } out.push("<li>" + mdInline(m[1]) + "</li>"); continue; }
    closeList(); para.push(mdInline(line));
  }
  flushPara(); closeList();
  return out.join("");
}
function render(text) {
  const blk = [];                                  // pre-built block HTML, passed through markdown untouched
  const hold = h => "\n@@B" + (blk.push(h) - 1) + "@@\n";
  text = String(text);
  text = text.replace(/<think>([\s\S]*?)<\/think>/gi, (_, t) => hold('<div class="think">' + renderMd(t) + "</div>"));
  text = text.replace(/<think>[\s\S]*$/i, "");                                   // unterminated think (streaming)
  text = text.replace(/<run>[\s\S]*?<\/run>/gi, () => hold("")).replace(/<write\s+path=[\s\S]*?<\/write>/gi, () => hold(""));
  text = text.replace(/```(?:html)?\s*[\s\S]*?```/gi, m => /<\/html>|<!doctype/i.test(m) ? hold('<div class="codecard">&#9633; <b>App</b> &rarr; shown in the live preview</div>') : m);
  let html = text.split(/(```[\s\S]*?```)/g).map(p =>
    p.startsWith("```") ? "<pre><code>" + escapeHtml(p.replace(/^```[^\n]*\n?/, "").replace(/```$/, "")) + "</code></pre>" : renderMd(p)
  ).join("");
  return html.replace(/@@B(\d+)@@/g, (_, i) => blk[+i]);
}
// While the model writes an HTML app, show ACTIVITY in the chat (not the raw
// code) — the finished app lands in the Preview / Code panes, Claude-Code style.
function parseStream(acc) {
  const fence = acc.match(/```[ \t]*([a-zA-Z]*)[ \t]*\r?\n/);
  if (!fence) return { prose: acc, code: null, complete: false };
  const after = acc.slice(fence.index + fence[0].length);
  const lang = (fence[1] || "").toLowerCase();
  if (lang !== "html" && !/^\s*(<!doctype|<html|<head|<body)/i.test(after)) return { prose: acc, code: null, complete: false };
  const close = after.indexOf("```");
  return { prose: acc.slice(0, fence.index), code: (close >= 0 ? after.slice(0, close) : after), complete: close >= 0 };
}
// A traceable task list, Claude-Code style: each row is queued / active / done.
function taskList(items) {
  return '<div class="tasks">' + items.map(t =>
    '<div class="tk tk-' + t.status + '"><span class="tki"></span><span>' + t.label +
    (t.meta ? ' <span class="meta">' + t.meta + '</span>' : '') + '</span></div>'
  ).join("") + "</div>";
}
// The "plan first" card: shows the reasoner planning, then the spec it produced
// (collapsible), so you can see the thinking — honestly — before the build.
function planCard(spec, status, modelName) {
  if (status === "active") return taskList([{ status: "active", label: "Planning the build", meta: modelName || "" }]);
  const open = (status === "open" || planOpen) ? " open" : "";
  return '<details class="plan"' + open + '><summary><span class="tk tk-done"><span class="tki"></span><span>Planned the build</span></span><span class="planhint">view plan</span></summary><div class="planbody">' + render(spec) + '</div></details>';
}
// The build bubble's static prefix — regenerated LIVE each paint (not frozen) so
// the plan card keeps its open/closed state across streaming repaints.
function planPrefix() { return buildSpec ? planCard(buildSpec, "done") : ""; }
function streamPrefix() { return planPrefix() + repairHtml; }
// The two honest phases of an app build. Tense follows reality: "Writing…" while
// the code streams, "Wrote" once the fence closes; "Rendering…" until the iframe
// actually loads, only then "Rendered". The status — not the prose — is the truth.
function buildTasks(lines, codeDone, previewDone) {
  return taskList([
    { status: codeDone ? "done" : "active",
      label: codeDone ? "Wrote the app" : "Writing the app",
      meta: lines + " lines" },
    { status: previewDone ? "done" : (codeDone ? "active" : "queued"),
      label: previewDone ? "Rendered the preview" : (codeDone ? "Rendering the preview" : "Render the preview") }
  ]);
}
// A clone's structural-fidelity score vs the original page (palette/fonts/sections/copy).
function fidelityCard(sc, from) {
  const tone = sc.score >= 75 ? "#2ecc71" : sc.score >= 50 ? "#e8b84b" : "#ff7a7a";
  const trail = (from != null && from !== sc.score) ? ' <span class="meta">(&#8593; from ' + from + '%)</span>' : '';
  let h = '<div class="tasks" style="margin-top:9px"><div class="tk"><span class="tki" style="border:0;color:' + tone + '">&#9678;</span>'
    + '<span><b>Clone fidelity: <span style="color:' + tone + '">' + sc.score + '%</span></b>' + trail + ' '
    + '<span class="meta">palette ' + sc.palette_match + '% · fonts ' + sc.font_match + '% · sections ' + sc.section_coverage + '% · copy ' + sc.heading_match + '%'
    + (typeof sc.motion_match === "number" ? ' · motion ' + sc.motion_match + '%' : '')
    + (typeof sc.token_match === "number" ? ' · tokens ' + sc.token_match + '%' : '') + '</span></span></div>';
  if (sc.missing_colors && sc.missing_colors.length)
    h += '<div class="tk tk-queued"><span class="tki"></span><span class="meta">unused original colours: ' + sc.missing_colors.join(", ") + '</span></div>';
  return h + "</div>";
}
// Score a clone (raw HTML) against the original URL; null on failure.
async function scoreClone(url, html) {
  try {
    const j = await (await fetch(AGENT_URL + "/api/agent/score", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ a: { url }, b: { html } }), signal: abortCtl.signal })).json();
    return j.ok ? j : null;
  } catch (e) { if (e.name === "AbortError") throw e; return null; }
}
// Turn the fidelity gaps into a concrete "close these" instruction for the coder.
function improvePrompt(sc) {
  const L = ["Your clone scored only " + sc.score + "% fidelity against the original page. Raise it by closing these specific gaps:"];
  if (sc.missing_colors && sc.missing_colors.length) L.push("- Use these EXACT colours from the original that you haven't used yet: " + sc.missing_colors.join(", ") + " — apply them to backgrounds, text, buttons and accents where they fit.");
  if (sc.missing_fonts && sc.missing_fonts.length) L.push("- Use these fonts from the original (load from Google Fonts if needed): " + sc.missing_fonts.join(", ") + ".");
  if (sc.sections_clone < sc.sections_original) L.push("- The original has ~" + sc.sections_original + " main sections; yours has " + sc.sections_clone + " — add the missing structural sections (nav, hero, features, footer, etc.).");
  if (sc.missing_animations && sc.missing_animations.length) L.push("- The original animates (" + sc.missing_animations.join(", ") + ") but your clone is static — add matching CSS @keyframes animations and hover transitions.");
  if (typeof sc.token_match === "number" && sc.token_match < 70) L.push("- Match the original's corner radii, box-shadows and type scale more closely (your design tokens are off).");
  L.push("Output the COMPLETE updated HTML file in ONE ```html block. Keep everything that already works; only close these gaps.");
  return L.join("\n");
}
/* ---------- Goal Mode: forge → agree → pursue → learn ---------- */
// Pull a JSON object out of a model reply — it may wrap it in prose or a ```json
// fence, and reasoners prepend <think>…</think>. Returns the object or null.
function parseGoalJSON(raw) {
  let s = stripThink(String(raw || "")).replace(/```(?:json)?/gi, "");
  const i = s.indexOf("{"), j = s.lastIndexOf("}");
  if (i < 0 || j <= i) return null;
  try { return JSON.parse(s.slice(i, j + 1)); } catch (e) { return null; }
}
// A sensible goal even when the model's JSON is unusable — so Goal Mode never dead-ends.
function fallbackGoal(text, auto) {
  const clone = !!auto.cloneUrl;
  return {
    capability: clone ? "Reproduce " + auto.cloneUrl + " as one self-contained page, matching its layout, palette and fonts."
                      : "Build: " + text.slice(0, 120),
    metric: clone ? { name: "Structural clone fidelity", how: "the scorer vs the real page", target: 75 }
                  : { name: "Requirements coverage", how: "strict model-graded check of the requirements vs the build", target: 80 },
    evals: clone ? ["Fidelity ≥ 75% on a fresh run", "Nav + hero + main sections all present"]
                 : ["The described features are implemented and work", "Renders with no runtime errors"],
    acceptance: clone ? "Fidelity hits target on a fresh run, or an honest ceiling is reported."
                      : "Every requirement is implemented (coverage ≥ target) on a fresh run.",
    nonGoals: clone ? ["Not pixel-perfect (a local model can't see)", "No backend beyond what's asked"]
                    : ["No backend / persistence beyond what's asked"],
    checkA: "A blank or off-topic page can't fake it — it would miss the requirements (low coverage) or fail to render.",
    checkB: clone ? "A local 14B from a text digest plateaus ~30% visual; structural target capped at 75. Lever: a vision model."
                  : "Coverage is model-graded (presence of each requirement); behavioural testing would harden it further."
  };
}
// Forge a measurable goal from the ask (reasoner -> JSON), normalised + made honest.
async function forgeGoal(text, auto, note, body) {
  if (body) { body.innerHTML = taskList([{ status: "active", label: "Forging a measurable goal", meta: (bestReasoner || bestCoder) }]); scrollDown(); }
  let g = null;
  try {
    const ask = text + (note ? "\n\nRevise the goal per this feedback: " + note : "");
    const raw = await callModel(() => {}, abortCtl.signal,
      { model: bestReasoner || bestCoder, system: GOAL_SPEC_SYSTEM, messages: [{ role: "user", content: ask }] });
    g = parseGoalJSON(raw);
  } catch (e) { if (e.name === "AbortError") throw e; }
  if (!g || !g.capability) g = fallbackGoal(text, auto);
  g.cloneUrl = auto.cloneUrl || null;
  if (!g.metric || typeof g.metric !== "object") g.metric = {};
  if (!Array.isArray(g.evals)) g.evals = [];
  // Scorer selection — OURS, not the model's word. A clone scores structural fidelity; ANY
  // build with checkable requirements scores requirements-coverage (model-graded, strict),
  // so Goal's iterate-loop now works beyond clones; a pure taste call (no evals) is honestly
  // "by inspection". Adding a scorer here is how Goal mode grows to new kinds of goal.
  if (g.cloneUrl) { g.scorer = "clone"; g.autoScored = true; g.metric.name = g.metric.name || "Structural clone fidelity"; const t = +g.metric.target; g.metric.target = (t >= 40 && t <= 88) ? t : 75; }
  else if (g.evals.length) { g.scorer = "spec"; g.autoScored = true; g.metric.name = "Requirements coverage"; const t = +g.metric.target; g.metric.target = (t >= 50 && t <= 95) ? t : 80; }
  else { g.scorer = null; g.autoScored = false; g.metric.name = "Acceptance by inspection"; g.metric.target = null; }
  if (!Array.isArray(g.nonGoals)) g.nonGoals = [];
  return g;
}
// The card's inner HTML (no outer .goal wrapper) — capability, metric, evals, checks.
function goalCardInner(g) {
  const m = g.metric || {};
  const badge = g.autoScored ? '<span class="gbadge">auto-scored</span>' : '<span class="gbadge warn">by inspection</span>';
  const cell = v => escapeHtml(String(v)).replace(/\*\*([^*]+?)\*\*/g, "<b>$1</b>");
  const row = (k, v) => v ? '<div class="k">' + k + '</div><div class="v">' + cell(v) + '</div>' : "";
  let h = '<h4>&#127919; Goal ' + badge + '</h4><div class="cap">' + escapeHtml(g.capability) + '</div><div class="grid">';
  h += row("Metric", (m.name || "—") + (m.target != null ? " · target **" + m.target + "%**" : "") + (m.how ? " · " + m.how : ""));
  if (g.evals.length) h += row("Evals", g.evals.map(e => "• " + e).join("\n"));
  h += row("Accept", g.acceptance);
  if (g.nonGoals.length) h += row("Non-goals", g.nonGoals.join(" · "));
  h += '</div>';
  let v = "";
  if (g.checkB) v += "<b>Feasibility:</b> " + escapeHtml(g.checkB);
  if (g.checkA) v += (v ? "<br>" : "") + "<b>Robustness:</b> " + escapeHtml(g.checkA);
  if (v) h += '<div class="verdict">' + v + '</div>';
  return h;
}
// Render the card + the Agree / Adjust / Skip gate. Resolves 'agree' | 'skip' | {note}.
function goalGate(body, g) {
  return new Promise(resolve => {
    body.innerHTML = '<div class="goal">' + goalCardInner(g)
      + '<div class="adjbox"><textarea placeholder="What should change? target, sections, the metric…"></textarea><div class="gbtns"><button class="ok rf">Re-forge</button></div></div>'
      + '<div class="gbtns main"><button class="ok ag">Agree &amp; pursue</button><button class="adj aj">Adjust</button><button class="skip sk">Skip — just build</button></div></div>';
    scrollDown();
    const card = body.querySelector(".goal");
    card.querySelector(".ag").addEventListener("click", () => { card.classList.add("locked", "agreed"); resolve("agree"); });
    card.querySelector(".sk").addEventListener("click", () => { card.classList.add("locked", "skipped"); resolve("skip"); });
    card.querySelector(".aj").addEventListener("click", () => { card.querySelector(".adjbox").classList.add("on"); card.querySelector(".gbtns.main").style.display = "none"; card.querySelector(".adjbox textarea").focus(); });
    card.querySelector(".rf").addEventListener("click", () => { const note = card.querySelector(".adjbox textarea").value.trim(); resolve({ note: note || "make it sharper and more measurable" }); });
  });
}
// Turn an agreed goal into a build spec the coder implements (non-clone goals).
function goalSpecText(g) {
  const L = ["Build to THIS goal — implement every point:", "Capability: " + g.capability];
  if (g.evals && g.evals.length) L.push("Must satisfy:\n" + g.evals.map(e => "- " + e).join("\n"));
  if (g.acceptance) L.push("Done when: " + g.acceptance);
  if (g.nonGoals && g.nonGoals.length) L.push("Out of scope: " + g.nonGoals.join("; "));
  return L.join("\n");
}
// Append a pursued-goal record to the learning/limits log; returns the run count.
async function logGoalRun(rec) {
  try {
    const j = await (await fetch(AGENT_URL + "/api/agent/goallog", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ run: rec }) })).json();
    return j && j.ok ? j.count : null;
  } catch (e) { return null; }
}
// The honest end-of-goal verdict: reached target, or plateaued at a ceiling (+ the lever).
function goalVerdictCard(g, reached, finalScore, runN) {
  const t = g.metric && g.metric.target;
  let line, tone;
  if (reached) { tone = "#2ecc71"; line = "<b>Goal reached</b> — " + finalScore + "% &ge; " + t + "% target."; }
  else if (finalScore != null) {
    tone = "#e8b84b";
    const lever = g.scorer === "clone"
      ? "the lever that raises it is a <b>vision model</b> (see + self-correct the layout)"
      : "the remaining gaps are the hardest for a local 14B from a text spec — a stronger coder, splitting the goal, or behavioural tests would lift it";
    line = "<b>Plateaued at " + finalScore + "%</b> (target " + t + "%) — " + lever + ".";
  }
  else { tone = "#7fd0ff"; line = "<b>Built to the goal.</b> No automatic scorer for this kind of ask — acceptance is by inspection."; }
  return '<div class="tasks" style="margin-top:9px"><div class="tk"><span class="tki" style="border:0;color:' + tone + '">&#9678;</span><span>' + line + (runN ? ' <span class="meta">· logged (run #' + runN + ')</span>' : '') + '</span></div></div>';
}
/* ---------- Build-quality scorer (non-clone goals): requirements coverage ---------- */
// The build is already self-repaired to RUN clean; here we check WHICH of the goal's
// requirements it actually implements — a strict, model-graded coverage score. This is the
// scorer that lets Goal mode iterate ANY build toward a bar, not just clones. (The next,
// harder scorer to add: behavioural testing — drive the page and assert it actually works.)
async function scoreSpec(goal, app) {
  const reqs = (goal.evals || []).filter(Boolean);
  if (!reqs.length || !app) return null;
  const sys = "You are a STRICT QA reviewer. Given a goal's requirements and the app's HTML, decide which requirements the build ACTUALLY implements (working markup + script), not merely mentions. Output ONLY JSON: {\"missing\":[\"<exact text of each requirement NOT met>\"]}. Return {\"missing\":[]} only if every requirement is genuinely implemented. Be strict.";
  const prompt = "Requirements:\n" + reqs.map((q, i) => (i + 1) + ". " + q).join("\n") + "\n\nApp (HTML):\n" + String(app).slice(0, 9000);
  try {
    const raw = await callModel(() => {}, abortCtl.signal, { model: bestReasoner || bestCoder, system: sys, messages: [{ role: "user", content: prompt }] });
    const j = parseGoalJSON(raw) || {};
    const missing = (Array.isArray(j.missing) ? j.missing : []).map(String).filter(Boolean).slice(0, reqs.length);
    const met = Math.max(0, reqs.length - missing.length);
    return { score: Math.round(100 * met / reqs.length), met, total: reqs.length, missing };
  } catch (e) { if (e.name === "AbortError") throw e; return null; }
}
function improveSpecPrompt(scov) {
  const L = ["Your build meets only " + scov.met + " of " + scov.total + " requirements (" + scov.score + "%). Implement these MISSING requirements fully — real, working markup + script:"];
  scov.missing.forEach(m => L.push("- " + m));
  L.push("Output the COMPLETE updated HTML file in ONE ```html block. Keep everything that already works; add what's missing.");
  return L.join("\n");
}
// Coverage score card (build goals), mirroring fidelityCard.
function specCard(sc, from) {
  const tone = sc.score >= 80 ? "#2ecc71" : sc.score >= 50 ? "#e8b84b" : "#ff7a7a";
  const trail = (from != null && from !== sc.score) ? ' <span class="meta">(&#8593; from ' + from + '%)</span>' : '';
  let h = '<div class="tasks" style="margin-top:9px"><div class="tk"><span class="tki" style="border:0;color:' + tone + '">&#9678;</span>'
    + '<span><b>Requirements coverage: <span style="color:' + tone + '">' + sc.score + '%</span></b>' + trail
    + ' <span class="meta">' + sc.met + ' / ' + sc.total + ' met</span></span></div>';
  if (sc.missing && sc.missing.length)
    h += '<div class="tk tk-queued"><span class="tki"></span><span class="meta">still missing: ' + sc.missing.slice(0, 4).map(m => escapeHtml(String(m).slice(0, 52))).join("; ") + '</span></div>';
  return h + "</div>";
}
/* ---------- Auto-recommend Agent / Goal when the task clearly benefits ---------- */
// A clone benefits from Goal (a fidelity target + iterate-to-it); a multi-file / backend /
// tooling task benefits from Agent (shell + file tools). Suggest the missing one — never
// force it, and let the user dismiss suggestions for the session.
function modeSuggestion(text, auto, agentOn, goalOn) {
  try { if (sessionStorage.getItem("llm.noSuggest")) return null; } catch (e) {}
  if (auto.cloneUrl && !goalOn) return {
    mode: "goal", title: "🎯 This looks like a site clone",
    body: "<b>Goal mode</b> sets a fidelity target and iterates the clone toward it, pausing for your approval first. (It works for <b>any build</b>, not just clones — and doesn't need the Agent toggle.) Turn it on?" };
  const agentTask = /\b(multi[- ]?file|several files|back[- ]?end|database|\bAPI\b|server|full[- ]?stack|npm\b|pip\b|install|scaffold|run (?:the|a|my)|execute|shell|command|\bCLI\b)\b/i.test(text);
  if (agentTask && !auto.cloneUrl && !agentOn) return {
    mode: "agent", title: "🤖 This looks like a multi-file / tooling task",
    body: "<b>Agent mode</b> gives the model real tools — run terminal commands and write files (it asks your approval before each). Turn it on for this?" };
  // a build with several requirements benefits from Goal's coverage loop (iterate until complete)
  if (auto.kind === "build" && !auto.cloneUrl && !agentTask && !goalOn && text.length > 45 && /\b(and|with|plus|including|that|then|also)\b/i.test(text)) return {
    mode: "goal", title: "🎯 This has a few moving parts",
    body: "<b>Goal mode</b> pins your request as a measurable goal you approve, then builds and <b>iterates until it covers every requirement</b> — not just a first draft. Turn it on?" };
  return null;
}
function modeNudge(body, sug) {
  return new Promise(resolve => {
    body.innerHTML = '<div class="goal"><h4>' + sug.title + '</h4><div class="cap">' + sug.body + '</div>'
      + '<div class="gbtns"><button class="ok yes">Turn on &amp; continue</button><button class="adj no">Continue without</button><button class="skip never">Don\'t suggest again</button></div></div>';
    scrollDown();
    const card = body.querySelector(".goal");
    card.querySelector(".yes").addEventListener("click", () => { card.classList.add("locked", "agreed"); resolve("on"); });
    card.querySelector(".no").addEventListener("click", () => { card.classList.add("locked", "skipped"); resolve("off"); });
    card.querySelector(".never").addEventListener("click", () => { try { sessionStorage.setItem("llm.noSuggest", "1"); } catch (e) {} card.classList.add("locked", "skipped"); resolve("off"); });
  });
}
// Throttle streaming re-renders to ~1/66ms so the bubble doesn't reflow on every
// token — that thrash is what made scrolling up jerk. The post-stream final paint
// always runs, so nothing is lost by skipping intermediate frames.
let _lastPaint = 0;
function paintReady(force) { const n = performance.now(); if (!force && n - _lastPaint < 66) return false; _lastPaint = n; return true; }
function displayStreaming(body, acc, sid) {
  const p = parseStream(acc);
  if (!paintReady(p.complete)) return;
  if (p.code !== null) {
    const n = p.code.replace(/\s+$/, "").split("\n").length;
    body.innerHTML = streamPrefix() + render(p.prose) + buildTasks(n, p.complete, false);
    if (sid === currentId) {                                          // only paint the shared panes for the ACTIVE project
      codeview.textContent = p.code;                                  // stream the code into the Code pane, live
      wsempty.classList.add("hidden"); wsbuild.classList.add("hidden");
      if (!p.complete && !buildingApp) { buildingApp = true; showTab("code"); }   // jump to Code so you watch it write
    }
  } else {
    body.innerHTML = streamPrefix() + render(acc);
  }
  scrollDown();
}
function addMsg(role, text) {
  empty.style.display = "none";
  const w = document.createElement("div");
  w.className = "msg " + (role === "user" ? "user" : "bot");
  w.innerHTML = '<div class="who">' + (role === "user" ? "You" : "AI") + '</div><div class="body"></div>';
  w.querySelector(".body").innerHTML = render(text);
  log.appendChild(w);
  scrollDown();
  return w.querySelector(".body");
}

/* ---------- scroll ---------- */
function atBottom() { return log.scrollHeight - log.scrollTop - log.clientHeight < 60; }
function scrollDown() { if (stick) log.scrollTop = log.scrollHeight; }
log.addEventListener("scroll", () => { stick = atBottom(); jump.hidden = stick; });
jump.addEventListener("click", () => { stick = true; log.scrollTop = log.scrollHeight; jump.hidden = true; });
// keep the plan card's expanded state across streaming repaints (it gets rebuilt
// each paint). Read happens pre-toggle, so the new state is !current.
log.addEventListener("click", e => { const s = e.target.closest("details.plan > summary"); if (s) planOpen = !s.parentElement.open; });

/* ---------- workspace ---------- */
function extractApp(text) {
  const fences = [...text.matchAll(/```(?:html)?\s*([\s\S]*?)```/gi)].map(m => m[1]);
  for (let i = fences.length - 1; i >= 0; i--) if (/<\/html>|<!doctype|<body/i.test(fences[i])) return fences[i].trim();
  return null;
}
// Design system injected into every generated app: Tailwind + shadcn-style
// tokens (light theme). The model writes Tailwind/shadcn classes; this makes
// them actually render — so previews look strong (Lovable/v0-style), not blank.
const DESIGN_HEAD = document.getElementById("designHead").innerHTML;
// Same tokens + tailwind.config but WITHOUT the CDN <script> — used when the model
// already added its own Tailwind CDN (so we supply the missing config, not a 2nd CDN).
const DESIGN_CONFIG = DESIGN_HEAD.replace(/<script[^>]*cdn\.tailwindcss\.com[^>]*><\/script>/i, "");
// Self-repair: the error-catcher injected into every preview + the channel that
// collects what it reports. The status — errors or clean — drives the auto-fix.
const ERR_HOOK = document.getElementById("errHook").innerHTML;
let previewErrors = [];
window.addEventListener("message", e => {
  const d = e.data;
  if (d && d.__llmbuilder === 1 && d.kind === "error" && typeof d.msg === "string" && previewErrors.length < 12) previewErrors.push(d.msg);
});
function instrument(html) {
  if (!html) return html;
  // inject FIRST (top of head) so the error handler is registered before any app script runs
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head([^>]*)>/i, "<head$1>" + ERR_HOOK);
  if (/<html[^>]*>/i.test(html)) return html.replace(/(<html[^>]*>)/i, "$1<head>" + ERR_HOOK + "</head>");
  return ERR_HOOK + html;
}
// Resolve with any runtime errors the preview threw. Resolves IMMEDIATELY once an
// error appears (so the fix starts fast), otherwise after the clean-window post-load
// — long enough to catch late async errors (e.g. a CDN lib loading then throwing).
const SETTLE_MS = 2500;
function previewSettled() {
  return new Promise(resolve => {
    let done = false, loadedAt = 0;
    const t0 = Date.now();
    const finish = () => { if (done) return; done = true; clearInterval(iv); resolve(previewErrors.slice()); };
    preview.addEventListener("load", () => { loadedAt = Date.now(); }, { once: true });
    const iv = setInterval(() => {
      if (previewErrors.length) return finish();                       // an error surfaced -> repair now
      if (loadedAt && Date.now() - loadedAt >= SETTLE_MS) return finish();   // loaded + clean window elapsed
      if (Date.now() - t0 >= SETTLE_MS + 6000) return finish();        // safety: load never fired
    }, 180);
  });
}
function fixPrompt(errs) {
  return "The web app you just generated threw a runtime error when it ran in the browser:\n\n" +
    errs.slice(0, 3).map(e => "• " + e).join("\n") +
    "\n\nFind and fix the bug, then output the COMPLETE corrected HTML file again in a single ```html code block. Keep everything that already worked — change only what's needed to fix the error.";
}
function repairSection(st) {
  if (!st) return "";
  const label = st.status === "done" ? "Fixed a runtime error"
    : st.status === "fail" ? "Tried to fix — an error remains"
    : "Caught an error — fixing";
  return taskList([{ status: st.status === "active" ? "active" : st.status, label, meta: st.attempt ? "attempt " + st.attempt : "" }]);
}
function usesTailwind(code) {
  return /class\s*=\s*["'][^"']*(?:\b(?:flex|grid|hidden|container)\b|(?:bg|text|p|px|py|pt|pb|m|mt|mb|mx|my|w|h|gap|rounded|shadow|border|items|justify|font|space|max|min)-)/i.test(code);
}
function injectDesign(code) {
  if (!code) return code;
  if (/border:\s*["']hsl\(var\(--border\)\)/.test(code)) return code;     // already has OUR tokens + config
  const hasCDN = /cdn\.tailwindcss\.com/i.test(code);
  if (!hasCDN && !usesTailwind(code)) return code;                        // plain app (e.g. a stopwatch) — render as-is
  // The model used Tailwind (often with our token classes like bg-background) but
  // without the config that DEFINES them -> inject it. Skip a 2nd CDN if it added one.
  const head = hasCDN ? DESIGN_CONFIG : DESIGN_HEAD;
  if (/<head[^>]*>/i.test(code)) return code.replace(/<head([^>]*)>/i, '<head$1>' + head);
  if (/<html[^>]*>/i.test(code)) return code.replace(/(<html[^>]*>)/i, '$1<head>' + head + '</head>');
  return '<!doctype html><html><head>' + head + '</head><body>' + code + '</body></html>';
}
// Render the app via a blob: URL (more reliable than srcdoc in a sandboxed iframe)
// + a loading state. Returns nothing; manages overlays.
let previewUrl = null;
function showLoading(on) { wsload.classList.toggle("hidden", !on); }
function loadPreview(html) {
  wsempty.classList.add("hidden"); wsbuild.classList.add("hidden");
  if (previewUrl) { URL.revokeObjectURL(previewUrl); previewUrl = null; }
  preview.removeAttribute("srcdoc");
  previewErrors = [];                                         // fresh error window for this render
  if (!html) { preview.src = "about:blank"; wsempty.classList.remove("hidden"); showLoading(false); return; }
  previewUrl = URL.createObjectURL(new Blob([instrument(html)], { type: "text/html" }));
  showLoading(true);
  preview.src = previewUrl;
}
preview.addEventListener("load", () => {
  showLoading(false);
  if (pendingBuild) {                                  // the preview has now truly rendered -> mark the build done
    const { body, lines, prose } = pendingBuild; pendingBuild = null;
    body.innerHTML = prose + buildTasks(lines, true, true);
    scrollDown();
  }
});
refreshBtn.addEventListener("click", () => { if (currentApp) { loadPreview(currentApp); showTab("preview"); } });
function setApp(code) { currentApp = injectDesign(code); codeview.textContent = currentApp; dlBtn.disabled = false; loadPreview(currentApp); showTab("preview"); }
function showTab(which) {
  for (const [t, n] of [[tabPreview, "preview"], [tabCode, "code"], [tabTerm, "term"]]) t.classList.toggle("on", n === which);
  preview.classList.toggle("hidden", which !== "preview");
  codeview.classList.toggle("hidden", which !== "code");
  termview.classList.toggle("hidden", which !== "term");
}
tabPreview.addEventListener("click", () => showTab("preview"));
tabCode.addEventListener("click", () => showTab("code"));
tabTerm.addEventListener("click", () => showTab("term"));
dlBtn.addEventListener("click", () => { const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([currentApp], { type: "text/html" })); a.download = "app.html"; a.click(); URL.revokeObjectURL(a.href); });
function term(html) { termview.classList.remove("hidden"); termview.insertAdjacentHTML("beforeend", html); termview.scrollTop = termview.scrollHeight; }

/* ---------- history (localStorage) ---------- */
const STORE = "llmbuilder.chats.v1";
function loadStore() { try { return JSON.parse(localStorage.getItem(STORE) || "[]"); } catch (e) { return []; } }
function saveStore(a) { localStorage.setItem(STORE, JSON.stringify(a)); }
// Persist a SPECIFIC session by id (not just the active one) so a build that
// finishes while you've switched to another chat saves to ITS own project.
// Snapshot the VISIBLE chat (goal cards, fidelity/coverage scores, plan, verdict, prose —
// not just the raw model messages) so reopening a chat restores the full story: the
// thinking, our decisions, the scores. Without this, a reload showed only the last message.
function captureTranscript() {
  return [...log.querySelectorAll(".msg")].map(m => ({
    role: m.classList.contains("user") ? "user" : "assistant",
    html: (m.querySelector(".body") || {}).innerHTML || ""
  })).filter(b => b.html);
}
function persistSession(id, msgs, app, transcript) {
  if (!msgs.length) return;
  const a = loadStore();
  const i = a.findIndex(c => c.id === id);
  const title = (msgs.find(m => m.role === "user") || {}).content || "New chat";
  // keep the prior transcript when this save isn't for the on-screen session (background build)
  const tx = transcript || (i >= 0 ? a[i].transcript : null);
  const rec = { id, title: title.slice(0, 60), messages: msgs, app, transcript: tx, ts: Date.now() };
  if (i >= 0) a[i] = rec; else a.unshift(rec);
  saveStore(a); renderList();
}
function persist() { persistSession(currentId, messages, currentApp, captureTranscript()); }
function renderList() {
  const a = loadStore();
  chatlist.innerHTML = a.length ? "" : '<div class="empty2">No saved chats yet.</div>';
  for (const c of a) {
    const d = document.createElement("div");
    d.className = "item" + (c.id === currentId ? " on" : "");
    const building = buildingIds.has(c.id);
    d.innerHTML = '<span class="ttl"></span>' + (building ? '<span class="sdot" title="Building&hellip;"></span>' : '') + '<span class="del" title="Delete">&times;</span>';
    d.querySelector(".ttl").textContent = c.title || "Untitled";
    d.querySelector(".ttl").addEventListener("click", () => openChat(c.id));
    d.querySelector(".del").addEventListener("click", e => { e.stopPropagation(); deleteChat(c.id); });
    chatlist.appendChild(d);
  }
}
function clearMessagesUI() { [...log.querySelectorAll(".msg")].forEach(n => n.remove()); }
// Swap the ENTIRE workspace to a project's own state. Each chat is an
// independent project: its own messages, app, preview, code + build state.
function resetWorkspace() {
  buildingApp = false; pendingBuild = null;
  wsbuild.classList.add("hidden"); showLoading(false);
  codeview.textContent = ""; termview.textContent = "";
}
function newChat() {
  currentId = newId(); messages = []; currentApp = "";
  resetWorkspace(); loadPreview(""); dlBtn.disabled = true;
  wsempty.classList.remove("hidden"); showTab("preview");
  clearMessagesUI(); empty.style.display = ""; renderList(); input.focus();
}
function openChat(id) {
  const c = loadStore().find(x => x.id === id); if (!c) return;
  currentId = id; messages = c.messages || []; currentApp = injectDesign(c.app || "");
  resetWorkspace();
  clearMessagesUI(); empty.style.display = (messages.length || (c.transcript && c.transcript.length)) ? "none" : "";
  if (c.transcript && c.transcript.length) {
    // restore the full visible transcript — goal cards, scores, plan, decisions and all
    for (const b of c.transcript) {
      const w = document.createElement("div");
      w.className = "msg " + (b.role === "user" ? "user" : "bot");
      w.innerHTML = '<div class="who">' + (b.role === "user" ? "You" : "AI") + '</div><div class="body"></div>';
      w.querySelector(".body").innerHTML = b.html;
      log.appendChild(w);
    }
  } else {
    for (const m of messages) addMsg(m.role, m.content);   // older sessions saved before transcripts
  }
  codeview.textContent = currentApp; dlBtn.disabled = !currentApp; loadPreview(currentApp);
  showTab("preview"); renderList(); stick = true; scrollDown();
}
function deleteChat(id) {
  saveStore(loadStore().filter(c => c.id !== id));
  if (id === currentId) newChat(); else renderList();
}
el("newBtn").addEventListener("click", newChat);
el("sbToggle").addEventListener("click", () => sidebar.classList.toggle("collapsed"));

/* ---------- agent tools ---------- */
const READONLY_TOOLS = ["read", "fetch", "inspect", "extract", "screenshot"];
function findToolCall(text) {
  const run = text.match(/<run>([\s\S]*?)<\/run>/i);
  if (run) return { kind: "run", cmd: run[1].trim() };
  const wr = text.match(/<write\s+path="([^"]+)">\n?([\s\S]*?)<\/write>/i);
  if (wr) return { kind: "write", path: wr[1].trim(), content: wr[2] };
  const rd = text.match(/<read\s+path="([^"]+)"\s*\/?>/i);
  if (rd) return { kind: "read", path: rd[1].trim() };
  const fe = text.match(/<fetch\s+url="([^"]+)"\s*\/?>/i);
  if (fe) return { kind: "fetch", url: fe[1].trim() };
  const ins = text.match(/<inspect\s+url="([^"]+)"\s*\/?>/i);
  if (ins) return { kind: "inspect", url: ins[1].trim() };
  const ex = text.match(/<extract\s+url="([^"]+)"\s*\/?>/i);
  if (ex) return { kind: "extract", url: ex[1].trim() };
  const sh = text.match(/<screenshot\s+url="([^"]+)"\s*\/?>/i);
  if (sh) return { kind: "screenshot", url: sh[1].trim() };
  const gs = text.match(/<gitsync\b([^>]*)\/?>/i);
  if (gs) {
    const attrs = gs[1] || "";
    const p = attrs.match(/path="([^"]*)"/i), m = attrs.match(/message="([^"]*)"/i), rm = attrs.match(/remote="([^"]*)"/i);
    return { kind: "gitsync", path: (p ? p[1].trim() : "."), message: (m ? m[1] : "Initial commit — scaffolded by Local LLM Builder"), remote: (rm ? rm[1].trim() : null) };
  }
  return null;
}
function approvalCard(tool) {
  return new Promise(resolve => {
    const c = document.createElement("div");
    c.className = "msg bot";
    const label = tool.kind === "run" ? "Run this command?"
                : tool.kind === "gitsync" ? "Make this a local git repo + commit?"
                : ("Write file: " + tool.path + "?");
    const codeTxt = tool.kind === "run" ? tool.cmd
                  : tool.kind === "gitsync" ? ("git init + .gitignore + commit\npath: " + tool.path + "\nmessage: " + tool.message + (tool.remote ? "\nremote (configured, NOT pushed): " + tool.remote : ""))
                  : tool.content;
    c.innerHTML = '<div class="who">&#9889;</div><div class="body"><div class="approve"><div class="lbl"></div><pre></pre><div class="btns"><button class="ok">Approve</button><button class="no">Skip</button></div></div></div>';
    c.querySelector(".lbl").textContent = label;
    c.querySelector("pre").textContent = codeTxt;
    log.appendChild(c); scrollDown();
    const card = c.querySelector(".approve");
    c.querySelector(".ok").addEventListener("click", () => { card.classList.add("done"); resolve(true); });
    c.querySelector(".no").addEventListener("click", () => { card.classList.add("done"); resolve(false); });
  });
}
async function runTool(tool) {
  if (tool.kind === "run") {
    term('<span class="cmd">$ ' + escapeHtml(tool.cmd) + '</span>\n');
    const r = await fetch(AGENT_URL + "/api/agent/run", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cmd: tool.cmd }) });
    const j = await r.json();
    const out = (j.stdout || "") + (j.stderr ? "\n" + j.stderr : "");
    if (out.trim()) term((j.stderr && !j.stdout ? '<span class="err">' : "<span>") + escapeHtml(out) + "</span>\n");
    term('<span style="color:#5b6472">[exit ' + j.code + ']</span>\n\n');
    showTab("term");
    return "exit code " + j.code + "\n" + out.slice(0, 4000);
  } else if (tool.kind === "write") {
    const r = await fetch(AGENT_URL + "/api/agent/write", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path: tool.path, content: tool.content }) });
    const j = await r.json();
    term('<span class="cmd">[write] ' + escapeHtml(tool.path) + '</span> ' + (j.ok ? "ok" : ('<span class="err">' + escapeHtml(j.error || "failed") + "</span>")) + "\n");
    showTab("term");
    return j.ok ? ("wrote " + tool.path) : ("error: " + (j.error || "failed"));
  } else if (tool.kind === "gitsync") {
    term('<span class="cmd">[gitsync] ' + escapeHtml(tool.path) + '</span>\n'); showTab("term");
    const r = await fetch(AGENT_URL + "/api/agent/gitsync", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path: tool.path, message: tool.message, remote: tool.remote }) });
    const j = await r.json();
    if (!j.ok) { term('<span class="err">' + escapeHtml(j.error || "failed") + "</span>\n\n"); return "gitsync error: " + (j.error || "failed"); }
    const out = "git repo ready at " + j.repo_path + "\n  branch: " + j.branch + " · commit: " + (j.commit ? j.commit.slice(0, 9) : "(none)")
              + " · files: " + j.files_tracked + (j.gitignore_written ? " · wrote .gitignore" : "")
              + (j.zip_path ? "\n  export: " + j.zip_path + " (" + j.zip_bytes + " bytes, includes .git history)" : "")
              + "\n  to push (your token): " + j.push_hint;
    term(escapeHtml(out) + "\n\n");
    return out;
  } else {
    // read-only tools: read | fetch | inspect | extract
    const label = tool.kind === "read" ? tool.path : tool.url;
    const payload = tool.kind === "read" ? { path: tool.path } : { url: tool.url };
    term('<span class="cmd">[' + tool.kind + '] ' + escapeHtml(label) + '</span>\n'); showTab("term");
    const r = await fetch(AGENT_URL + "/api/agent/" + tool.kind, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    const j = await r.json();
    if (!j.ok) { term('<span class="err">' + escapeHtml(j.error || "failed") + "</span>\n\n"); return tool.kind + " error: " + (j.error || "failed"); }
    let out;
    if (tool.kind === "read") out = j.content || "(empty)";
    else if (tool.kind === "fetch") out = "Fetched " + j.url + " — status " + j.status + (j.truncated ? " (truncated)" : "") + "\n\n" + j.html;
    else if (tool.kind === "screenshot") {
      if (j.dataurl) { termview.classList.remove("hidden"); termview.insertAdjacentHTML("beforeend", '<img src="' + j.dataurl + '" style="max-width:100%;border:1px solid #1e2430;border-radius:8px;margin:4px 0">'); termview.scrollTop = termview.scrollHeight; }
      out = "screenshot saved to workspace/" + (j.path || "shots") + " (" + (j.bytes || 0) + " bytes)";   // model can't see images; gets the path
    }
    else { delete j.ok; delete j.dataurl; out = JSON.stringify(j, null, 1); }   // inspect / extract / score -> the structured digest
    term(escapeHtml(out.slice(0, 1400)) + (out.length > 1400 ? "\n  …(" + out.length + " chars)" : "") + "\n\n");
    return out.slice(0, 6000);
  }
}

/* ---------- the model call ---------- */
async function callModel(onTok, signal, opts) {
  opts = opts || {};
  const sys = opts.system || (agentChk.checked ? AGENT_SYSTEM : BUILDER_SYSTEM);
  const model = opts.model || currentModel;
  const msgs = opts.messages || messages;
  const resp = await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, signal,
    body: JSON.stringify({ model, stream: true, messages: [{ role: "system", content: sys }, ...msgs] }) });
  const reader = resp.body.getReader(); const dec = new TextDecoder(); let buf = "", acc = "";
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true });
    const lines = buf.split("\n"); buf = lines.pop();
    for (const line of lines) { if (!line.trim()) continue; const o = JSON.parse(line); if (o.message && o.message.content) { acc += o.message.content; onTok(acc); } }
  }
  return acc;
}

function setBusy(on) {
  busy = on;
  sendBtn.textContent = on ? "Stop" : "Send";
  sendBtn.classList.toggle("stop", on);
}
function stopGen() { if (abortCtl) abortCtl.abort(); }

// deepseek-r1 & friends emit <think>…</think> before the answer — keep only the answer.
function stripThink(s) {
  if (/<\/think>/i.test(s)) return s.replace(/[\s\S]*?<\/think>/i, "");
  return s.replace(/<think>/i, "");
}

async function send() {
  const text = input.value.trim();
  if (!text || busy || !currentModel) return;
  const sid = currentId;                 // this generation belongs to THIS project, even if you switch away
  const sessionMessages = messages;      // keeps pointing at this project's history after a switch
  let sessionApp = currentApp;
  setBusy(true); input.value = ""; input.style.height = "auto"; stick = true;
  buildingIds.add(sid); renderList();
  addMsg("user", text); sessionMessages.push({ role: "user", content: text });
  abortCtl = new AbortController();
  buildSpec = ""; repairHtml = ""; buildingApp = false; _lastPaint = 0; planOpen = false;
  goalActive = false; goalTarget = 0; goalMeta = null; goalRounds = [];
  let body = null;
  let goalSpec = "";                                              // a forged build spec for a non-clone goal
  // ---- route: which brain, and do we plan first? ----
  let agentRun = agentChk.checked && agentReady;
  let goalRun = goalChk.checked && agentReady;                    // Goal Mode: needs the server (works alongside Agent)
  const auto = route(text);                                       // also detects a "clone <url>" request
  // ---- Auto-recommend a mode when the task clearly benefits and it's off (one card, session-dismissible) ----
  if (agentReady && (!agentRun || !goalRun)) {
    const sug = modeSuggestion(text, auto, agentRun, goalRun);
    if (sug) {
      const choice = await modeNudge(addMsg("assistant", ""), sug);
      if (choice === "on") {
        if (sug.mode === "goal") { goalChk.checked = true; goalRun = true; }
        else { agentChk.checked = true; agentRun = true; }
      }
    }
  }
  let r = auto.cloneUrl
    ? auto                                                        // a clone ALWAYS uses the clone path (preview + score), never the raw agent loop
    : (autoMode && !agentRun) ? auto
    : { kind: agentRun ? "agent" : (currentApp ? "edit" : "build"), model: currentModel || bestCoder, plan: false };
  try {
    // ---- Goal Mode: forge a measurable goal, get the user's agreement, THEN pursue + log ----
    if (goalRun && (r.kind === "build" || r.cloneUrl)) {
      const gb = addMsg("assistant", "");
      let g = await forgeGoal(text, auto, "", gb);
      let decision;
      while (true) {
        decision = await goalGate(gb, g);
        if (decision === "agree" || decision === "skip") break;
        g = await forgeGoal(text, auto, decision.note, gb);       // re-forge with the adjustment, then re-gate
      }
      if (decision === "agree") {
        goalActive = true; goalMeta = g; goalRounds = [];
        if (g.cloneUrl) { r = { kind: "build", model: bestCoder, plan: false, cloneUrl: g.cloneUrl }; goalTarget = (g.metric && +g.metric.target) || 75; }
        else goalSpec = goalSpecText(g);
      }
    }
    if (agentRun && !r.cloneUrl && !goalActive) {
      // ---- agent mode: multi-step approve-to-run tool loop. Clones + Goal mode are
      // deliberately NOT routed here — they use the build/clone path (live preview +
      // fidelity score); the raw tool loop is for shell / multi-file / non-web tasks. ----
      let steps = 0;
      while (steps++ < 12) {
        body = addMsg("assistant", "");
        const acc = await callModel(t => displayStreaming(body, t, sid), abortCtl.signal, { model: r.model });
        sessionMessages.push({ role: "assistant", content: acc });
        body.innerHTML = render(acc);
        const tool = findToolCall(acc);
        if (tool) {
          // read-only tools (read/fetch/inspect/extract) run directly; mutations are approved
          const ok = READONLY_TOOLS.includes(tool.kind) ? true : await approvalCard(tool);
          const result = ok ? await runTool(tool) : "skipped by user";
          sessionMessages.push({ role: "user", content: "<result>\n" + result + "\n</result>" });
          continue;
        }
        break;
      }
    } else if (r.kind === "reason") {
      // ---- reasoning / Q&A: the reasoner, plain answer (no app) ----
      body = addMsg("assistant", "");
      const acc = await callModel(t => { if (!paintReady(false)) return; body.innerHTML = render(stripThink(t)); scrollDown(); }, abortCtl.signal,
        { model: r.model, system: "You are a helpful, concise engineering assistant running locally on the user's machine." });
      sessionMessages.push({ role: "assistant", content: acc });
      body.innerHTML = render(stripThink(acc));
    } else {
      // ---- build / edit / clone ----
      let spec = goalSpec || "";
      // clone: OBSERVE the real page first (palette, fonts, sections), then build to it
      if (r.cloneUrl) {
        body = addMsg("assistant", "");
        body.innerHTML = taskList([{ status: "active", label: "Inspecting " + r.cloneUrl }]);
        if (sid === currentId) showTab("term");
        try {
          const dg = await (await fetch(AGENT_URL + "/api/agent/inspect", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: r.cloneUrl }), signal: abortCtl.signal })).json();
          if (dg.ok) {
            const th = await pageTheme(r.cloneUrl); if (th) dg.theme = th.theme;   // match dark/light
            spec = cloneSpecFromDigest(dg); buildSpec = spec;
            body.innerHTML = taskList([{ status: "done", label: "Inspected the page", meta: (dg.palette || []).length + " colours · " + (dg.fonts || []).length + " fonts" }]) + streamPrefix() + buildTasks(0, false, false);
            scrollDown();
          } else {
            body.innerHTML = taskList([{ status: "fail", label: "Couldn't inspect " + r.cloneUrl }]) + render("That page couldn't be fetched (" + (dg.error || "failed") + "). I'll build from your description instead.");
          }
        } catch (e) { if (e.name === "AbortError") throw e; }
      }
      // L1 — plan first: the reasoner turns a short ask into a concrete spec the coder builds to
      if (r.plan && bestReasoner && !spec) {
        body = addMsg("assistant", "");
        body.innerHTML = planCard("", "active", bestReasoner);
        if (sid === currentId) showTab("code");
        const planText = await callModel(() => {}, abortCtl.signal,
          { model: bestReasoner, system: SPEC_SYSTEM, messages: [{ role: "user", content: text }] });
        spec = stripThink(planText).trim();
        buildSpec = spec;
        body.innerHTML = streamPrefix() + buildTasks(0, false, false);
        scrollDown();
      }
      // L?: the coder writes the app (to the spec if we have one)
      if (!body) body = addMsg("assistant", "");
      // For an edit, give the coder JUST the current app + the instruction (focused,
      // small context) and force a full-file rewrite — small models love to reply
      // with a snippet or an explanation otherwise.
      let sys, callMsgs;
      if (r.kind === "edit" && currentApp) {
        const lastApp = [...sessionMessages].reverse().find(m => m.role === "assistant" && extractApp(m.content));
        sys = BUILDER_SYSTEM + "\n\nThis is an EDIT to the app you built earlier (shown above). Output the COMPLETE updated HTML file in ONE ```html block — never a snippet, a diff, or only an explanation. Keep everything that already works; change only what is asked.";
        callMsgs = lastApp
          ? [{ role: "user", content: "Here is the current app:" }, { role: "assistant", content: lastApp.content }, { role: "user", content: text }]
          : undefined;
      } else {
        sys = spec ? (BUILDER_SYSTEM + "\n\nBuild to THIS spec — implement every point:\n" + spec) : BUILDER_SYSTEM;
      }
      const acc = await callModel(t => displayStreaming(body, t, sid), abortCtl.signal, { model: r.model, system: sys, messages: callMsgs });
      sessionMessages.push({ role: "assistant", content: acc });
      const app = extractApp(acc);
      if (app) {
        const prose = render(acc.replace(/```(?:html)?\s*[\s\S]*?```/gi, "").trim());
        let curLines = app.replace(/\s+$/, "").split("\n").length;
        sessionApp = injectDesign(app);
        if (sid !== currentId) {
          body.innerHTML = planPrefix() + prose + buildTasks(curLines, true, true);   // background: artifact exists
        } else {
          body.innerHTML = planPrefix() + prose + buildTasks(curLines, true, false);  // "Rendering the preview…"
          setApp(app);
          let errs = await previewSettled();                     // wait for the real render, collect any errors
          body.innerHTML = planPrefix() + prose + buildTasks(curLines, true, true);   // "Rendered"
          // L2 — self-repair: if it threw at runtime, fix it silently (up to 2 rounds)
          let st = null, attempt = 0;
          while (errs.length && attempt < 2 && sid === currentId) {
            attempt++;
            st = { status: "active", attempt }; repairHtml = repairSection(st);
            body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true);
            showTab("code"); scrollDown();
            const fixMsgs = sessionMessages.concat([{ role: "user", content: fixPrompt(errs) }]);
            const facc = await callModel(t => displayStreaming(body, t, sid), abortCtl.signal, { model: r.model, system: BUILDER_SYSTEM, messages: fixMsgs });
            const fapp = extractApp(facc);
            if (!fapp) { st = { status: "fail", attempt }; break; }
            sessionMessages[sessionMessages.length - 1] = { role: "assistant", content: facc };   // replace broken app w/ fixed
            curLines = fapp.replace(/\s+$/, "").split("\n").length;
            sessionApp = injectDesign(fapp);
            repairHtml = repairSection(st);
            body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, false);
            setApp(fapp);
            errs = await previewSettled();
          }
          if (st) {
            st = { status: errs.length ? "fail" : "done", attempt: st.attempt }; repairHtml = repairSection(st);
            body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true);
            scrollDown();
          }
          // build goal: score the build's REQUIREMENTS COVERAGE (strict, model-graded) and
          // ITERATE toward the target — feed the missing requirements back, rebuild, re-score.
          // A goal with no checkable requirements falls back to an honest "by inspection" log.
          if (goalActive && !r.cloneUrl) {
            try {
              let scored = false;
              if (goalMeta.scorer === "spec") {
                const TARGET = (goalMeta.metric && +goalMeta.metric.target) || 80, MAX_ROUNDS = 2;
                let sc = await scoreSpec(goalMeta, sessionApp);
                const first = sc ? sc.score : null;
                if (sc) { goalRounds.push({ round: 0, score: sc.score }); body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + specCard(sc); scrollDown(); }
                let round = 0;
                while (sc && sc.score < TARGET && sc.missing.length && round < MAX_ROUNDS && sid === currentId) {
                  round++;
                  repairHtml = taskList([{ status: "active", label: "Closing the gaps (round " + round + " of " + MAX_ROUNDS + ")", meta: "target " + TARGET + "%" }]);
                  body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + specCard(sc, first);
                  showTab("code"); scrollDown();
                  const facc = await callModel(t => displayStreaming(body, t, sid), abortCtl.signal,
                    { model: r.model, system: BUILDER_SYSTEM + "\n\nThis improves a build you wrote earlier (shown above). Output the COMPLETE updated HTML file.",
                      messages: sessionMessages.concat([{ role: "user", content: improveSpecPrompt(sc) }]) });
                  const fapp = extractApp(facc);
                  if (!fapp) break;
                  sessionMessages[sessionMessages.length - 1] = { role: "assistant", content: facc };
                  curLines = fapp.replace(/\s+$/, "").split("\n").length;
                  sessionApp = injectDesign(fapp); setApp(fapp); await previewSettled();
                  const nsc = await scoreSpec(goalMeta, sessionApp);
                  if (!nsc) break;
                  const improved = nsc.score > sc.score;
                  repairHtml = taskList([{ status: improved ? "done" : "fail", label: "Closed gaps (round " + round + ")", meta: sc.score + "% → " + nsc.score + "%" }]);
                  sc = nsc; goalRounds.push({ round, score: nsc.score });
                  body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + specCard(sc, first);
                  scrollDown();
                  if (!improved) break;
                }
                if (sc) {
                  scored = true;
                  const reached = sc.score >= TARGET;
                  const runN = await logGoalRun({ kind: "build", capability: goalMeta.capability, metric: goalMeta.metric, scorer: "spec", target: TARGET, autoScored: true, initial_score: first, final_score: sc.score, rounds: goalRounds, reached: reached, missing: sc.missing });
                  body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + specCard(sc, first) + goalVerdictCard(goalMeta, reached, sc.score, runN);
                  scrollDown();
                }
              }
              if (!scored) {   // no checkable requirements (or grading failed) -> honest by-inspection log
                const runN = await logGoalRun({ kind: "build", capability: goalMeta.capability, metric: goalMeta.metric, autoScored: false, reached: null, evals: goalMeta.evals });
                body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + goalVerdictCard(goalMeta, false, null, runN);
                scrollDown();
              }
            } catch (e) { if (e.name === "AbortError") throw e; }
          }
          // clone: score the rebuild, then ITERATE toward a fidelity target — feed the
          // gaps back to the coder, rebuild, re-score; stop on target, no-gain, or cap.
          if (r.cloneUrl) {
            try {
              const TARGET = goalActive && goalTarget ? goalTarget : 75, MAX_ROUNDS = goalActive ? 3 : 2;
              let sc = await scoreClone(r.cloneUrl, sessionApp);
              const first = sc ? sc.score : null;
              if (goalActive && sc) goalRounds.push({ round: 0, score: sc.score });
              if (sc) { body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + fidelityCard(sc); scrollDown(); }
              let round = 0;
              while (sc && sc.score < TARGET && round < MAX_ROUNDS && sid === currentId) {
                round++;
                repairHtml = taskList([{ status: "active", label: "Refining the clone (round " + round + " of " + MAX_ROUNDS + ")", meta: "target " + TARGET + "%" }]);
                body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + fidelityCard(sc, first);
                showTab("code"); scrollDown();
                const facc = await callModel(t => displayStreaming(body, t, sid), abortCtl.signal,
                  { model: r.model, system: BUILDER_SYSTEM + "\n\nThis is a fidelity FIX of a clone you built earlier (shown above). Output the COMPLETE updated HTML file.",
                    messages: sessionMessages.concat([{ role: "user", content: improvePrompt(sc) }]) });
                const fapp = extractApp(facc);
                if (!fapp) break;
                sessionMessages[sessionMessages.length - 1] = { role: "assistant", content: facc };   // canonical app = refined
                curLines = fapp.replace(/\s+$/, "").split("\n").length;
                sessionApp = injectDesign(fapp);
                setApp(fapp);
                await previewSettled();
                const nsc = await scoreClone(r.cloneUrl, sessionApp);
                if (!nsc) break;
                const improved = nsc.score > sc.score;
                repairHtml = taskList([{ status: improved ? "done" : "fail", label: "Refined the clone (round " + round + ")", meta: sc.score + "% → " + nsc.score + "%" }]);
                sc = nsc;
                if (goalActive) goalRounds.push({ round, score: nsc.score });
                body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + fidelityCard(sc, first);
                scrollDown();
                if (!improved) break;   // a round that didn't help -> stop
              }
              if (sc) { body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + fidelityCard(sc, first); scrollDown(); }
              if (goalActive && sc) {
                const reached = sc.score >= TARGET;
                const runN = await logGoalRun({ kind: "clone", url: r.cloneUrl, capability: goalMeta.capability, metric: goalMeta.metric, target: TARGET, autoScored: true, initial_score: first, final_score: sc.score, rounds: goalRounds, reached: reached, ceiling: reached ? null : sc.score, lever: reached ? null : "vision model" });
                body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + fidelityCard(sc, first) + goalVerdictCard(goalMeta, reached, sc.score, runN);
                scrollDown();
              }
            } catch (e) { if (e.name === "AbortError") throw e; }
          }
        }
      } else {
        body.innerHTML = streamPrefix() + render(acc);              // answered without an app
      }
    }
  } catch (e) {
    if (e.name === "AbortError") { if (body) body.innerHTML = '<div class="codecard">Stopped.</div>'; else addMsg("assistant", "Stopped."); }
    else { if (body) body.innerHTML = '<div class="codecard">Error: ' + escapeHtml(e.message) + '</div>'; else addMsg("assistant", "Error: " + e.message); }
  } finally {
    abortCtl = null; setBusy(false); buildSpec = ""; repairHtml = "";
    buildingIds.delete(sid);
    persistSession(sid, sessionMessages, sessionApp, sid === currentId ? captureTranscript() : null);
    if (sid === currentId) input.focus();
  }
}
sendBtn.addEventListener("click", () => busy ? stopGen() : send());
input.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } });
input.addEventListener("input", () => { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; });
document.querySelectorAll(".empty .ex span").forEach(s => s.addEventListener("click", () => { input.value = s.dataset.ex; send(); }));

/* ---------- Capabilities modal: hardware-aware "what can I run + what am I missing" ---------- */
function capBadge(s){ return s==="active"?"✅":s==="available"?"🟢":s==="locked"?"🔒":"🛠"; }
function capRowHtml(r){ return '<div class="caprow'+(r.status==="locked"?" locked":"")+'"><span class="st">'+capBadge(r.status)+'</span><div class="cn"><b>'+r.name+'</b>'+(r.sub?'<div class="sub">'+r.sub+'</div>':'')+(r.act?'<div class="act">'+r.act+'</div>':'')+(r.unlock?'<div class="sub">→ '+r.unlock+'</div>':'')+'</div></div>'; }
let _capPoll = null;
async function renderCaps(){
  let sys = {};
  try { sys = await (await fetch(AGENT_URL + "/api/agent/system")).json(); } catch(e){}
  const detected = !!(sys && sys.ok && sys.effective_gb);
  const eff = sys.effective_gb || 0;
  // re-read the LIVE model list each tick, so pulling a model (e.g. the vision one) shows up at once
  let inst = models;
  try { const ns = ((await (await fetch(API + "/api/tags")).json()).models || []).map(m => m.name); if (ns.length) inst = ns.map(n => ({ name: n, params: parseParams(n), role: parseRole(n) })); } catch(e){}
  const hasTier = n => inst.some(m => (m.role==="coder"||m.role==="reasoner") && Math.round(m.params)===n);
  const hasVision = inst.some(m => /vl|llava|vision|moondream|bakllava|minicpm-?v/i.test(m.name));
  const tiers = [
    { n:7,  need:7,  gb:"~8 GB",  label:"7B coder + reasoner",  unlock:"genuinely useful local coding" },
    { n:14, need:14, gb:"~16 GB", label:"14B coder + reasoner", unlock:"the builder + cloning we recommend", star:true },
    { n:32, need:22, gb:"~24 GB", label:"32B coder + reasoner", unlock:"sharper output with the headroom" },
    { n:70, need:44, gb:"~48 GB", label:"70B coder + reasoner", unlock:"top tier — needs a big machine" },
  ];
  const modelRows = tiers.map(t => {
    const installed = hasTier(t.n), can = detected ? eff >= t.need : true;   // undetected -> never a false lock
    return { status: installed?"active":(detected ? (can?"available":"locked") : "available"), name: t.label+(t.star?" ⭐":""),
      sub: "needs "+t.gb+(detected && !can ? " — your "+eff+" GB can't hold it" : ""),
      act: (!installed && can) ? "the installer auto-picks the right tier for your machine" : "", unlock: t.unlock };
  });
  const visCan = !detected || eff >= 7;
  modelRows.push({ status: hasVision?"active":(visCan?"available":"locked"), name:"Vision model (qwen2.5vl:7B)",
    sub:"needs ~6 GB (~24 GB to run alongside the coder)", unlock:"lets the builder SEE the page → visual clone fidelity",
    act:(visCan&&!hasVision)?'available now — <code>ollama pull qwen2.5vl:7b</code> to unlock it':'' });
  const a = (typeof agentReady !== "undefined") && agentReady;
  const caps = [
    { status:"active", name:"Build single-page apps", sub:"live preview, any model" },
    { status:a?"active":"available", name:"Website cloning", sub: a?(sys.render?"render-based (Playwright) — full fidelity":"basic path — re-run --agent for render fidelity"):"needs the --agent server" },
    { status:a?"active":"available", name:"Clone-fidelity score + iterate-to-target", sub:a?"active":"needs --agent" },
    { status:a?"active":"available", name:"🎯 Goal mode (forge → agree → pursue → learn)", sub:a?"active":"needs --agent" },
    { status:a?"active":"available", name:"Agent tools (run · write · fetch · gitsync)", sub:a?"active":"needs --agent" },
    { status:"coming", name:"Vision-critique clone loop", sub:"in progress — will use the vision model above" },
    { status:"coming", name:"Multi-file projects", sub:"on the roadmap" },
    { status:"coming", name:"Web search · image generation", sub:"on the roadmap" },
    { status:"coming", name:"Backend / database · one-click deploy", sub:"on the roadmap" },
  ];
  const sysLine = detected
    ? "🖥️ " + (sys.os==="Darwin"?"macOS":sys.os) + " · " + (sys.gpu||"CPU only") + " · " + (sys.ram_gb||"?") + " GB RAM"
      + (sys.vram_gb && sys.gpu && !/unified/i.test(sys.gpu) ? " · " + sys.vram_gb + " GB VRAM" : "")
      + " → up to the <b>" + (sys.tier||"?").toUpperCase() + "</b> tier"
    : "🖥️ Reading your machine… if this stays, your <code>--agent</code> server is an older version — re-run <code>./local-llm-setup.sh --agent</code> to refresh it. (Showing what's installed below.)";
  capBody.innerHTML = '<div class="sysline">'+sysLine+'</div>'
    + '<div class="caph">Models — what your machine can run</div>' + modelRows.map(capRowHtml).join("")
    + '<div class="caph">Capabilities</div>' + caps.map(capRowHtml).join("")
    + '<div class="caplegend">✅ active &nbsp;·&nbsp; 🟢 available — your machine can run it, just not installed &nbsp;·&nbsp; 🔒 needs more memory &nbsp;·&nbsp; 🛠 coming soon</div>';
}
function openCapabilities(){
  capModal.hidden = false;
  capBody.innerHTML = '<div class="sysline">Detecting your system…</div>';
  renderCaps();
  if (_capPoll) clearInterval(_capPoll);
  _capPoll = setInterval(renderCaps, 3000);   // live: reflects the server coming up or a model being pulled
}
function closeCaps(){ capModal.hidden = true; if (_capPoll) { clearInterval(_capPoll); _capPoll = null; } }
capBtn.addEventListener("click", openCapabilities);
capClose.addEventListener("click", closeCaps);
capModal.addEventListener("click", e => { if (e.target === capModal) closeCaps(); });
document.addEventListener("keydown", e => { if (e.key === "Escape" && !capModal.hidden) closeCaps(); });
loadModels(); detectAgent(); renderList(); input.focus();
</script>
</body>
</html>
CHATHTML
}

# Write the bundled agent tool-server (Python) to $1. Embedded so the script
# stays self-contained; its safety model is documented in the file's header.
write_agent_server() {
  cat > "$1" <<'AGENTPY'
#!/usr/bin/env python3
# Local LLM Builder — agent server.
#
# Serves the builder page AND exposes a small, sandboxed tool API to it:
#   GET  /api/agent/ping              -> {ok:true}
#   POST /api/agent/run   {cmd}       -> run a shell command IN the workspace dir   (mutating -> approved in UI)
#   POST /api/agent/write {path,content} -> write a file UNDER the workspace dir    (mutating -> approved in UI)
#   POST /api/agent/read  {path}      -> read a file UNDER the workspace dir          (read-only)
#   POST /api/agent/fetch {url}       -> fetch a public web page (raw HTML, capped)   (read-only, network)
#   POST /api/agent/inspect {url|html}-> structured digest: title, sections, headings,
#                                        links, images, palette, fonts; when a headless
#                                        browser is present it RENDERS the page (JS sites
#                                        read), adding computed tokens, motion, framework,
#                                        hover states + responsive breakpoints   (read-only)
#   POST /api/agent/extract {url}     -> design tokens: palette, fonts, type scale, radii,
#                                        shadows, spacing + motion + framework      (read-only, network)
#   POST /api/agent/score {a,b}       -> design-fidelity score between two pages       (read-only)
#                                        (each of a/b is {url} or {html}) — palette/font/
#                                        section/heading/motion/token overlap -> 0-100 + deltas.
#                                        NB: structural, not pixel — local models aren't vision.
#   POST /api/agent/screenshot {url|html} -> render in a headless browser -> PNG       (read-only)
#                                        Playwright (managed Chromium) first, then a
#                                        system/managed Chrome subprocess; full-page +
#                                        element (selector) capture on the Playwright path.
#   POST /api/agent/gitsync {path,message,remote?} -> turn a generated project into a   (mutating -> approved)
#                                        real local git repo: git init + sensible
#                                        .gitignore + stage + commit, and export a .zip
#                                        that INCLUDES the .git history. An optional
#                                        remote is only *configured*, never pushed —
#                                        pushing uses the user's own GitHub token.
#   POST /api/agent/goallog {run}     -> append one pursued-goal record to the           (local-file write)
#                                        learning/limits log (~/.local-llm-setup/goal_runs.jsonl);
#                                        GET /api/agent/goalruns reads it back. This is the
#                                        Goal-Mode loop persisted: what it reached vs. the ceiling.
#
# These read/inspect/extract/score tools are what let the builder CLONE a real site:
# observe the page, rebuild it, then SCORE how close the rebuild is.
#
# Safety posture:
#   - binds 127.0.0.1 only; CORS + Origin check (only this page's origin may drive tools)
#   - file read/write confined to the workspace (path-escape rejected)
#   - shell commands run with cwd = workspace, 30s timeout
#   - network fetch/screenshot are SSRF-guarded: http/https only, public hosts only
#     (loopback / private / link-local / reserved rejected, incl. on redirect), 15s/2MB
#   - the page approves every MUTATING tool (run / write); read-only tools run directly
#
# An approved command itself is not sandboxed (an approved `rm -rf ~` still runs) —
# UI approval is the guardrail for mutations. Harden before any default ship.

import json, os, re, socket, ipaddress, subprocess, base64, shutil, tempfile, struct, glob, sys, time, platform, urllib.request
from collections import Counter
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT = "127.0.0.1", int(os.environ.get("LLM_AGENT_PORT", "8765"))
HOME = os.path.expanduser("~")
CHAT_DIR  = os.path.join(HOME, ".local-llm-setup", "chat")
WORKSPACE = os.path.realpath(os.path.join(HOME, ".local-llm-setup", "workspace"))
os.makedirs(WORKSPACE, exist_ok=True)
ORIGINS = {f"http://localhost:{PORT}", f"http://127.0.0.1:{PORT}"}
GOAL_LOG = os.path.join(HOME, ".local-llm-setup", "goal_runs.jsonl")   # learning/limits log: one JSON line per pursued goal

UA = "Mozilla/5.0 (LocalLLMBuilder; +http://localhost) AppleWebKit/537.36"
FETCH_CAP = 2_000_000
FETCH_TIMEOUT = 15

def safe_path(rel):
    p = os.path.realpath(os.path.join(WORKSPACE, rel))
    if p != WORKSPACE and not p.startswith(WORKSPACE + os.sep):
        raise ValueError("path escapes the workspace")
    return p

# ---------- network: SSRF-guarded fetch ----------
def _assert_public(host):
    if not host:
        raise ValueError("no host")
    for info in socket.getaddrinfo(host, None):
        ip = ipaddress.ip_address(info[4][0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved
                or ip.is_multicast or ip.is_unspecified):
            raise ValueError(f"blocked non-public address ({ip}) for host {host!r}")

class _GuardedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        p = urlsplit(newurl)
        if p.scheme not in ("http", "https"):
            return None
        _assert_public(p.hostname)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

_OPENER = urllib.request.build_opener(_GuardedRedirect)

def fetch(url):
    p = urlsplit(url)
    if p.scheme not in ("http", "https"):
        raise ValueError("only http/https URLs are allowed")
    _assert_public(p.hostname)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,*/*"})
    with _OPENER.open(req, timeout=FETCH_TIMEOUT) as r:
        raw = r.read(FETCH_CAP + 1)
        final, status = r.geturl(), getattr(r, "status", 200)
    return {"final_url": final, "status": status,
            "html": raw[:FETCH_CAP].decode("utf-8", "replace"), "truncated": len(raw) > FETCH_CAP}

# ---------- html digest (stdlib only) ----------
_COLOR_RE = re.compile(r'#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)')
_FONT_RE  = re.compile(r'font-family\s*:\s*([^;}{]+)', re.I)

class _Digest(HTMLParser):
    def __init__(self, base):
        super().__init__(convert_charrefs=True)
        self.base = base
        self.title = ""; self.desc = ""
        self.headings = []; self.links = []; self.images = []
        self.sections = []; self.styles = []; self.font_links = []; self.css_links = []
        self._in_title = False; self._in_style = False
        self._h = None; self._htext = []
        self._abuf = None; self._ahref = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "title": self._in_title = True
        elif tag == "meta" and a.get("name", "").lower() == "description": self.desc = a.get("content", "")
        elif tag == "meta" and a.get("property", "").lower() == "og:description" and not self.desc: self.desc = a.get("content", "")
        elif tag in ("h1", "h2", "h3"): self._h = tag; self._htext = []
        elif tag == "a" and a.get("href"): self._ahref = urljoin(self.base, a["href"]); self._abuf = []
        elif tag == "img" and a.get("src"): self.images.append({"src": urljoin(self.base, a["src"]), "alt": (a.get("alt") or "")[:80]})
        elif tag == "style": self._in_style = True
        elif tag == "link" and "stylesheet" in (a.get("rel", "") or "").lower():
            href = a.get("href", "")
            if "fonts.googleapis" in href: self.font_links.append(href)
            elif href: self.css_links.append(urljoin(self.base, href))
        if tag in ("section", "header", "footer", "nav", "main", "article", "aside") or a.get("id"):
            self.sections.append({"tag": tag, "id": (a.get("id") or "")[:40], "class": (a.get("class") or "")[:80]})
        if a.get("style"): self.styles.append(a["style"])

    def handle_endtag(self, tag):
        if tag == "title": self._in_title = False
        elif tag in ("h1", "h2", "h3") and self._h == tag:
            t = "".join(self._htext).strip()
            if t: self.headings.append({"level": tag, "text": t[:140]})
            self._h = None
        elif tag == "a" and self._ahref is not None:
            self.links.append({"href": self._ahref, "text": "".join(self._abuf).strip()[:60]})
            self._ahref = None; self._abuf = None
        elif tag == "style": self._in_style = False

    def handle_data(self, data):
        if self._in_title: self.title += data
        if self._h is not None: self._htext.append(data)
        if self._abuf is not None: self._abuf.append(data)
        if self._in_style: self.styles.append(data)

def _norm_color(c):
    c = c.lower().strip()
    m = re.fullmatch(r'#([0-9a-f]{8})', c)        # #rrggbbaa -> #rrggbb (collapse alpha variants)
    if m: return "#" + m.group(1)[:6]
    m = re.fullmatch(r'#([0-9a-f]{4})', c)        # #rgba -> #rgb
    if m: return "#" + m.group(1)[:3]
    return c

def _palette(style_text):
    return [c for c, _ in Counter(_norm_color(m) for m in _COLOR_RE.findall(style_text)).most_common(16)]

# A font-family VALUE -> the first real font name. Resolves CSS vars: keeps a var's
# inline fallback (var(--x, Inter, sans-serif) -> Inter), drops bare vars (var(--x)).
def _clean_font(decl):
    decl = re.sub(r'var\(\s*--[^,()]*,\s*([^()]*)\)', r'\1', decl)   # var with fallback -> fallback list
    decl = re.sub(r'var\([^()]*\)', '', decl)                         # bare var -> drop
    for tok in decl.split(","):
        tok = tok.strip().strip('"\'')
        if tok and not tok.lower().startswith("var("):
            return tok[:60]
    return ""

# Keep the font list REAL: drop pure numbers / lengths (from --font-size-* vars), icon fonts
# (webflow-icons, fontawesome…) and "fallback" faces, and strip variable-font axis tokens so a
# name is actually loadable ("Geist Variablefont Wght" -> "Geist"). Fixes the clone fonts-0%.
_FONT_JUNK_RE = re.compile(r'^[\d.\s]+(px|em|rem|pt|%|vh|vw)?$|^(unset|inherit|initial|none|normal|auto|currentcolor)$|icon|webflow|glyph|fontawesome|material', re.I)
def _clean_font_name(name):
    name = re.sub(r'\b(variable\s*font|wght|opsz|slnt|ital|regular)\b', '', name or '', flags=re.I)
    return re.sub(r'\s+', ' ', name).strip()
def _is_real_font(name):
    name = (name or "").strip().strip('"\'')
    return bool(name) and len(name) <= 60 and "fallback" not in name.lower() and not _FONT_JUNK_RE.search(name)

def _fonts(style_text, font_links):
    out = []
    def add(name):
        if not _is_real_font(name): return
        name = _clean_font_name((name or "").strip().strip('"\'')[:60])
        if name and name.lower() not in (x.lower() for x in out): out.append(name)
    for m in re.findall(r'@font-face[^{}]*\{[^{}]*?font-family\s*:\s*([^;}{]+)', style_text, re.I): add(_clean_font(m))  # loaded fonts
    for m in re.findall(r'--[\w-]*font[\w-]*\s*:\s*([^;}{]+)', style_text, re.I): add(_clean_font(m))                    # --font-* tokens
    for decl in _FONT_RE.findall(style_text): add(_clean_font(decl))                                                    # font-family decls
    for href in font_links:
        for fam in re.findall(r'family=([^&:]+)', href): add(fam.replace("+", " "))
    return out[:8]

def _build_digest(d, base, extra_css=""):
    style_text = "\n".join(d.styles) + ("\n" + extra_css if extra_css else "")
    return {
        "url": base,
        "title": d.title.strip()[:200], "description": (d.desc or "")[:300],
        "headings": d.headings[:30], "sections": d.sections[:30],
        "nav_links": d.links[:30], "images": d.images[:24],
        "palette": _palette(style_text), "fonts": _fonts(style_text, d.font_links),
        "counts": {"links": len(d.links), "images": len(d.images), "sections": len(d.sections)},
    }

# Fetch a few linked stylesheets so palette/fonts come from the REAL CSS — most modern
# sites keep their colours/fonts in external .css files, not inline. SSRF-guarded + capped.
def _fetch_stylesheets(links, max_sheets=4, cap=600_000):
    css, seen = [], set()
    for href in links:
        if len(css) >= max_sheets: break
        if href in seen: continue
        seen.add(href)
        try:
            p = urlsplit(href)
            if p.scheme not in ("http", "https"): continue
            _assert_public(p.hostname)
            req = urllib.request.Request(href, headers={"User-Agent": UA, "Accept": "text/css,*/*"})
            with _OPENER.open(req, timeout=8) as r:
                css.append(r.read(cap).decode("utf-8", "replace"))
        except Exception:
            continue
    return "\n".join(css), len(css)

# ============================================================================
# Render-based inspection (the depth unlock). The stdlib fetch() above only sees
# RAW HTML — useless on a JS-rendered site (an empty <div id=root> shell). When
# Playwright is present we drive a real headless browser instead: load the page,
# wait for the network to settle, then read the RENDERED DOM + the *computed*
# styles, the motion language (@keyframes / animations / transitions), hover/focus
# interaction states, responsive breakpoints, and a framework guess. digest()
# prefers this path and falls back to the raw fetch when the browser is missing.
# ============================================================================

# One self-contained snippet evaluated IN the page. Walks the rendered DOM (capped),
# aggregates the design tokens that actually paint, and mines the live stylesheets
# for motion. Pure browser JS — also runnable on set_content() HTML for offline tests.
_BROWSER_EXTRACT_JS = r"""() => {
  const MAX = 4000;
  const els = Array.from(document.querySelectorAll('*')).slice(0, MAX);
  const C={}, BG={}, F={}, SZ={}, RAD={}, SH={}, SP={};
  const bump=(m,k)=>{ if(k==null) return; k=(''+k).trim();
    if(!k||k==='none'||k==='normal'||k==='0px'||k==='auto'||k==='rgba(0, 0, 0, 0)') return; m[k]=(m[k]||0)+1; };
  const vis=(e,s)=>{ const r=e.getBoundingClientRect();
    return r.width>1 && r.height>1 && s.visibility!=='hidden' && s.display!=='none' && parseFloat(s.opacity||'1')>0.05; };
  const anim=new Set(), trans=new Set();
  let visible=0;
  for (const e of els){
    let s; try{ s=getComputedStyle(e); }catch(_){ continue; }
    if(!vis(e,s)) continue;
    visible++;
    bump(C, s.color); bump(BG, s.backgroundColor);
    if(s.backgroundImage && s.backgroundImage!=='none') bump(BG, s.backgroundImage.slice(0,140));
    bump(F, (s.fontFamily||'').split(',')[0].replace(/["']/g,'').trim());
    bump(SZ, s.fontSize); bump(RAD, s.borderRadius);
    if(s.boxShadow && s.boxShadow!=='none') bump(SH, s.boxShadow.slice(0,140));
    bump(SP, s.paddingTop); bump(SP, s.marginBottom);
    if(s.animationName && s.animationName!=='none') anim.add((s.animationName+' '+(s.animationDuration||'')).trim());
    if(s.transitionDuration && s.transitionDuration!=='0s') trans.add(((s.transitionProperty||'all')+' '+s.transitionDuration).trim());
  }
  const top=(m,n)=>Object.entries(m).sort((a,b)=>b[1]-a[1]).slice(0,n).map(x=>x[0]);
  // motion: @keyframes names from every reachable (same-origin) stylesheet
  const keyframes=new Set();
  for(const ss of Array.from(document.styleSheets)){
    let rules; try{ rules=ss.cssRules; }catch(_){ continue; }   // cross-origin sheet -> skip
    if(!rules) continue;
    for(const r of Array.from(rules)){
      try{
        if(r.type===7 || (r.name!=null && /@keyframes/i.test(r.cssText||''))) keyframes.add(r.name);
        else if(r.style){
          if(r.style.animationName && r.style.animationName!=='none') anim.add((r.style.animationName+' '+(r.style.animationDuration||'')).trim());
          const tp=r.style.transitionProperty;
          if(tp && tp!=='none' && tp!=='all') trans.add((tp+' '+(r.style.transitionDuration||'')).trim());
        }
      }catch(_){}
    }
  }
  // framework guess from class soup + well-known roots
  const cls=(document.body?document.body.className+' ':'')+
    Array.from(document.querySelectorAll('[class]')).slice(0,500).map(e=>(''+e.className)).join(' ');
  const fw=[];
  if(/\b(?:flex|grid|p[xy]?-\d|m[xy]?-\d|gap-\d|text-(?:xs|sm|base|lg|\dxl)|bg-\w+-\d{2,3}|rounded(?:-\w+)?)\b/.test(cls)) fw.push('tailwind');
  if(/\b(?:container|row|col-(?:xs|sm|md|lg|\d)|navbar|btn-(?:primary|secondary|outline))\b/.test(cls)) fw.push('bootstrap');
  if(window.__NEXT_DATA__||document.querySelector('#__next')) fw.push('next.js');
  if(document.querySelector('#root,[data-reactroot]')) fw.push('react');
  if(document.querySelector('[data-v-app],[data-server-rendered]')) fw.push('vue');
  if(document.querySelector('[x-data],[wire\\:id]')) fw.push('alpine/livewire');
  return {
    visible_elements: visible,
    colors: top(C,12), backgrounds: top(BG,10), fonts: top(F,8),
    font_sizes: top(SZ,8), radii: top(RAD,6), shadows: top(SH,6), spacing: top(SP,8),
    motion: { keyframes: Array.from(keyframes).filter(Boolean).slice(0,24),
              animations: Array.from(anim).filter(Boolean).slice(0,24),
              transitions: Array.from(trans).filter(Boolean).slice(0,24) },
    framework: Array.from(new Set(fw)),
  };
}"""

# Phase 2 — interaction states: hover/focus the top interactive elements and diff
# the computed style, so the clone can reproduce :hover/:focus affordances.
def _interaction_states(page, max_els=6):
    out = []
    try:
        handles = page.query_selector_all("a, button, [role=button], input[type=submit], .btn")
    except Exception:
        return out
    probe = ("e=>{const s=getComputedStyle(e);return {bg:s.backgroundColor,color:s.color,"
             "transform:s.transform,boxShadow:s.boxShadow,opacity:s.opacity,textDecorationLine:s.textDecorationLine};}")
    for h in handles[:max_els]:
        try:
            before = h.evaluate(probe)
            h.hover(timeout=1000)
            page.wait_for_timeout(140)
            after = h.evaluate(probe)
            delta = {k: [before.get(k), after.get(k)] for k in after if before.get(k) != after.get(k)}
            if delta:
                label = h.evaluate("e=>((e.innerText||e.value||e.tagName)+'').trim().slice(0,40)")
                out.append({"el": label, "hover_changes": delta})
        except Exception:
            continue
    return out

# Phase 2 — responsive: re-flow at a few widths and capture the layout signal
# (does the nav collapse? does a hamburger appear? does the page overflow?).
def _responsive(page, widths=(390, 768, 1280)):
    out = {}
    sig_js = ("()=>({scrollW:document.documentElement.scrollWidth,"
              "nav_links:document.querySelectorAll('nav a, header a').length,"
              "hamburger:!!document.querySelector('[class*=hamburger i],[class*=menu-toggle i],"
              "[aria-label*=menu i],button[class*=menu i]'),"
              "body_dir:document.body?getComputedStyle(document.body).flexDirection:''})")
    for w in widths:
        try:
            page.set_viewport_size({"width": w, "height": 900})
            page.wait_for_timeout(160)
            out[str(w)] = page.evaluate(sig_js)
        except Exception:
            continue
    return out

# Run the extraction against an already-loaded page. `deep` adds the hover +
# responsive passes (they mutate the page, so they run last).
def _extract_with_page(page, deep=True):
    data = page.evaluate(_BROWSER_EXTRACT_JS)
    html = page.content()
    if deep:
        try: data["states"] = _interaction_states(page)
        except Exception: data["states"] = []
        try: data["responsive"] = _responsive(page)
        except Exception: data["responsive"] = {}
    return html, data

def _render_inspect(url, deep=True, timeout_ms=20000):
    """Load `url` in headless Chromium and return (final_url, rendered_html, data).
    SSRF-guarded exactly like fetch(). Raises if Playwright isn't importable."""
    from playwright.sync_api import sync_playwright
    p2 = urlsplit(url)
    if p2.scheme not in ("http", "https"): raise ValueError("only http/https URLs are allowed")
    _assert_public(p2.hostname)
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--no-sandbox"])
        try:
            page = browser.new_page(viewport={"width": 1280, "height": 900}, user_agent=UA)
            try: page.goto(url, wait_until="networkidle", timeout=timeout_ms)
            except Exception: page.goto(url, wait_until="load", timeout=timeout_ms)
            final = page.url
            html, data = _extract_with_page(page, deep=deep)
            return final, html, data
        finally:
            browser.close()

def _inspect_html_via_browser(html, deep=False):
    """Render an HTML STRING in the browser (no network) and extract from it.
    Used for inline {html} targets and for the offline test suite."""
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--no-sandbox"])
        try:
            page = browser.new_page(viewport={"width": 1280, "height": 900})
            page.set_content(html, wait_until="networkidle")
            return _extract_with_page(page, deep=deep)
        finally:
            browser.close()

# Fold the browser-extracted tokens/motion onto a stdlib digest. Computed colours
# and fonts are authoritative (they actually painted), so they lead the palette.
def _merge_rendered(out, data):
    comp = []
    for c in (data.get("colors") or []) + (data.get("backgrounds") or []):
        c = (c or "").strip()
        if c.startswith(("rgb", "#", "hsl")):
            comp.append(_norm_color(c))
    if comp:
        seen = []
        for c in comp:
            if c and c not in seen: seen.append(c)
        out["palette"] = (seen + [c for c in out.get("palette", []) if c not in seen])[:16]
    ff = []
    for f in (data.get("fonts") or []):
        if _is_real_font(f):
            cf = _clean_font_name(f)
            if cf and cf.lower() not in (x.lower() for x in ff): ff.append(cf)
    if ff:
        out["fonts"] = (ff + [f for f in out.get("fonts", []) if f.lower() not in (x.lower() for x in ff)])[:8]
    out["tokens"] = {"font_sizes": data.get("font_sizes", []), "radii": data.get("radii", []),
                     "shadows": data.get("shadows", []), "spacing": data.get("spacing", []),
                     "backgrounds": data.get("backgrounds", [])}
    # surface REAL background-image URLs (heroes / section bgs) the page actually paints,
    # so a clone can reuse them instead of placeholders. Computed styles are absolute.
    bgimgs = []
    for s in (data.get("backgrounds") or []):
        for m in re.findall(r'url\(\s*["\']?(https?://[^"\')\s]+)', s or ""):
            if m not in bgimgs: bgimgs.append(m)
    out["bg_images"] = bgimgs[:8]
    out["motion"] = data.get("motion", {}) or {}
    out["framework"] = data.get("framework", [])
    out["states"] = data.get("states", [])
    out["responsive"] = data.get("responsive", {})
    out["visible_elements"] = data.get("visible_elements", 0)

def _digest_html(html, base=""):
    d = _Digest(base)
    try: d.feed(html)
    except Exception: pass
    out = _build_digest(d, base)
    out["rendered"] = False
    if _have_playwright():
        try:
            _rhtml, data = _inspect_html_via_browser(html, deep=False)
            _merge_rendered(out, data)
            out["rendered"] = True
        except Exception:
            pass
    return out

def digest(url):
    # Preferred path: a real headless render, so JS-built sites actually read.
    if _have_playwright():
        try:
            final, html, data = _render_inspect(url, deep=True)
            d = _Digest(final)
            try: d.feed(html)
            except Exception: pass
            ext_css, n = _fetch_stylesheets(d.css_links)
            out = _build_digest(d, final, ext_css)
            _merge_rendered(out, data)
            out.update({"status": 200, "truncated": False, "stylesheets_parsed": n, "rendered": True})
            return out
        except Exception:
            pass   # browser missing / nav failed / blocked -> fall back to raw fetch
    # Fallback: stdlib fetch of raw HTML (no JS) — better than nothing.
    f = fetch(url)
    d = _Digest(f["final_url"])
    try: d.feed(f["html"])
    except Exception: pass
    ext_css, n = _fetch_stylesheets(d.css_links)
    out = _build_digest(d, f["final_url"], ext_css)
    out.update({"status": f["status"], "truncated": f["truncated"], "stylesheets_parsed": n, "rendered": False})
    return out

def target_digest(obj):
    if not obj: raise ValueError("missing target (need {url} or {html})")
    if obj.get("html") is not None: return _digest_html(obj["html"], obj.get("base", ""))
    return digest((obj.get("url") or "").strip())

# ---------- fidelity score (structural; not pixels — local models aren't vision) ----------
def _norm(xs): return set(x.lower().strip() for x in xs if x and x.strip())

# Motion fingerprint of a digest: keyframe names + the animation NAMES in use
# (the first token of each "name duration" entry), lower-cased.
def _motion_set(x):
    m = x.get("motion", {}) or {}
    names = set(m.get("keyframes", []) or [])
    names |= set((a.split() or [""])[0] for a in (m.get("animations", []) or []))
    return _norm(names)

# Token fingerprint: the discrete design tokens that should match across a clone —
# corner radii, shadows and the type scale.
def _token_set(x):
    t = x.get("tokens", {}) or {}
    return _norm((t.get("radii") or []) + (t.get("shadows") or []) + (t.get("font_sizes") or []))

def fidelity(a, b):
    # Grade against the DOMINANT palette/fonts (what defines the look + what the focused clone
    # spec feeds the model), not every minor overlay colour — matching the 16th subtle rgba
    # doesn't move fidelity, and demanding it just punishes a richer (rendered) inspection.
    pa, pb = _norm((a["palette"] or [])[:8]), _norm(b["palette"])
    fa, fb = _norm((a["fonts"] or [])[:4]), _norm(b["fonts"])
    ha, hb = _norm(h["text"] for h in a["headings"]), _norm(h["text"] for h in b["headings"])
    ma, mb = _motion_set(a), _motion_set(b)
    ta, tb = _token_set(a), _token_set(b)
    pal = len(pa & pb) / len(pa) if pa else (1.0 if not pb else 0.0)
    fon = len(fa & fb) / len(fa) if fa else 1.0
    secA, secB = len(a["sections"]), len(b["sections"])
    sec = min(secB, secA) / secA if secA else 1.0
    head = len(ha & hb) / len(ha) if ha else 1.0
    # motion / tokens only count when the original HAS them; otherwise neutral (1.0)
    # so a token-less or browser-less digest scores exactly as before.
    mot = len(ma & mb) / len(ma) if ma else 1.0
    tok = len(ta & tb) / len(ta) if ta else 1.0
    score = round(100 * (0.28 * pal + 0.18 * fon + 0.16 * sec + 0.14 * head + 0.14 * mot + 0.10 * tok))
    return {
        "score": score,
        "palette_match": round(pal * 100), "font_match": round(fon * 100),
        "section_coverage": round(sec * 100), "heading_match": round(head * 100),
        "motion_match": round(mot * 100), "token_match": round(tok * 100),
        "missing_colors": [c for c in a["palette"] if c.lower() not in pb][:8],
        "missing_fonts": [f for f in a["fonts"] if f.lower() not in fb][:5],
        "missing_animations": sorted(ma - mb)[:8],
        "sections_original": secA, "sections_clone": secB,
    }

# ---------- screenshot: robust headless capture ----------
# Primary path is Playwright driving a *managed* Chromium it downloads itself, so
# screenshots work even on a machine with no browser installed (and we install the
# browser on demand). If Playwright isn't present we fall back to a system / managed
# Chrome subprocess so the zero-dependency install still degrades usefully rather
# than failing. Only when BOTH are unavailable do we raise a clear, actionable error.
PLAYWRIGHT_HINT = "pip install playwright && python3 -m playwright install chromium"

def _png_dims(b):
    """(width, height) from a PNG's IHDR, or (0,0) if it isn't a PNG."""
    if len(b) >= 24 and b[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", b[16:24]); return w, h
    return (0, 0)

# Full Chrome/Chromium binaries usable via the `--headless=new --screenshot` subprocess
# path. We try SYSTEM browsers first (they drive cleanly via raw subprocess), and only
# then Playwright's downloaded Chromium as a last resort — that binary is meant to be
# driven by the Playwright protocol, and via raw --screenshot it can hang, so it sits
# at the back of the line. (chrome-headless-shell is reserved for the Playwright path.)
def _full_chrome_candidates():
    cands = []
    for c in ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              "/Applications/Chromium.app/Contents/MacOS/Chromium",
              "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
              "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"):
        if os.path.exists(c): cands.append(c)
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
                 "chrome", "microsoft-edge", "brave-browser"):
        p = shutil.which(name)
        if p: cands.append(p)
    caches = [os.path.join(HOME, "Library", "Caches", "ms-playwright"),
              os.path.join(HOME, ".cache", "ms-playwright"),
              os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "")]
    pats = ("chromium-*/chrome-*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
            "chromium-*/chrome-*/chrome",          # linux
            "chromium-*/chrome-*/chrome.exe")      # windows
    for c in caches:
        if not c: continue
        for pat in pats:
            cands += sorted(glob.glob(os.path.join(c, pat)), reverse=True)   # highest revision first
    seen, out = set(), []
    for c in cands:
        if c not in seen and os.path.exists(c): seen.add(c); out.append(c)
    return out

def find_browser():
    c = _full_chrome_candidates()
    return c[0] if c else None

def _have_playwright():
    try:
        import playwright.sync_api  # noqa: F401
        return True
    except Exception:
        return False

def _resolve_target(url, html, prof):
    if html is not None:
        src = os.path.join(prof, "page.html")
        with open(src, "w", encoding="utf-8") as f: f.write(html)
        return "file://" + src
    p = urlsplit(url or "")
    if p.scheme not in ("http", "https"): raise ValueError("only http/https URLs (or pass html=)")
    _assert_public(p.hostname)
    return url

def _shot_playwright(target, width, height, full_page, selector):
    """Render with Playwright's managed Chromium. Returns PNG bytes, or None if
    Playwright isn't importable. Installs the browser on demand if it's missing."""
    try:
        from playwright.sync_api import sync_playwright
    except Exception:
        return None
    for attempt in range(2):
        try:
            with sync_playwright() as p:
                browser = p.chromium.launch(args=["--no-sandbox"])
                try:
                    page = browser.new_page(viewport={"width": width, "height": height},
                                            device_scale_factor=1)
                    page.goto(target, wait_until="load", timeout=20000)
                    if selector:
                        el = page.query_selector(selector)
                        if el is None: raise ValueError(f"element not found for selector {selector!r}")
                        return el.screenshot(type="png")
                    return page.screenshot(type="png", full_page=bool(full_page))
                finally:
                    browser.close()
        except Exception as e:
            # Browser not downloaded yet -> install it on demand, then retry once.
            if attempt == 0 and ("Executable doesn't exist" in str(e) or "playwright install" in str(e)):
                try:
                    subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"],
                                   capture_output=True, timeout=300)
                    continue
                except Exception:
                    pass
            raise

def _shot_chrome(target, width, height, deadline=20.0):
    """Render with a system / managed Chrome subprocess. Tries each known browser in
    turn and returns the first that produces a PNG, so one stalled binary can't sink the
    whole path. We launch headless and POLL for the output file rather than waiting for
    a clean exit — some Chrome builds write the screenshot but linger, so a plain
    run(timeout=) would discard a perfectly good image. Returns None if none succeed.
    Does not support element/full-page capture — those need the Playwright path."""
    import time
    for browser in _full_chrome_candidates():
        prof = tempfile.mkdtemp(prefix="llmshot_")
        out = os.path.join(prof, "shot.png")
        proc = None
        try:
            # --virtual-time-budget makes headless render then (usually) exit; the
            # no-first-run/extension flags keep cold starts fast.
            proc = subprocess.Popen([browser, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
                                     "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                                     "--disable-background-networking", "--virtual-time-budget=5000",
                                     "--user-data-dir=" + prof, f"--window-size={width},{height}",
                                     f"--screenshot={out}", target],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            end = time.monotonic() + deadline
            data = None
            while time.monotonic() < end:
                if os.path.exists(out) and os.path.getsize(out) > 0:
                    time.sleep(0.05)                       # let the final flush land
                    with open(out, "rb") as _f: data = _f.read()
                    break
                if proc.poll() is not None:                # exited; one more look
                    if os.path.exists(out) and os.path.getsize(out) > 0:
                        with open(out, "rb") as _f: data = _f.read()
                    break
                time.sleep(0.1)
            if data:
                return data
        except Exception:
            pass            # this browser errored — try the next candidate
        finally:
            if proc and proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=3)
                except Exception: proc.kill()
            shutil.rmtree(prof, ignore_errors=True)
    return None

def screenshot(url=None, html=None, width=1280, height=1600, name="shot",
               full_page=False, selector=None, outdir=None):
    width  = max(1, min(int(width),  4000))
    height = max(1, min(int(height), 8000))
    shots = outdir or os.path.join(WORKSPACE, "shots"); os.makedirs(shots, exist_ok=True)
    out = os.path.join(shots, (re.sub(r'[^A-Za-z0-9_.-]', '_', name)[:40] or "shot") + ".png")
    prof = tempfile.mkdtemp(prefix="llmshot_")
    errors = []
    try:
        target = _resolve_target(url, html, prof)
        png, backend = None, None
        try:
            png = _shot_playwright(target, width, height, full_page, selector)
            if png is not None: backend = "playwright"
        except Exception as e:
            errors.append("playwright: " + str(e))
        if png is None and not selector:        # the subprocess path can't clip to a selector
            try:
                png = _shot_chrome(target, width, height)
                if png is not None: backend = "chrome"
            except Exception as e:
                errors.append("chrome: " + str(e))
        if png is None:
            detail = ("  (" + "; ".join(errors) + ")") if errors else ""
            raise ValueError("couldn't capture a screenshot — install Playwright ["
                             + PLAYWRIGHT_HINT + "] or Google Chrome/Chromium." + detail)
        with open(out, "wb") as f: f.write(png)
    finally:
        shutil.rmtree(prof, ignore_errors=True)
    w, h = _png_dims(png)
    rel = os.path.relpath(out, WORKSPACE)
    return {"path": rel if not rel.startswith("..") else out, "abspath": out,
            "bytes": len(png), "width": w, "height": h, "backend": backend,
            "dataurl": "data:image/png;base64," + base64.b64encode(png).decode()}

# ---------- local git sync: turn a generated project into a real git repo ----------
GITIGNORE_DEFAULT = """# Dependencies
node_modules/
bower_components/
vendor/
.pnp/
.pnp.js

# Build output / caches
dist/
build/
out/
.next/
.nuxt/
.svelte-kit/
.cache/
coverage/
*.tsbuildinfo

# Environment / secrets — never commit these
.env
.env.*
!.env.example
*.pem
*.key

# Logs
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# Python
__pycache__/
*.py[cod]
.venv/
venv/

# OS / editor cruft
.DS_Store
Thumbs.db
.vscode/
.idea/
*.swp
"""

def _git(args, cwd, env=None):
    e = dict(os.environ)
    if env: e.update(env)
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=30, env=e)

def git_sync(path=".", message="Initial commit — scaffolded by Local LLM Builder",
             remote=None, branch="main", base=None, export=True, deterministic=False):
    """Initialise (or reuse) a local git repo for a generated project, write a sensible
    .gitignore, stage everything and commit, and export a .zip that includes the .git
    history. `remote`, if given, is only *configured* — we never push (that needs the
    user's own GitHub credentials). `base` defaults to the workspace; tests pass a temp
    dir. `deterministic` pins author/committer identity + dates for reproducible commits."""
    if shutil.which("git") is None:
        raise ValueError("git is not installed — install git to enable repo sync")
    base = os.path.realpath(base or WORKSPACE)
    proj = os.path.realpath(os.path.join(base, path))
    if proj != base and not proj.startswith(base + os.sep):
        raise ValueError("project path escapes the workspace")
    if not os.path.isdir(proj):
        raise ValueError(f"no such project directory: {path!r}")

    # 1) .gitignore — create if absent; never clobber a project's existing one.
    gi = os.path.join(proj, ".gitignore"); wrote_gi = False
    if not os.path.exists(gi):
        with open(gi, "w", encoding="utf-8") as f: f.write(GITIGNORE_DEFAULT)
        wrote_gi = True

    # 2) init (idempotent).
    already = os.path.isdir(os.path.join(proj, ".git"))
    if not already:
        if _git(["init", "-b", branch], proj).returncode != 0:   # older git: no -b on init
            _git(["init"], proj); _git(["checkout", "-b", branch], proj)

    # Local identity so a fresh machine never fails to commit (doesn't touch global config).
    if not _git(["config", "user.name"], proj).stdout.strip():
        _git(["config", "user.name", "Local LLM Builder"], proj)
    if not _git(["config", "user.email"], proj).stdout.strip():
        _git(["config", "user.email", "builder@local-llm-setup"], proj)

    env = {}
    if deterministic:
        env = {"GIT_AUTHOR_NAME": "Local LLM Builder", "GIT_AUTHOR_EMAIL": "builder@local-llm-setup",
               "GIT_COMMITTER_NAME": "Local LLM Builder", "GIT_COMMITTER_EMAIL": "builder@local-llm-setup",
               "GIT_AUTHOR_DATE": "2020-01-01T00:00:00+0000", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00+0000"}

    # 3) stage + commit.
    head_before = _git(["rev-parse", "HEAD"], proj).stdout.strip()
    _git(["add", "-A"], proj, env)
    _git(["commit", "-m", message], proj, env)   # nonzero if nothing to commit; detected via HEAD below
    head = _git(["rev-parse", "HEAD"], proj)
    commit_hash = head.stdout.strip() if head.returncode == 0 else None
    commit_made = bool(commit_hash) and commit_hash != head_before
    n_commits = 0
    rc = _git(["rev-list", "--count", "HEAD"], proj)
    if rc.returncode == 0: n_commits = int((rc.stdout.strip() or "0"))
    tracked = [t for t in _git(["ls-files"], proj).stdout.split("\n") if t]

    # 4) optional remote — configure only, never push.
    remote_set = False
    if remote:
        _git(["remote", "remove", "origin"], proj)            # ignore failure if none
        remote_set = _git(["remote", "add", "origin", remote], proj).returncode == 0

    # 5) export a .zip that INCLUDES the .git history. Build it in a temp dir first so we
    #    never try to zip the export into itself when path == ".".
    zip_path, zip_bytes = None, 0
    if export:
        exports = os.path.join(base, "exports"); os.makedirs(exports, exist_ok=True)
        name = os.path.basename(proj.rstrip(os.sep)) or "project"
        tmpd = tempfile.mkdtemp(prefix="llmzip_")
        try:
            made = shutil.make_archive(os.path.join(tmpd, name), "zip", root_dir=proj)
            zip_path = os.path.join(exports, name + ".zip")
            shutil.move(made, zip_path)
            zip_bytes = os.path.getsize(zip_path)
        finally:
            shutil.rmtree(tmpd, ignore_errors=True)

    cur_branch = _git(["rev-parse", "--abbrev-ref", "HEAD"], proj).stdout.strip() or branch
    return {
        "repo_path": proj, "branch": cur_branch,
        "initialized": not already, "gitignore_written": wrote_gi,
        "gitignore_path": os.path.relpath(gi, base),
        "commit": commit_hash, "commit_made": commit_made, "commits_total": n_commits,
        "message": message, "files_tracked": len(tracked), "tracked_sample": tracked[:50],
        "remote": remote, "remote_set": remote_set,
        "zip_path": zip_path, "zip_bytes": zip_bytes,
        "push_hint": ((f"git -C {proj} push -u origin {cur_branch}" if remote
                       else f"git -C {proj} remote add origin <your-repo-url> && git -C {proj} push -u origin {cur_branch}")
                      + "   # uses YOUR GitHub credentials/token — not stored or sent by this tool"),
    }

# ---------- goal runs: the learning / limits log ----------
# One JSON line per pursued goal — the capability, the metric, every round's score, and
# whether it reached target or hit a ceiling. This is the "test its limits by pushing to
# the max" loop, persisted: over time it maps what this local setup can and can't reach,
# and names the lever (a vision model) that would raise the ceiling.
def append_goal_run(rec):
    rec = dict(rec or {})
    rec.setdefault("ts", int(time.time()))
    os.makedirs(os.path.dirname(GOAL_LOG), exist_ok=True)
    with open(GOAL_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    n = 0
    try:
        with open(GOAL_LOG, encoding="utf-8") as f:
            n = sum(1 for line in f if line.strip())
    except Exception:
        pass
    return n

def read_goal_runs(limit=100):
    out = []
    try:
        with open(GOAL_LOG, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try: out.append(json.loads(line))
                except Exception: pass
    except FileNotFoundError:
        pass
    return out[-limit:]


# ---------- system detection: powers the "Capabilities" modal ----------
# Best-effort, stdlib-only, graceful: RAM via sysconf (mac/linux) or GlobalMemoryStatusEx
# (windows); GPU/VRAM via Apple-Silicon detection or nvidia-smi. The effective memory (VRAM
# if a discrete GPU, else RAM) picks the model tier — the same logic the installer uses — so
# the UI can honestly say what this machine can and can't run.
def detect_system():
    info = {"os": platform.system() or "?", "arch": platform.machine() or "?"}
    ram = 0
    try:
        if hasattr(os, "sysconf") and "SC_PHYS_PAGES" in os.sysconf_names and "SC_PAGE_SIZE" in os.sysconf_names:
            ram = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    except Exception:
        pass
    if not ram and info["os"] == "Windows":
        try:
            import ctypes
            class _MS(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            m = _MS(); m.dwLength = ctypes.sizeof(_MS)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
            ram = int(m.ullTotalPhys)
        except Exception:
            pass
    info["ram_gb"] = round(ram / (1024 ** 3), 1) if ram else None
    gpu, vram = None, None
    if info["os"] == "Darwin" and info["arch"] in ("arm64", "aarch64"):
        gpu, vram = "Apple Silicon GPU (unified memory)", info["ram_gb"]
    else:
        try:
            r = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
                               capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and r.stdout.strip():
                row = r.stdout.strip().split("\n")[0].split(",")
                gpu = row[0].strip()
                if len(row) > 1:
                    vram = round(int(row[1].strip()) / 1024, 1)
        except Exception:
            pass
    info["gpu"], info["vram_gb"] = gpu, vram
    eff = vram or info["ram_gb"] or 0
    info["effective_gb"] = eff
    info["tier"] = ("70b" if eff >= 44 else "32b" if eff >= 22 else "14b" if eff >= 14
                    else "7b" if eff >= 7 else "tiny")
    info["render"] = _have_playwright()
    return info


class H(BaseHTTPRequestHandler):
    def _cors(self):
        o = self.headers.get("Origin")
        if o in ORIGINS:
            self.send_header("Access-Control-Allow-Origin", o)
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def _origin_ok(self):
        o = self.headers.get("Origin")
        return o is None or o in ORIGINS
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()
    def do_GET(self):
        if self.path.startswith("/api/agent/ping"):
            return self._json(200, {"ok": True, "workspace": WORKSPACE,
                                    "tools": ["run", "write", "read", "fetch", "inspect", "extract", "score", "screenshot", "gitsync", "goallog"],
                                    "goal_runs": GOAL_LOG,
                                    "browser": bool(find_browser()) or _have_playwright(),
                                    "screenshot_backend": ("playwright" if _have_playwright()
                                                           else ("chrome" if find_browser() else None))})
        if self.path.startswith("/api/agent/goalruns"):
            return self._json(200, {"ok": True, "runs": read_goal_runs(), "path": GOAL_LOG})
        if self.path.startswith("/api/agent/system"):
            return self._json(200, {"ok": True, **detect_system()})
        name = "index.html" if self.path in ("/", "") else os.path.basename(self.path.split("?")[0])
        fp = os.path.join(CHAT_DIR, name)
        if os.path.isfile(fp):
            data = open(fp, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store, must-revalidate")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data)
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        if not self._origin_ok():
            return self._json(403, {"error": "origin not allowed"})
        n = int(self.headers.get("Content-Length", 0) or 0)
        try: req = json.loads(self.rfile.read(n) or b"{}")
        except Exception: req = {}
        path = self.path
        if path.startswith("/api/agent/run"):
            cmd = (req.get("cmd") or "").strip()
            if not cmd: return self._json(400, {"error": "no command"})
            try:
                p = subprocess.run(cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True, timeout=30)
                return self._json(200, {"stdout": p.stdout, "stderr": p.stderr, "code": p.returncode})
            except subprocess.TimeoutExpired:
                return self._json(200, {"stdout": "", "stderr": "timed out after 30s", "code": 124})
        if path.startswith("/api/agent/write"):
            try:
                fp = safe_path(req.get("path", ""))
                os.makedirs(os.path.dirname(fp), exist_ok=True)
                with open(fp, "w") as f: f.write(req.get("content", ""))
                return self._json(200, {"ok": True})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/read"):
            try:
                fp = safe_path(req.get("path", ""))
                with open(fp, "r", errors="replace") as f: data = f.read(200_000)
                return self._json(200, {"ok": True, "content": data})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/fetch"):
            try:
                f = fetch((req.get("url") or "").strip())
                return self._json(200, {"ok": True, "url": f["final_url"], "status": f["status"],
                                        "html": f["html"][:12000], "truncated": f["truncated"] or len(f["html"]) > 12000})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/inspect"):
            try:
                if req.get("html") is not None:
                    return self._json(200, {"ok": True, **_digest_html(req["html"], req.get("base", ""))})
                return self._json(200, {"ok": True, **digest((req.get("url") or "").strip())})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/extract"):
            try:
                d = digest((req.get("url") or "").strip())
                return self._json(200, {"ok": True, "url": d["url"], "title": d["title"],
                                        "palette": d["palette"], "fonts": d["fonts"],
                                        "sections": [s["tag"] for s in d["sections"]][:20],
                                        "tokens": d.get("tokens", {}), "motion": d.get("motion", {}),
                                        "framework": d.get("framework", []),
                                        "states": d.get("states", []), "responsive": d.get("responsive", {}),
                                        "rendered": d.get("rendered", False)})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/score"):
            try:
                a, b = target_digest(req.get("a")), target_digest(req.get("b"))
                return self._json(200, {"ok": True, "a_url": a.get("url", ""), "b_url": b.get("url", ""), **fidelity(a, b)})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/screenshot"):
            try:
                return self._json(200, {"ok": True, **screenshot(url=req.get("url"), html=req.get("html"),
                                                                  width=int(req.get("width", 1280)), height=int(req.get("height", 1600)),
                                                                  name=req.get("name", "shot"),
                                                                  full_page=bool(req.get("full_page", False)),
                                                                  selector=req.get("selector"))})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/gitsync"):
            try:
                return self._json(200, {"ok": True, **git_sync(path=(req.get("path") or "."),
                                                               message=(req.get("message") or "Initial commit — scaffolded by Local LLM Builder"),
                                                               remote=req.get("remote"),
                                                               branch=(req.get("branch") or "main"),
                                                               export=bool(req.get("export", True)))})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        if path.startswith("/api/agent/goallog"):
            try:
                n = append_goal_run(req.get("run") or req)
                return self._json(200, {"ok": True, "count": n, "path": GOAL_LOG})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        return self._json(404, {"error": "unknown endpoint"})
    def log_message(self, *a): pass

if __name__ == "__main__":
    print(f"Local LLM agent server -> http://{HOST}:{PORT}   (workspace: {WORKSPACE})")
    _be = "playwright (managed Chromium)" if _have_playwright() else ("chrome subprocess" if find_browser() else None)
    print("  tools: run, write, read, fetch, inspect, extract, score, screenshot, gitsync, goallog"
          + (f"  [screenshots: {_be}]" if _be else "  [screenshots: install Playwright or Chrome to enable]"))
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
AGENTPY
}

# --agent: the builder page PLUS the approve-to-run tool server (runs commands
# you OK and writes files, all inside a workspace folder). Opt-in + consented.
# Render-based site cloning (and reliable screenshots) need Playwright. Install it into a
# dedicated venv (PEP-668-safe) and run the agent server from that venv's python. Best-effort:
# if anything fails we fall back to system python3 — stdlib inspect + system-Chrome screenshots
# still work, just at lower clone fidelity — so the server always starts.
ensure_agent_python() {
  AGENT_PYTHON="python3"
  command -v python3 >/dev/null 2>&1 || return 0
  local vpy="${AGENT_VENV}/bin/python"
  [ -x "$vpy" ] || python3 -m venv "$AGENT_VENV" >/dev/null 2>&1 || return 0
  if ! "$vpy" -c "import playwright.sync_api" >/dev/null 2>&1; then
    say "  ${DIM}Setting up render-based cloning (Playwright + Chromium, one-time ~150 MB)…${RESET}"
    "${AGENT_VENV}/bin/pip" install --quiet --upgrade pip playwright >/dev/null 2>&1 \
      || { warn "Playwright setup skipped — clones use the built-in fallback (lower fidelity)."; return 0; }
  fi
  "$vpy" -m playwright install chromium >/dev/null 2>&1 || true
  if "$vpy" -c "import playwright.sync_api" >/dev/null 2>&1; then AGENT_PYTHON="$vpy"; ok "Render-based cloning ready (Playwright)"; fi
  return 0
}
start_agent() {
  step "Agent mode — builder + approve-to-run tools"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "Agent mode needs python3 (it runs the tiny local tool server)."
    say "  Install python3, or use the no-tools builder:  ${DIM}./local-llm-setup.sh --chat${RESET}"
    return 0
  fi
  warn "Agent mode lets the model RUN COMMANDS and WRITE FILES on your machine."
  say "  It only ever acts after you click ${BOLD}Approve${RESET} in the browser, inside a workspace folder"
  say "  (${DIM}${HOME}/.local-llm-setup/workspace${RESET}); commands run locally with a 30s timeout."
  if $DRY_RUN; then say "${DIM}[dry-run] write builder page + agent server, launch on 127.0.0.1:${CHAT_PORT}${RESET}"; return 0; fi
  ask "Start the agent server?" n || { say "  Skipped — run the no-tools builder anytime: ./local-llm-setup.sh --chat"; return 0; }
  mkdir -p "$CHAT_DIR"; write_chat_html "$CHAT_DIR/index.html"; write_agent_server "$AGENT_PY"
  ensure_agent_python   # set up Playwright (render-based cloning) in a venv; AGENT_PYTHON falls back to python3
  if curl -fsS "http://127.0.0.1:${CHAT_PORT}/api/agent/ping" >/dev/null 2>&1; then
    ok "Agent server already running"
  else
    lsof -ti:"${CHAT_PORT}" 2>/dev/null | xargs kill 2>/dev/null || true   # free the port from a plain --chat server
    nohup "$AGENT_PYTHON" "$AGENT_PY" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do curl -fsS "http://127.0.0.1:${CHAT_PORT}/api/agent/ping" >/dev/null 2>&1 && break; sleep 0.5; done
  fi
  if curl -fsS "http://127.0.0.1:${CHAT_PORT}/api/agent/ping" >/dev/null 2>&1; then
    open_url "http://localhost:${CHAT_PORT}/"
    ok "Agent is live at ${BOLD}http://localhost:${CHAT_PORT}${RESET} — flip the ${BOLD}Agent${RESET} toggle on (top-right)."
    say "  ${DIM}Stop it:  lsof -ti:${CHAT_PORT} | xargs kill     ·     Re-open:  ./local-llm-setup.sh --agent${RESET}"
  else
    warn "Couldn't start the agent server on port ${CHAT_PORT}."
  fi
  return 0
}

# Open a local browser chat. Serves the page from 127.0.0.1 via python3 (present
# on ~every mac/linux); falls back to the terminal if python3 is missing.
start_chat() {
  step "Opening a local chat in your browser"
  curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 || \
    warn "Ollama doesn't look like it's running yet — run setup first (the chat page will say so too)."
  if $DRY_RUN; then say "${DIM}[dry-run] write chat page, serve on 127.0.0.1:${CHAT_PORT}, open browser${RESET}"; return 0; fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 isn't installed, so I can't auto-serve the chat page."
    say "  Chat in the terminal instead:  ${DIM}ollama run <a model from 'ollama list'>${RESET}"
    return 0
  fi
  mkdir -p "$CHAT_DIR"; write_chat_html "$CHAT_DIR/index.html"
  if ! curl -fsS "http://127.0.0.1:${CHAT_PORT}/" >/dev/null 2>&1; then
    nohup python3 -m http.server "$CHAT_PORT" --bind 127.0.0.1 --directory "$CHAT_DIR" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do curl -fsS "http://127.0.0.1:${CHAT_PORT}/" >/dev/null 2>&1 && break; sleep 0.5; done
  fi
  if curl -fsS "http://127.0.0.1:${CHAT_PORT}/" >/dev/null 2>&1; then
    open_url "http://localhost:${CHAT_PORT}/"
    ok "Chat is live at ${BOLD}http://localhost:${CHAT_PORT}${RESET}  ${DIM}(opened in your browser)${RESET}"
    say "  ${DIM}Stop it:  lsof -ti:${CHAT_PORT} | xargs kill     ·     Re-open:  ./local-llm-setup.sh --chat${RESET}"
  else
    warn "Couldn't start the chat server on port ${CHAT_PORT}."
    say "  Chat in the terminal instead:  ${DIM}ollama run <a model from 'ollama list'>${RESET}"
  fi
  return 0
}

# Pick the best installed coder / reasoning models for the editor config.
EDITOR_CODER=""
EDITOR_REASONER=""
pick_editor_models() {
  EDITOR_CODER="$(installed_models | grep -i coder | grep -- '-8k$' | head -1 || true)"
  [[ -z "$EDITOR_CODER" ]] && EDITOR_CODER="$(installed_models | grep -i coder | grep -v lean | head -1 || true)"
  EDITOR_REASONER="$(installed_models | grep -iE 'deepseek|-r1' | grep -- '-8k$' | head -1 || true)"
  [[ -z "$EDITOR_REASONER" ]] && EDITOR_REASONER="$(installed_models | grep -iE 'deepseek|-r1' | head -1 || true)"
  return 0   # the trailing [[ ]] above can be false; don't let that fail the function under `set -e`
}

# Write ~/.continue/config.yaml pointed at the local models (chat + edit + apply).
write_continue_config() {
  mkdir -p "$HOME/.continue"
  { echo "name: Local (Ollama) Assistant"
    echo "version: 0.0.1"
    echo "schema: v1"
    echo "models:"
    echo "  - name: Coder (local)"
    echo "    provider: ollama"
    echo "    model: ${EDITOR_CODER}"
    echo "    roles: [chat, edit, apply]"
    if [[ -n "$EDITOR_REASONER" ]]; then
      echo "  - name: Reasoner (local)"
      echo "    provider: ollama"
      echo "    model: ${EDITOR_REASONER}"
      echo "    roles: [chat]"
    fi
  } > "$HOME/.continue/config.yaml"
}

# Set up Continue in VS Code / Cursor, pointed at the local models.
setup_editor() {
  step "Setting up your editor (Continue, pointed at your local models)"
  local cli=""
  command -v code >/dev/null 2>&1 && cli="code"
  [[ -z "$cli" ]] && command -v cursor >/dev/null 2>&1 && cli="cursor"
  if [[ -z "$cli" ]]; then
    warn "No VS Code / Cursor command ('code') found."
    say "  Install VS Code (${DIM}https://code.visualstudio.com${RESET}), then re-run:  ${DIM}./local-llm-setup.sh --editor${RESET}"
    say "  Or point any editor at the local API:  ${DIM}Base URL http://localhost:11434/v1${RESET}"
    return 0
  fi
  pick_editor_models
  if [[ -z "$EDITOR_CODER" ]]; then
    warn "No coder model is installed yet — run setup first, then ./local-llm-setup.sh --editor."
    return 0
  fi
  if $DRY_RUN; then
    say "${DIM}[dry-run] $cli --install-extension Continue.continue${RESET}"
    say "${DIM}[dry-run] write ~/.continue/config.yaml -> ${EDITOR_CODER}${EDITOR_REASONER:+, ${EDITOR_REASONER}}${RESET}"
    return 0
  fi
  if $cli --install-extension Continue.continue >/dev/null 2>&1; then
    ok "Installed the Continue extension in ${cli}"
  else
    warn "Couldn't install Continue automatically — add it from your editor's Extensions panel."
  fi
  write_continue_config
  ok "Wrote ~/.continue/config.yaml — ${BOLD}${EDITOR_CODER}${RESET} is ready in Continue."
  say "  ${DIM}Open your editor -> Continue icon in the sidebar -> pick a '(local)' model.${RESET}"
}

case "$MODE" in
  benchmark) do_benchmark; exit 0 ;;
  uninstall) do_uninstall; exit 0 ;;
  chat)      start_chat;   exit 0 ;;
  editor)    setup_editor; exit 0 ;;
  agent)     start_agent;  exit 0 ;;
esac

# ----------------------------------------------------------------------------
# 2. Recommend a tier from your hardware (the OS itself needs ~4-8 GB headroom)
# ----------------------------------------------------------------------------
BASIS="ram"
if [[ -n "$FORCE_TIER" ]]; then
  TIER="$FORCE_TIER"; BASIS="forced"
elif (( GPU_VRAM_GB >= 6 )); then
  # A capable dedicated GPU runs the model from its own VRAM — size to that,
  # not to system RAM (the usual constraint on GPU-less machines).
  if   (( GPU_VRAM_GB <= 8 ));  then TIER="7b"
  elif (( GPU_VRAM_GB <= 16 )); then TIER="14b"
  elif (( GPU_VRAM_GB <= 32 )); then TIER="32b"
  else                              TIER="70b"; fi
  BASIS="gpu"
elif (( RAM_GB <= 16 )); then TIER="7b"
elif (( RAM_GB <= 32 )); then TIER="14b"
elif (( RAM_GB <= 64 )); then TIER="32b"
else                          TIER="70b"
fi

MODELS="$(tier_models "$TIER")"
if [[ -z "$MODELS" ]]; then err "Unknown tier '$TIER' (use 7b|14b|32b|70b)"; exit 1; fi

EST_GB="$(tier_disk_gb "$TIER")"
FREE_GB="$(free_disk_gb)"

step "Recommended setup"
case "$BASIS" in
  gpu)    say "  Tier:     ${BOLD}${TIER}${RESET}  ${DIM}(sized to your ${GPU_VRAM_GB} GB GPU — the fast path)${RESET}" ;;
  forced) say "  Tier:     ${BOLD}${TIER}${RESET}  ${DIM}(forced via --tier)${RESET}" ;;
  *)      say "  Tier:     ${BOLD}${TIER}${RESET}  ${DIM}(sized to your ${RAM_GB} GB of memory)${RESET}" ;;
esac
say "  Models:   ${BOLD}${MODELS}${RESET}"
say "  Context:  ${BOLD}${CTX}${RESET} tokens  ${DIM}(keeps memory use sane)${RESET}"
if (( FREE_GB > 0 )); then
  say "  Download: ${BOLD}~${EST_GB} GB${RESET}  ${DIM}(you have ${FREE_GB} GB free)${RESET}"
else
  say "  Download: ${BOLD}~${EST_GB} GB${RESET}"
fi
say ""
say "  ${DIM}A larger context window or bigger model eats memory fast. These"
say "  defaults are tuned to run smoothly, not to max out your machine.${RESET}"

# Disk preflight — running out of space mid-download is the worst failure mode,
# so catch it before a single byte is pulled.
if (( FREE_GB > 0 && FREE_GB < EST_GB )); then
  err "Not enough free disk: this tier needs ~${EST_GB} GB but only ${FREE_GB} GB is free."
  say "  Free up space, or pick a smaller tier:  ${DIM}./local-llm-setup.sh --tier 7b${RESET}"
  exit 1
elif (( FREE_GB > 0 && FREE_GB < EST_GB + EST_GB/5 + 2 )); then
  warn "Disk is tight (~${EST_GB} GB needed, ${FREE_GB} GB free). It should fit, but only just."
fi

ask "Proceed with this setup?" y || { warn "Stopped. Re-run with --tier to override."; exit 0; }

# ----------------------------------------------------------------------------
# 3. Ensure the package manager (macOS only — Linux installs Ollama directly)
# ----------------------------------------------------------------------------
if [[ "$OS" == "mac" ]]; then
  step "Checking for Homebrew (package manager)"
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew already installed"
  else
    warn "Homebrew not found. It's the standard tool for installing Mac software."
    if ask "Install Homebrew now? (will ask for your Mac password)" y; then
      run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      # Make brew available on Apple Silicon in this session
      [[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
      ok "Homebrew installed"
    else
      err "Homebrew is required to install Ollama automatically. Aborting."
      exit 1
    fi
  fi
fi

# ----------------------------------------------------------------------------
# 4. Install Ollama (the runtime that actually runs the models)
# ----------------------------------------------------------------------------
step "Installing the runtime (Ollama)"
if command -v ollama >/dev/null 2>&1; then
  # Grab just the version line — when the server is down, `ollama --version`
  # also prints a "could not connect" warning we don't want to surface.
  ver="$(ollama --version 2>/dev/null | grep -ai 'version' | head -1)"
  ok "Ollama already installed${ver:+ ($ver)}"
else
  if [[ "$OS" == "mac" ]]; then
    # HOMEBREW_NO_AUTO_UPDATE keeps the install fast, quiet, and deterministic
    # (a cold `brew install` otherwise auto-updates and dumps a wall of output).
    run "HOMEBREW_NO_AUTO_UPDATE=1 brew install ollama"
  else
    run "curl -fsSL https://ollama.com/install.sh | sh"
  fi
  ok "Ollama installed"
fi

# ----------------------------------------------------------------------------
# 5. Make sure the Ollama service is running
# ----------------------------------------------------------------------------
step "Starting the Ollama service"
if curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1; then
  ok "Ollama is already serving on localhost:11434"
else
  if $DRY_RUN; then
    if [[ "$OS" == "mac" ]]; then say "${DIM}[dry-run] brew services start ollama${RESET}"
    else say "${DIM}[dry-run] ollama serve &${RESET}"; fi
  else
    # Prefer a managed service that SURVIVES this script exiting. An in-script
    # `ollama serve &` dies with the script, leaving a later `ollama run` with
    # no server to talk to.
    if [[ "$OS" == "mac" ]] && command -v brew >/dev/null 2>&1; then
      brew services start ollama >/dev/null 2>&1 || (ollama serve >/tmp/ollama-setup.log 2>&1 &)
    else
      (ollama serve >/tmp/ollama-setup.log 2>&1 &) || true
    fi
    # wait up to ~15s for it to come alive
    for _ in $(seq 1 30); do
      curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1 && break
      sleep 0.5
    done
  fi
  if $DRY_RUN || curl -fsS http://localhost:11434/api/tags >/dev/null 2>&1; then
    ok "Ollama service is up"
  else
    err "Could not reach Ollama. Check /tmp/ollama-setup.log"; exit 1
  fi
fi

# ----------------------------------------------------------------------------
# 6. Pull the models (this is the big download — multiple GB each)
# ----------------------------------------------------------------------------
step "Downloading models  ${DIM}(several GB each — this can take a while)${RESET}"
say "  ${DIM}Big models over a home connection can take 30+ min and may hit"
say "  transient network drops — this resumes automatically, and is safe to re-run.${RESET}"
for m in $MODELS; do
  if installed_models | grep -qx "$m"; then
    ok "$m already downloaded"
  elif $DRY_RUN; then
    say "${DIM}[dry-run] ollama pull $m  (with resume-retry)${RESET}"
  else
    say "  Pulling ${BOLD}$m${RESET} ..."
    if pull_with_retry "$m"; then
      ok "$m ready"
    else
      err "Couldn't finish downloading $m after several retries."
      say "  This is almost always a flaky or rate-limited connection, not a bug."
      say "  Your partial download is saved — just re-run this script to resume."
      say "  If a resume stays stuck, clear the partial and start that model fresh:"
      say "    ${DIM}rm -f ~/.ollama/models/blobs/*-partial* && ./local-llm-setup.sh${RESET}"
      exit 1
    fi
  fi
done

# ----------------------------------------------------------------------------
# 7. Bake the context window into ready-to-use custom models
# ----------------------------------------------------------------------------
step "Setting context window to ${CTX} tokens"
for m in $MODELS; do
  alias_name="$(ctx_alias "$m")"             # e.g. qwen2.5-coder-14b-8k
  if $DRY_RUN; then
    say "${DIM}[dry-run] create $alias_name from $m with num_ctx=$CTX${RESET}"; continue
  fi
  # Ollama needs a real Modelfile PATH — `-f -` (stdin) is rejected with
  # "no Modelfile or safetensors files found". Write a temp file and pass it.
  mf="$(mktemp -t modelfile.XXXXXX)"
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$m" "$CTX" > "$mf"
  if ollama create "$alias_name" -f "$mf" >/dev/null 2>&1; then
    ok "Created ${BOLD}$alias_name${RESET} (ready to use, context pre-set)"
  else
    warn "Could not create $alias_name (you can still use $m directly)"
  fi
  rm -f "$mf"
done

# ----------------------------------------------------------------------------
# 7b. Optional --lean: a minimal-code "ponytail" coder variant
# ----------------------------------------------------------------------------
if $LEAN; then
  step "Baking lean coder variant (ponytail)"
  for m in $MODELS; do
    [[ "$m" == *coder* ]] || continue
    lname="$(lean_alias "$m")"
    if $DRY_RUN; then
      say "${DIM}[dry-run] create $lname from $m (num_ctx=$CTX + ponytail minimal-code prompt)${RESET}"; continue
    fi
    lmf="$(mktemp -t modelfile.XXXXXX)"
    write_lean_modelfile "$lmf" "$m"
    if ollama create "$lname" -f "$lmf" >/dev/null 2>&1; then
      ok "Created ${BOLD}$lname${RESET} (writes minimal code — a big win on a small local model)"
    else
      warn "Could not create $lname (you can still use $m directly)"
    fi
    rm -f "$lmf"
  done
fi

# ----------------------------------------------------------------------------
# 8. Smoke test — prove it actually works and show speed
# ----------------------------------------------------------------------------
step "Smoke test"
TEST_MODEL="$(echo "$MODELS" | awk '{print $1}')"
if $DRY_RUN; then
  say "${DIM}[dry-run] ollama run $TEST_MODEL 'Say hello in one short sentence.'${RESET}"
else
  say "Asking ${BOLD}$TEST_MODEL${RESET} a quick question..."
  say ""
  if ollama run "$TEST_MODEL" --verbose "Say hello in one short sentence, then stop." 2>&1; then
    ok "It works. Look for the 'eval rate' above — that's your tokens/second."
  else
    err "The test run failed. Try: ollama run $TEST_MODEL"; exit 1
  fi
fi

# ----------------------------------------------------------------------------
# 9. What to do next
# ----------------------------------------------------------------------------
# Prefer the context-tuned variant for daily use, if it got created.
CHAT_MODEL="$TEST_MODEL"
CHAT_ALIAS="$(ctx_alias "$TEST_MODEL")"
if ! $DRY_RUN && installed_models | grep -qx "$CHAT_ALIAS"; then
  CHAT_MODEL="$CHAT_ALIAS"
fi

step "You're set up. Here's how to use it:"
cat <<EOF

  ${BOLD}Chat in your browser${RESET} (nice UI, nothing extra to install):
    ./local-llm-setup.sh --chat

  ${BOLD}AI inside your editor${RESET} (Continue in VS Code / Cursor):
    ./local-llm-setup.sh --editor

  ${BOLD}Chat in the terminal:${RESET}
    ollama run ${CHAT_MODEL}

  ${BOLD}Your context-tuned models${RESET} (use these in daily work):
$(for m in $MODELS; do echo "    $(ctx_alias "$m")"; done)

  ${BOLD}Point an app or agent at it${RESET} (OpenAI-compatible API):
    Base URL:  http://localhost:11434/v1
    API key:   ollama        ${DIM}(any non-empty string works)${RESET}
    Model:     ${TEST_MODEL}

  ${BOLD}See everything you have:${RESET}
    ollama list

  ${BOLD}Compare model speeds anytime:${RESET}
    ./local-llm-setup.sh --benchmark

  ${DIM}Models live in ~/.ollama. Remove this tool's models with:  ./local-llm-setup.sh --uninstall${RESET}

EOF

# Surface the lean coder variant, if --lean built one.
if $LEAN && ! $DRY_RUN; then
  for m in $MODELS; do
    [[ "$m" == *coder* ]] || continue
    installed_models | grep -qx "$(lean_alias "$m")" || continue
    say "  ${BOLD}Lean coder${RESET} (ponytail — writes minimal code):"
    say "    ollama run $(lean_alias "$m")"
    say ""
  done
fi

# Offer the chat + editor right now — the fastest path from "installed" to "using it".
# Only when interactive (a real terminal, not --yes / not piped / not a dry-run).
if ! $ASSUME_YES && ! $DRY_RUN && [[ -t 0 && -t 1 ]]; then
  ask "Open a chat in your browser now?" y && start_chat || true
  ask "Set up your editor (Continue in VS Code / Cursor) for these models?" y && setup_editor || true
fi
ok "Done."
