# ClipText

[![CI](https://github.com/tellmesameer/ClipImageText/actions/workflows/ci.yml/badge.svg)](https://github.com/tellmesameer/ClipImageText/actions/workflows/ci.yml)

ClipText is a lightweight, native macOS menu-bar application that combines **PowerToys-style screen-region text extraction** with **persistent, encrypted clipboard history** into a unified tool.

Operating 100% locally on Apple Silicon (macOS 14+ Sonoma), ClipText sends zero data to external services and requires no account or cloud dependencies.

---

## Features

- **Screen-Region Text Extraction**: Press `⌥⇧T` (Option + Shift + T), drag a rectangle across any area of any display, and extract text instantly using on-device Apple Vision OCR.
- **Unified Clipboard History**: Extracted OCR text is copied directly to the system clipboard and recorded once into the same encrypted history store as standard copies.
- **Zero-Latency History Picker**: Press `⌘⇧V` (Command + Shift + V) to search, preview, pin, and restore previous clips.
- **Privacy & Security**: All clipboard entries are encrypted with AES-GCM using Keychain-backed keys. Concealed and transient pasteboard markers (e.g. from password managers) are filtered automatically.
- **Menu Bar Accessory**: Runs cleanly as a background menu-bar accessory (`LSUIElement = YES`) without polluting the Dock.
- **Launch at Login**: Optional user toggle backed by Apple's modern `SMAppService` framework.

---

## Requirements

- **Target Device**: MacBook Air / Pro (Apple Silicon `arm64`)
- **Operating System**: macOS 14.0 (Sonoma) or newer
- **Frameworks**: SwiftUI, AppKit, ScreenCaptureKit, Vision, ServiceManagement (Zero third-party dependencies)

---

## Quick Start & Repeatable Scripts

ClipText provides reproducible bash scripts under `scripts/`:

### 1. Build and Package
Builds the Release configuration and signs the bundle with embedded entitlements:
```bash
./scripts/build.sh
```
Output: `build/Release/ClipText.app`

### 2. Install or Update
Safely installs the application to `/Applications` (or `~/Applications` with `--user`):
```bash
# Install to ~/Applications (no sudo required)
./scripts/install.sh --user

# Or install system-wide to /Applications (if writable)
./scripts/install.sh --system

# Optional: automatically launch after install
./scripts/install.sh --user --launch
```
*Note*: `scripts/install.sh` safely replaces the application bundle while preserving user history in `~/Library/Application Support/` and Keychain secrets.

### 3. Verify Installation
Performs comprehensive bundle integrity, Info.plist, code signature, entitlements, and smoke-launch checks:
```bash
./scripts/verify.sh ~/Applications/ClipText.app
```

### 4. Create Standalone Release Archive
```bash
./scripts/package.sh
```
Output: `build/ClipText-1.0.zip`

---

## Running Automated Tests

Run the full unit test suite using `xcodebuild`:
```bash
xcodebuild -project ClipText.xcodeproj -scheme ClipText -destination 'platform=macOS' test
```

All **85 tests** across clipboard persistence, AES-GCM encryption, OCR coordinate conversion, line sorting, deduplication, smart paste, snippet library, panel placement, and paused monitoring execute natively.

### Automated vs Manual Testing

| Category | Method | Count |
| :--- | :--- | :--- |
| Clipboard store persistence & deduplication | XCTest (CI) | 62 |
| Screen OCR pipeline & coordinator | XCTest (CI) | 12 |
| Text processor (line sorting, normalization) | XCTest (CI) | 11 |
| Global hotkey invocation from another app | Manual | — |
| Multi-display region selection & Retina scaling | Manual | — |
| Screen Recording permission grant & relaunch | Manual | — |
| Independent launch outside Xcode | `scripts/verify.sh` | — |

See [Documentation/ManualAcceptanceChecklist.md](Documentation/ManualAcceptanceChecklist.md) for the full manual test procedure.

---

## Keyboard Shortcuts

| Action | Default Shortcut | Configurable |
| :--- | :--- | :--- |
| **Extract Text from Screen (OCR)** | `⌥⇧T` (Option + Shift + T) | Yes (in Settings) |
| **Open Clipboard History** | `⌘⇧V` (Command + Shift + V) | Yes (in Settings) |
| **Cancel Selection / Dismiss** | `Esc` | Built-in |

---

## Permissions & First-Launch Security

- **First-Launch Gatekeeper Prompt**: Because locally built development binaries are ad-hoc signed rather than signed with an Apple Developer ID and notarized by Apple, macOS Gatekeeper may display a prompt ("macOS cannot verify the developer") if opened from Finder.
  - **Manual Approval Procedure**: Right-click (or Control-click) `ClipText.app` in Finder, choose **Open**, and click **Open** in the confirmation dialog. Alternatively, go to **System Settings > Privacy & Security** and click **Open Anyway** in the Security section.
  - `scripts/install.sh` deliberately preserves Gatekeeper controls and does not remove quarantine attributes.
- **Screen Recording**: Required for capturing screen regions for Apple Vision OCR. If prompted, grant permission in **System Settings > Privacy & Security > Screen Recording** and relaunch the app.
- **Accessibility**: Optional. Enables automatic caret-anchored panel placement and direct synthetic pasting.
- **Local Development Signing vs Public Distribution**: `scripts/build.sh` applies local ad-hoc signing (`codesign -s - --entitlements ...`). **The current build is ad-hoc signed and not notarized.** Public distribution requires an Apple Developer ID Application certificate, Hardened Runtime, and Apple notarization via `notarytool`.
- See [Documentation/Permissions.md](Documentation/Permissions.md) for full details.

---

## Attributions & Licensing

ClipText is released under the permissive [MIT License](LICENSE).

It incorporates and adapts code from:
- [Kelsiito/clipboard](https://github.com/Kelsiito/clipboard) (MIT License) - Clipboard monitoring, encrypted storage, and history UI.
- [arsh342/TextGrab](https://github.com/arsh342/TextGrab) (MIT License) - ScreenCaptureKit capture pipeline, selection overlay, and Vision OCR line sorting.
- [tamibot/klip](https://github.com/tamibot/klip) (Apache-2.0 License) - Architectural reference.

See [Documentation/UpstreamAttributions.md](Documentation/UpstreamAttributions.md) for complete license notices and attributions.
