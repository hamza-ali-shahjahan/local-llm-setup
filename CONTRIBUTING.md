# Contributing

Thanks for helping make first-time local-LLM setup painless. This is a small, focused tool — contributions that keep it simple are the most welcome.

## Two scripts, one behavior

There are two entry points that must stay in lockstep:

- [`local-llm-setup.sh`](local-llm-setup.sh) — Bash, for macOS + Linux.
- [`local-llm-setup.ps1`](local-llm-setup.ps1) — PowerShell, for native Windows.

A change to one (a new tier, a new flag, a reworded prompt) should land in the other in the same PR. The model list lives in `tier_models()` (Bash) and `Get-TierModels` (PowerShell).

## Good first contributions

- **Bump model tags.** New models ship constantly — update the tier list in *both* scripts, test, open a PR.
- **Improve hardware detection** for machines a script reads incorrectly.
- **Clarify a message** that confused you as a first-timer.

## Ground rules

1. **Each script stays single-file and dependency-free.** The Bash script needs only Bash + standard Unix tools; the PowerShell script needs only Windows PowerShell 5.1+ (built into Windows). No Python, no Node, no extra runtime. The whole point is "one file anyone can read and run."
2. **Nothing destructive, everything consented.** Any install or download must be gated behind a prompt (or `--yes` / `-Yes`). `--dry-run` / `-DryRun` must remain a true no-op.
3. **Bare command lines in docs.** Never put a trailing `# comment` on a `curl … | bash` line in the README or anywhere a user copy-pastes — it can mis-parse on paste and kill the script. Put explanations on their own line, above the command.

## Before you open a PR

Bash:

```bash
bash -n local-llm-setup.sh           # syntax check
shellcheck -S error local-llm-setup.sh   # lint (CI runs this too)
./local-llm-setup.sh --dry-run       # confirm the plan prints, nothing executes
```

PowerShell (if you touched the `.ps1`):

```powershell
# parse check — no execution
$e=$null; [System.Management.Automation.Language.Parser]::ParseFile("$PWD/local-llm-setup.ps1",[ref]$null,[ref]$e); $e
.\local-llm-setup.ps1 -DryRun        # confirm the plan prints, nothing executes
```

If you don't have these tools locally, the GitHub Actions CI runs ShellCheck plus a real Linux *and* Windows dry-run on your PR.

## Reporting issues

Open an issue with: your OS, your chip/GPU, total RAM, what you expected, and what happened. A copy of the script's output helps a lot.
