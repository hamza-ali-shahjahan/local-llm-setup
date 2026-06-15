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
#   ./local-llm-setup.sh --benchmark      # measure tokens/sec for installed models
#   ./local-llm-setup.sh --uninstall      # remove the models this tool installs
#   ./local-llm-setup.sh --version        # print the version and exit
#   ./local-llm-setup.sh --help
#
set -euo pipefail
VERSION="1.3.0"

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
<title>Local LLM Chat</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; height: 100vh; display: flex; flex-direction: column;
    font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #0d1017; color: #e6e6e6;
  }
  header {
    display: flex; align-items: center; gap: 12px;
    padding: 12px 18px; border-bottom: 1px solid #1e2430; background: #11151d;
  }
  header h1 { font-size: 15px; margin: 0; font-weight: 600; color: #cfe3ff; }
  header .dot { width: 8px; height: 8px; border-radius: 50%; background: #2ecc71; box-shadow: 0 0 8px #2ecc71; }
  select {
    margin-left: auto; background: #0d1017; color: #e6e6e6;
    border: 1px solid #2a3140; border-radius: 8px; padding: 6px 10px; font-size: 13px;
  }
  #log { flex: 1; overflow-y: auto; padding: 24px 0; }
  .wrap { max-width: 760px; margin: 0 auto; padding: 0 18px; }
  .msg { display: flex; gap: 12px; margin: 0 0 22px; }
  .msg .who {
    flex: none; width: 30px; height: 30px; border-radius: 7px; font-size: 13px;
    display: flex; align-items: center; justify-content: center; font-weight: 700;
  }
  .msg.user .who { background: #2b4a78; color: #dbe9ff; }
  .msg.bot  .who { background: #1d3a2a; color: #aef0c4; }
  .msg .body { padding-top: 4px; white-space: pre-wrap; word-wrap: break-word; min-width: 0; }
  .msg .body pre {
    background: #0a0d13; border: 1px solid #1e2430; border-radius: 8px;
    padding: 12px 14px; overflow-x: auto; white-space: pre;
  }
  .msg .body code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
  .msg .body :not(pre) > code { background: #1a1f29; padding: 1px 5px; border-radius: 4px; }
  .think { color: #7d8694; font-style: italic; border-left: 2px solid #2a3140; padding-left: 10px; margin: 6px 0; }
  footer { border-top: 1px solid #1e2430; background: #11151d; padding: 12px 0 16px; }
  .inrow { display: flex; gap: 10px; align-items: flex-end; }
  textarea {
    flex: 1; resize: none; background: #0d1017; color: #e6e6e6; border: 1px solid #2a3140;
    border-radius: 10px; padding: 11px 13px; font: inherit; max-height: 180px;
  }
  button {
    background: #2b6cff; color: #fff; border: 0; border-radius: 10px;
    padding: 11px 18px; font-weight: 600; cursor: pointer;
  }
  button:disabled { opacity: .5; cursor: default; }
  .hint { color: #5b6472; font-size: 12px; text-align: center; margin-top: 8px; }
  .empty { text-align: center; color: #5b6472; margin-top: 12vh; }
  .empty h2 { color: #aab4c4; font-weight: 600; }
</style>
</head>
<body>
  <header>
    <span class="dot" id="dot"></span>
    <h1>Local LLM Chat</h1>
    <select id="model" title="Choose a model"></select>
  </header>
  <div id="log">
    <div class="wrap" id="logwrap">
      <div class="empty" id="empty">
        <h2>Chat with a model running on your machine</h2>
        <div>100% local — nothing leaves this computer.</div>
      </div>
    </div>
  </div>
  <footer>
    <div class="wrap">
      <div class="inrow">
        <textarea id="input" rows="1" placeholder="Message your local model...  (Enter to send, Shift+Enter for a new line)"></textarea>
        <button id="send">Send</button>
      </div>
      <div class="hint" id="hint">Talking to Ollama at http://localhost:11434</div>
    </div>
  </footer>
<script>
const API = "http://localhost:11434";
const logwrap = document.getElementById("logwrap");
const empty = document.getElementById("empty");
const input = document.getElementById("input");
const sendBtn = document.getElementById("send");
const modelSel = document.getElementById("model");
const dot = document.getElementById("dot");
const hint = document.getElementById("hint");
let messages = [];
let busy = false;
async function loadModels() {
  try {
    const r = await fetch(API + "/api/tags");
    const data = await r.json();
    const names = (data.models || []).map(m => m.name).sort();
    if (!names.length) throw new Error("no models");
    modelSel.innerHTML = "";
    for (const n of names) {
      const o = document.createElement("option");
      o.value = n; o.textContent = n; modelSel.appendChild(o);
    }
    const preferred = names.find(n => /coder.*8k/i.test(n)) || names.find(n => /coder/i.test(n)) || names[0];
    modelSel.value = preferred;
  } catch (e) {
    dot.style.background = "#e74c3c"; dot.style.boxShadow = "0 0 8px #e74c3c";
    hint.textContent = "Can't reach Ollama at localhost:11434 - is it running? (try: ollama list)";
  }
}
function escapeHtml(s) {
  return s.replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
}
function render(text) {
  const parts = text.split(/(```[\s\S]*?```)/g);
  return parts.map(p => {
    if (p.startsWith("```")) {
      const body = p.replace(/^```[^\n]*\n?/, "").replace(/```$/, "");
      return "<pre><code>" + escapeHtml(body) + "</code></pre>";
    }
    let h = escapeHtml(p);
    h = h.replace(/&lt;think&gt;([\s\S]*?)&lt;\/think&gt;/g, '<div class="think">$1</div>');
    h = h.replace(/`([^`]+)`/g, "<code>$1</code>");
    h = h.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    return h;
  }).join("");
}
function addMsg(role, text) {
  empty.style.display = "none";
  const el = document.createElement("div");
  el.className = "msg " + (role === "user" ? "user" : "bot");
  el.innerHTML = '<div class="who">' + (role === "user" ? "You" : "AI") + '</div><div class="body"></div>';
  const body = el.querySelector(".body");
  body.innerHTML = render(text);
  logwrap.appendChild(el);
  scrollDown();
  return body;
}
function scrollDown() { const l = document.getElementById("log"); l.scrollTop = l.scrollHeight; }
async function send() {
  const text = input.value.trim();
  if (!text || busy) return;
  busy = true; sendBtn.disabled = true;
  input.value = ""; input.style.height = "auto";
  addMsg("user", text);
  messages.push({ role: "user", content: text });
  const body = addMsg("assistant", "");
  let acc = "";
  try {
    const resp = await fetch(API + "/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: modelSel.value, messages, stream: true })
    });
    const reader = resp.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split("\n"); buf = lines.pop();
      for (const line of lines) {
        if (!line.trim()) continue;
        const obj = JSON.parse(line);
        if (obj.message && obj.message.content) {
          acc += obj.message.content;
          body.innerHTML = render(acc);
          scrollDown();
        }
      }
    }
    messages.push({ role: "assistant", content: acc });
  } catch (e) {
    body.innerHTML = render("Error talking to the model: " + e.message);
  } finally {
    busy = false; sendBtn.disabled = false; input.focus();
  }
}
sendBtn.addEventListener("click", send);
input.addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
});
input.addEventListener("input", () => {
  input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 180) + "px";
});
loadModels();
input.focus();
</script>
</body>
</html>
CHATHTML
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
