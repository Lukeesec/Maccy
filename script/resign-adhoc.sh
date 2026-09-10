#!/usr/bin/env bash
#
# Re-sign a built Maccy.app ad-hoc with the fork's entitlements.
#
# This is done after the build rather than by overriding CODE_SIGN_ENTITLEMENTS on
# the xcodebuild command line: a command-line override applies to every target in
# the build, including the SwiftPM dependency targets, which then resolve the
# relative path against their own source roots and fail with
# "Build input file cannot be found".
#
# Nested code is signed first, deepest first, because a bundle's signature covers
# its contents.
#
# Usage: script/resign-adhoc.sh <path to Maccy.app> <path to entitlements>

set -euo pipefail

APP="${1:?usage: resign-adhoc.sh <app> <entitlements>}"
ENT="${2:?usage: resign-adhoc.sh <app> <entitlements>}"

[[ -d "$APP" ]] || { echo "error: no such app: $APP" >&2; exit 1; }
[[ -f "$ENT" ]] || { echo "error: no such entitlements: $ENT" >&2; exit 1; }

if [[ -d "$APP/Contents/Frameworks" ]]; then
  while IFS= read -r nested; do
    codesign --force --sign - --timestamp=none "$nested"
  done < <(find "$APP/Contents/Frameworks" -depth \
             \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "Autoupdate" \))
fi

# No --options runtime: the hardened runtime enables library validation, which an
# ad-hoc signature cannot satisfy for embedded frameworks.
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
echo "re-signed ad-hoc: $APP"
