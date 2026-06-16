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
VERSION="1.4.0"

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
  .menu li.sel::before { content: "\2713"; position: absolute; left: 9px; }

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
  .chatlist .item .del { opacity: 0; color: #6b7787; font-size: 15px; }
  .chatlist .item:hover .del { opacity: 1; }
  .chatlist .empty2 { color: #4d5765; font-size: 12px; padding: 10px 9px; }

  .chat { flex: 0 0 42%; min-width: 320px; display: flex; flex-direction: column; min-height: 0; border-right: 1px solid #1e2430; }
  .workspace { flex: 1; display: flex; flex-direction: column; min-height: 0; min-width: 0; background: #0a0d13; }

  #log { flex: 1; overflow-y: auto; padding: 20px 18px; position: relative; }
  .msg { display: flex; gap: 11px; margin: 0 0 20px; }
  .msg .who { flex: none; width: 28px; height: 28px; border-radius: 7px; font-size: 12px; display: flex; align-items: center; justify-content: center; font-weight: 700; }
  .msg.user .who { background: #2b4a78; color: #dbe9ff; }
  .msg.bot .who { background: #1d3a2a; color: #aef0c4; }
  .msg .body { padding-top: 4px; white-space: pre-wrap; word-wrap: break-word; min-width: 0; flex: 1; }
  .msg .body pre { background: #0a0d13; border: 1px solid #1e2430; border-radius: 8px; padding: 11px 13px; overflow-x: auto; white-space: pre; }
  .msg .body code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
  .msg .body :not(pre) > code { background: #1a1f29; padding: 1px 5px; border-radius: 4px; }
  .codecard { background: #0a0d13; border: 1px solid #233; border-radius: 8px; padding: 10px 12px; color: #9fb3c8; font-size: 13px; }
  .codecard b { color: #cfe3ff; }
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
  .jump { position: absolute; right: 16px; bottom: 12px; background: #1c2433; border: 1px solid #2a3140; color: #c7d0dd; border-radius: 20px; padding: 6px 12px; font-size: 12px; cursor: pointer; box-shadow: 0 6px 18px rgba(0,0,0,.4); }
  .jump[hidden] { display: none; }

  .composer { flex: none; border-top: 1px solid #1e2430; background: #11151d; padding: 12px 16px 14px; }
  .inrow { display: flex; gap: 10px; align-items: flex-end; }
  textarea { flex: 1; resize: none; background: #0d1017; color: #e6e6e6; border: 1px solid #2a3140; border-radius: 10px; padding: 10px 12px; font: inherit; min-height: 42px; max-height: 160px; }
  textarea:focus, .picker-btn:focus { outline: none; border-color: #2b6cff; }
  button.send { flex: none; height: 42px; padding: 0 18px; background: #2b6cff; color: #fff; border: 0; border-radius: 10px; font-weight: 600; cursor: pointer; }
  button.send:disabled { opacity: .5; cursor: default; }
  .hint { color: #5b6472; font-size: 11.5px; text-align: center; margin-top: 7px; }

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
        <button class="jump" id="jump" hidden>Jump to latest &darr;</button>
      </div>
      <div class="composer">
        <div class="inrow">
          <textarea id="input" rows="1" placeholder="Describe an app to build, or ask anything...  (Enter to send, Shift+Enter = new line)"></textarea>
          <button class="send" id="send">Send</button>
        </div>
        <div class="hint" id="hint">Talking to Ollama at http://localhost:11434</div>
      </div>
    </section>

    <section class="workspace">
      <div class="tabs">
        <button class="tab on" id="tabPreview" data-tab="preview">Preview</button>
        <button class="tab" id="tabCode" data-tab="code">Code</button>
        <button class="tab" id="tabTerm" data-tab="term">Terminal</button>
      </div>
      <div class="wsbody">
        <iframe id="preview" sandbox="allow-scripts allow-forms allow-modals allow-popups"></iframe>
        <pre id="codeview" class="hidden"></pre>
        <pre id="termview" class="hidden"></pre>
        <div class="wsempty" id="wsempty"><b>No app yet</b><div>Ask the model to build something &mdash; it'll render here, live.</div></div>
      </div>
    </section>
  </main>

<script>
const API = "http://localhost:11434";
const AGENT_URL = location.origin;   // the page is served by the agent server (when present)
const BUILDER_SYSTEM =
  "You are a local web-app builder (like Lovable or Bolt) running on the user's machine. " +
  "When the user asks you to build, create, make, or modify an app, page, UI, game, widget, or tool, " +
  "respond with ONE complete, self-contained HTML file inside a single ```html code block — all CSS and " +
  "JavaScript inline, no external libraries, CDNs, or build steps. Put a one-line description before the code. " +
  "When the user asks for a change, output the FULL updated file again. For non-build questions, answer normally.";
const AGENT_SYSTEM =
  "You are a local coding agent on the user's machine, working inside a sandboxed workspace folder. " +
  "You have two tools. To run a shell command, output EXACTLY one block:\n<run>the command</run>\n" +
  "To write a file (path is relative to the workspace), output EXACTLY:\n<write path=\"relative/path\">\nfile contents\n</write>\n" +
  "Output ONE tool call, then STOP and wait — I will reply with <result>...</result>. Use the result to decide the next step. " +
  "When the task is fully done, reply normally with NO tool tags. Keep commands safe and scoped to the workspace.";

const el = id => document.getElementById(id);
const log = el("log"), empty = el("empty"), input = el("input"), sendBtn = el("send");
const dot = el("dot"), hint = el("hint"), jump = el("jump");
const pickerBtn = el("pickerBtn"), pickerName = el("pickerName"), menu = el("menu");
const preview = el("preview"), codeview = el("codeview"), termview = el("termview"), wsempty = el("wsempty");
const tabPreview = el("tabPreview"), tabCode = el("tabCode"), tabTerm = el("tabTerm"), dlBtn = el("dlBtn");
const sidebar = el("sidebar"), chatlist = el("chatlist"), agentChk = el("agentChk"), agentLabel = el("agentLabel");

let messages = [], busy = false, currentModel = "", currentApp = "", stick = true;
let currentId = newId(), agentReady = false;
function newId() { return "c" + Math.random().toString(36).slice(2, 9); }

/* ---------- model picker ---------- */
async function loadModels() {
  try {
    const names = ((await (await fetch(API + "/api/tags")).json()).models || []).map(m => m.name).sort();
    if (!names.length) throw new Error("no models");
    currentModel = names.find(n => /coder.*8k/i.test(n)) || names.find(n => /coder/i.test(n)) || names[0];
    pickerName.textContent = currentModel;
    menu.innerHTML = "";
    for (const n of names) {
      const li = document.createElement("li");
      li.textContent = n; li.dataset.model = n;
      if (n === currentModel) li.classList.add("sel");
      li.addEventListener("click", () => { currentModel = n; pickerName.textContent = n; for (const x of menu.children) x.classList.toggle("sel", x.dataset.model === n); menu.hidden = true; });
      menu.appendChild(li);
    }
  } catch (e) {
    pickerName.textContent = "no models";
    dot.style.background = "#e74c3c"; dot.style.boxShadow = "0 0 8px #e74c3c";
    hint.textContent = "Can't reach Ollama at localhost:11434 - is it running? (try: ollama list)";
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
function render(text) {
  // hide tool tags + full HTML apps from the bubble (they show in workspace panes)
  let t = text.replace(/<run>[\s\S]*?<\/run>/gi, " RUNTOOL ").replace(/<write\s+path=[\s\S]*?<\/write>/gi, " WRITETOOL ");
  t = t.replace(/```(?:html)?\s*[\s\S]*?```/gi, m => /<\/html>|<!doctype/i.test(m) ? " APP " : m);
  let html = t.split(/(```[\s\S]*?```)/g).map(p => {
    if (p.startsWith("```")) return "<pre><code>" + escapeHtml(p.replace(/^```[^\n]*\n?/, "").replace(/```$/, "")) + "</code></pre>";
    let h = escapeHtml(p);
    h = h.replace(/&lt;think&gt;([\s\S]*?)&lt;\/think&gt;/g, '<div class="think">$1</div>');
    h = h.replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    return h;
  }).join("");
  html = html.replace(/ APP /g, '<div class="codecard">&#9633; <b>App</b> &rarr; shown in the live preview</div>')
             .replace(/ RUNTOOL /g, "").replace(/ WRITETOOL /g, "");
  return html;
}
function addMsg(role, text) {
  empty.style.display = "none";
  const w = document.createElement("div");
  w.className = "msg " + (role === "user" ? "user" : "bot");
  w.innerHTML = '<div class="who">' + (role === "user" ? "You" : "AI") + '</div><div class="body"></div>';
  w.querySelector(".body").innerHTML = render(text);
  log.insertBefore(w, jump);
  scrollDown();
  return w.querySelector(".body");
}

/* ---------- scroll ---------- */
function atBottom() { return log.scrollHeight - log.scrollTop - log.clientHeight < 60; }
function scrollDown() { if (stick) log.scrollTop = log.scrollHeight; }
log.addEventListener("scroll", () => { stick = atBottom(); jump.hidden = stick; });
jump.addEventListener("click", () => { stick = true; log.scrollTop = log.scrollHeight; jump.hidden = true; });

/* ---------- workspace ---------- */
function extractApp(text) {
  const fences = [...text.matchAll(/```(?:html)?\s*([\s\S]*?)```/gi)].map(m => m[1]);
  for (let i = fences.length - 1; i >= 0; i--) if (/<\/html>|<!doctype|<body/i.test(fences[i])) return fences[i].trim();
  return null;
}
function setApp(code) { currentApp = code; preview.srcdoc = code; codeview.textContent = code; wsempty.classList.add("hidden"); dlBtn.disabled = false; showTab("preview"); }
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
function persist() {
  if (!messages.length) return;
  const a = loadStore();
  const title = (messages.find(m => m.role === "user") || {}).content || "New chat";
  const rec = { id: currentId, title: title.slice(0, 60), messages, app: currentApp, ts: Date.now() };
  const i = a.findIndex(c => c.id === currentId);
  if (i >= 0) a[i] = rec; else a.unshift(rec);
  saveStore(a); renderList();
}
function renderList() {
  const a = loadStore();
  chatlist.innerHTML = a.length ? "" : '<div class="empty2">No saved chats yet.</div>';
  for (const c of a) {
    const d = document.createElement("div");
    d.className = "item" + (c.id === currentId ? " on" : "");
    d.innerHTML = '<span class="ttl"></span><span class="del" title="Delete">&times;</span>';
    d.querySelector(".ttl").textContent = c.title || "Untitled";
    d.querySelector(".ttl").addEventListener("click", () => openChat(c.id));
    d.querySelector(".del").addEventListener("click", e => { e.stopPropagation(); deleteChat(c.id); });
    chatlist.appendChild(d);
  }
}
function clearMessagesUI() { [...log.querySelectorAll(".msg")].forEach(n => n.remove()); }
function newChat() {
  currentId = newId(); messages = []; currentApp = "";
  preview.srcdoc = ""; codeview.textContent = ""; termview.textContent = ""; dlBtn.disabled = true;
  wsempty.classList.remove("hidden"); showTab("preview");
  clearMessagesUI(); empty.style.display = ""; renderList(); input.focus();
}
function openChat(id) {
  const c = loadStore().find(x => x.id === id); if (!c) return;
  currentId = id; messages = c.messages || []; currentApp = c.app || "";
  clearMessagesUI(); empty.style.display = messages.length ? "none" : "";
  for (const m of messages) addMsg(m.role, m.content);
  if (currentApp) { preview.srcdoc = currentApp; codeview.textContent = currentApp; wsempty.classList.add("hidden"); dlBtn.disabled = false; }
  else { preview.srcdoc = ""; wsempty.classList.remove("hidden"); dlBtn.disabled = true; }
  showTab("preview"); renderList(); stick = true; scrollDown();
}
function deleteChat(id) {
  saveStore(loadStore().filter(c => c.id !== id));
  if (id === currentId) newChat(); else renderList();
}
el("newBtn").addEventListener("click", newChat);
el("sbToggle").addEventListener("click", () => sidebar.classList.toggle("collapsed"));

/* ---------- agent tools ---------- */
function findToolCall(text) {
  const run = text.match(/<run>([\s\S]*?)<\/run>/i);
  if (run) return { kind: "run", cmd: run[1].trim() };
  const wr = text.match(/<write\s+path="([^"]+)">\n?([\s\S]*?)<\/write>/i);
  if (wr) return { kind: "write", path: wr[1].trim(), content: wr[2] };
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
    log.insertBefore(c, jump); scrollDown();
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
  } else {
    const r = await fetch(AGENT_URL + "/api/agent/write", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path: tool.path, content: tool.content }) });
    const j = await r.json();
    term('<span class="cmd">[write] ' + escapeHtml(tool.path) + '</span> ' + (j.ok ? "ok" : ('<span class="err">' + escapeHtml(j.error || "failed") + "</span>")) + "\n");
    showTab("term");
    return j.ok ? ("wrote " + tool.path) : ("error: " + (j.error || "failed"));
  }
}

/* ---------- the model call ---------- */
async function callModel(onTok) {
  const sys = agentChk.checked ? AGENT_SYSTEM : BUILDER_SYSTEM;
  const resp = await fetch(API + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: currentModel, stream: true, messages: [{ role: "system", content: sys }, ...messages] }) });
  const reader = resp.body.getReader(); const dec = new TextDecoder(); let buf = "", acc = "";
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true });
    const lines = buf.split("\n"); buf = lines.pop();
    for (const line of lines) { if (!line.trim()) continue; const o = JSON.parse(line); if (o.message && o.message.content) { acc += o.message.content; onTok(acc); } }
  }
  return acc;
}

async function send() {
  const text = input.value.trim();
  if (!text || busy || !currentModel) return;
  busy = true; sendBtn.disabled = true; input.value = ""; input.style.height = "auto"; stick = true;
  addMsg("user", text); messages.push({ role: "user", content: text });
  try {
    let steps = 0;
    while (steps++ < 12) {
      const body = addMsg("assistant", "");
      const acc = await callModel(t => { body.innerHTML = render(t); scrollDown(); });
      messages.push({ role: "assistant", content: acc });
      // builder mode: render any app
      const app = extractApp(acc); if (app) setApp(app);
      // agent mode: handle a tool call (with approval), then loop
      if (agentChk.checked && agentReady) {
        const tool = findToolCall(acc);
        if (tool) {
          const ok = await approvalCard(tool);
          const result = ok ? await runTool(tool) : "skipped by user";
          messages.push({ role: "user", content: "<result>\n" + result + "\n</result>" });
          continue;
        }
      }
      break;
    }
  } catch (e) {
    addMsg("assistant", "Error: " + e.message);
  } finally {
    busy = false; sendBtn.disabled = false; input.focus(); persist();
  }
}
sendBtn.addEventListener("click", send);
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
# Local LLM Builder — agent server (MVP).
#
# Serves the builder page AND exposes a tiny, sandboxed tool API to it:
#   GET  /api/agent/ping          -> {ok:true}
#   POST /api/agent/run  {cmd}    -> run a shell command IN the workspace dir
#   POST /api/agent/write {path,content} -> write a file UNDER the workspace dir
#
# Safety posture (MVP — see README before shipping):
#   - binds 127.0.0.1 only (never exposed off the machine)
#   - CORS + Origin check: browser requests are only accepted from this page's
#     own origin, so a random website you visit cannot drive your tools
#   - file writes are confined to the workspace (path-escape is rejected)
#   - shell commands run with cwd = workspace and a 30s timeout
#   - the *page* asks you to Approve every command before it is ever sent here
#
# It does NOT yet sandbox the command itself (an approved `rm -rf ~` would still
# run) — approval in the UI is the guardrail. Harden before any default ship.

import json, os, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST, PORT = "127.0.0.1", 8765
HOME = os.path.expanduser("~")
CHAT_DIR  = os.path.join(HOME, ".local-llm-setup", "chat")
WORKSPACE = os.path.realpath(os.path.join(HOME, ".local-llm-setup", "workspace"))
os.makedirs(WORKSPACE, exist_ok=True)
ORIGINS = {f"http://localhost:{PORT}", f"http://127.0.0.1:{PORT}"}

def safe_path(rel):
    p = os.path.realpath(os.path.join(WORKSPACE, rel))
    if p != WORKSPACE and not p.startswith(WORKSPACE + os.sep):
        raise ValueError("path escapes the workspace")
    return p

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
            return self._json(200, {"ok": True, "workspace": WORKSPACE})
        name = "index.html" if self.path in ("/", "") else os.path.basename(self.path.split("?")[0])
        fp = os.path.join(CHAT_DIR, name)
        if os.path.isfile(fp):
            data = open(fp, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
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
        if self.path.startswith("/api/agent/run"):
            cmd = (req.get("cmd") or "").strip()
            if not cmd: return self._json(400, {"error": "no command"})
            try:
                p = subprocess.run(cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True, timeout=30)
                return self._json(200, {"stdout": p.stdout, "stderr": p.stderr, "code": p.returncode})
            except subprocess.TimeoutExpired:
                return self._json(200, {"stdout": "", "stderr": "timed out after 30s", "code": 124})
        if self.path.startswith("/api/agent/write"):
            try:
                fp = safe_path(req.get("path", ""))
                os.makedirs(os.path.dirname(fp), exist_ok=True)
                with open(fp, "w") as f: f.write(req.get("content", ""))
                return self._json(200, {"ok": True})
            except Exception as e:
                return self._json(200, {"ok": False, "error": str(e)})
        return self._json(404, {"error": "unknown endpoint"})
    def log_message(self, *a): pass

if __name__ == "__main__":
    print(f"Local LLM agent server -> http://{HOST}:{PORT}   (workspace: {WORKSPACE})")
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
