# Security Policy

## The short version

This is a small Bash script that installs a runtime (Ollama) and downloads open models to **your** machine. It sends nothing to any third party, handles no secrets, and runs entirely locally.

**Always read a script before you run it.** The [Quickstart](README.md#quickstart) deliberately downloads the file first so you can inspect it, and `./local-llm-setup.sh --dry-run` prints every action it would take without executing anything.

## Reporting a vulnerability

If you find a security issue — for example a way the script could be tricked into running unintended commands — please **do not open a public issue**. Email **mail.hamza.ali@gmail.com** with:

- A description of the issue and its impact
- Steps to reproduce
- Any suggested fix

You can expect an acknowledgement within a few days. Thank you for reporting responsibly.

## Supported versions

This is a single-file tool; only the latest version on the `main` branch is supported. Pull the newest copy before reporting.
