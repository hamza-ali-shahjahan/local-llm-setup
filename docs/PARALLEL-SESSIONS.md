# Working in parallel — the per-session worktree standard

When more than one session (human or AI) works this repo at the same time, they must not
share a working tree. The standard is: **one git worktree per session, branch-first, integrate
through PRs.** This makes clashes physically impossible instead of merely discouraged.

## TL;DR

```bash
tools/new-session.sh my-feature      # own folder + own branch off latest origin/main
cd ../local-llm-my-feature
# …edit, commit…
git push -u origin my-feature
gh pr create                         # branch → main
# human reviews, then on their go:
gh pr merge my-feature --squash --delete-branch
```

Never commit straight to `main`. Pause at the PR for human review.

## The mental model

Four distinct things people lump together as "git":

| Thing | What it is | Where |
|---|---|---|
| **Repository** (`.git`) | The object database: every commit, branch, tag in full history. The single source of truth. | one per project (plus the GitHub copy `origin`) |
| **Branch** | A movable *named pointer* to one commit. Cheap. `main` is just the branch we agree is canonical. | lives inside the repository |
| **Working tree** | The actual checked-out *files on disk* you edit. A snapshot of one branch, expanded to real files. | normally **one** per repo |
| **Commit** | An immutable snapshot of the working tree at a moment, with a parent. Branches move; commits don't. | stored in the repository |

Normally a repo has **one** working tree. That's the whole problem with parallel sessions: two
sessions editing one working tree are editing the *same files at the same time* — uncommitted work
from one bleeds into the other's commits, or a half-saved change breaks a live build.

## What a worktree changes

`git worktree` lets **one repository** have **several working trees at once**, each checked out to a
**different branch**, each in its **own folder** — all sharing the same `.git` history underneath.

```
                         ┌─────────────────────────── GitHub (origin) ───────────────────────────┐
                         │   main ──●────●────●  (the canonical branch; PRs merge here)           │
                         └────────────────────────────────▲──────────────────────────────────────┘
                                                           │ push / PR / merge
        one shared .git history (objects, branches, tags)  │
   ┌───────────────────────────────────────────────────────┴───────────────────────────────────┐
   │                                                                                             │
   ▼                                  ▼                                  ▼
 working tree A                    working tree B                    working tree C
 folder: local-llm/                folder: local-llm-feat-x/         folder: local-llm-feat-y/
 branch: main                      branch: feat-x                    branch: feat-y
 (session 1 edits here)            (session 2 edits here)            (session 3 edits here)
```

Because each session edits a **different folder**, no two sessions ever touch the same file. They
only meet when a branch is pushed and a PR is merged into `main`. That's the isolation.

## The cycle, step by step

1. **edit** — change files in *your* working tree (your folder only).
2. **commit** — `git commit` snapshots those files onto *your branch* in the shared repository. Nothing leaves your machine yet; other branches are untouched.
3. **push** — `git push` uploads your branch to GitHub (`origin`). Still isolated from `main`.
4. **PR** — `gh pr create` opens a Pull Request proposing *your branch → main*. CI runs. A human reviews the diff.
5. **review** — the gate. Nothing lands on `main` without an explicit go. (We pause here.)
6. **merge** — `gh pr merge --squash` fast-forwards `main` to include your work; the branch is deleted.
7. **sync** — other worktrees do `git fetch` and branch their *next* work off the new `main`.

Worktrees + this cycle = each session is a sealed lane; `main` is the only shared road, and you only
get onto it through a reviewed PR.

## Cleaning up

```bash
git worktree list                       # see all active worktrees
git worktree remove ../local-llm-feat-x # after its PR merges
git branch -D feat-x                    # drop the merged local branch
```

A worktree whose folder you delete by hand leaves a stale entry — run `git worktree prune` to clear it.

## Known gap: the dogfood files are shared (outside git)

The live builder's source of truth — `~/.local-llm-setup/chat/index.html` and
`~/.local-llm-setup/agent-server.py` — lives **outside** the repo (the repo only stores the *baked*
installers). A worktree does **not** isolate these: every session, in every worktree, reads and
writes the *same* dogfood files, and the live builder on `:8765` serves them. This is how a parallel
session's half-built feature can show up in your builder.

**Interim rule:** only one session edits the dogfood at a time; when another session's
work-in-progress is sitting in it, **bake from clean `origin/main`** (extract the embedded HTML,
apply only your change, splice just your region) rather than baking the shared dogfood wholesale.

**Recommended permanent fix:** move the source into the repo (`src/index.html`, `src/agent-server.py`)
and bake from the worktree's `src/`. Then each worktree carries its own source, the dogfood becomes a
disposable *test install* synced from a merged `main`, and worktrees isolate the source completely —
no interim rule needed.
