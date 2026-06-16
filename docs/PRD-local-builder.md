# PRD — Local Builder: a private, local-first Lovable + Claude Code

**Status:** draft v0.1 · **Owner:** Hamza · **Date:** 2026-06-16
**One-liner:** One command turns any machine into a private AI workspace that builds apps with a live preview (like Lovable) and does agentic, traceable, tool-using engineering (like Claude Code) — 100% on the user's own models via Ollama. No cloud, no subscription, nothing leaves the machine.

---

## 1. Why this exists

Lovable and Claude Code are magic but **cloud-bound, paid, and they see your code**. Capable local models now exist; the missing piece is a *workspace* that makes them feel like those tools. We already ship the hard part (the local model, the agent server, the preview). This PRD defines the product it should become: **the local-first builder.**

**Differentiation:** private · free · your models · works offline · no lock-in. The honest trade-off — local models are weaker than frontier — is handled by **harness taste** (inject the design system, scope tasks tightly, the `--lean` prompt) rather than by hoping the model is smart.

---

## 2. The three modes (the core structure)

One app, three modes in the top bar. Power, tools, and risk increase left → right. Each has its own panel layout and intent.

| | **Chat** | **Cowork** | **Code** |
|---|---|---|---|
| **Like** | ChatGPT / Claude.ai | **Lovable / v0 / Bolt** | **Claude Code / Cursor agent** |
| **Does** | Pure conversation | Co-build a **web app** with live preview | Agentic engineering in a real workspace |
| **Tools** | None | Write the app file · render preview | Read/write files · run commands · terminal (approve-to-run) |
| **Workspace** | None | One project = one app (single file, then multi) | A real project dir per session |
| **Right panels** | (none / references) | **Preview · Code · Console** | **Files · Editor · Terminal · Preview** |
| **Best model** | deepseek-r1 (reasoning) | qwen-coder | qwen-coder + reasoner |
| **Risk** | none | low (sandboxed iframe) | real (runs commands) → consent + approval |

- **Chat** = *think with a local model.* No tools, no panes. Reasoning, writing, Q&A.
- **Cowork** = *build a UI together.* The model writes a self-contained app; it renders live; you refine by talking ("make the hero sticky", "add pricing"). Each chat is a **project**.
- **Code** = *build software.* Real files + terminal + approve-to-run tools, multi-file, with a traceable plan. This is `--agent` grown up.

> **Mode switch is the headline UX.** It replaces today's single "Agent on/off" toggle.

---

## 3. Speak and act like Claude Code (the agent-tracing requirement)

**Principle: show the work as it happens — honestly. Never say "done" while still doing.**

Today the model says "I've built X" *before* X exists, and dumps prose. It must instead:

1. **Plan first.** For any non-trivial task it emits a short **task list** up front.
2. **Trace each task live.** Each task is a row with a status:
   `○ queued → ◐ in progress (spinner) → ✓ done` / `✕ failed`, each with a one-line result.
3. **Honest tense.** "Building the hero section…" (present) while active; "Built the hero section" (past) only once real. The status, not the prose, is the source of truth.
4. **Activity in chat, artifacts in panes.** The conversation shows the **task tracker** + brief narration — *not* walls of code. Code streams into the **Code pane**; the result lands in **Preview**; commands and their output land in **Terminal**.
5. **Works with any model.** A text protocol (`<plan>…</plan>`, `<task>…`, `<status>…`), parsed by the UI — *not* function-calling (which only some models support, and would break "any model").

This is the difference between a chatbot and a teammate: you can *see and trace* what it's doing and step in.

---

## 4. Per-session = per-project isolation (today's bug → the model)

**Each chat/session is an independent project** with its own: conversation, files/workspace, preview, code, terminal, and task state. Switching projects swaps the *entire* workspace to that project's state.

- **Today's bug:** building in one chat shows "Building…" in *all* of them, and the preview/app is global. → Fix: scope every piece of live state (building flag, currentApp, preview URL, task list, terminal buffer) to the active project; persist per project.
- **Storage:** Cowork single-file apps → `localStorage` per project. Code projects → a real dir under `~/.local-llm-setup/projects/<id>/` managed by the agent server.
- **Project list (left rail):** name (auto from first prompt, renameable), **mode badge**, last-updated, a status dot (idle / building / error). New · search · delete · duplicate.

---

## 5. Layout & panels (detailed)

```
┌────────────┬───────────────────────────┬──────────────────────────────┐
│  PROJECTS  │       CONVERSATION        │         WORKSPACE            │
│  (left)    │       (center)            │         (right)              │
│            │                           │                              │
│  + New     │  messages                 │  [ mode-dependent tabs ]     │
│  search    │  + live TASK TRACKER      │  Chat:   —                   │
│  ───────   │  (○◐✓ per step)           │  Cowork: Preview · Code ·    │
│  proj A ●  │                           │          Console             │
│  proj B    │  ─────────────────────    │  Code:   Files · Editor ·    │
│  proj C    │  composer (auto-grow,     │          Terminal · Preview  │
│            │  Stop while running)      │                              │
└────────────┴───────────────────────────┴──────────────────────────────┘
   top bar:  ● Local Builder   [ Chat | Cowork | Code ]   ⌄ model   ⚙
```

- **Top bar:** product mark · **mode switch (Chat/Cowork/Code)** · model picker · settings.
- **Preview pane:** blob-URL iframe (sandboxed) · **Refresh** · loading spinner · device-width toggle (desktop/mobile) · open-in-browser · the injected Tailwind+shadcn design system.
- **Code pane:** streams the code **as it's written** (P0, shipped); read-only now → light editor later.
- **Console pane (Cowork):** captures the preview iframe's `console.*` + errors.
- **Files / Editor / Terminal (Code):** file tree, an editor, a real terminal wired to the agent server with **approve-to-run** + output.

---

## 6. Composer & chat UX (P0 — "looks bad")

- Fix the clipped input: proper min-height, hint never cut off, comfortable padding.
- Auto-grow textarea · **Enter** sends · **Shift+Enter** newline · **Stop** button while generating.
- Roles clear, code in panes (not bubbles), task tracker inline, copy on any code block.
- Reasoning models: a collapsible "thinking" block, not raw `<think>` noise.
- Streaming feels alive (token-by-token); the activity pill shows progress, not raw code.

---

## 7. Architecture (local-first, secure)

- **Models:** Ollama (`localhost:11434`). Coder + reasoner; route by mode/task.
- **Server:** one small local process (today's `agent-server.py`) that serves the UI, exposes sandboxed tools, and manages per-project dirs. Bound to `127.0.0.1`, CORS-locked to the page, `no-store` while iterating.
- **Cowork preview:** blob-URL sandboxed iframe + injected Tailwind + shadcn tokens. The generated app is sandboxed *from* the agent (no `allow-same-origin`) so it can't call the tools.
- **Code mode safety:** workspace-confined, 30s command timeout, **approve-per-action**, obvious-danger warnings. Opt-in by design.
- **Design taste built in:** Tailwind + shadcn/tweakcn theme injected so even a 14B model outputs v0-grade UI; `--lean` prompt to keep output tight.

---

## 8. Roadmap / phasing

**P0 — make today's builder *good* (this week)**
- ✅ Activity-in-chat (not raw code) · ✅ live code streaming into the Code pane · ✅ blob-URL preview + Refresh + loading.
- ▢ Fix the composer (clipped input, Stop button).
- ▢ **Per-project isolation** (building/preview/app/tasks scoped per chat).
- ▢ **Task tracker** (plan → ○◐✓ statuses, honest tense) in Cowork.

**P1 — the three modes**
- ▢ Mode switch (Chat / Cowork / Code) with per-mode panels.
- ▢ **Code mode** on the agent server: file tree, terminal, multi-step traceable agent, approve-to-run.
- ▢ Honest in-progress tense everywhere; Stop/interrupt.

**P2 — polish toward parity**
- ▢ Multi-file Cowork projects · device-frame preview · Console pane · export project as a folder/zip/repo.
- ▢ Model routing (reasoner plans, coder writes) · starter templates.

**P3 — reach**
- ▢ Remote/mobile via **PersonalDispatch** (text/PWA your local builder from your phone).
- ▢ Publish as its own public repo (see §9).

---

## 9. Open decisions (recommendations first)

1. **Extract into its own product/repo?** *Recommend: yes, after P1.* The builder is outgrowing `local-llm-setup` (an *installer*). Once it has modes + Code mode it deserves `local-builder` as its own public repo, bootstrapped by `local-llm-setup --build`. Keeps the installer dependency-free; lets the builder grow.
2. **Code editor:** light embedded editor (CodeMirror — a dependency, but huge UX) vs read-only Code pane. *Recommend: read-only through P1, editor in P2.*
3. **Agent autonomy default:** approve-everything vs approve-only-dangerous. *Recommend: approve-everything by default (safe), with a per-project "trust this project" toggle later.*
4. **Single-file vs multi-file Cowork:** *Recommend: single-file through P1 (covers ~80% of "build me a X"), multi-file in P2.*

---

## 10. Success criteria

- A **first-timer** builds a working, good-looking web app in **< 2 min**, watches it render, and iterates by chatting — entirely offline.
- A **developer** runs an agentic multi-file task and **sees a traceable plan** (○◐✓) with approve-to-run tools, never a "done" that wasn't.
- **Per-project** state is fully isolated; switching projects switches everything.
- **Nothing leaves the machine.**

---

## 11. Non-goals (for now)

- Cloud sync / accounts / collaboration. (Local-first is the point.)
- Beating frontier models on raw capability — we win on *privacy + cost + control*, and close the quality gap with harness taste, not model size.
- A general IDE. Code mode is an *agent workspace*, not a VS Code replacement.
