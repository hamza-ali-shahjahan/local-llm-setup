#!/usr/bin/env python3
"""Materialize the embedded builder OUT of the installer, into ~/.local-llm-setup.

The reverse of tools/bake.py. bake.py splices the dogfood source of truth
(~/.local-llm-setup/{chat/index.html,agent-server.py}) INTO both installers; this pulls
it back out of local-llm-setup.sh. That lets a fresh checkout — or CI, which has no
dogfood instance — import the agent server and run the test suite against exactly the
code that ships. Respects $HOME, so CI writes to the runner's home and tests read it.

    python3 tools/materialize.py
"""
import os, pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = pathlib.Path.home() / ".local-llm-setup"


def extract(text, start_line, end_line):
    lines = text.splitlines(keepends=True)
    s = next(i for i, ln in enumerate(lines) if ln.strip() == start_line)
    e = next(i for i in range(s + 1, len(lines)) if lines[i].rstrip("\n") == end_line)
    return "".join(lines[s + 1:e])


def main():
    sh = (REPO / "local-llm-setup.sh").read_text()
    html = extract(sh, "cat > \"$1\" <<'CHATHTML'", "CHATHTML")
    py = extract(sh, "cat > \"$1\" <<'AGENTPY'", "AGENTPY")
    (SRC / "chat").mkdir(parents=True, exist_ok=True)
    (SRC / "chat" / "index.html").write_text(html)
    (SRC / "agent-server.py").write_text(py)
    print("materialized -> %s  (index.html %d lines, agent-server.py %d lines)"
          % (SRC, html.count(chr(10)), py.count(chr(10))))


if __name__ == "__main__":
    main()
