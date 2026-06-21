#!/usr/bin/env bash
# new-session.sh — start an isolated workspace for one parallel session.
#
# Each session gets its OWN git worktree: its own folder, its own branch, branched
# off the LATEST origin/main. Two sessions can then never edit the same working
# tree, so they physically cannot clash — they integrate only through PRs.
# This is the "branch-first / per-session worktree" standard — see
# docs/PARALLEL-SESSIONS.md.
#
#   tools/new-session.sh <name>      e.g.  tools/new-session.sh light-mode
#
set -euo pipefail

name="${1:-}"
if [ -z "$name" ]; then
  echo "usage: tools/new-session.sh <session-name>   (e.g. light-mode)" >&2
  exit 1
fi
# branch/folder-safe name
case "$name" in *[!A-Za-z0-9._-]*) echo "✗ use only letters/digits/.-_ in the name" >&2; exit 1;; esac

repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
wt="$(cd "$repo/.." && pwd)/$(basename "$repo")-$name"

if [ -e "$wt" ]; then
  echo "✗ $wt already exists — pick another name or remove it first." >&2
  exit 1
fi
if git -C "$repo" show-ref --verify --quiet "refs/heads/$name"; then
  echo "✗ branch '$name' already exists — pick another name." >&2
  exit 1
fi

cd "$repo"
echo "→ syncing origin/main…"
git fetch origin --quiet
echo "→ creating worktree…"
git worktree add "$wt" -b "$name" origin/main

cat <<EOF

✓ Session workspace ready — isolated from every other session:

    folder : $wt
    branch : $name   (off the latest origin/main)

  Work entirely inside that folder. The full cycle:

    cd "$wt"
    #  …edit files…
    git add -A && git commit -m "…"        # snapshot your changes onto branch '$name'
    git push -u origin $name                # send the branch up to GitHub
    gh pr create                            # open a PR proposing: branch '$name' → main
    #  …human reviews the PR… then, only on their explicit go:
    gh pr merge $name --squash --delete-branch

  When the PR is merged, retire the workspace:

    cd "$repo" && git worktree remove "$wt" && git branch -D $name 2>/dev/null || true

  ⚠ Dogfood caveat: the live builder's SOURCE files (~/.local-llm-setup/chat/index.html
    and agent-server.py) live OUTSIDE git and are shared by every session — a worktree
    does NOT isolate them. Until the source is moved into the repo (recommended; see
    docs/PARALLEL-SESSIONS.md), make sure only one session edits the dogfood at a time,
    and bake from clean origin/main (not the shared dogfood) when another session's
    work-in-progress is sitting in it.
EOF
