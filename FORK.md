# Maccy — Spotlight fork

A personal fork of [p0deje/Maccy](https://github.com/p0deje/Maccy) with two changes:

1. **<kbd>Ctrl</kbd>+<kbd>C</kbd> copies.** It does exactly what <kbd>Enter</kbd>
   does — copies the highlighted item and closes the popup. <kbd>Enter</kbd> keeps
   working; this is an addition, not a replacement.
2. **The popup is restyled after macOS 26 Spotlight.** Borderless search field,
   taller rows, softer selection, and a panel that follows Dark/Light Mode instead
   of taking its cast from the wallpaper.

Everything else — history, settings, pins, previews, paste stacks, shortcuts — is
upstream's and unchanged.

Branched from upstream `master` at `c376789`, which is slightly ahead of the 2.7.1
release. That is deliberate: it picks up a post-2.7.1 fix for a CoreText hang on
macOS 26.

## What actually changed

| Area | Before | After |
|---|---|---|
| Search field | 23pt, filled grey box, 11pt glyph | 34pt, borderless on the glass, 16pt text, 15pt glyph |
| Row height | 24pt | 30pt |
| Selection | Hard accent block, forced white label | Soft accent tint, label keeps its normal colour |
| App icons | 15pt | 17pt |
| Corner radius | 7pt items / 12pt panel | 9pt items / 17pt panel |
| Glass | Untinted — reads light over a light wallpaper even in Dark Mode | Tinted toward `windowBackgroundColor`, so it follows the system appearance |
| <kbd>Ctrl</kbd>+<kbd>C</kbd> | Swallowed, did nothing | Copies and closes |

**Every visual change is gated behind `#available(macOS 26.0, *)`.** On macOS 14 and
15 this fork renders exactly like upstream, because the old layout is tuned for
`NSVisualEffectView` and looks wrong at Tahoe metrics.

The version is reported as `2.7.1-spotlight` (build `9062`). The high build number
is intentional: it keeps Sparkle from ever deciding that an upstream release is
newer than your fork and quietly replacing it.

## Requirements

**Full Xcode 26.** Command Line Tools alone cannot build Maccy — it needs `actool`
for `Assets.xcassets` and `momc` for `Storage.xcdatamodeld`, and neither ships with
CLT.

```sh
mas install 497799835          # or: brew install xcodesorg/made/xcodes && xcodes install --latest
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

If `mas install` says "not purchased", open Xcode's App Store page once in the GUI
first — that needs your Apple ID interactively.

## If you are running stock Maccy, here is the upgrade

Your clipboard history and settings survive. The bundle identifier is unchanged, so
this build reads the same container (`~/Library/Containers/org.p0deje.Maccy`).

```sh
# 1. Detach Homebrew so it cannot overwrite the fork later.
#    This removes the app bundle only. History and settings are untouched.
brew uninstall --cask maccy

# 2. Build and install.
git clone https://github.com/Lukeesec/Maccy.git
cd Maccy
git checkout spotlight-ui
script/build-and-install.sh
```

**One-time step afterwards.** This build is ad-hoc signed, so macOS treats it as a
different app for privacy purposes and the old Accessibility grant does not carry
over. Pasting will not work until you fix that:

> System Settings → Privacy & Security → Accessibility
> Remove the old **Maccy** entry, then add `/Applications/Maccy.app`

The script backs the previous app up to `/Applications/Maccy.app.backup-<timestamp>`
before replacing it.

### Optional: finish the Spotlight look

Spotlight has no title next to its search field. Maccy's is a setting, left working
rather than removed:

> Maccy Settings → Appearance → uncheck **Show title**

Or: `defaults write org.p0deje.Maccy showTitle -bool false` and relaunch.

## Reverting to stock

```sh
brew install --cask maccy
```

Then re-grant Accessibility for the stock app. History and settings survive this too.
Delete any leftover `/Applications/Maccy.app.backup-*` once you are happy.

## Tuning the look

Every metric lives in one place: `Maccy/Observables/Popup.swift`.

| Constant | Does what |
|---|---|
| `glassTintAlpha` | How strongly the panel is anchored to Dark/Light. Raise if it still washes out over bright wallpaper; lower for more glass. |
| `selectionFillOpacity` | Strength of the highlight on the active row. |
| `itemHeight` | Row height. |
| `searchFieldHeight`, `searchFontSize`, `searchIconSize` | Search row. |
| `cornerRadius` | Item curvature. The panel derives from it via `windowCornerRadius`, so they stay concentric. |

Edit, then `script/build-and-install.sh` again.

## Keeping up with upstream

```sh
git fetch upstream
git rebase upstream/master
script/build-and-install.sh
```

The changes are small and confined to seven files, so conflicts should be rare. If
upstream retires `Popup.cornerRadius` or reworks `KeyChord`, expect to resolve there.

## Caveats

- **Ad-hoc signed, not notarized.** Fine for a locally built app you run yourself.
  It is not something to distribute.
- **Do not use "Check for Updates…"** It still points at upstream's appcast. The
  version bump means it should report you are up to date, but rebuilding from source
  is the real update path.
- **`brew upgrade --greedy` would clobber it** if you ever reinstall the cask.
