#!/usr/bin/env bash
#
# Omarchy Hold'em installer — no-limit Texas Hold'em for the Omarchy shell.
#
# Run it from a clone of the repo:  ./install.sh
#
# What it does:
#   1. Registers the plugin (omarchy plugin add — never a file copy, or
#      `omarchy plugin update` could never fast-forward it later).
#   2. Enables it and places the bar icon on the right.
#
# There is nothing else to install: the deck ships in the repo and the game
# needs nothing beyond what Omarchy already has, so `omarchy plugin add` on its
# own works fine too.
#
# Overrides:
#   HOLDEM_REPO=user/repo    register the plugin from a different repo
#   HOLDEM_SECTION=left|center|right   where the bar icon lands
set -euo pipefail

REPO="${HOLDEM_REPO:-cfryerdev/OmarchyPoker}"
SECTION="${HOLDEM_SECTION:-right}"
PLUGIN_ID="cfryerdev.omarchyholdem"
# The plugin shipped as nosignal.omarchyholdem before 1.0.0; that id is
# retired on the marketplace, so migrate any old registration aside.
LEGACY_ID="nosignal.omarchyholdem"

say() { printf '%s\n' "$*"; }

if ! command -v omarchy >/dev/null 2>&1; then
  say "This needs Omarchy 4 (the omarchy CLI is not on PATH)."
  exit 1
fi

# Already installed under the retired id? Then this is an update that also
# finishes the 1.0.0 rename: swap the registration, keeping the bar section.
if omarchy plugin list 2>/dev/null | grep -q "^${LEGACY_ID}[[:space:]]"; then
  say "==> ${LEGACY_ID} is installed; migrating it to ${PLUGIN_ID}"
  omarchy plugin remove "$LEGACY_ID" --yes
  omarchy plugin add "https://github.com/${REPO}" --yes
elif omarchy plugin list 2>/dev/null | grep -q "^${PLUGIN_ID}[[:space:]]"; then
  say "==> ${PLUGIN_ID} is already installed; updating"
  omarchy plugin update "$PLUGIN_ID"
else
  say "==> Registering ${PLUGIN_ID} from ${REPO}"
  # --yes only when there is no terminal to prompt on: with a TTY the user
  # gets the placement prompt they would get from a bare `plugin add`.
  if [ -t 0 ] && [ -t 1 ]; then
    omarchy plugin add "https://github.com/${REPO}"
  else
    omarchy plugin add "https://github.com/${REPO}" --yes
  fi
fi

say "==> Enabling and placing the bar icon (${SECTION})"
omarchy plugin enable "$PLUGIN_ID" --section "$SECTION" || true
# A fresh unattended add can race the registry's rescan and land the widget in
# center regardless of defaultSection, so place it explicitly afterwards.
omarchy bar move "$PLUGIN_ID" --section "$SECTION" >/dev/null 2>&1 || true

say ""
say "Done. Click the card icon in the bar, or bind a key to:"
say "  omarchy-shell shell toggle ${PLUGIN_ID}"
