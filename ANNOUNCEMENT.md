# 📣 Your locally-built apps just got a backend

`local-llm-setup` turns one command into a private, on-device AI dev environment: Ollama + the
right coder/reasoner models for your machine, plus a Lovable/v0-style app builder with live
preview — running **100% locally**. No cloud, no API keys, no per-token bill.

The headline of this wave: **the apps you build now get a real backend — and it never leaves your
machine.**

## 🗄️ Build a real app, deploy it locally, and it remembers

Build an app from a chat box, hit **🚀 Deploy**, and it comes up on a real local URL with a real
backend — **zero setup, no config, no cloud**:

- **A database** — a SQLite-backed JSON store (`/api/data/<collection>`), so a todo list, notes app
  or guestbook actually *persists* across visits.
- **Real logins** — signup / login / sessions (`/api/auth/…`), with **PBKDF2-hashed** passwords and
  **HttpOnly, SameSite=Strict** cookies.
- **A 🗄️ Data panel** in the builder to browse, edit and clean it all — collections row-by-row and
  user accounts (passwords are never shown).

It's stdlib SQLite, **same-origin**, bound to localhost — **secure by construction**: no CORS, the
raw database is never web-served, and removing a user signs them out everywhere. Just ask for
*"a notes app with logins that saves my notes,"* deploy it, and it works.
(Full reference: **[docs/backend.md](docs/backend.md)**.)

## ✨ The rest of the wave

- 🔎 **Keyless web search** — the builder can look things up (DuckDuckGo by default, or point it at
  your own self-hosted SearXNG). No API key.
- 🚀 **One-click local deploy** — your app on a real `http://` URL that keeps running after you close
  the builder; the agent can build *and* deploy in one turn.
- 🔌 **MCP support** — connect Model Context Protocol servers (filesystem, git, search, your own) and
  the agent uses their tools. **Parity with Claude Code, fully local.**
- 🎯 **Goal-limits dashboard** — the honest record of what your local setup actually reaches per task.
- 📚 **Visual RAG** — add pages/images and ask questions answered from how they *look*, not just their
  text.

## 🔒 Why it matters

Every other local app-builder is BYO-API-key, and the apps they generate forget everything. This is
keyless and offline by default — and now the apps you build can be *real* (data, accounts, the lot)
without anything ever leaving your hardware.

## 🚀 Try it

One command (macOS / Linux / native Windows) — see the **[README](README.md)**. Then open the builder
(`./local-llm-setup.sh --agent`), build something that saves data, and hit **🚀 Deploy**.

> **Honest note:** this is your machine's backend, not a hosted one — to put an app on the public
> internet you bring your own host. And we keep an honest scorecard: multi-file projects, image
> generation, and arbitrary server-side logic are the next frontiers, not faked.

*Full history: **[CHANGELOG.md](CHANGELOG.md)**.*
