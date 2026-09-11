#!/usr/bin/env bash
#
# Build this fork and install it over the copy in /Applications.
#
# The build is ad-hoc signed. That is enough to run locally, but macOS keys
# Accessibility permission to the signature, so the first launch after switching
# from a stock (Developer ID signed) Maccy needs the permission re-granted. See
# FORK.md.
#
# Usage:
#   script/build-and-install.sh              build, then install over /Applications
#   script/build-and-install.sh --build-only build only, print where the .app landed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$REPO_ROOT/.build/DerivedData"
APP_DEST="/Applications/Maccy.app"
BUILD_ONLY=0

[[ "${1:-}" == "--build-only" ]] && BUILD_ONLY=1

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

# --- preflight ---------------------------------------------------------------

DEVELOPER_DIR_ACTIVE="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEVELOPER_DIR_ACTIVE" != *".app/Contents/Developer" ]]; then
  die "full Xcode is required (active toolchain: ${DEVELOPER_DIR_ACTIVE:-none}).
       Command Line Tools alone cannot build Maccy: it has no actool for
       Assets.xcassets and no momc for Storage.xcdatamodeld.

       Install Xcode, then:
         sudo xcode-select -s /Applications/Xcode.app
         sudo xcodebuild -license accept"
fi

xcodebuild -version >/dev/null 2>&1 || die "xcodebuild is not usable. Try: sudo xcodebuild -license accept"

# --- build -------------------------------------------------------------------

step "Building Maccy (Release, ad-hoc signed)"
xcodebuild \
  -project "$REPO_ROOT/Maccy.xcodeproj" \
  -scheme Maccy \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=NO \
  build

APP_BUILT="$DERIVED/Build/Products/Release/Maccy.app"
[[ -d "$APP_BUILT" ]] || die "build reported success but $APP_BUILT is missing"

step "Re-signing ad-hoc with fork entitlements"
"$REPO_ROOT/script/resign-adhoc.sh" "$APP_BUILT" "$REPO_ROOT/Maccy/Maccy-adhoc.entitlements"

# Hardened runtime turns on library validation, which requires every embedded
# library to share the app's Team ID. An ad-hoc signature has none, so
# Sparkle.framework fails to map and the app aborts at launch with a dyld
# "Library missing" error.
FLAGS="$(codesign -dv --verbose=4 "$APP_BUILT" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p')"
case "$FLAGS" in
  *runtime*) die "built app has the hardened runtime flag ($FLAGS) under an ad-hoc
       signature; it would abort at launch. ENABLE_HARDENED_RUNTIME=NO did not
       take effect." ;;
esac

if codesign -d --entitlements - --xml "$APP_BUILT" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  die "built app carries the app-sandbox entitlement under an ad-hoc signature;
       it would hang at launch in _libsecinit_appsandbox.
       CODE_SIGN_ENTITLEMENTS=Maccy/Maccy-adhoc.entitlements did not take effect."
fi

BUILT_VERSION="$(defaults read "$APP_BUILT/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
step "Built Maccy $BUILT_VERSION at $APP_BUILT"

if (( BUILD_ONLY )); then
  echo "Stopping here (--build-only). Nothing in /Applications was touched."
  exit 0
fi

# --- install -----------------------------------------------------------------

if command -v brew >/dev/null 2>&1 && brew list --cask maccy >/dev/null 2>&1; then
  die "Homebrew still manages Maccy. Detach it first so brew does not overwrite
       this build (your clipboard history and settings are NOT touched):
         brew uninstall --cask maccy
       then re-run this script."
fi

# Stop first: the Core Data store may be in WAL mode and cannot be copied safely
# while the process still has it open.
quit_maccy

step "Migrating data out of the sandbox container if needed"
"$(dirname "${BASH_SOURCE[0]}")/migrate-container-data.sh"

if [[ -d "$APP_DEST" ]]; then
  BACKUP="/Applications/Maccy.app.backup-$(date +%Y%m%d-%H%M%S)"
  step "Backing up the current app to $BACKUP"
  mv "$APP_DEST" "$BACKUP"
fi

step "Installing to $APP_DEST"
ditto "$APP_BUILT" "$APP_DEST"

step "Launching"
open "$APP_DEST"

cat <<EOF

Done. Running Maccy $BUILT_VERSION.

History and settings live at ~/Library/Application Support/Maccy and
~/Library/Preferences/org.p0deje.Maccy.plist. These builds are not sandboxed --
an ad-hoc signature cannot satisfy the App Sandbox -- so they do not use
~/Library/Containers/org.p0deje.Maccy. Your data was copied out of that
container, which is left intact, so reverting to stock Maccy still finds it.

One-time step: this build is ad-hoc signed, so macOS treats it as a new app for
privacy purposes. Pasting will not work until you re-grant Accessibility:

  System Settings > Privacy & Security > Accessibility
  Remove the old Maccy entry if present, then add /Applications/Maccy.app

EOF
