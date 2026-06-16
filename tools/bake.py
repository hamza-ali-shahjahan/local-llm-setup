#!/usr/bin/env python3
"""Bake the live builder into the installer scripts.

The two installers (local-llm-setup.sh / .ps1) EMBED the builder page and the
agent server verbatim inside literal heredocs / here-strings, so a one-command
install needs no network for the UI. This tool splices the current source of
truth into both scripts so they can never drift.

Source of truth (the running, dogfooded instance):
    ~/.local-llm-setup/chat/index.html
    ~/.local-llm-setup/agent-server.py

It is marker-driven and asserts every marker is found exactly once — it fails
loudly rather than producing a half-spliced script. Run from the repo root:
    python3 tools/bake.py            # bake
    python3 tools/bake.py --check    # verify embedded == source, change nothing
"""
import sys, pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = pathlib.Path.home() / ".local-llm-setup"
HTML = (SRC / "chat" / "index.html").read_text()
PY = (SRC / "agent-server.py").read_text()
if not HTML.endswith("\n"): HTML += "\n"
if not PY.endswith("\n"): PY += "\n"


def splice(text, start_pred, end_line, body, label):
    """Replace the lines strictly between the start marker and the end marker
    line with `body`. Keeps both marker lines. Asserts a unique, well-formed
    block so a missing/duplicated marker is a hard error, never a silent splice."""
    lines = text.splitlines(keepends=True)
    starts = [i for i, ln in enumerate(lines) if start_pred(ln)]
    assert len(starts) == 1, f"{label}: expected 1 start marker, found {len(starts)}"
    s = starts[0]
    ends = [i for i in range(s + 1, len(lines)) if lines[i].rstrip("\n") == end_line]
    assert ends, f"{label}: no end marker {end_line!r} after start"
    e = ends[0]
    return "".join(lines[: s + 1]) + body + "".join(lines[e:])


def extract(text, start_pred, end_line):
    lines = text.splitlines(keepends=True)
    s = next(i for i, ln in enumerate(lines) if start_pred(ln))
    e = next(i for i in range(s + 1, len(lines)) if lines[i].rstrip("\n") == end_line)
    return "".join(lines[s + 1 : e])


# (file, start predicate, end-marker line, body) for each embedded block
JOBS = {
    "local-llm-setup.sh": [
        (lambda ln: ln.strip() == "cat > \"$1\" <<'CHATHTML'", "CHATHTML", HTML, "sh/html"),
        (lambda ln: ln.strip() == "cat > \"$1\" <<'AGENTPY'", "AGENTPY", PY, "sh/py"),
    ],
    "local-llm-setup.ps1": [
        (lambda ln: ln.strip() == "$html = @'", "'@", HTML, "ps1/html"),
        (lambda ln: ln.strip() == "$py = @'", "'@", PY, "ps1/py"),
    ],
}


def main():
    check = "--check" in sys.argv
    ok = True
    for fname, jobs in JOBS.items():
        fp = REPO / fname
        text = fp.read_text()
        for pred, end, body, label in jobs:
            if check:
                got = extract(text, pred, end)
                same = got == body
                ok = ok and same
                print(f"  {label}: {'✓ in sync' if same else '✗ DRIFT'} ({len(got.splitlines())} lines embedded)")
            else:
                text = splice(text, pred, end, body, label)
        if not check:
            fp.write_text(text)
            print(f"baked -> {fname} ({len(text.splitlines())} lines)")
    if check and not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
