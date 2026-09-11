# Spotlight fork notes

This branch began at upstream commit `c376789`, just after Maccy 2.7.1, to keep
the upstream CoreText hang fix for macOS 26. It has since become a substantial UI
and interaction fork rather than a two-file theme patch. The release reports
version `2.7.1-spotlight` (build `9062`) so Sparkle does not silently replace it
with an upstream 2.7.1 build.

## Fork scope

On macOS 26, this branch adds:

- A Spotlight-style, appearance-aware popup with taller rows, softer selection,
  revised typography and icons, and configurable grouping and chrome.
- A docked scope picker for All, Text, Links, Images, and Files. Left arrow opens
  it from the focused search row; `/text`, `/links`, `/images`, and `/files` work
  as command-style filters. After Down enters history, Left instead opens a
  one-shot Copy & paste without formatting action for that row.
- An editable scratch preview for text items. Copy or paste uses the draft while
  leaving the stored history item unchanged.
- <kbd>⌘C</kbd>, <kbd>⌃C</kbd>, and <kbd>⌥C</kbd> as copy-and-close shortcuts,
  including inside the preview.
- Keyset-paged history loading and optional time grouping to keep large histories
  responsive.
- Navigation and focus fixes, including preserving the selected row when opening
  or clicking into the preview.

The Spotlight UI and fork-specific controls are gated by
`#available(macOS 26.0, *)`. The app still supports macOS 14 and 15 using the
upstream presentation. Core history, pins, settings, paste stacks, and upstream
shortcuts remain, but their surrounding navigation and loading paths are not
byte-for-byte upstream code.

## Published builds

The public [latest release](https://github.com/Lukeesec/Maccy/releases/latest)
contains:

- `Maccy.zip`, an ad-hoc-signed universal application (`arm64` + `x86_64`).
- `Maccy.zip.sha256`, checked automatically by `script/install-artifact.sh`.

The release is durable and anonymously downloadable. GitHub Actions also keeps a
30-day copy for build diagnostics, but the installer does not depend on it or on
an authenticated GitHub CLI session.

The **Build fork** workflow runs on pushes to `spotlight-ui` and manual dispatch:

1. Run all `MaccyTests`, including the preview-selection regression test.
2. Cross-compile the Release app for Apple Silicon and Intel.
3. Re-sign the app with the fork's ad-hoc entitlements.
4. Verify every Mach-O file has both architectures, the deep signature is valid,
   the App Sandbox entitlement is absent, and hardened runtime is off.
5. Package the app, generate its SHA-256 checksum, and publish a commit-specific
   GitHub Release.

Repository collaborators can request a build with:

```sh
gh workflow run build-fork.yml --repo Lukeesec/Maccy --ref spotlight-ui
gh run watch --repo Lukeesec/Maccy
```

Manual dispatch requires repository write access. Installing a published release
does not require `gh`, authentication, or collaborator access.

## Why published builds are unsandboxed

An ad-hoc identity has no Apple Team ID or provisioning profile and cannot launch
this app reliably with its App Sandbox entitlement. Hardened runtime also enables
library validation, while the embedded Sparkle framework does not share a Team ID
with an ad-hoc app. The release workflow therefore:

- signs with `Maccy/Maccy-adhoc.entitlements`, which omits
  `com.apple.security.app-sandbox`; and
- builds with `ENABLE_HARDENED_RUNTIME=NO`.

This gives the clipboard manager the full file access of the signed-in user. It
is a meaningful security reduction from stock Maccy. Releases are also not
notarized, and the installer removes the downloaded app's quarantine attribute
after verifying the published checksum and ad-hoc signature. Review the source
and workflow before installing.

For a sandboxed build, use Xcode with an Apple Development identity and the
unchanged `Maccy/Maccy.entitlements`. That path needs a real Team ID and is not
what the public release contains.

## Safe migration from stock Maccy

Stock Maccy stores history under:

```text
~/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy
```

The unsandboxed fork stores it under:

```text
~/Library/Application Support/Maccy
```

The installer stops Maccy before migration so the SQLite database is closed. The
migration uses SQLite's backup operation, which includes committed WAL content in
one consistent snapshot, verifies the result, and never writes to the source
container. Any non-empty unsandboxed history is kept, so rerunning the installer
cannot roll it back to an older sandbox snapshot. An empty or incomplete
destination is moved to a timestamped `Maccy.superseded-*` directory rather than
deleted.

The previous application is similarly moved to
`/Applications/Maccy.app.backup-<timestamp>` before replacement.

## Key map on macOS 26

| Key | Action |
|---|---|
| <kbd>←</kbd> | Leave the editor; search row: scopes/settings; history row: Copy & paste without formatting |
| <kbd>/</kbd> | Type a scope command; Return commits a matching scope |
| <kbd>→</kbd> | Open the selected text item's editable preview |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Move through results (wrapping at both ends) or through the open picker |
| <kbd>↩</kbd> | Copy, paste at the cursor, and close; from the preview, paste the draft |
| <kbd>⌘C</kbd> / <kbd>⌃C</kbd> / <kbd>⌥C</kbd> | Copy and close without pasting |
| <kbd>⌥↩</kbd> | Run the configured alternate action (see Settings) |
| <kbd>⌫</kbd> | Remove the scope chip when the query is empty |
| <kbd>⌃U</kbd> | Clear the query and scope |
| <kbd>⎋</kbd> | Leave the preview or picker; a second press closes the popup |
| <kbd>⌘,</kbd> | Open Settings |

A preview edit is a scratch draft. It is discarded when selection changes or the
popup closes. Copying the draft creates a new clipboard event but never rewrites
the original stored item.

## Design switches

The macOS 26 variants can be compared without rebuilding:

```sh
script/set-style.sh
script/set-style.sh rowStyle oneLine            # twoLine | oneLine | compact
script/set-style.sh chrome stripped              # stripped | hintBar | menu
script/set-style.sh selectionStyle neutralPill  # pill | neutralPill | bar
script/set-style.sh grouping none                # byTime | none
script/set-style.sh actions searchRow            # searchRow | hintBar | none
script/set-style.sh showIcons false               # true | false
script/set-style.sh autoPreview true              # true | false
script/set-style.sh rowStyle default              # clear one override
```

Defaults are `twoLine`, `hintBar`, `pill`, `byTime`, no actions affordance, icons
on, and auto-preview off. Because macOS may redirect `defaults write` into the old
sandbox container, use `script/set-style.sh`; it writes the unsandboxed preference
file and restarts the app.

The central visual metrics are in `Maccy/Observables/Popup.swift`:
`glassTintAlpha`, `selectionFillOpacity`, `itemHeight`, `searchFieldHeight`,
`searchFontSize`, `searchIconSize`, and `cornerRadius`.

## Local development

Command Line Tools cannot compile Maccy because the project needs Xcode asset and
Swift macro tooling. Full Xcode 26 is required:

```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
script/build-and-install.sh
```

The script creates a native local build, verifies the same signing properties,
stops Maccy before migration, backs up the installed app, and launches the build.
Use `script/build-and-install.sh --build-only` to avoid installation.

## Keeping up with upstream

This is a broad, multi-file fork, so an upstream rebase may require deliberate
conflict resolution across UI, navigation, storage, and tests:

```sh
git fetch upstream
git rebase upstream/master
git push --force-with-lease origin spotlight-ui
```

Do not use the in-app **Check for Updates** command for this fork; Sparkle still
follows upstream. Pull the branch and rerun `script/install-artifact.sh` to install
the latest fork release. Reinstalling or upgrading the Homebrew cask can replace
the fork with stock Maccy.
