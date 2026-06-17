#!/usr/bin/env bash
# Hard-timeout wrapper (macOS has no coreutils `timeout`). Kills the command if it
# runs longer than N seconds so a stalled Playwright/Chromium launch, vhs record, or
# any long step can't hang the session indefinitely.
#
#   tools/run-timeout.sh <seconds> <command> [args...]
# Exit code: the command's own, or 124 if it was killed for exceeding the limit.
set -u
secs="$1"; shift
"$@" &
pid=$!
( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
watcher=$!
wait "$pid"; rc=$?
# if the watcher already exited, the sleep elapsed -> we timed out
if ! kill -0 "$watcher" 2>/dev/null; then
  echo "run-timeout: '$*' exceeded ${secs}s — killed" >&2
  rc=124
else
  kill "$watcher" 2>/dev/null
fi
exit $rc
