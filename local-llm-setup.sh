#!/usr/bin/env bash
#
# local-llm-setup.sh — Zero-to-running local LLM in one command (macOS + Linux).
#
# Auto-detects your OS and hardware (including an NVIDIA GPU, if present), picks
# models that actually fit your machine, checks you have the disk space, installs
# the Ollama runtime, downloads the right models, sets a sane context window, and
# runs a smoke test so you KNOW it works — then offers to start chatting.
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
#   ./local-llm-setup.sh --benchmark      # measure tokens/sec for installed models
#   ./local-llm-setup.sh --uninstall      # remove the models this tool installs
#   ./local-llm-setup.sh --version        # print the version and exit
#   ./local-llm-setup.sh --help
#
set -euo pipefail
VERSION="1.1.0"

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
MODE="setup"   # setup | benchmark | uninstall
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)    ASSUME_YES=true ;;
    --dry-run)   DRY_RUN=true ;;
    --tier)      FORCE_TIER="${2:-}"; shift ;;
    --platform)  FORCE_OS="${2:-}"; shift ;;
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
      echo "${m%%:*}-$((CTX/1024))k"
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
    ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$m" && installed+=("$m")
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

case "$MODE" in
  benchmark) do_benchmark; exit 0 ;;
  uninstall) do_uninstall; exit 0 ;;
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
  if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$m"; then
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
  alias_name="${m%%:*}-$((CTX/1024))k"       # e.g. qwen2.5-coder-8k
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
CHAT_ALIAS="${TEST_MODEL%%:*}-$((CTX/1024))k"
if ! $DRY_RUN && ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$CHAT_ALIAS"; then
  CHAT_MODEL="$CHAT_ALIAS"
fi

step "You're set up. Here's how to use it:"
cat <<EOF

  ${BOLD}Chat in the terminal:${RESET}
    ollama run ${CHAT_MODEL}

  ${BOLD}Your context-tuned models${RESET} (use these in daily work):
$(for m in $MODELS; do echo "    ${m%%:*}-$((CTX/1024))k"; done)

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

# Offer to jump straight into a chat — the most intuitive way to start exploring.
# Only when interactive (a real terminal, not --yes / not piped / not a dry-run).
if ! $ASSUME_YES && ! $DRY_RUN && [[ -t 0 && -t 1 ]]; then
  if ask "Start chatting with ${CHAT_MODEL} now? (type /bye to leave)" y; then
    say ""
    ollama run "$CHAT_MODEL"
  fi
fi
ok "Done."
