# Barc

Barc is a native macOS web browser built with SwiftUI and WebKit. It uses a vertical sidebar with spaces, a command bar, per-space themes, and runs Chrome Web Store extensions on WebKit's built-in Web Extensions engine.

## Features

- **Sidebar tabs.** Each space has favorites, pinned tabs, folders, and a "Today" list for short-lived tabs that you can clear in one go.
- **Live folders.** A folder that follows a feed and shows its newest five posts with unread dots, refreshed every 15 minutes. Posts open as tabs inside the folder. GitHub presets cover a user's open pull requests and activity, or a repo's releases, commits (any branch), and tags. Any other RSS or Atom feed works too: paste its address, or a website's address and Barc finds the feed (File → New Live Folder…).
- **Spaces.** Every space has its own name, icon, and theme. A space can share browsing data with the others or keep its own cookies and storage.
- **Command bar.** Open a URL, search, or jump to a tab or history entry from one field (`⌘T` / `⌘L`).
- **Themes.** Per-space gradient themes with color harmonies, presets, grain, and light/dark/auto modes.
- **Chrome extensions.** Install from the Chrome Web Store (the store's button turns into "Add to Barc"), paste a store link or ID, or load an unpacked folder, `.zip`, or `.crx`. You can pin extension buttons to the top bar, open their popups, and manage them in Settings → Extensions.
- **Everyday browser features.** Downloads, find in page, zoom, a share sheet, reopening closed tabs, and making Barc your default browser.

## Chrome extension compatibility

Barc loads extensions with `WKWebExtensionController`, so Manifest V3 extensions run the same way they do in Safari. Some Chrome-only behavior is missing in WebKit, so Barc patches each extension when it is installed or loaded:

- It fills in Chrome APIs that WebKit doesn't have (`offscreen`, `sidePanel`, `tabGroups`, `storage.managed`, parts of `runtime` and `action`) with harmless stubs, so background scripts don't crash on startup.
- It adds `requestIdleCallback` / `cancelIdleCallback` to every script file. WebKit doesn't have them, and extensions such as Proton Pass, Grammarly, and Bitwarden call them from their content scripts.
- It keeps `chrome` and `browser` pointing at the same API in content scripts, and fills in `sender.frameId` for messages.
- It fires `runtime.onInstalled` when WebKit doesn't.
- It reports tab loading state, so `tabs.onUpdated` delivers `status: "complete"`.

Checked to load and inject into pages: Proton Pass, Dark Reader, Grammarly, and Video Speed Controller. uBlock Origin Lite loads without errors. Bitwarden's background script currently fails because it doesn't recognize Barc's browser type.

## Requirements

- macOS 15.4 or later (WebKit Web Extensions API)
- Xcode 16 or a Swift 5.10+ toolchain

## Build and run

Beta DMGs will be available on the [GitHub Releases page](https://github.com/DivinPrince/barc/releases). Download `Barc-X.Y.Z-beta.N-universal.dmg`, open it, and drag Barc into Applications. The universal app supports Apple Silicon and Intel Macs running macOS 15.4 or later.

The app is ad-hoc signed, not Apple-notarized. If macOS blocks the first launch and you trust the download, attempt to open the app, then choose **Open Anyway** in **System Settings → Privacy & Security**.

```sh
./build.sh
```

This builds a release binary, generates the app icon, assembles and ad-hoc signs `dist/Barc.app`, and installs it to `/Applications/Barc.app`. Set `INSTALL=0` to skip the install, or `CONFIG=debug` for a debug build.

For development:

```sh
swift build
swift test
```

Set `BARC_DATA_DIR=/some/folder` to run with a separate profile (library, history, and extensions) instead of `~/Library/Application Support/Barc`.

## DMG builds and releases

Build a universal DMG locally without installing the app:

```sh
./scripts/package-dmg.sh
# Override the bundle and DMG version:
VERSION=0.2.0-beta.1 BUILD_NUMBER=2 ./scripts/package-dmg.sh
```

The script produces `dist/Barc-X.Y.Z-beta.N-universal.dmg` and its `.sha256` checksum. It compiles both architectures, verifies the app signature, and packages an Applications shortcut for drag-and-drop installation. `VERSION` defaults to the version in `Resources/Info.plist` with `-beta.1` appended. The app bundle uses the numeric `X.Y.Z` version required by macOS; the DMG and release retain the beta label.

The **Build and release** GitHub Actions workflow runs tests and uploads the DMG and checksum as the **Barc-macOS-universal** artifact on pull requests, pushes to `main`, and manual runs. Download these from the workflow run's **Artifacts** section (requires signing in to GitHub; retained for 14 days).

To publish a release after the workflow has been merged, tag the desired commit and push the tag:

```sh
git tag v0.1.0-beta.1
git push origin v0.1.0-beta.1
```

Tags must use `vX.Y.Z-beta.N` while Barc is in beta. The workflow sets the app version from the tag, runs tests, builds the DMG, and publishes a GitHub prerelease (never marked as the latest stable release) with the DMG, checksum, and generated release notes. The build number comes from the Actions run number. No extra secrets are needed: publishing uses GitHub's automatic `GITHUB_TOKEN`. Manual runs on branches produce artifacts without publishing a release.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New tab / open location | `⌘T` / `⌘L` |
| Close tab / reopen closed tab | `⌘W` / `⇧⌘T` |
| Show or hide sidebar | `⌘S` |
| Pin tab / add to favorites | `⌘D` / `⇧⌘D` |
| Next / previous tab | `⌃Tab` / `⌃⇧Tab`, `⌥⌘↓` / `⌥⌘↑` |
| Go to tab 1–9 | `⌘1` … `⌘9` |
| Next / previous space | `⌥⌘→` / `⌥⌘←` |
| Go to space | `⌃1` … `⌃9` |
| New space / new folder | `⇧⌘N` / `⌥⌘N` |
| Clear Today | `⇧⌘K` |
| Edit theme | `⇧⌘E` |
| Find in page | `⌘F` |
| Copy URL | `⇧⌘C` |
| Reload / zoom | `⌘R` / `⌘+` `⌘-` `⌘0` |
| Back / forward | `⌘[` / `⌘]` |

## Project layout

```
Sources/Barc/
  BarcApp.swift         App entry point, menus, and shortcuts
  BrowserStore.swift    Library, spaces, tabs, history, persistence
  BrowserView.swift     Main window and top bar
  Sidebar.swift         Sidebar, favorites, pinned tabs, folders
  LiveFolders.swift     RSS/Atom live folders, feed parsing, GitHub presets
  CommandBar.swift      URL and search command bar
  TabSession.swift      WKWebView lifecycle per tab
  Extensions.swift      Extension install, Chrome compatibility, popups, settings
  Theme*.swift          Space themes and the theme editor
  Services.swift        Favicons and downloads
Tests/BarcTests/        Unit tests and WebKit extension injection tests
scripts/make-icon.swift App icon generator
```
