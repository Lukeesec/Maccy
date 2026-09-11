# Maccy — Spotlight fork

This is a personal fork of [Maccy](https://github.com/p0deje/Maccy), a fast,
native clipboard manager for macOS. It keeps Maccy's core behavior and adds a
macOS 26 Spotlight-style popup, scoped search, an editable text preview, grouped
and paged history, and <kbd>⌘C</kbd>/<kbd>⌃C</kbd>/<kbd>⌥C</kbd> copy shortcuts.

This repository and its releases are not affiliated with the upstream Maccy
project. The only official upstream website is [maccy.app](https://maccy.app).

## Requirements and security

- macOS 14 or newer. The Spotlight presentation and fork-only controls activate
  on macOS 26; macOS 14 and 15 use the upstream presentation.
- Apple Silicon or Intel Mac. Published releases are universal (`arm64` and
  `x86_64`), and CI rejects a package missing either architecture.
- Internet access and `git` for the installation below. Xcode, Homebrew, a
  GitHub account, and the GitHub CLI are not required.
- Releases are ad-hoc signed and **not notarized**. They are also **not
  sandboxed** and do not use hardened runtime. The installer verifies the
  published SHA-256 checksum and code signature, then removes quarantine. Only
  install this fork if you trust this repository and its build workflow.

## Install on a new Mac

If Homebrew currently manages Maccy, detach the app first. This leaves its
history and settings in place:

```sh
brew uninstall --cask maccy
```

Then install the latest durable [GitHub Release](https://github.com/Lukeesec/Maccy/releases/latest):

```sh
git clone --branch spotlight-ui --single-branch https://github.com/Lukeesec/Maccy.git
cd Maccy
script/install-artifact.sh
```

The installer downloads the public release without authentication, verifies its
checksum, signature, architecture, version, and minimum macOS version, safely
migrates existing history, backs up `/Applications/Maccy.app`, installs the new
app, and launches it.

Afterward, remove any old Maccy entry and add `/Applications/Maccy.app` under
**System Settings → Privacy & Security → Accessibility**. Copying works without
that grant; automatic pasting does not.

To update, pull this repository and rerun the installer:

```sh
git pull --ff-only
script/install-artifact.sh
```

Maccy's built-in updater follows upstream and does not install this fork.

## Essential keys on macOS 26

| Key | Action |
|---|---|
| <kbd>↑</kbd> / <kbd>↓</kbd> | Move through history or the open scope picker |
| <kbd>←</kbd> | Open the scope picker when the query is empty |
| <kbd>/</kbd> | Type a scope command such as `/links` |
| <kbd>→</kbd> | Open the selected text item's editable preview |
| <kbd>↩</kbd> | Copy and close; from the preview, copy the draft |
| <kbd>⌥↩</kbd> | Paste instead of copy |
| <kbd>⌘C</kbd> / <kbd>⌃C</kbd> / <kbd>⌥C</kbd> | Copy and close, including from the preview |
| <kbd>⎋</kbd> | Leave the preview or picker; press again to close |

Preview edits are scratch copies. They never rewrite the stored history item;
copying an edited draft creates a new clipboard-history entry.

## Data and reverting

The unsandboxed fork uses:

- `~/Library/Application Support/Maccy/Storage.sqlite`
- `~/Library/Preferences/org.p0deje.Maccy.plist`

Before first install, Maccy is stopped and SQLite creates a consistent snapshot
from the stock sandbox container. The source container is never moved or
modified, so reverting preserves the stock app's original history and settings:

```sh
brew install --cask maccy
```

Items copied while using this fork remain in its unsandboxed store and will not
appear in stock Maccy.

## Building and testing

Every push to `spotlight-ui` and every manual **Build fork** dispatch runs the
unit tests, builds a universal Release app on GitHub's macOS 26 runner, verifies
its architecture and security properties, and publishes `Maccy.zip` plus
`Maccy.zip.sha256` as a durable GitHub Release. The Actions artifact is only a
short-lived duplicate; installation uses the Release.

Local builds require full Xcode 26:

```sh
script/build-and-install.sh
```

Implementation notes, design switches, upstream synchronization, and release
details are in [FORK.md](FORK.md). Maccy remains available under the [MIT License](LICENSE).
