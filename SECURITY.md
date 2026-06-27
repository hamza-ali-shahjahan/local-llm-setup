# Security Policy

## The short version

The **installer** is a single Bash (or PowerShell) script that sets up a runtime (Ollama) and downloads open models to **your** machine — it sends nothing to any third party and handles no secrets. The optional **builder / agent server** (`--chat` / `--agent`) is a local Python server that adds opt-in tools; those reach the network only when *you* invoke them — keyless **web search** sends your query to a search engine (DuckDuckGo by default, or a self-hosted SearXNG via `LLM_SEARCH_URL`), `fetch`/`inspect` load public URLs you point them at, and a **deployed** app is exposed to your LAN only if you choose `host: 0.0.0.0`. Deployed-app passwords are PBKDF2-hashed **locally** and never leave your machine.

**Always read a script before you run it.** The [Quick Start](README.md#quick-start) deliberately downloads the file first so you can inspect it, and `./local-llm-setup.sh --dry-run` prints every action it would take without executing anything.

## Agent mode — the threat surface to know

Agent mode (`--agent`) is **off by default and consented**. With it on, the model can run shell commands and write files — and **an approved command is not sandboxed** (an approved `rm -rf ~` still runs). The UI approval prompt is the guardrail: approve only what you understand. Read-only tools (`read` / `fetch` / `inspect` / `search` / `screenshot`) run without a prompt; the network ones are **SSRF-guarded** — http/https and public hosts only, with loopback / private / link-local / metadata addresses blocked, including across redirects. The agent server binds `127.0.0.1` and is origin-locked to the builder page.

## Reporting a vulnerability

If you find a security issue — for example a way the script could be tricked into running unintended commands — please **do not open a public issue**. Email **mail.hamza.ali@gmail.com** with:

- A description of the issue and its impact
- Steps to reproduce
- Any suggested fix

You can expect an acknowledgement within a few days. Thank you for reporting responsibly.

## Supported versions

This is a single-file tool; only the latest version on the `main` branch is supported. Pull the newest copy before reporting.
