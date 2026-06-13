# Contributing

Thanks for helping make first-time local-LLM setup painless. This is a small, focused tool — contributions that keep it simple are the most welcome.

## Good first contributions

- **Bump model tags.** New models ship constantly. The tier list lives in one place — the `tier_models()` function near the top of [`local-llm-setup.sh`](local-llm-setup.sh). Update a tag, test, open a PR.
- **Improve hardware detection** for Macs the script reads incorrectly.
- **Clarify a message** that confused you as a first-timer.

## Ground rules

1. **Keep it a single, dependency-free Bash script.** No Python, no Node, no extra runtime. The whole point is "one file anyone can read and run."
2. **Nothing destructive, everything consented.** Any install or download must be gated behind a prompt (or `--yes`). `--dry-run` must remain a true no-op.
3. **Bare command lines in docs.** Never put a trailing `# comment` on a `curl … | bash` line in the README or anywhere a user copy-pastes — it can mis-parse on paste and kill the script. Put explanations on their own line, above the command.

## Before you open a PR

```bash
bash -n local-llm-setup.sh        # syntax check
shellcheck local-llm-setup.sh     # lint (CI runs this too)
./local-llm-setup.sh --dry-run    # confirm the plan prints, nothing executes
```

If you don't have `shellcheck`, the GitHub Actions CI will run it on your PR.

## Reporting issues

Open an issue with: your Mac chip, total RAM (`sysctl hw.memsize`), what you expected, and what happened. A copy of the script's output helps a lot.
