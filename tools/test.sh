#!/usr/bin/env bash
# Run the builder/agent test suite (stdlib unittest — no test framework to install).
#
# Tests are deterministic and offline: screenshots render local HTML fixtures via
# file://, git-sync runs in temp dirs, no network or API keys needed. To exercise the
# PRIMARY screenshot path (Playwright's managed Chromium) we use a local .venv; without
# it the suite still passes by skipping the two Playwright-only capture tests and using
# the system-Chrome subprocess fallback.
#
#   tools/test.sh            # bootstrap .venv (+ Playwright) if possible, then run
#   tools/test.sh --system   # run with the system python3 only (no venv bootstrap)
set -euo pipefail
cd "$(dirname "$0")/.."

PY="python3"
if [ "${1:-}" != "--system" ]; then
  if [ ! -x ".venv/bin/python" ]; then
    echo "• creating .venv and installing Playwright (one-time)…"
    python3 -m venv .venv
    ./.venv/bin/python -m pip install --quiet --upgrade pip playwright
    ./.venv/bin/python -m playwright install chromium
  fi
  PY="./.venv/bin/python"
fi

echo "• bake check (installers embed the live builder verbatim)"
python3 tools/bake.py --check

echo "• running tests with: $PY"
exec "$PY" -m unittest discover -s tests -v
