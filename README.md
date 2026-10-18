# MenuMonitor

**English** | [简体中文](README.zh-CN.md)

A lightweight macOS menu-bar system monitor built with native SwiftUI and AppKit.

![Panel screenshot](docs/screenshot.png)

## Features

- **Menu bar**: live memory usage percentage
- **Popover panel**
  - Junk (cache) size estimate and **Quick Clean** (cleans `~/Library/Caches`, no confirmation, with progress)
  - Memory / CPU / CPU temperature
  - Top 10 apps by memory (quit an app or view its details)
  - Disk space, network and disk I/O throughput
  - **Manage Processes** opens Activity Monitor; **Hardware Info** opens System Information
- **Dark mode**: follows the system appearance, or force Light / Dark in Settings
- **Languages**: English and Chinese (中文); defaults to following the system (Chinese if your preferred language is Chinese, otherwise English)
- **Settings** (right-click the menu bar icon → **Settings…**, ⌘,)
  - Launch at Login
  - Language: Follow System / English / 中文
  - Appearance: Follow System / Light / Dark
  - Refresh interval: 1 / 2 / 5 s
  - Menu bar shows: Memory / CPU / Memory + CPU / Icon Only
  - Temperature unit: °C / °F
- **Quit**: right-click the menu bar icon → **Quit MenuMonitor** (left-click toggles the panel)

<img src="docs/settings.png" alt="Settings window" width="440">

## Requirements

- **macOS 14+** (see `Package.swift`)
- Apple Silicon or Intel (CPU temperature is read from IOKit HID sensors; shows `--` if unavailable)
- Only the **Command Line Tools** are needed (`xcode-select --install`); full Xcode is not required

## Build & Install

```bash
git clone https://github.com/linhuitang/MenuMonitor.git
cd MenuMonitor
./build.sh
```

`build.sh` runs `swift build -c release`, assembles `MenuMonitor.app` in a temporary directory, ad-hoc signs it, quits any running copy, installs it to `/Applications` and launches it (no second copy is left in the project folder).

Build only:

```bash
swift build -c release
```

## Quit

- Right-click the menu bar icon → **Quit MenuMonitor**
- Or from Terminal: `pkill -x MenuMonitor`

## First Launch (not notarized)

Releases are **ad-hoc signed** and **not notarized by Apple**. If macOS refuses to open the app after downloading the DMG/ZIP from GitHub Releases:

1. Drag `MenuMonitor.app` into Applications
2. **Right-click** the app → **Open** (don't double-click), then click **Open** in the dialog
3. Or remove the quarantine attribute in Terminal and launch:

```bash
xattr -dr com.apple.quarantine /Applications/MenuMonitor.app
open /Applications/MenuMonitor.app
```

You can also allow a blocked app in **System Settings → Privacy & Security**.

## Notes

- **Quick Clean** only removes safely deletable items under your `~/Library/Caches`; it never touches the Trash or other folders
- When the junk size is below 1 MiB the header shows **No junk to clean** and the Quick Clean button is disabled

## License

MIT © 2026 linhuitang
