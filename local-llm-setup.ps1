#Requires -Version 5.1
<#
local-llm-setup.ps1 — Zero-to-running local LLM in one command (native Windows).

The PowerShell twin of local-llm-setup.sh. Auto-detects your hardware (including
an NVIDIA GPU, if present), picks models that actually fit your machine, checks
you have the disk space, installs the Ollama runtime, downloads the right
models, sets a sane context window, runs a smoke test so you KNOW it works —
then offers a browser chat + editor setup. No WSL required; this runs Ollama natively so a
discrete GPU is used for real.

Designed for someone doing this for the very first time. No prior knowledge
assumed. Nothing destructive — it only installs Ollama + the models you OK.

Usage (PowerShell):
  .\local-llm-setup.ps1                 # interactive, recommended
  .\local-llm-setup.ps1 -Yes            # accept all defaults, no prompts
  .\local-llm-setup.ps1 -DryRun         # show what it WOULD do, change nothing
  .\local-llm-setup.ps1 -Tier 14b       # force a model tier (7b|14b|32b|70b)
  .\local-llm-setup.ps1 -Lean           # also bake a minimal-code "ponytail" coder variant
  .\local-llm-setup.ps1 -Chat           # open a local chat in your browser (no extra installs)
  .\local-llm-setup.ps1 -Editor         # set up Continue in VS Code / Cursor for your local models
  .\local-llm-setup.ps1 -Agent          # builder + approve-to-run tools (runs commands you OK)
  .\local-llm-setup.ps1 -Benchmark      # measure tokens/sec for installed models
  .\local-llm-setup.ps1 -Uninstall      # remove the models this tool installs
  .\local-llm-setup.ps1 -Version        # print the version and exit
  .\local-llm-setup.ps1 -Help

If you see "running scripts is disabled on this system", run this once:
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
then run the script again — it only affects the current window.
#>
[CmdletBinding()]
param(
  [switch]$Yes,
  [switch]$DryRun,
  [string]$Tier,
  [switch]$Lean,
  [switch]$Chat,
  [switch]$Editor,
  [switch]$Agent,
  [switch]$Benchmark,
  [switch]$Uninstall,
  [switch]$Version,
  [switch]$Help
)

$AppVersion = '1.4.0'   # NB: not $Version — that name is the -Version switch param
$Ctx = 8192             # default context window — big enough for real work, light on RAM
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$ChatDir = Join-Path $HomeDir '.local-llm-setup\chat'   # where the chat page is written
$ChatPort = 8765                                         # localhost port the chat page is served on
$AgentPy = Join-Path $HomeDir '.local-llm-setup\agent-server.py'   # the optional -Agent tool server

# Name of the context-tuned variant for a model tag (the size is kept in the
# name so a later run at a different tier won't overwrite an earlier one):
#   qwen2.5-coder:14b  ->  qwen2.5-coder-14b-8k
function Get-CtxAlias {
  param([string]$m)
  "$($m -replace ':','-')-$([int]($Ctx/1024))k"
}

# Name of the optional -Lean (ponytail) variant for a coder model, e.g.
#   qwen2.5-coder:14b  ->  qwen2.5-coder-14b-lean
function Get-LeanAlias {
  param([string]$m)
  "$($m -replace ':','-')-lean"
}

# Minimal-code system prompt, adapted from ponytail
# (https://github.com/DietrichGebert/ponytail, MIT). Steers the coder model to
# the simplest solution — pays off most on a small local model (less code =
# fewer tokens, faster, fits the context window).
$PonytailSystem = @'
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
'@

# ----------------------------------------------------------------------------
# Pretty output
# ----------------------------------------------------------------------------
function Say {
  param([string]$m = '')
  Write-Host $m
}
function Step {
  param([string]$m)
  Write-Host ''
  Write-Host "==> $m" -ForegroundColor Blue
}
function Ok {
  param([string]$m)
  Write-Host '[ok] ' -ForegroundColor Green -NoNewline
  Write-Host $m
}
function Warn {
  param([string]$m)
  Write-Host '[!]  ' -ForegroundColor Yellow -NoNewline
  Write-Host $m
}
function ErrMsg {
  param([string]$m)
  Write-Host '[x]  ' -ForegroundColor Red -NoNewline
  Write-Host $m
}

# Ask a yes/no question. Honors -Yes (auto-yes). Default is 'y' unless told 'n'.
function Ask {
  param([string]$q, [string]$def = 'y')
  if ($Yes) { Say "$q [auto-yes]"; return $true }
  $reply = Read-Host "? $q [$def]"
  if ([string]::IsNullOrWhiteSpace($reply)) { $reply = $def }
  return ($reply -match '^[Yy]')
}

function Show-Help {
  # Print the comment-based help block at the top of this file.
  $inBlock = $false
  foreach ($line in (Get-Content -LiteralPath $PSCommandPath)) {
    if ($line -match '^<#') { $inBlock = $true; continue }
    if ($line -match '^#>') { break }
    if ($inBlock) { Say $line }
  }
}

# ----------------------------------------------------------------------------
# Model tiers — keep in lockstep with tier_models() in local-llm-setup.sh
# ----------------------------------------------------------------------------
function Get-TierModels {
  param([string]$t)
  switch ($t) {
    '7b'  { @('qwen2.5-coder:7b',  'deepseek-r1:7b') }
    '14b' { @('qwen2.5-coder:14b', 'deepseek-r1:14b') }
    '32b' { @('qwen2.5-coder:32b', 'deepseek-r1:32b') }
    '70b' { @('qwen2.5-coder:32b', 'deepseek-r1:70b') }
    default { @() }
  }
}
# Rough on-disk size (GB) of a tier's two models at Ollama's default quant.
function Get-TierDiskGb {
  param([string]$t)
  switch ($t) { '7b' { 10 } '14b' { 19 } '32b' { 40 } '70b' { 63 } default { 0 } }
}

# ----------------------------------------------------------------------------
# Hardware detection
# ----------------------------------------------------------------------------
function Get-RamGb {
  try { [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB) } catch { 0 }
}
function Get-Cpu {
  try { ((Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name).Trim() } catch { 'Unknown CPU' }
}
# NVIDIA VRAM via nvidia-smi (the only reliable cross-vendor source on Windows;
# Win32_VideoController.AdapterRAM is a 32-bit field that caps at 4 GB).
function Get-Gpu {
  $g = [pscustomobject]@{ Name = ''; VramGb = 0 }
  if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $g }
  try {
    $line = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ($line) {
      $parts = $line -split '\s*,\s*'
      $g.Name = $parts[0]
      if ($parts[1] -match '^\d+$') { $g.VramGb = [math]::Floor([int]$parts[1] / 1024) }
    }
  } catch {}
  return $g
}
# Free disk (GB) on the drive that holds Ollama's models. 0 means unknown.
function Get-FreeDiskGb {
  $p = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $env:USERPROFILE '.ollama' }
  while ($p -and -not (Test-Path $p)) { $p = Split-Path $p -Parent }
  if (-not $p) { $p = $env:USERPROFILE }
  try {
    $device = ([System.IO.Path]::GetPathRoot($p)).Substring(0, 2)   # e.g. "C:"
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$device'" -ErrorAction Stop
    return [math]::Floor($disk.FreeSpace / 1GB)
  } catch { return 0 }
}

# ----------------------------------------------------------------------------
# Ollama helpers
# ----------------------------------------------------------------------------
function Test-OllamaUp {
  try { Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 3 -ErrorAction Stop | Out-Null; $true }
  catch { $false }
}
function Get-InstalledModels {
  # `ollama create` tags variants ":latest"; strip it so our bare names match
  # (ollama rm/run with the bare name still target the ":latest" copy).
  try { & ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { (($_ -split '\s+')[0]) -replace ':latest$','' } | Where-Object { $_ } }
  catch { @() }
}
function Test-ModelInstalled {
  param([string]$m)
  (Get-InstalledModels) -contains $m
}
# Pull a model, resuming through transient network drops (Ollama keeps partial
# data, so a retry continues where it left off).
function Invoke-PullWithRetry {
  param([string]$model, [int]$max = 8)
  for ($i = 1; $i -le $max; $i++) {
    & ollama pull $model
    if ($LASTEXITCODE -eq 0) { return $true }
    Warn "Download of $model interrupted (attempt $i/$max) — resuming in ${i}s..."
    Start-Sleep -Seconds $i
  }
  return $false
}

# Every model this tool can install (all tiers) plus its context-tuned variant.
function Get-ManagedModels {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($t in @('7b','14b','32b','70b')) {
    foreach ($m in (Get-TierModels $t)) {
      $out.Add($m)
      $out.Add((Get-CtxAlias $m))                              # current naming
      $out.Add("$($m.Split(':')[0])-$([int]($Ctx/1024))k")     # legacy pre-1.1.1 naming
      if ($m -like '*coder*') { $out.Add((Get-LeanAlias $m)) } # optional -Lean variant
    }
  }
  $out | Sort-Object -Unique
}

# ----------------------------------------------------------------------------
# Maintenance modes
# ----------------------------------------------------------------------------
function Invoke-Benchmark {
  Step 'Benchmark — tokens/sec for your installed models'
  if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { ErrMsg 'Ollama isn''t installed yet. Run setup first.'; exit 1 }
  $models = Get-InstalledModels
  if (-not $models) { ErrMsg 'No models installed yet. Run .\local-llm-setup.ps1 first.'; exit 1 }
  Say '  Each model writes one short sentence; we report its generation rate.'
  Say ''
  Say ('  {0,-34} {1}' -f 'MODEL', 'EVAL RATE')
  foreach ($m in $models) {
    if ($DryRun) { Say "[dry-run] benchmark $m"; continue }
    $rate = 'n/a'
    $out = & ollama run $m --verbose 'Write one sentence about the sea.' 2>&1
    $hit = $out | Select-String -Pattern '^\s*eval rate:\s*(.+)$' | Select-Object -First 1
    if ($hit) { $rate = $hit.Matches[0].Groups[1].Value.Trim() }
    Say ('  {0,-34} {1}' -f $m, $rate)
  }
  Ok 'Done.'
}

function Invoke-Uninstall {
  Step 'Uninstall — removing the models this tool installs'
  if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { Ok 'Ollama isn''t installed — nothing to do.'; exit 0 }
  $installed = @(Get-ManagedModels | Where-Object { Test-ModelInstalled $_ })
  if ($installed.Count -eq 0) {
    Ok 'None of this tool''s models are installed — nothing to remove.'
  } else {
    Say '  These models will be removed:'
    foreach ($m in $installed) { Say "    - $m" }
    if ($DryRun) {
      foreach ($m in $installed) { Say "[dry-run] ollama rm $m" }
    } elseif (Ask "Remove the $($installed.Count) model(s) above?" 'n') {
      foreach ($m in $installed) {
        & ollama rm $m 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "Removed $m" } else { Warn "Could not remove $m" }
      }
    } else { Say '  Left models in place.' }
  }
  if (Ask 'Also uninstall the Ollama runtime itself?' 'n') {
    if ($DryRun) {
      Say '[dry-run] winget uninstall Ollama.Ollama'
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
      & winget uninstall --id Ollama.Ollama -e --silent
      Ok 'Ollama runtime removed.'
    } else {
      Warn 'winget not found — remove Ollama from Settings > Apps instead.'
    }
  }
  Ok 'Uninstall complete.'
}

# ----------------------------------------------------------------------------
# Chat + editor helpers (used by -Chat / -Editor and offered after setup)
# ----------------------------------------------------------------------------
function Open-Url {
  param([string]$u)
  try { Start-Process $u } catch {}
}
function Test-ChatUp {
  try { Invoke-WebRequest -Uri "http://127.0.0.1:$ChatPort/" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop | Out-Null; $true }
  catch { $false }
}

# Write the self-contained local chat page to $path. Same page the Bash script
# ships; served from localhost (which Ollama allows by default) it needs no
# Docker and no extra install, and does NOT expose Ollama to the wider web.
function Write-ChatHtml {
  param([string]$path)
  $html = @'
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
'@
  Set-Content -LiteralPath $path -Value $html -Encoding utf8
}

# Open a local browser chat. Serves the page from 127.0.0.1 via python if
# present; otherwise points you at the native Ollama app (which has its own chat).
function Test-AgentUp {
  try { Invoke-WebRequest -Uri "http://127.0.0.1:$ChatPort/api/agent/ping" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop | Out-Null; $true }
  catch { $false }
}

# Write the bundled agent tool-server (Python) to $path. Embedded so the script
# stays self-contained; its safety model is documented in the file's header.
function Write-AgentServer {
  param([string]$path)
  $py = @'
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
'@
  Set-Content -LiteralPath $path -Value $py -Encoding utf8
}

# -Agent: the builder page PLUS the approve-to-run tool server (runs commands you
# OK and writes files inside a workspace folder). Opt-in + consented. Needs Python.
function Invoke-Agent {
  Step 'Agent mode — builder + approve-to-run tools'
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
  if (-not $py) {
    Warn 'Agent mode needs Python (it runs the tiny local tool server).'
    Say '  Install Python from https://python.org, or use the no-tools builder:  .\local-llm-setup.ps1 -Chat'
    return
  }
  Warn 'Agent mode lets the model RUN COMMANDS and WRITE FILES on your machine.'
  Say "  It only ever acts after you click Approve in the browser, inside a workspace folder"
  Say "  ($HomeDir\.local-llm-setup\workspace); commands run locally with a 30s timeout."
  if ($DryRun) { Say '[dry-run] write builder page + agent server, launch on 127.0.0.1:8765'; return }
  if (-not (Ask 'Start the agent server?' 'n')) { Say '  Skipped — run the no-tools builder anytime: .\local-llm-setup.ps1 -Chat'; return }
  New-Item -ItemType Directory -Force -Path $ChatDir | Out-Null
  Write-ChatHtml (Join-Path $ChatDir 'index.html')
  Write-AgentServer $AgentPy
  if (-not (Test-AgentUp)) {
    Start-Process -FilePath $py.Source -ArgumentList $AgentPy -WindowStyle Hidden
    for ($i = 0; $i -lt 12; $i++) { if (Test-AgentUp) { break }; Start-Sleep -Milliseconds 500 }
  }
  if (Test-AgentUp) {
    Open-Url "http://localhost:$ChatPort/"
    Ok "Agent is live at http://localhost:$ChatPort — flip the Agent toggle on (top-right)."
    Say "  Re-open anytime:  .\local-llm-setup.ps1 -Agent"
  } else {
    Warn "Couldn't start the agent server on port $ChatPort (is something else using it?)."
  }
}

function Invoke-Chat {
  Step 'Opening a local chat in your browser'
  if (-not (Test-OllamaUp)) { Warn "Ollama doesn't look like it's running yet — run setup first (the chat page will say so too)." }
  if ($DryRun) { Say '[dry-run] write the chat page, serve it on 127.0.0.1:8765, and open the browser'; return }
  New-Item -ItemType Directory -Force -Path $ChatDir | Out-Null
  Write-ChatHtml (Join-Path $ChatDir 'index.html')
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
  if ($py) {
    if (-not (Test-ChatUp)) {
      Start-Process -FilePath $py.Source -ArgumentList '-m', 'http.server', "$ChatPort", '--bind', '127.0.0.1', '--directory', $ChatDir -WindowStyle Hidden
      for ($i = 0; $i -lt 12; $i++) { if (Test-ChatUp) { break }; Start-Sleep -Milliseconds 500 }
    }
    if (Test-ChatUp) {
      Open-Url "http://localhost:$ChatPort/"
      Ok "Chat is live at http://localhost:$ChatPort  (opened in your browser)"
      Say "  Re-open anytime:  .\local-llm-setup.ps1 -Chat"
    } else {
      Warn "Couldn't start the chat server on port $ChatPort."
      Say '  Tip: open the Ollama app from your Start menu — it has a built-in chat.'
    }
  } else {
    Warn 'python isn''t installed, so I can''t auto-serve the chat page.'
    Say '  Easiest: open the Ollama app from your Start menu — it has a built-in chat.'
    Say "  (The chat page is saved at $ChatDir if you'd rather serve it yourself.)"
  }
}

# Pick the best installed coder / reasoning models for the editor config.
function Get-EditorModels {
  $installed = Get-InstalledModels
  $coder = $installed | Where-Object { $_ -match 'coder' -and $_ -match '-8k$' } | Select-Object -First 1
  if (-not $coder) { $coder = $installed | Where-Object { $_ -match 'coder' -and $_ -notmatch 'lean' } | Select-Object -First 1 }
  $reasoner = $installed | Where-Object { ($_ -match 'deepseek' -or $_ -match '-r1') -and $_ -match '-8k$' } | Select-Object -First 1
  if (-not $reasoner) { $reasoner = $installed | Where-Object { $_ -match 'deepseek' -or $_ -match '-r1' } | Select-Object -First 1 }
  [pscustomobject]@{ Coder = $coder; Reasoner = $reasoner }
}

# Write ~/.continue/config.yaml pointed at the local models (chat + edit + apply).
function Write-ContinueConfig {
  param([string]$coder, [string]$reasoner)
  $dir = Join-Path $env:USERPROFILE '.continue'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $lines = @(
    'name: Local (Ollama) Assistant'
    'version: 0.0.1'
    'schema: v1'
    'models:'
    '  - name: Coder (local)'
    '    provider: ollama'
    "    model: $coder"
    '    roles: [chat, edit, apply]'
  )
  if ($reasoner) {
    $lines += @('  - name: Reasoner (local)', '    provider: ollama', "    model: $reasoner", '    roles: [chat]')
  }
  ($lines -join "`n") | Set-Content -LiteralPath (Join-Path $dir 'config.yaml') -Encoding utf8
}

# Set up Continue in VS Code / Cursor, pointed at the local models.
function Invoke-EditorSetup {
  Step 'Setting up your editor (Continue, pointed at your local models)'
  $cli = Get-Command code -ErrorAction SilentlyContinue
  if (-not $cli) { $cli = Get-Command cursor -ErrorAction SilentlyContinue }
  if (-not $cli) {
    Warn "No VS Code / Cursor command ('code') found."
    Say '  Install VS Code (https://code.visualstudio.com), then re-run:  .\local-llm-setup.ps1 -Editor'
    Say '  Or point any editor at the local API:  Base URL http://localhost:11434/v1'
    return
  }
  $em = Get-EditorModels
  if (-not $em.Coder) { Warn 'No coder model is installed yet — run setup first, then -Editor.'; return }
  if ($DryRun) {
    Say "[dry-run] $($cli.Name) --install-extension Continue.continue"
    Say "[dry-run] write ~/.continue/config.yaml -> $($em.Coder)"
    return
  }
  & $cli.Source --install-extension Continue.continue 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Ok "Installed the Continue extension in $($cli.Name)" }
  else { Warn "Couldn't install Continue automatically — add it from your editor's Extensions panel." }
  Write-ContinueConfig $em.Coder $em.Reasoner
  Ok "Wrote ~/.continue/config.yaml — $($em.Coder) is ready in Continue."
  Say '  Open your editor -> Continue icon in the sidebar -> pick a (local) model.'
}

# ============================================================================
# Entry point
# ============================================================================
# Note: we deliberately do NOT set $ErrorActionPreference = 'Stop' globally.
# Under PowerShell 7.4+ that makes native commands (ollama) throw on a non-zero
# exit, which would defeat the resume-retry loop and the $LASTEXITCODE checks
# below. Cmdlet calls that must fail hard use a local -ErrorAction Stop instead.

if ($Help)    { Show-Help; exit 0 }
if ($Version) { Say "local-llm-setup $AppVersion"; exit 0 }

Step 'Checking your machine'
$RamGb = Get-RamGb
$CpuName = Get-Cpu
$Gpu = Get-Gpu
Ok "Platform: windows"
Ok "Chip: $CpuName"
Ok "Memory: $RamGb GB"
if ($Gpu.Name) { Ok "GPU: $($Gpu.Name) ($($Gpu.VramGb) GB VRAM)" }

if ($Benchmark) { Invoke-Benchmark; exit 0 }
if ($Uninstall) { Invoke-Uninstall; exit 0 }
if ($Chat)      { Invoke-Chat; exit 0 }
if ($Editor)    { Invoke-EditorSetup; exit 0 }
if ($Agent)     { Invoke-Agent; exit 0 }

# ----------------------------------------------------------------------------
# Recommend a tier — prefer a capable GPU's VRAM, else system RAM
# ----------------------------------------------------------------------------
$Basis = 'ram'
if ($Tier) {
  $Basis = 'forced'
} elseif ($Gpu.VramGb -ge 6) {
  $Basis = 'gpu'
  if     ($Gpu.VramGb -le 8)  { $Tier = '7b' }
  elseif ($Gpu.VramGb -le 16) { $Tier = '14b' }
  elseif ($Gpu.VramGb -le 32) { $Tier = '32b' }
  else                        { $Tier = '70b' }
} else {
  if     ($RamGb -le 16) { $Tier = '7b' }
  elseif ($RamGb -le 32) { $Tier = '14b' }
  elseif ($RamGb -le 64) { $Tier = '32b' }
  else                   { $Tier = '70b' }
}

$Models = Get-TierModels $Tier
if (-not $Models) { ErrMsg "Unknown tier '$Tier' (use 7b|14b|32b|70b)"; exit 1 }
$EstGb = Get-TierDiskGb $Tier
$FreeGb = Get-FreeDiskGb

Step 'Recommended setup'
switch ($Basis) {
  'gpu'    { Say ("  Tier:     {0,-5}(sized to your $($Gpu.VramGb) GB GPU — the fast path)" -f $Tier) }
  'forced' { Say ("  Tier:     {0,-5}(forced via -Tier)" -f $Tier) }
  default  { Say ("  Tier:     {0,-5}(sized to your $RamGb GB of memory)" -f $Tier) }
}
Say "  Models:   $($Models -join ' ')"
Say "  Context:  $Ctx tokens  (keeps memory use sane)"
if ($FreeGb -gt 0) { Say "  Download: ~$EstGb GB  (you have $FreeGb GB free)" }
else               { Say "  Download: ~$EstGb GB" }
Say ''
Say '  A larger context window or bigger model eats memory fast. These'
Say '  defaults are tuned to run smoothly, not to max out your machine.'

# Disk preflight — running out of space mid-download is the worst failure mode.
if ($FreeGb -gt 0 -and $FreeGb -lt $EstGb) {
  ErrMsg "Not enough free disk: this tier needs ~$EstGb GB but only $FreeGb GB is free."
  Say "  Free up space, or pick a smaller tier:  .\local-llm-setup.ps1 -Tier 7b"
  exit 1
} elseif ($FreeGb -gt 0 -and $FreeGb -lt ($EstGb + [math]::Floor($EstGb / 5) + 2)) {
  Warn "Disk is tight (~$EstGb GB needed, $FreeGb GB free). It should fit, but only just."
}

if (-not (Ask 'Proceed with this setup?' 'y')) { Warn 'Stopped. Re-run with -Tier to override.'; exit 0 }

# ----------------------------------------------------------------------------
# Install Ollama (native Windows)
# ----------------------------------------------------------------------------
Step 'Installing the runtime (Ollama)'
if (Get-Command ollama -ErrorAction SilentlyContinue) {
  Ok 'Ollama already installed'
} elseif ($DryRun) {
  Say '[dry-run] winget install Ollama.Ollama   (falls back to OllamaSetup.exe)'
} else {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    & winget install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements
  } else {
    Warn 'winget not found — downloading the official installer instead.'
    $exe = Join-Path $env:TEMP 'OllamaSetup.exe'
    Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $exe
    if ($Yes) {
      Start-Process -FilePath $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES' -Wait
    } else {
      Start-Process -FilePath $exe -Wait
    }
  }
  # Make ollama reachable in THIS session (installer adds it for new shells).
  $ollamaDir = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
  if (Test-Path $ollamaDir) { $env:Path = "$env:Path;$ollamaDir" }
  if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    ErrMsg 'Ollama was installed but isn''t on PATH in this window yet.'
    Say '  Open a NEW PowerShell window and run the script again to finish.'
    exit 1
  }
  Ok 'Ollama installed'
}

# ----------------------------------------------------------------------------
# Make sure the Ollama service is running
# ----------------------------------------------------------------------------
Step 'Starting the Ollama service'
if (Test-OllamaUp) {
  Ok 'Ollama is already serving on localhost:11434'
} elseif ($DryRun) {
  Say '[dry-run] start the Ollama background service'
  Ok 'Ollama service is up'
} else {
  Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
  for ($i = 0; $i -lt 30; $i++) { if (Test-OllamaUp) { break }; Start-Sleep -Milliseconds 500 }
  if (Test-OllamaUp) { Ok 'Ollama service is up' } else { ErrMsg 'Could not reach Ollama on localhost:11434.'; exit 1 }
}

# ----------------------------------------------------------------------------
# Pull the models (the big download — multiple GB each)
# ----------------------------------------------------------------------------
Step 'Downloading models  (several GB each — this can take a while)'
Say '  Big models over a home connection can take 30+ min and may hit'
Say '  transient network drops — this resumes automatically, and is safe to re-run.'
foreach ($m in $Models) {
  if (Test-ModelInstalled $m) {
    Ok "$m already downloaded"
  } elseif ($DryRun) {
    Say "[dry-run] ollama pull $m  (with resume-retry)"
  } else {
    Say "  Pulling $m ..."
    if (Invoke-PullWithRetry $m) {
      Ok "$m ready"
    } else {
      ErrMsg "Couldn't finish downloading $m after several retries."
      Say '  This is almost always a flaky or rate-limited connection, not a bug.'
      Say '  Your partial download is saved — just re-run this script to resume.'
      exit 1
    }
  }
}

# ----------------------------------------------------------------------------
# Bake the context window into ready-to-use custom models
# ----------------------------------------------------------------------------
Step "Setting context window to $Ctx tokens"
foreach ($m in $Models) {
  $alias = Get-CtxAlias $m
  if ($DryRun) { Say "[dry-run] create $alias from $m with num_ctx=$Ctx"; continue }
  $mf = New-TemporaryFile
  "FROM $m`nPARAMETER num_ctx $Ctx" | Set-Content -LiteralPath $mf.FullName -Encoding ascii
  & ollama create $alias -f $mf.FullName 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Ok "Created $alias (ready to use, context pre-set)" }
  else { Warn "Could not create $alias (you can still use $m directly)" }
  Remove-Item -LiteralPath $mf.FullName -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Optional -Lean: a minimal-code "ponytail" coder variant
# ----------------------------------------------------------------------------
if ($Lean) {
  Step 'Baking lean coder variant (ponytail)'
  foreach ($m in $Models) {
    if ($m -notlike '*coder*') { continue }
    $lname = Get-LeanAlias $m
    if ($DryRun) { Say "[dry-run] create $lname from $m (num_ctx=$Ctx + ponytail minimal-code prompt)"; continue }
    $lmf = New-TemporaryFile
    @"
FROM $m
PARAMETER num_ctx $Ctx
SYSTEM """
$PonytailSystem
"""
"@ | Set-Content -LiteralPath $lmf.FullName -Encoding ascii
    & ollama create $lname -f $lmf.FullName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "Created $lname (writes minimal code — a big win on a small local model)" }
    else { Warn "Could not create $lname (you can still use $m directly)" }
    Remove-Item -LiteralPath $lmf.FullName -ErrorAction SilentlyContinue
  }
}

# ----------------------------------------------------------------------------
# Smoke test
# ----------------------------------------------------------------------------
Step 'Smoke test'
$TestModel = $Models[0]
if ($DryRun) {
  Say "[dry-run] ollama run $TestModel 'Say hello in one short sentence.'"
} else {
  Say "Asking $TestModel a quick question..."
  Say ''
  & ollama run $TestModel --verbose 'Say hello in one short sentence, then stop.'
  if ($LASTEXITCODE -eq 0) { Ok "It works. Look for the 'eval rate' above — that's your tokens/second." }
  else { ErrMsg "The test run failed. Try: ollama run $TestModel"; exit 1 }
}

# ----------------------------------------------------------------------------
# What to do next
# ----------------------------------------------------------------------------
$ChatModel = $TestModel
$ChatAlias = Get-CtxAlias $TestModel
if (-not $DryRun -and (Test-ModelInstalled $ChatAlias)) { $ChatModel = $ChatAlias }

Step "You're set up. Here's how to use it:"
Say ''
Say "  Chat in your browser (nice UI, nothing extra to install):"
Say "    .\local-llm-setup.ps1 -Chat"
Say ''
Say "  AI inside your editor (Continue in VS Code / Cursor):"
Say "    .\local-llm-setup.ps1 -Editor"
Say ''
Say "  Agent mode — builder + approve-to-run tools (needs Python):"
Say "    .\local-llm-setup.ps1 -Agent"
Say ''
Say "  Chat in the terminal:"
Say "    ollama run $ChatModel"
Say ''
Say "  Your context-tuned models (use these in daily work):"
foreach ($m in $Models) { Say "    $(Get-CtxAlias $m)" }
Say ''
if ($Lean -and -not $DryRun) {
  foreach ($m in $Models) {
    if ($m -notlike '*coder*') { continue }
    if (-not (Test-ModelInstalled (Get-LeanAlias $m))) { continue }
    Say "  Lean coder (ponytail — writes minimal code):"
    Say "    ollama run $(Get-LeanAlias $m)"
    Say ''
  }
}
Say "  Point an app or agent at it (OpenAI-compatible API):"
Say "    Base URL:  http://localhost:11434/v1"
Say "    API key:   ollama        (any non-empty string works)"
Say "    Model:     $TestModel"
Say ''
Say "  Compare model speeds anytime:"
Say "    .\local-llm-setup.ps1 -Benchmark"
Say ''
Say "  Models live in $env:USERPROFILE\.ollama. Remove this tool's models with:"
Say "    .\local-llm-setup.ps1 -Uninstall"
Say ''

# Offer the chat + editor right now — the fastest path from "installed" to "using it".
if (-not $Yes -and -not $DryRun -and [Environment]::UserInteractive) {
  if (Ask 'Open a chat in your browser now?' 'y') { Invoke-Chat }
  if (Ask 'Set up your editor (Continue in VS Code / Cursor) for these models?' 'y') { Invoke-EditorSetup }
}
Ok 'Done.'
