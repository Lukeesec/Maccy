#!/usr/bin/env bash
#
# Flip a redesign variant and restart Maccy.
#
# This exists because `defaults write org.p0deje.Maccy ...` does NOT work for
# these builds. macOS still has a sandbox container registered for the bundle
# identifier, so `defaults` redirects domain writes into
# ~/Library/Containers/org.p0deje.Maccy/Data/Library/Preferences — while the
# unsandboxed fork reads ~/Library/Preferences/org.p0deje.Maccy.plist. Writes
# appear to succeed, `defaults read` even reflects them, and the app never sees
# them. Passing the plist path explicitly bypasses the redirect.
#
# Usage:
#   script/set-style.sh                       show current values
#   script/set-style.sh rowStyle oneLine
#   script/set-style.sh chrome stripped
#   script/set-style.sh selectionStyle neutralPill
#   script/set-style.sh grouping none

set -euo pipefail

PLIST="$HOME/Library/Preferences/org.p0deje.Maccy.plist"

KEYS=(forkRowStyle forkChrome forkSelectionStyle forkGrouping forkActions
      showApplicationIcons openPreviewAutomatically)

usage() {
  cat <<EOF
Variants:
  rowStyle          twoLine | oneLine | compact
  chrome            stripped | hintBar | menu
  selectionStyle    pill | neutralPill | bar
  grouping          byTime | none
  actions           searchRow | hintBar | none
  showIcons         true | false
  autoPreview       true | false

Pass "default" as the value to clear an override, e.g.
  script/set-style.sh rowStyle default
EOF
}

show() {
  echo "Current (from $PLIST):"
  for key in "${KEYS[@]}"; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || echo '(default)')"
    printf '  %-22s %s\n' "$key" "$value"
  done
}

if [[ $# -eq 0 ]]; then
  show; echo; usage; exit 0
fi

[[ $# -eq 2 ]] || { usage >&2; exit 1; }

case "$1" in
  rowStyle)       KEY=forkRowStyle ;;
  chrome)         KEY=forkChrome ;;
  selectionStyle) KEY=forkSelectionStyle ;;
  grouping)       KEY=forkGrouping ;;
  actions)        KEY=forkActions ;;
  autoPreview)    KEY=openPreviewAutomatically ;;
  showIcons)      KEY=showApplicationIcons ;;
  *) echo "unknown variant: $1" >&2; usage >&2; exit 1 ;;
esac

# Quit BEFORE writing. A running Maccy holds the domain in memory and can flush
# its cached copy over the new value on the way out, which looks exactly like the
# setting silently refusing to change.
osascript -e 'tell application "Maccy" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do pgrep -x Maccy >/dev/null 2>&1 || break; sleep 0.25; done
pgrep -x Maccy >/dev/null 2>&1 && { pkill -x Maccy || true; sleep 1; }

if [[ "$2" == "default" ]]; then
  defaults delete "$PLIST" "$KEY" 2>/dev/null || true
elif [[ "$KEY" == "showApplicationIcons" || "$KEY" == "openPreviewAutomatically" ]]; then
  defaults write "$PLIST" "$KEY" -bool "$2"
else
  defaults write "$PLIST" "$KEY" -string "$2"
fi

# cfprefsd caches aggressively; without this the app reads the old value straight
# back out of the cache.
killall cfprefsd 2>/dev/null || true
sleep 1

open /Applications/Maccy.app

echo
show
