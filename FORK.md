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

## Building it

Maccy is a native Swift app, so there is no way around compiling it. Command Line
Tools alone are not enough: `Assets.xcassets` needs `actool`, and the `@Model` and
`#Preview` expansions need Xcode's macro plugins. Neither ships with CLT.

There are two ways to get a build, and the first does not touch your machine.

### Option A — build on GitHub, install locally (no Xcode)

The `Build fork` workflow compiles the app on a GitHub-hosted macOS 26 runner,
which has Xcode preinstalled, and uploads the finished `.app` as an artifact.

```sh
gh workflow run build-fork.yml --repo Lukeesec/Maccy   # or just push to spotlight-ui
gh run watch --repo Lukeesec/Maccy

# then, from a clone of this repo:
script/install-artifact.sh
```

`script/install-artifact.sh` downloads the newest successful build, clears the
quarantine flag that any internet download carries, verifies the signature, and
installs it. It needs only Command Line Tools.

### Option B — build locally

Requires **full Xcode 26**, roughly 20GB installed.

```sh
brew install xcodesorg/made/xcodes && xcodes install --latest
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept

script/build-and-install.sh
```

`mas install 497799835` also works, but only if Xcode is already associated with
your Apple ID — `mas` cannot perform the initial "Get". If it reports that you do
not own the app, use `xcodes` or the App Store GUI.

## One real trade-off: these builds are not sandboxed

Stock Maccy ships sandboxed. This fork cannot be, and you should decide whether
that is acceptable before installing it.

An ad-hoc signature cannot satisfy the App Sandbox. `secinitd` never answers the
sandbox-initialisation XPC request, so the process deadlocks inside
`_libsecinit_appsandbox` during dyld's initialisers — before AppKit loads. It looks
alive (a real PID, no crash log) but has one thread and never opens a window.
Sandboxing needs a genuine signing identity with a Team ID and provisioning
profile, which neither a CI build nor a local ad-hoc build has.

So `Maccy/Maccy-adhoc.entitlements` drops `com.apple.security.app-sandbox`, and
both build paths assert the entitlement is absent so it cannot creep back in.

**What that costs you.** A sandboxed Maccy is confined to its own container; this
one is not, so it runs with your user's full file access. For a clipboard manager
that already sees everything you copy, the marginal exposure is small — but it is
a real reduction against stock, and it is your call.

**If you would rather keep the sandbox**, build locally in Xcode signed with your
own Apple Development identity (a free Apple ID is enough). A real Team ID makes
the sandbox work, and `Maccy/Maccy.entitlements` — upstream's, unmodified — is
still there for exactly that.

**Where your data lives.** An unsandboxed Maccy reads
`~/Library/Application Support/Maccy/Storage.sqlite` and
`~/Library/Preferences/org.p0deje.Maccy.plist`, rather than the same paths
redirected into `~/Library/Containers/org.p0deje.Maccy/Data`.
`script/migrate-container-data.sh` copies your history and settings across on first
install. It copies rather than moves, so the container stays intact and reverting
to stock Maccy restores everything.

## If you are running stock Maccy, here is the upgrade

Your clipboard history and settings survive — they are copied out of the sandbox
container on first install, as described above. The container itself is left
untouched.

```sh
# 1. Detach Homebrew so it cannot overwrite the fork later.
#    This removes the app bundle only. History and settings are untouched.
brew uninstall --cask maccy

# 2. Get a build and install it, by either option above.
git clone https://github.com/Lukeesec/Maccy.git
cd Maccy
git checkout spotlight-ui
script/install-artifact.sh      # no Xcode needed
```

**One-time step afterwards.** This build is ad-hoc signed, so macOS treats it as a
different app for privacy purposes and the old Accessibility grant does not carry
over. Pasting will not work until you fix that:

> System Settings → Privacy & Security → Accessibility
> Remove the old **Maccy** entry, then add `/Applications/Maccy.app`

Either script backs the previous app up to
`/Applications/Maccy.app.backup-<timestamp>` before replacing it.

### Optional: finish the Spotlight look

Spotlight has no title next to its search field. Maccy's is a setting, left working
rather than removed:

> Maccy Settings → Appearance → uncheck **Show title**

(The title is suppressed outright by the redesign on macOS 26, so this only
matters on older systems.)

## Reverting to stock

```sh
brew install --cask maccy
```

Then re-grant Accessibility for the stock app. Stock Maccy reads the sandbox
container, which this fork never modified, so your history and settings are exactly
as they were before you switched. Anything you copied *while running the fork*
lives in `~/Library/Application Support/Maccy` and will not appear.

Delete any leftover `/Applications/Maccy.app.backup-*` and
`~/Library/Application Support/Maccy.superseded-*` once you are happy.

## Trying the design variants

The contentious parts of the redesign are switchable at runtime so they can be
compared on a real machine and the losers deleted. Use the script — see the
warning below:

```sh
script/set-style.sh                          # show current values
script/set-style.sh rowStyle oneLine         # twoLine | oneLine | compact
script/set-style.sh chrome stripped          # stripped | hintBar | menu
script/set-style.sh selectionStyle neutralPill  # pill | neutralPill | bar
script/set-style.sh grouping none            # byTime | none
script/set-style.sh actions searchRow        # rowTrailing | searchRow | hintBar | none
script/set-style.sh showIcons false          # true | false
script/set-style.sh autoPreview true         # true | false
script/set-style.sh rowStyle default         # clear an override
```

Defaults: `twoLine` / `hintBar` / `pill` / `byTime` / `rowTrailing`, icons on,
auto-preview off.

`actions` decides where the actions affordance lives and therefore how it is
reached. Tab focuses it in every placement, Shift-Tab and Left arrow leave it,
Return opens it. Right arrow also reaches it, but only when the search field is
empty — otherwise it has a caret to move.

- `rowTrailing` — a circular button on the selected row, the way Spotlight
  attaches actions to the result rather than to the window.
- `searchRow` — one glyph in the search row.
- `hintBar` — one glyph in the bottom bar, leaving the search row clean.
- `none` — no affordance at all, which is what Spotlight itself does. `⌘,` still
  opens Settings.

> **`defaults write org.p0deje.Maccy <key>` does not work on these builds.**
> macOS still has a sandbox container registered for the bundle identifier and
> redirects domain writes into
> `~/Library/Containers/org.p0deje.Maccy/Data/Library/Preferences`, while the
> unsandboxed fork reads `~/Library/Preferences/org.p0deje.Maccy.plist`. The
> write appears to succeed and `defaults read` even reflects it, but the app
> never sees the change. `script/set-style.sh` writes to the real path and
> restarts the app.

## Tuning the look

Every metric lives in one place: `Maccy/Observables/Popup.swift`.

| Constant | Does what |
|---|---|
| `glassTintAlpha` | How strongly the panel is anchored to Dark/Light. Raise if it still washes out over bright wallpaper; lower for more glass. |
| `selectionFillOpacity` | Strength of the highlight on the active row. |
| `itemHeight` | Row height. |
| `searchFieldHeight`, `searchFontSize`, `searchIconSize` | Search row. |
| `cornerRadius` | Item curvature. The panel derives from it via `windowCornerRadius`, so they stay concentric. |

Edit, push, and re-run the workflow — or `script/build-and-install.sh` if you have
Xcode locally.

## Keeping up with upstream

```sh
git fetch upstream
git rebase upstream/master
git push --force-with-lease origin spotlight-ui   # rebuilds via CI
script/install-artifact.sh
```

The changes are small and confined to seven files, so conflicts should be rare. If
upstream retires `Popup.cornerRadius` or reworks `KeyChord`, expect to resolve there.

## Caveats

- **Ad-hoc signed, not notarized.** Fine for an app you build and run yourself. It
  is not something to distribute. A CI build additionally arrives quarantined;
  `script/install-artifact.sh` clears that flag for you.
- **Do not use "Check for Updates…"** It still points at upstream's appcast. The
  version bump means it should report you are up to date, but rebuilding from source
  is the real update path.
- **`brew upgrade --greedy` would clobber it** if you ever reinstall the cask.
- **Hardened runtime is off in these builds** (`ENABLE_HARDENED_RUNTIME=NO`).
  It has to be. Hardened runtime turns on library validation, which requires every
  embedded library to share the app's Team ID — and an ad-hoc signature has no Team
  ID, so `Sparkle.framework` fails to map and the app aborts at launch with a dyld
  `Library missing` error. Both build paths assert the flag is absent so this cannot
  regress silently. Upstream's own signed releases keep hardened runtime on, as they
  should; it is only incompatible with ad-hoc signing.
