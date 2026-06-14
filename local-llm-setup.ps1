#Requires -Version 5.1
<#
local-llm-setup.ps1 — Zero-to-running local LLM in one command (native Windows).

The PowerShell twin of local-llm-setup.sh. Auto-detects your hardware (including
an NVIDIA GPU, if present), picks models that actually fit your machine, checks
you have the disk space, installs the Ollama runtime, downloads the right
models, sets a sane context window, runs a smoke test so you KNOW it works —
then offers to start chatting. No WSL required; this runs Ollama natively so a
discrete GPU is used for real.

Designed for someone doing this for the very first time. No prior knowledge
assumed. Nothing destructive — it only installs Ollama + the models you OK.

Usage (PowerShell):
  .\local-llm-setup.ps1                 # interactive, recommended
  .\local-llm-setup.ps1 -Yes            # accept all defaults, no prompts
  .\local-llm-setup.ps1 -DryRun         # show what it WOULD do, change nothing
  .\local-llm-setup.ps1 -Tier 14b       # force a model tier (7b|14b|32b|70b)
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
  [switch]$Benchmark,
  [switch]$Uninstall,
  [switch]$Version,
  [switch]$Help
)

$AppVersion = '1.1.0'   # NB: not $Version — that name is the -Version switch param
$Ctx = 8192             # default context window — big enough for real work, light on RAM

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
  try { & ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ } }
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
      $out.Add("$($m.Split(':')[0])-$([int]($Ctx/1024))k")
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
  $alias = "$($m.Split(':')[0])-$([int]($Ctx/1024))k"
  if ($DryRun) { Say "[dry-run] create $alias from $m with num_ctx=$Ctx"; continue }
  $mf = New-TemporaryFile
  "FROM $m`nPARAMETER num_ctx $Ctx" | Set-Content -LiteralPath $mf.FullName -Encoding ascii
  & ollama create $alias -f $mf.FullName 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Ok "Created $alias (ready to use, context pre-set)" }
  else { Warn "Could not create $alias (you can still use $m directly)" }
  Remove-Item -LiteralPath $mf.FullName -ErrorAction SilentlyContinue
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
$ChatAlias = "$($TestModel.Split(':')[0])-$([int]($Ctx/1024))k"
if (-not $DryRun -and (Test-ModelInstalled $ChatAlias)) { $ChatModel = $ChatAlias }

Step "You're set up. Here's how to use it:"
Say ''
Say "  Chat in the terminal:"
Say "    ollama run $ChatModel"
Say ''
Say "  Your context-tuned models (use these in daily work):"
foreach ($m in $Models) { Say "    $($m.Split(':')[0])-$([int]($Ctx/1024))k" }
Say ''
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

# Offer to jump straight into a chat — the most intuitive way to start exploring.
if (-not $Yes -and -not $DryRun -and [Environment]::UserInteractive) {
  if (Ask "Start chatting with $ChatModel now? (type /bye to leave)" 'y') {
    Say ''
    & ollama run $ChatModel
  }
}
Ok 'Done.'
