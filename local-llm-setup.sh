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
VERSION="1.7.0"

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

  header { flex: none; display: flex; align-items: center; gap: 12px; padding: 10px 16px; border-bottom: 1px solid #1e2430; background: #11151d; }
  header h1 { font-size: 14px; margin: 0; font-weight: 600; color: #cfe3ff; display: flex; align-items: center; gap: 8px; }
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

  @media (max-width: 980px) { .sidebar { width: 0; display: none; } }
  @media (max-width: 860px) { main { flex-direction: column; } .chat { flex: 1 1 50%; min-width: 0; border-right: 0; border-bottom: 1px solid #1e2430; } .workspace { flex: 1 1 50%; } }
</style>
</head>
<body>
  <header>
    <button class="tbtn" id="sbToggle" title="Toggle history">&#9776;</button>
    <h1><span class="dot" id="dot"></span> Local LLM Builder</h1>
    <div class="picker">
      <button class="picker-btn" id="pickerBtn" type="button"><span class="name" id="pickerName">Loading...</span><span class="caret">&#9660;</span></button>
      <ul class="menu" id="menu" hidden></ul>
    </div>
    <div class="grow"></div>
    <label class="toggle" id="agentLabel" title="Let the model run commands + write files (asks before each)"><input type="checkbox" id="agentChk"><span class="sw"></span> Agent</label>
    <button class="tbtn" id="dlBtn" title="Download the current app" disabled>Download</button>
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
  "generous padding, and subtle shadows (shadow-sm / shadow-md). For any image use https://picsum.photos/seed/NAME/W/H " +
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
  "<inspect url=\"https://...\">  — a STRUCTURED digest of a page: title, sections, headings, links, images, the real colour palette and font families\n" +
  "<extract url=\"https://...\">  — just a page's design tokens (palette + fonts)\n" +
  "<screenshot url=\"https://...\">  — render a page in a headless browser and capture a PNG (best-effort; needs Chrome/Chromium)\n" +
  "To CLONE or recreate a real website, FIRST <inspect url=\"...\"> to observe its real structure, palette and fonts — never invent them — then write the page to match those exact colours, fonts and sections. " +
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

const el = id => document.getElementById(id);
const log = el("log"), empty = el("empty"), input = el("input"), sendBtn = el("send");
const dot = el("dot"), hint = el("hint"), jump = el("jump");
const pickerBtn = el("pickerBtn"), pickerName = el("pickerName"), menu = el("menu");
const preview = el("preview"), codeview = el("codeview"), termview = el("termview"), wsempty = el("wsempty"), wsbuild = el("wsbuild"), wsload = el("wsload"), refreshBtn = el("refreshBtn");
const tabPreview = el("tabPreview"), tabCode = el("tabCode"), tabTerm = el("tabTerm"), dlBtn = el("dlBtn");
const sidebar = el("sidebar"), chatlist = el("chatlist"), agentChk = el("agentChk"), agentLabel = el("agentLabel");

let messages = [], busy = false, currentModel = "", currentApp = "", stick = true, buildingApp = false;
let currentId = newId(), agentReady = false;
let abortCtl = null;                 // aborts the in-flight generation (Stop button)
let pendingBuild = null;             // { body, lines } awaiting the preview's load event
let buildSpec = "", repairHtml = ""; // plan spec + repair status; the prefix is rebuilt live each paint
let planOpen = false;                // is the plan card expanded? persisted across streaming repaints
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
  // clone intent: a URL + a recreate verb, with the tool server available -> observe then build
  const urlM = text.match(/https?:\/\/[^\s)"'<>]+/i);
  const cloneIntent = /\b(clone|recreate|replicate|reproduce|rebuild|copy|mimic|inspired by|like (this|the)|same as)\b/.test(t);
  if (urlM && cloneIntent && agentReady) return { kind: "build", model: bestCoder, plan: false, cloneUrl: urlM[0] };
  // a clear non-build question -> the reasoner answers (with or without an app)
  if (reasonRe.test(t) && !hasBuildWord.test(t)) return { kind: "reason", model: bestReasoner || bestCoder, plan: false };
  // app already on screen -> iterate on it (fast, no re-plan), unless they ask to start fresh
  if (hasApp && !newAppRe.test(t)) return { kind: "edit", model: bestCoder, plan: false };
  // no app yet (or an explicit new build) -> build; plan first unless it's a trivial one-liner
  return { kind: "build", model: bestCoder, plan: !!bestReasoner && !trivial };
}
// Turn an inspect() digest into a concrete build spec — the REAL palette, fonts,
// sections and copy from the page, so the coder transcribes it instead of inventing.
function cloneSpecFromDigest(d) {
  const L = ["Recreate this web page as ONE self-contained HTML file: " + (d.title || d.url)];
  if (d.description) L.push("Tagline / description: " + d.description);
  if (d.palette && d.palette.length) L.push("Use THESE exact colours from the site (hex/rgb): " + d.palette.join(", "));
  if (d.fonts && d.fonts.length) L.push("Use THESE fonts (load from Google Fonts if needed): " + d.fonts.join(" · "));
  if (d.sections && d.sections.length) L.push("Section order, top to bottom: " + d.sections.map(s => s.tag + (s.id ? "#" + s.id : "")).join(" › "));
  if (d.headings && d.headings.length) L.push("Real headings / copy to reuse:\n" + d.headings.slice(0, 16).map(h => "• (" + h.level + ") " + h.text).join("\n"));
  if (d.nav_links && d.nav_links.length) { const nav = d.nav_links.map(l => l.text).filter(Boolean).slice(0, 8); if (nav.length) L.push("Nav items: " + nav.join(" · ")); }
  if (d.counts && d.counts.images) L.push("It has ~" + d.counts.images + " images — use https://picsum.photos/seed/NAME/W/H placeholders in those spots.");
  L.push("Match the layout, spacing and visual hierarchy as closely as you can. Make it responsive.");
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
function fidelityCard(sc) {
  const tone = sc.score >= 75 ? "#2ecc71" : sc.score >= 50 ? "#e8b84b" : "#ff7a7a";
  let h = '<div class="tasks" style="margin-top:9px"><div class="tk"><span class="tki" style="border:0;color:' + tone + '">&#9678;</span>'
    + '<span><b>Clone fidelity: <span style="color:' + tone + '">' + sc.score + '%</span></b> '
    + '<span class="meta">palette ' + sc.palette_match + '% · fonts ' + sc.font_match + '% · sections ' + sc.section_coverage + '% · copy ' + sc.heading_match + '%</span></span></div>';
  if (sc.missing_colors && sc.missing_colors.length)
    h += '<div class="tk tk-queued"><span class="tki"></span><span class="meta">unused original colours: ' + sc.missing_colors.join(", ") + '</span></div>';
  return h + "</div>";
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
function persistSession(id, msgs, app) {
  if (!msgs.length) return;
  const a = loadStore();
  const title = (msgs.find(m => m.role === "user") || {}).content || "New chat";
  const rec = { id, title: title.slice(0, 60), messages: msgs, app, ts: Date.now() };
  const i = a.findIndex(c => c.id === id);
  if (i >= 0) a[i] = rec; else a.unshift(rec);
  saveStore(a); renderList();
}
function persist() { persistSession(currentId, messages, currentApp); }
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
  clearMessagesUI(); empty.style.display = messages.length ? "none" : "";
  for (const m of messages) addMsg(m.role, m.content);
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
  return null;
}
function approvalCard(tool) {
  return new Promise(resolve => {
    const c = document.createElement("div");
    c.className = "msg bot";
    const label = tool.kind === "run" ? "Run this command?" : ("Write file: " + tool.path + "?");
    const codeTxt = tool.kind === "run" ? tool.cmd : tool.content;
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
  let body = null;
  // ---- route: which brain, and do we plan first? ----
  const agentRun = agentChk.checked && agentReady;
  const r = (autoMode && !agentRun)
    ? route(text)
    : { kind: agentRun ? "agent" : (currentApp ? "edit" : "build"), model: currentModel || bestCoder, plan: false };
  try {
    if (agentRun) {
      // ---- agent mode: multi-step approve-to-run tool loop ----
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
      let spec = "";
      // clone: OBSERVE the real page first (palette, fonts, sections), then build to it
      if (r.cloneUrl) {
        body = addMsg("assistant", "");
        body.innerHTML = taskList([{ status: "active", label: "Inspecting " + r.cloneUrl }]);
        if (sid === currentId) showTab("term");
        try {
          const dg = await (await fetch(AGENT_URL + "/api/agent/inspect", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: r.cloneUrl }), signal: abortCtl.signal })).json();
          if (dg.ok) {
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
          // clone: score the rebuild against the real page (structural fidelity)
          if (r.cloneUrl) {
            try {
              const sc = await (await fetch(AGENT_URL + "/api/agent/score", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ a: { url: r.cloneUrl }, b: { html: sessionApp } }), signal: abortCtl.signal })).json();
              if (sc.ok) { body.innerHTML = planPrefix() + repairHtml + prose + buildTasks(curLines, true, true) + fidelityCard(sc); scrollDown(); }
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
    persistSession(sid, sessionMessages, sessionApp);
    if (sid === currentId) input.focus();
  }
}
sendBtn.addEventListener("click", () => busy ? stopGen() : send());
input.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } });
input.addEventListener("input", () => { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; });
document.querySelectorAll(".empty .ex span").forEach(s => s.addEventListener("click", () => { input.value = s.dataset.ex; send(); }));

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
#                                        links, images, palette, fonts                (read-only)
#   POST /api/agent/extract {url}     -> just the design tokens: palette + fonts       (read-only, network)
#   POST /api/agent/score {a,b}       -> design-fidelity score between two pages       (read-only)
#                                        (each of a/b is {url} or {html}) — palette/font/
#                                        section/heading overlap -> 0-100 + deltas.
#                                        NB: structural, not pixel — local models aren't vision.
#   POST /api/agent/screenshot {url|html} -> render via an installed headless Chrome/   (read-only)
#                                        Chromium -> PNG (graceful if no browser found)
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

import json, os, re, socket, ipaddress, subprocess, base64, shutil, tempfile, urllib.request
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
        self.sections = []; self.styles = []; self.font_links = []
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
            if "fonts.googleapis" in a.get("href", ""): self.font_links.append(a["href"])
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

def _palette(style_text):
    return [c for c, _ in Counter(m.lower() for m in _COLOR_RE.findall(style_text)).most_common(16)]

def _fonts(style_text, font_links):
    out = []
    for m in _FONT_RE.findall(style_text):
        f = m.strip().strip('"\'')[:80]
        if f and f.lower() not in (x.lower() for x in out): out.append(f)
    for href in font_links:
        for fam in re.findall(r'family=([^&:]+)', href):
            fam = fam.replace('+', ' ').strip()
            if fam and fam.lower() not in (x.lower() for x in out): out.append(fam)
    return out[:8]

def _digest_html(html, base=""):
    d = _Digest(base)
    try: d.feed(html)
    except Exception: pass
    style_text = "\n".join(d.styles)
    return {
        "url": base,
        "title": d.title.strip()[:200], "description": (d.desc or "")[:300],
        "headings": d.headings[:30], "sections": d.sections[:30],
        "nav_links": d.links[:30], "images": d.images[:24],
        "palette": _palette(style_text), "fonts": _fonts(style_text, d.font_links),
        "counts": {"links": len(d.links), "images": len(d.images), "sections": len(d.sections)},
    }

def digest(url):
    f = fetch(url)
    out = _digest_html(f["html"], f["final_url"])
    out.update({"status": f["status"], "truncated": f["truncated"]})
    return out

def target_digest(obj):
    if not obj: raise ValueError("missing target (need {url} or {html})")
    if obj.get("html") is not None: return _digest_html(obj["html"], obj.get("base", ""))
    return digest((obj.get("url") or "").strip())

# ---------- fidelity score (structural; not pixels — local models aren't vision) ----------
def _norm(xs): return set(x.lower().strip() for x in xs if x and x.strip())

def fidelity(a, b):
    pa, pb = _norm(a["palette"]), _norm(b["palette"])
    fa, fb = _norm(a["fonts"]), _norm(b["fonts"])
    ha, hb = _norm(h["text"] for h in a["headings"]), _norm(h["text"] for h in b["headings"])
    pal = len(pa & pb) / len(pa) if pa else (1.0 if not pb else 0.0)
    fon = len(fa & fb) / len(fa) if fa else 1.0
    secA, secB = len(a["sections"]), len(b["sections"])
    sec = min(secB, secA) / secA if secA else 1.0
    head = len(ha & hb) / len(ha) if ha else 1.0
    score = round(100 * (0.35 * pal + 0.25 * fon + 0.20 * sec + 0.20 * head))
    return {
        "score": score,
        "palette_match": round(pal * 100), "font_match": round(fon * 100),
        "section_coverage": round(sec * 100), "heading_match": round(head * 100),
        "missing_colors": [c for c in a["palette"] if c.lower() not in pb][:8],
        "missing_fonts": [f for f in a["fonts"] if f.lower() not in fb][:5],
        "sections_original": secA, "sections_clone": secB,
    }

# ---------- screenshot via an installed headless browser (graceful) ----------
def find_browser():
    for c in ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
              "/Applications/Chromium.app/Contents/MacOS/Chromium",
              "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
              "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"):
        if os.path.exists(c): return c
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
                 "chrome", "microsoft-edge", "brave-browser"):
        p = shutil.which(name)
        if p: return p
    return None

def screenshot(url=None, html=None, width=1280, height=1600, name="shot"):
    browser = find_browser()
    if not browser:
        raise ValueError("no headless browser found — install Google Chrome or Chromium to enable screenshots")
    shots = os.path.join(WORKSPACE, "shots"); os.makedirs(shots, exist_ok=True)
    out = os.path.join(shots, (re.sub(r'[^A-Za-z0-9_.-]', '_', name)[:40] or "shot") + ".png")
    prof = tempfile.mkdtemp(prefix="llmshot_")
    try:
        if html is not None:
            src = os.path.join(prof, "page.html")
            with open(src, "w") as f: f.write(html)
            target = "file://" + src
        else:
            p = urlsplit(url or "")
            if p.scheme not in ("http", "https"): raise ValueError("only http/https URLs")
            _assert_public(p.hostname); target = url
        # --virtual-time-budget makes headless render then EXIT (otherwise it can hang on
        # network-idle); the no-first-run/extension flags keep cold starts fast.
        subprocess.run([browser, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
                        "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                        "--disable-background-networking", "--virtual-time-budget=5000",
                        "--user-data-dir=" + prof, f"--window-size={width},{height}",
                        f"--screenshot={out}", target], capture_output=True, timeout=25)
    finally:
        shutil.rmtree(prof, ignore_errors=True)
    if not os.path.exists(out):
        raise ValueError("the browser produced no image (it may be too old for --headless=new)")
    data = open(out, "rb").read()
    return {"path": os.path.relpath(out, WORKSPACE), "bytes": len(data),
            "dataurl": "data:image/png;base64," + base64.b64encode(data).decode()}

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
                                    "tools": ["run", "write", "read", "fetch", "inspect", "extract", "score", "screenshot"],
                                    "browser": bool(find_browser())})
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
                                        "sections": [s["tag"] for s in d["sections"]][:20]})
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
                                                                  name=req.get("name", "shot"))})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        return self._json(404, {"error": "unknown endpoint"})
    def log_message(self, *a): pass

if __name__ == "__main__":
    print(f"Local LLM agent server -> http://{HOST}:{PORT}   (workspace: {WORKSPACE})")
    print("  tools: run, write, read, fetch, inspect, extract, score, screenshot"
          + ("  [headless browser: found]" if find_browser() else "  [no headless browser -> screenshots disabled]"))
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
AGENTPY
}

# --agent: the builder page PLUS the approve-to-run tool server (runs commands
# you OK and writes files, all inside a workspace folder). Opt-in + consented.
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
  if curl -fsS "http://127.0.0.1:${CHAT_PORT}/api/agent/ping" >/dev/null 2>&1; then
    ok "Agent server already running"
  else
    lsof -ti:"${CHAT_PORT}" 2>/dev/null | xargs kill 2>/dev/null || true   # free the port from a plain --chat server
    nohup python3 "$AGENT_PY" >/dev/null 2>&1 &
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
