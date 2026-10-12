# ClipText Permissions & Code Signing Guide

## Overview

ClipText is a native macOS menu bar application built for macOS 14+ on Apple Silicon. It operates entirely local-first without telemetry, network requests, or cloud dependencies.

To provide global keyboard shortcuts, screen-region selection, and on-device OCR, ClipText requires specific system capabilities and user permissions.

---

## 1. Required Permissions

### A. Screen Recording (`NSScreenCaptureUsageDescription`)
- **Purpose**: Enables ScreenCaptureKit to capture the user-selected rectangle on any connected display for local Apple Vision text recognition.
- **System Location**: **System Settings > Privacy & Security > Screen Recording**.
- **User Prompt**: macOS presents a system prompt on first screen capture attempt.
- **Relaunch Requirement**: When granted in macOS System Settings, macOS requires terminating and reopening the application before ScreenCaptureKit receives capture buffers. ClipText detects this state and provides a direct "Relaunch ClipText" button in Settings.
- **Denial Behavior**: If permission is denied, ClipText cancels the selection cleanly without disturbing the user's existing clipboard or stored history, and presents a non-intrusive status HUD.

### B. Accessibility (`AXIsProcessTrusted`)
- **Purpose**: Allows ClipText to position the clipboard history panel directly under the active text insertion caret, and paste restored items directly into the frontmost application.
- **System Location**: **System Settings > Privacy & Security > Accessibility**.
- **Optional**: If Accessibility access is not granted, ClipText remains fully functional; the panel positions at the center of the active display, and selecting an item copies it to `NSPasteboard` without synthesizing keyboard events.

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

### Local Development Signing (Ad-hoc)
For local development, builds, and automated testing, ClipText is signed using ad-hoc signing (`-s -`) with embedded entitlements:
```bash
codesign --force --deep --sign - --entitlements ClipText/ClipText.entitlements build/Release/ClipText.app
```

> **Important Note on Rebuilding**: macOS TCC (Transparency, Consent, and Control) tracks permissions by code signature identity (CDHash / designated requirement). Rebuilding with ad-hoc signing generates a new CDHash. If macOS prompts for Screen Recording access again after a rebuild, remove the prior entry from **System Settings > Privacy & Security > Screen Recording** and grant it for the newly built binary.

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
