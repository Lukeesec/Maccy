#!/usr/bin/env bash
#
# Install a Maccy.app built by the "Build fork" GitHub Actions workflow.
# Needs no Xcode — only Command Line Tools, which every Mac with git already has.
#
# Usage:
#   script/install-artifact.sh                  # fetch the latest CI build via gh
#   script/install-artifact.sh ~/Downloads/Maccy.zip

set -euo pipefail

APP_DEST="/Applications/Maccy.app"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# --- obtain the zip ----------------------------------------------------------

ZIP="${1:-}"

if [[ -z "$ZIP" ]]; then
  command -v gh >/dev/null 2>&1 || die "gh is not installed. Pass a downloaded zip instead:
       script/install-artifact.sh ~/Downloads/Maccy.zip"

  step "Downloading the latest successful CI build"
  RUN_ID="$(gh run list --workflow=build-fork.yml --status=success --limit=1 --json databaseId --jq '.[0].databaseId')"
  [[ -n "$RUN_ID" ]] || die "no successful 'Build fork' run found. Check: gh run list --workflow=build-fork.yml"

  gh run download "$RUN_ID" --name Maccy-spotlight --dir "$WORKDIR"
  ZIP="$WORKDIR/Maccy.zip"
fi

[[ -f "$ZIP" ]] || die "no such file: $ZIP"

# --- unpack ------------------------------------------------------------------

step "Unpacking $ZIP"
ditto -x -k "$ZIP" "$WORKDIR/unpacked"
APP_SRC="$WORKDIR/unpacked/Maccy.app"
[[ -d "$APP_SRC" ]] || die "the zip did not contain Maccy.app"

# Anything downloaded from the internet carries a quarantine flag, and this build
# is ad-hoc signed rather than notarized, so Gatekeeper would refuse to open it.
step "Clearing the quarantine flag"
xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true

step "Checking the signature"
codesign --verify --strict "$APP_SRC" || die "signature does not verify; refusing to install"

VERSION="$(defaults read "$APP_SRC/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
echo "Maccy $VERSION"

# --- install -----------------------------------------------------------------

if brew list --cask maccy >/dev/null 2>&1; then
  die "Homebrew still manages Maccy. Detach it first so brew cannot overwrite
       this build (clipboard history and settings are NOT touched):
         brew uninstall --cask maccy
       then re-run this script."
fi

step "Migrating data out of the sandbox container if needed"
"$(dirname "${BASH_SOURCE[0]}")/migrate-container-data.sh"

step "Quitting Maccy if it is running"
osascript -e 'tell application "Maccy" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  pgrep -x Maccy >/dev/null 2>&1 || break
  sleep 0.25
done
pgrep -x Maccy >/dev/null 2>&1 && { pkill -x Maccy || true; sleep 1; }

if [[ -d "$APP_DEST" ]]; then
  BACKUP="/Applications/Maccy.app.backup-$(date +%Y%m%d-%H%M%S)"
  step "Backing up the current app to $BACKUP"
  mv "$APP_DEST" "$BACKUP"
fi

step "Installing to $APP_DEST"
ditto "$APP_SRC" "$APP_DEST"

step "Launching"
open "$APP_DEST"

cat <<EOF

Done. Running Maccy $VERSION.

Clipboard history and settings are untouched: the bundle identifier is unchanged,
so this build reads the same container (~/Library/Containers/org.p0deje.Maccy).

One-time step: this build is ad-hoc signed, so macOS treats it as a new app for
privacy purposes. Pasting will not work until you re-grant Accessibility:

  System Settings > Privacy & Security > Accessibility
  Remove the old Maccy entry if present, then add /Applications/Maccy.app

EOF
