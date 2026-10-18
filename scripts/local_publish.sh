#!/usr/bin/env bash
#
# Local publish — sync this repo into your Omarchy plugin directory and
# restart the shell, exactly the dev loop for a plugin installed as a local
# copy: edit, publish, table comes back with the change.
#
#   ./scripts/local_publish.sh              # test, sync, restart the shell
#   ./scripts/local_publish.sh --no-restart # sync only; restart when you like
#   ./scripts/local_publish.sh --no-tests   # skip the engine test suite
#
# What it does:
#   1. Runs the engine test suite (tests/poker-test.js) unless told not to.
#      A failing test stops the publish — the table never gets a broken deal.
#   2. rsyncs the repo into the plugin directory, deleting anything there
#      that the repo no longer has, so the copy is exactly the repo.
#   3. Restarts omarchy-shell to load the new QML.
#
# Overrides:
#   HOLDEM_DEST=/path/to/plugins/nosignal.omarchyholdem   where it publishes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOLDEM_DEST:-$HOME/.config/omarchy/plugins/nosignal.omarchyholdem}"
RUN_TESTS=1
RESTART=1

for arg in "$@"; do
  case "$arg" in
    --no-tests) RUN_TESTS=0 ;;
    --no-restart) RESTART=0 ;;
    *) echo "local_publish: unknown flag $arg" >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }

if [ "$RUN_TESTS" = 1 ]; then
  if command -v node >/dev/null 2>&1; then
    say "==> Engine tests"
    (cd "$ROOT" && node tests/poker-test.js)
  else
    say "==> node not found; skipping engine tests"
  fi
fi

say "==> Syncing ${ROOT} -> ${DEST}"
mkdir -p "$DEST"
rsync -a --delete --exclude .git "$ROOT/" "$DEST/"

if [ "$RESTART" = 1 ]; then
  say "==> Restarting omarchy-shell"
  omarchy-restart-shell
  say ""
  say "Done. Click the ♠ in the bar, or:"
  say "  omarchy-shell shell toggle nosignal.omarchyholdem"
else
  say ""
  say "Done (no restart). Pick it up with:"
  say "  omarchy-restart-shell"
fi
