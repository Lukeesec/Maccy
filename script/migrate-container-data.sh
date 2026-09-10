#!/usr/bin/env bash
#
# One-time migration from the sandbox container to the unsandboxed locations.
#
# Fork builds are ad-hoc signed and therefore cannot be sandboxed (see
# Maccy/Maccy-adhoc.entitlements). An unsandboxed Maccy reads:
#
#   history      ~/Library/Application Support/Maccy/Storage.sqlite
#   preferences  ~/Library/Preferences/org.p0deje.Maccy.plist
#
# whereas the sandboxed App Store / Homebrew build reads the same paths redirected
# into ~/Library/Containers/org.p0deje.Maccy/Data.
#
# This copies, never moves: the container is left untouched so that reverting to
# stock Maccy restores the original history and settings.
#
# Idempotent. Refuses to overwrite a destination that already holds more history
# than the container, so re-running after you have used the fork is harmless.

set -euo pipefail

CONTAINER="$HOME/Library/Containers/org.p0deje.Maccy/Data"
SRC_DB="$CONTAINER/Library/Application Support/Maccy/Storage.sqlite"
SRC_PREFS="$CONTAINER/Library/Preferences/org.p0deje.Maccy.plist"
DEST_DIR="$HOME/Library/Application Support/Maccy"
DEST_DB="$DEST_DIR/Storage.sqlite"
DEST_PREFS="$HOME/Library/Preferences/org.p0deje.Maccy.plist"

step() { printf '\n==> %s\n' "$*"; }

count_items() {
  [[ -f "$1" ]] || { echo 0; return; }
  sqlite3 "$1" "select count(*) from ZHISTORYITEM;" 2>/dev/null || echo 0
}

if [[ ! -f "$SRC_DB" ]]; then
  step "No sandbox container found; nothing to migrate"
  exit 0
fi

SRC_N="$(count_items "$SRC_DB")"
DEST_N="$(count_items "$DEST_DB")"

step "History: container has $SRC_N item(s), unsandboxed store has $DEST_N"

if (( DEST_N >= SRC_N )) && (( DEST_N > 0 )); then
  echo "Unsandboxed store is already at least as full. Leaving it alone."
else
  if [[ -e "$DEST_DIR" ]]; then
    ASIDE="$DEST_DIR.superseded-$(date +%Y%m%d-%H%M%S)"
    step "Moving the existing store aside to $ASIDE"
    mv "$DEST_DIR" "$ASIDE"
  fi

  step "Copying history out of the container"
  mkdir -p "$DEST_DIR"
  cp -p "$SRC_DB" "$DEST_DB"
  for suffix in -wal -shm; do
    [[ -f "$SRC_DB$suffix" ]] && cp -p "$SRC_DB$suffix" "$DEST_DB$suffix"
  done
  echo "Migrated $(count_items "$DEST_DB") item(s)."
fi

if [[ -f "$SRC_PREFS" && ! -f "$DEST_PREFS" ]]; then
  step "Copying preferences out of the container"
  cp -p "$SRC_PREFS" "$DEST_PREFS"
  # cfprefsd caches aggressively; without this the app reads stale defaults.
  killall cfprefsd 2>/dev/null || true
else
  step "Preferences already present outside the container; leaving them alone"
fi

step "Done. The container was not modified, so reverting to stock Maccy still works."
