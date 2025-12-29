# Fix Tim

[English](./README.md) | [中文文档](./README_CN.md)

It fix bug on macOS.

![screenshot](./Resources/SCR-20240206.gif)

## What is this?

There are numerous instances where we may need to restart our Mac to rectify a glitch. This user-friendly tool is designed to resolve most runtime bugs without necessitating a full system restart, and it can restore your applications to the state they were in before the issue arose.

This tool can address issues like:

- Screenshot sucks on desktop
- Lagging Input Method Editor (IME)
- Disrupted core audio stream
- AirDrop malfunction or inefficiency
- Wi-Fi failing to scan or connect
- Any unresponsive or spinning app
- iCloud sync issues
- Xcode not looking for devices
- Xcode Simulator not booting
- debugserver not responding

And more ...

**Please note, however, this app does not have the ability to fix hardware problems or kernel bugs.**

---

## ✨ Enhanced Features

This enhanced version adds comprehensive support for restarting startup items:

### New Features
- ✅ **Full LaunchAgents Support** - Automatically reloads user-level LaunchAgents after soft restart
- ✅ **Login Items Support** - Restarts all login items configured in System Settings
- ✅ **Expanded App Search** - Supports applications in any location, not just `/Applications`
- ✅ **Background Launch** - Login items launch silently in the background (using `-g` flag)
- ✅ **Command-line Options** - New flags: `--no-launch-agents` and `--no-login-items`

### Bug Fixes
- 🐛 Fixed array out-of-bounds error in `listApplications()` (`0 ... entryCount` → `0 ..< entryCount`)
- 🐛 Removed application path restrictions (previously limited to `/Applications/` and `/System/Applications/`)
- 🐛 Added proper error handling for LaunchAgents and Login Items

### Modified Files
- `FixTim/ListApps.swift` - Added LaunchAgents and Login Items support for GUI version
- `FixTim/App.swift` - Added new settings toggles and restart logic
- `Resources/CommandLineTool.swift` - Synchronized all enhancements to command-line version

---

## System Requirements

- **macOS 10.10+** - Basic functionality
- **All macOS versions** - Full LaunchAgents and Login Items support (via AppleScript)

> **Note**: Login Items support uses AppleScript to query System Events, which works on all macOS versions without requiring macOS 13+ APIs.

---

## Installation

### Method 1: GUI Application (Recommended)

#### Build from source:
```bash
# Switch to Xcode command line tools
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Build without code signing (no developer account needed)
cd "/path/to/FixTim-main"
xcodebuild -project FixTim.xcodeproj -scheme FixTim -configuration Release \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# The app will be located at:
# ~/Library/Developer/Xcode/DerivedData/FixTim-*/Build/Products/Release/FixTim.app

# Copy to Applications folder
cp -R ~/Library/Developer/Xcode/DerivedData/FixTim-*/Build/Products/Release/FixTim.app /Applications/
```

#### First launch (security):
If macOS blocks the app, run:
```bash
xattr -cr /Applications/FixTim.app
```

Or go to **System Settings → Privacy & Security** and click "Open Anyway".

---

### Method 2: Command Line Tool

Perfect for macOS below 13.0 or if you prefer terminal usage:

```bash
# Compile
swiftc -o fixtim -framework AppKit -framework ServiceManagement ./Resources/CommandLineTool.swift

# Run directly
./fixtim

# Or install to system path
sudo cp fixtim /usr/local/bin/
sudo chmod +x /usr/local/bin/fixtim
```

#### Command-line Options:
```bash
fixtim                      # Full restart with all features
fixtim --no-launch-agents   # Skip LaunchAgents reload
fixtim --no-login-items     # Skip Login Items restart
fixtim --help               # Show help message
```

---

## macOS below 13.0

The command-line tool works perfectly on older macOS versions:

```bash
swiftc -o fixtim -framework AppKit -framework ServiceManagement ./Resources/CommandLineTool.swift
./fixtim
```

All features including LaunchAgents and Login Items support are fully compatible with older macOS versions.

---

## Principles

We initiate a reboot process using launchd and reopen applications thereafter. This reboot doesn't involve reloading the kernel, but instead only reloads the user space.

This process is akin to a soft reboot on Android, which is fast and doesn't consume a lot of resources.

### What Gets Restored:
1. **Running Applications** - All apps that were running before restart
2. **LaunchAgents** - User-level background services (optional)
3. **Login Items** - Applications configured to start at login (optional)
4. **Dock Layout** - Your Dock configuration

---

## Admin Privileges

Most of the issue wont require an administator privileges, but some of them will. If you need it, execute the binary in terminal with a parameter `--now`.

```bash
sudo /Applications/FixTim.app/Contents/MacOS/FixTim --now
```

---

##
I use this project:https://github.com/Lakr233/FixTim Made the modifications.