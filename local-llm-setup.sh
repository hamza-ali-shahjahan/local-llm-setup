#!/usr/bin/env bash
#
# local-llm-setup.sh — Zero-to-running local LLM in one command (macOS + Linux).
#
# Auto-detects your OS and hardware, picks models that actually fit your RAM,
# installs the Ollama runtime, downloads the right models, sets a sane context
# window, and runs a smoke test so you KNOW it works.
#
# Designed for someone doing this for the very first time. No prior knowledge
# assumed. Nothing destructive — it only installs Ollama + the models you OK.
#
# Usage:
#   ./local-llm-setup.sh                  # interactive, recommended
#   ./local-llm-setup.sh --yes            # accept all defaults, no prompts
#   ./local-llm-setup.sh --dry-run        # show what it WOULD do, change nothing
#   ./local-llm-setup.sh --tier 14b       # force a model tier (7b|14b|32b|70b)
#   ./local-llm-setup.sh --platform linux # override OS auto-detect (mac|linux)
#   ./local-llm-setup.sh --help
#
set -euo pipefail

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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)    ASSUME_YES=true ;;
    --dry-run)   DRY_RUN=true ;;
    --tier)      FORCE_TIER="${2:-}"; shift ;;
    --platform)  FORCE_OS="${2:-}"; shift ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'
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

step "Checking your machine"
CHIP="$(detect_chip)"
RAM_GB="$(detect_ram_gb)"
ok "Platform: ${BOLD}${OS}${RESET}"
ok "Chip: ${BOLD}${CHIP}${RESET}"
ok "Memory: ${BOLD}${RAM_GB} GB${RESET}"

# ----------------------------------------------------------------------------
# 2. Recommend a tier from RAM (the OS itself needs ~4-8 GB headroom)
# ----------------------------------------------------------------------------
if [[ -n "$FORCE_TIER" ]]; then
  TIER="$FORCE_TIER"
elif (( RAM_GB <= 16 )); then TIER="7b"
elif (( RAM_GB <= 32 )); then TIER="14b"
elif (( RAM_GB <= 64 )); then TIER="32b"
else                          TIER="70b"
fi

MODELS="$(tier_models "$TIER")"
if [[ -z "$MODELS" ]]; then err "Unknown tier '$TIER' (use 7b|14b|32b|70b)"; exit 1; fi

step "Recommended setup for ${RAM_GB} GB"
say "  Tier:    ${BOLD}${TIER}${RESET}  (best fit for your memory)"
say "  Models:  ${BOLD}${MODELS}${RESET}"
say "  Context: ${BOLD}${CTX}${RESET} tokens  ${DIM}(keeps RAM use sane)${RESET}"
say ""
say "  ${DIM}A larger context window or bigger model eats RAM fast. These"
say "  defaults are tuned to run smoothly, not to max out your machine.${RESET}"

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
  say "Asking ${BOLD}$TEST_MODEL${RESET} a quick question...\n"
  if ollama run "$TEST_MODEL" --verbose "Say hello in one short sentence, then stop." 2>&1; then
    ok "It works. Look for the 'eval rate' above — that's your tokens/second."
  else
    err "The test run failed. Try: ollama run $TEST_MODEL"; exit 1
  fi
fi

# ----------------------------------------------------------------------------
# 9. What to do next
# ----------------------------------------------------------------------------
step "You're set up. Here's how to use it:"
cat <<EOF

  ${BOLD}Chat in the terminal:${RESET}
    ollama run ${TEST_MODEL}

  ${BOLD}Your context-tuned models${RESET} (use these in daily work):
$(for m in $MODELS; do echo "    ${m%%:*}-$((CTX/1024))k"; done)

  ${BOLD}Point an app or agent at it${RESET} (OpenAI-compatible API):
    Base URL:  http://localhost:11434/v1
    API key:   ollama        ${DIM}(any non-empty string works)${RESET}
    Model:     ${TEST_MODEL}

  ${BOLD}See everything you have:${RESET}
    ollama list

  ${DIM}Models live in ~/.ollama. Delete one with:  ollama rm <model>${RESET}

EOF
ok "Done."
