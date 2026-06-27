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

**Touching the builder or the cloning / vision path?** Read **[docs/vision-model.md](docs/vision-model.md)** first — the Ollama context-window trap (`num_ctx`), the swallowed-error-body gotcha, and the "restart the agent server with the same venv or you silently downgrade Playwright→Chrome" lesson will bite you otherwise.

## Ground rules

1. **The two installer scripts stay single-file and dependency-free.** The Bash script needs only Bash + standard Unix tools; the PowerShell script needs only Windows PowerShell 5.1+ (built into Windows) — no Python, no Node, no extra runtime to install or run *them*. The whole point is "one file anyone can read and run." (The optional builder / agent server they set up is **Python** — stdlib only, plus an optional Playwright venv for render-based cloning; keep it stdlib-only where you can.)
2. **Nothing destructive, everything consented.** Any install or download must be gated behind a prompt (or `--yes` / `-Yes`). `--dry-run` / `-DryRun` must remain a true no-op.
3. **Bare command lines in docs.** Never put a trailing `# comment` on a `curl … | bash` line in the README or anywhere a user copy-pastes — it can mis-parse on paste and kill the script. Put explanations on their own line, above the command.

## Working in parallel

If more than one session (human or AI) works this repo at once, give each its own git
worktree so they can't clash: `tools/new-session.sh <name>`. Branch-first always — never
commit straight to `main`; integrate through reviewed PRs. See [docs/PARALLEL-SESSIONS.md](docs/PARALLEL-SESSIONS.md).

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
