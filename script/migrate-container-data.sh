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
# Idempotent. Never replaces a non-empty unsandboxed history store, so re-running
# after you have used the fork cannot roll back newer fork history.

set -euo pipefail

MACCY_USER_HOME="${MACCY_MIGRATION_HOME:-$HOME}"
CONTAINER="$MACCY_USER_HOME/Library/Containers/org.p0deje.Maccy/Data"
SRC_DB="$CONTAINER/Library/Application Support/Maccy/Storage.sqlite"
SRC_PREFS="$CONTAINER/Library/Preferences/org.p0deje.Maccy.plist"
DEST_DIR="$MACCY_USER_HOME/Library/Application Support/Maccy"
DEST_DB="$DEST_DIR/Storage.sqlite"
DEST_PREFS="$MACCY_USER_HOME/Library/Preferences/org.p0deje.Maccy.plist"

step() { printf '\n==> %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

count_items() {
  [[ -f "$1" ]] || { echo 0; return; }
  sqlite3 "$1" "select count(*) from ZHISTORYITEM;" 2>/dev/null ||
    die "cannot read history store: $1"
}

# SQLite uses a WAL while Maccy is running. Copying its three files independently
# can mix different points in time, so callers must close Maccy before migration.
pgrep -x Maccy >/dev/null 2>&1 &&
  die "Maccy is running. Quit it before migrating clipboard history."

if [[ ! -f "$SRC_DB" ]]; then
  step "No sandbox container found; nothing to migrate"
  exit 0
fi

SRC_N="$(count_items "$SRC_DB")"
DEST_N="$(count_items "$DEST_DB")"

step "History: container has $SRC_N item(s), unsandboxed store has $DEST_N"

if (( DEST_N > 0 )); then
  echo "Unsandboxed history already exists. Leaving it alone."
else
  if [[ -e "$DEST_DIR" ]]; then
    ASIDE="$DEST_DIR.superseded-$(date +%Y%m%d-%H%M%S)"
    step "Moving the existing store aside to $ASIDE"
    mv "$DEST_DIR" "$ASIDE"
  fi

  step "Creating a consistent history snapshot from the closed container store"
  mkdir -p "$DEST_DIR"
  # SQLite's backup command reads the database and any committed WAL pages as one
  # transaction. It does not write to the source container.
  sqlite3 "$SRC_DB" ".backup \"$DEST_DB\""
  [[ "$(sqlite3 "$DEST_DB" 'PRAGMA quick_check;')" == "ok" ]] ||
    die "the migrated history failed SQLite's integrity check"
  echo "Migrated $(count_items "$DEST_DB") item(s)."
fi

if [[ ! -f "$SRC_PREFS" ]]; then
  step "No sandbox preferences found; nothing to migrate"
elif [[ -f "$DEST_PREFS" ]]; then
  step "Preferences already present outside the container; leaving them alone"
else
  step "Copying preferences out of the container"
  cp -p "$SRC_PREFS" "$DEST_PREFS"
  # cfprefsd caches aggressively; without this the app reads stale defaults.
  killall cfprefsd 2>/dev/null || true
fi

step "Done. The container was not modified, so reverting to stock Maccy still works."
