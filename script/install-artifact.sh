#!/usr/bin/env bash
# Install the latest published Spotlight-fork release, or a supplied Maccy.zip.
# No GitHub account, GitHub CLI, or Xcode is required.

set -euo pipefail

APP_DEST="/Applications/Maccy.app"
RELEASE_BASE="${MACCY_RELEASE_BASE_URL:-https://github.com/Lukeesec/Maccy/releases/latest/download}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

quit_maccy() {
  if ! pgrep -x Maccy >/dev/null 2>&1; then
    return
  fi

  step "Quitting Maccy before reading or replacing its data"
  osascript -e 'tell application "Maccy" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x Maccy >/dev/null 2>&1 || return 0
    sleep 0.25
  done

  pkill -x Maccy >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x Maccy >/dev/null 2>&1 || return 0
    sleep 0.25
  done

  die "Maccy is still running; quit it manually and run the installer again"
}

OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ ! "$OS_MAJOR" =~ ^[0-9]+$ ]] || (( OS_MAJOR < 14 )); then
  die "Maccy requires macOS 14 or newer (this Mac reports $(sw_vers -productVersion))"
fi

ZIP="${1:-}"
if [[ -z "$ZIP" ]]; then
  command -v curl >/dev/null 2>&1 || die "curl is required to download the release"
  command -v shasum >/dev/null 2>&1 || die "shasum is required to verify the release"

  step "Downloading the latest public release"
  curl --fail --location --retry 3 --show-error \
    "$RELEASE_BASE/Maccy.zip" --output "$WORKDIR/Maccy.zip"
  curl --fail --location --retry 3 --show-error \
    "$RELEASE_BASE/Maccy.zip.sha256" --output "$WORKDIR/Maccy.zip.sha256"

  step "Checking the published SHA-256 checksum"
  (cd "$WORKDIR" && shasum -a 256 --check Maccy.zip.sha256) || \
    die "release checksum does not match; refusing to install"
  ZIP="$WORKDIR/Maccy.zip"
fi

[[ -f "$ZIP" ]] || die "no such file: $ZIP"

step "Unpacking $ZIP"
ditto -x -k "$ZIP" "$WORKDIR/unpacked"
APP_SRC="$WORKDIR/unpacked/Maccy.app"
[[ -d "$APP_SRC" ]] || die "the zip did not contain Maccy.app"

INFO_PLIST="$APP_SRC/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || die "the app is missing Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "org.p0deje.Maccy" ]] || \
  die "unexpected bundle identifier '${BUNDLE_ID:-missing}'; refusing to install"
[[ -n "$VERSION" ]] || die "the app has no version metadata; refusing to install"
[[ -n "$BUILD" ]] || die "the app has no build metadata; refusing to install"

step "Clearing the quarantine flag"
xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true

step "Checking the app signature"
codesign --verify --deep --strict "$APP_SRC" || \
  die "signature does not verify; refusing to install"

APP_BINARY="$APP_SRC/Contents/MacOS/Maccy"
[[ -f "$APP_BINARY" ]] || die "the app executable is missing"
ARCHITECTURES="$(lipo -archs "$APP_BINARY")"
HOST_ARCH="$(uname -m)"
case " $ARCHITECTURES " in
  *" $HOST_ARCH "*) ;;
  *) die "this release does not support $HOST_ARCH (contains: $ARCHITECTURES)" ;;
esac

echo "Maccy $VERSION ($BUILD), architectures: $ARCHITECTURES"

if command -v brew >/dev/null 2>&1 && brew list --cask maccy >/dev/null 2>&1; then
  die "Homebrew still manages Maccy. Detach it first so brew cannot overwrite this build
       (clipboard history and settings are not touched):
         brew uninstall --cask maccy
       then run this installer again."
fi

# The source database may be in WAL mode. Stop the app before inspecting or
# copying any part of the store so the migration always sees a closed database.
quit_maccy

step "Migrating data out of the sandbox container if needed"
"$(dirname "${BASH_SOURCE[0]}")/migrate-container-data.sh"

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

Done. Running Maccy $VERSION ($BUILD).

History and settings live at ~/Library/Application Support/Maccy and
~/Library/Preferences/org.p0deje.Maccy.plist. The sandbox container was copied,
never moved or modified, so reverting to stock Maccy can still read it.

This release is ad-hoc signed and macOS treats it as a new app for privacy
purposes. Pasting will not work until you re-grant Accessibility:

  System Settings > Privacy & Security > Accessibility
  Remove the old Maccy entry if present, then add /Applications/Maccy.app

EOF
