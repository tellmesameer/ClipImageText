# ClipText Permissions & Code Signing Guide

## Overview

ClipText is a native macOS menu bar application built for macOS 14+ on Apple Silicon. It operates entirely local-first without telemetry, network requests, or cloud dependencies.

To provide global keyboard shortcuts, screen-region selection, and on-device OCR, ClipText requires specific system capabilities and user permissions.

---

## 1. Required Permissions

### A. Screen Recording (`NSScreenCaptureUsageDescription`)
- **Purpose**: Enables ScreenCaptureKit to capture the user-selected rectangle on any connected display for local Apple Vision text recognition.
- **System Location**: **System Settings > Privacy & Security > Screen Recording**.
- **Guidance Flow**: ClipText checks this access without prompting automatically. If it is missing, the menu and Settings provide an explicit link to the Screen Recording pane; after granting access, relaunch ClipText.
- **Relaunch Requirement**: When granted in macOS System Settings, macOS requires terminating and reopening the application before ScreenCaptureKit receives capture buffers. ClipText detects this state and provides a direct "Relaunch ClipText" button in Settings.
- **Denial Behavior**: If permission is denied, ClipText cancels the selection cleanly without disturbing the user's existing clipboard or stored history, and presents a non-intrusive status HUD.

### B. Accessibility (`AXIsProcessTrusted`)
- **Purpose**: Allows ClipText to position the clipboard history panel directly under the active text insertion caret, and paste restored items directly into the frontmost application.
- **System Location**: **System Settings > Privacy & Security > Accessibility**.
- **Optional**: If Accessibility access is not granted, ClipText remains fully functional; the panel positions at the center of the active display, and selecting an item copies it to `NSPasteboard` without synthesizing keyboard events.
- **Guidance Flow**: ClipText never repeatedly triggers the Accessibility authorization prompt. It reports the degraded behavior and opens the Accessibility pane only when the person chooses that action.

---

## 2. Entitlements Configuration

ClipText uses the following entitlements defined in `ClipText/ClipText.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.device.screen-capture</key>
	<true/>
</dict>
</plist>
```

- `com.apple.security.app-sandbox = false`: Required for system-wide display capture across all windows, Carbon global hotkey monitoring, and inter-application paste events.
- `com.apple.security.device.screen-capture = true`: Declares intent for display capture under ScreenCaptureKit.

---

## 3. Code Signing Architecture

### Local Development Signing (Apple Development)
For local development builds, ClipText uses a stable Apple Development identity rather than ephemeral ad-hoc signatures. This binds the application's Designated Requirement (DR) to the developer's certificate identity and TeamIdentifier:

```bash
# Auto-detects valid Apple Development identity in Keychain
./scripts/build.sh

# Or with an explicit identity override:
CLIPTEXT_SIGNING_IDENTITY="Apple Development: sameer355u@gmail.com (9325V822RQ)" ./scripts/build.sh
```

**Benefits for Development**:
- macOS TCC (Screen Recording permission) tracks applications by Designated Requirement. With a certificate-backed signature, the DR is bound to the developer certificate and Team ID rather than the binary's CDHash.
- Screen Recording and Accessibility permissions persist across rebuilds only when the bundle identifier, Team ID, and certificate-backed designated requirement remain stable. Release builds require the configured Apple Development identity for Team `B6537Y9X84`; they never fall back to ad-hoc signing.

> **One-Time Migration Grant**: When migrating from an ad-hoc signed build to an Apple Development signed build, macOS requires granting Screen Recording permission once in **System Settings > Privacy & Security > Screen Recording**, because the Designated Requirement changes from CDHash-based to certificate-based. Subsequent rebuilds with the same certificate retain the grant automatically.

### CI & Contributor Fallback (Ad-hoc)
On CI runners (e.g. GitHub Actions) or environments where no Apple Development certificate is present in the Keychain, `./scripts/build.sh` automatically falls back to ad-hoc signing (`-s -`):
```bash
CLIPTEXT_SIGNING_IDENTITY="-" ./scripts/build.sh
```
This ensures CI workflows and external contributors without Apple Developer accounts can build, test, and package ClipText without configuration changes or failed builds.

### Distribution Signing & Notarization (Developer ID)
For ordinary public distribution outside the local machine:
1. Sign the bundle with a valid Apple Developer ID Application certificate:
   ```bash
   codesign --force --deep --timestamp --options runtime \
     --sign "Developer ID Application: <Your Team> (<TeamID>)" \
     --entitlements ClipText/ClipText.entitlements \
     build/Release/ClipText.app
   ```
2. Submit the zipped bundle or DMG to Apple's notarization service:
   ```bash
   xcrun notarytool submit build/ClipText-1.0.zip --keychain-profile "<Profile>" --wait
   ```
3. Staple the notarization ticket:
   ```bash
   xcrun stapler staple build/Release/ClipText.app
   ```

*ClipText does not claim notarization until these steps are executed by a developer with a registered Apple Developer Account.*

---

## 4. Gatekeeper & First-Launch Approval Procedure

When launching a locally built development bundle for the first time without Developer ID notarization, macOS Gatekeeper protects the system by blocking unverified binaries by default.

### Standard Manual Approval
1. In Finder, navigate to the installed app (e.g., `~/Applications` or `/Applications`).
2. Right-click (or Control-click) `ClipText.app` and choose **Open**.
3. In the warning prompt ("macOS cannot verify the developer..."), click **Open**.
4. Alternatively, open **System Settings > Privacy & Security**, scroll down to the **Security** section, and click **Open Anyway**.

*Note: ClipText's installation scripts never strip quarantine attributes (`xattr -d com.apple.quarantine`) automatically, ensuring that all macOS user-consent and security controls remain fully intact.*

---

## 5. Resetting Permissions & Safe Uninstallation

To test the first-run permission onboarding experience or remove ClipText, run the uninstall script:

```bash
# Normal uninstall (preserves privacy permissions, history, and Keychain keys):
./scripts/uninstall.sh --keep-data

# Deliberate permission reset (preserves history and Keychain keys):
./scripts/uninstall.sh --keep-data --reset-permissions

# Preview prospective changes safely:
./scripts/uninstall.sh --dry-run

# Complete uninstallation with full data wipe (prompts for confirmation):
./scripts/uninstall.sh
```

This script:
1. Safely terminates active `ClipText` processes.
2. Validates target bundles strictly (rejects symlinks, non-.app paths, and mismatched `CFBundleIdentifier`).
3. Unregisters installed app bundles from the macOS LaunchServices database.
4. Removes verified `ClipText.app` bundles.
5. Preserves macOS TCC permissions by default. Only `--reset-permissions` runs `tccutil reset` for `ScreenCapture` and `Accessibility`; use it only when you intend to authorize ClipText again.
6. Cleans application caches and saved application state.
7. Manages clipboard history and the Keychain AES-GCM encryption key (`service: com.kelsiito.clipboard.local-storage`, `account: aes-gcm-key-v1`), preserving them when `--keep-data` is specified and requiring explicit confirmation before permanent deletion.
