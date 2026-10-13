# Manual Acceptance Checklist

This checklist covers behaviors that **cannot be verified by the automated XCTest suite or CI** because they require:

- macOS TCC (Transparency, Consent, and Control) permission grants
- Live Screen Recording access
- A running GUI session with multiple displays
- Keyboard interaction from a foreground application other than Xcode

Complete every item before creating a GitHub Release.

---

## Prerequisites

- [ ] Build ClipText with `./scripts/build.sh`
- [ ] Install with `./scripts/install.sh --user` (or `--system`)
- [ ] Run `./scripts/verify.sh` and confirm all 5 automated checks pass
- [ ] Launch ClipText **from Finder or `open ~/Applications/ClipText.app`** (not from Xcode)
- [ ] Confirm the menu bar icon appears and no Dock icon is shown

---

## 1. Screen-Region OCR (`⌥⇧T`)

### 1. Screen Recording permission behavior
- [ ] (Optional clean slate): Run `./scripts/uninstall.sh` to remove prior installs and reset macOS permissions to a clean, unprompted state
- [ ] Open a different application (e.g., Safari, Notes, or Terminal) so ClipText is **not** the frontmost app
- [ ] Press `⌥⇧T` (Option + Shift + T)
- [ ] macOS should present the Screen Recording permission prompt if not yet granted
- [ ] If permission is denied or missing, verify ClipText shows clear guidance and does not crash or leave broken overlays
- [ ] Grant permission in **System Settings > Privacy & Security > Screen Recording**
- [ ] Quit and relaunch ClipText (macOS requires restart after granting Screen Recording)
- [ ] Confirm ClipText's Settings view no longer shows a "Relaunch" warning for Screen Recording
- [ ] Rebuild and re-install ClipText using `./scripts/build.sh` and `./scripts/install.sh --system`
- [ ] Confirm that Screen Recording permissions persist without repeating the macOS permission prompt (stable Designated Requirement)

### 2. OCR on the primary display
- [ ] Switch to an application with visible text on the primary display
- [ ] Press `⌥⇧T` — verify transparent overlays appear seamlessly across all displays
- [ ] Draw a selection rectangle on the primary display around text
- [ ] Release the mouse — verify brief success feedback HUD appears on the primary screen
- [ ] Paste (`⌘V`) — verify the recognized text matches the selected text
- [ ] Open clipboard history (`⌘⇧V`) — verify the item appears exactly once

### 3. OCR on each secondary display
- [ ] With one or more external displays connected, switch to text on a secondary display
- [ ] Press `⌥⇧T` — verify the selection overlay responds smoothly to mouse events on the secondary display
- [ ] Draw a selection rectangle exclusively on the secondary display
- [ ] Release the mouse — verify the status HUD appears on that display and recognized text is copied
- [ ] Verify extracted text matches without clipping or coordinate misalignment

### 4. Selection on displays arranged left or above the primary display
- [ ] In **System Settings > Displays > Arrange**, position a secondary display to the left of the primary display (negative X coordinate origin)
- [ ] Press `⌥⇧T` and select text on the left display
- [ ] Verify coordinates are correctly mapped to local display space and text is accurately extracted
- [ ] Rearrange a display above the primary display (positive Y offset)
- [ ] Press `⌥⇧T` and select text on the top display; verify capture and OCR succeed without vertical offset errors

### 5. Accurate OCR from Retina-scaled displays
- [ ] Test OCR on a Retina display (2x scale, e.g., MacBook built-in liquid retina)
- [ ] Test OCR on a standard (1x scale) external monitor
- [ ] Test a setup with mixed scales (built-in Retina 2x + external 1x)
- [ ] Verify that captured images preserve full native pixel resolution and do not blur or crop text
- [ ] Verify selections crossing the boundary between 1x and 2x displays stitch cleanly and yield readable text

### 6. Escape cancellation and cleanup
- [ ] Press `⌥⇧T` to show multi-display overlays
- [ ] Press `Esc` before dragging or mid-drag
- [ ] Verify that **all** overlay windows on **all** connected displays immediately disappear
- [ ] Verify pre-existing clipboard contents are completely unchanged
- [ ] Verify no blank or partial entry is written to clipboard history

### 7. Repeated selections and lingering overlay prevention
- [ ] Perform 5 consecutive captures in rapid succession (`⌥⇧T`, select text, release)
- [ ] Verify that after each capture, overlay windows are fully dismissed without lingering invisible hit-test traps
- [ ] Verify clicks pass normally through to background applications between captures
- [ ] Verify that duplicate captures of identical text move the existing entry to top without duplicating entries in history
- [ ] Test display disconnection or resolution change while overlay is active: verify overlays safely dismiss without crashing (screen reconfiguration observer)

### 8. Empty result
- [ ] Press `⌥⇧T` and select a region with no text (e.g., a solid blank background)
- [ ] Verify the clipboard is not modified
- [ ] Verify a non-intrusive "No text found" HUD appears and overlays are dismissed

---

## 2. Clipboard History (`⌘⇧V`)

### Basic history and search

- [ ] Copy several different text items using `⌘C` in various apps
- [ ] Press `⌘⇧V` — the history panel should appear
- [ ] Verify all copied items are listed in reverse chronological order
- [ ] Type a search query — results should filter to matching items
- [ ] Use arrow keys to navigate and press `Enter` to select an item
- [ ] Paste (`⌘V`) — the selected historical item should be pasted

### Draggable header and custom position persistence

- [ ] Click and drag anywhere in the history panel header area (title, search bar background, top bar)
- [ ] Verify the panel moves smoothly with the mouse drag
- [ ] Release the panel in a custom location on screen
- [ ] Dismiss the panel (`Esc` or click outside) and reopen with `⌘⇧V`
- [ ] Verify the panel reopens at the saved custom position
- [ ] In Settings, verify "Reset Position" restores automatic placement behavior

### Deduplication

- [ ] Copy the same text twice
- [ ] Open history — the item should appear **once** (moved to top), not duplicated

### Persistence across restarts

- [ ] Quit ClipText entirely
- [ ] Relaunch ClipText
- [ ] Press `⌘⇧V` — all previously copied items should still be present

### Pin and clear

- [ ] Pin an item in the history panel
- [ ] Use the Clear History control
- [ ] Verify pinned items survive the clear, unpinned items are removed

---

## 3. App Lifecycle

### Independent launch (no Xcode)

- [ ] Quit Xcode entirely
- [ ] Launch ClipText from Finder or `open` command
- [ ] Verify the app runs normally without Xcode

### Gatekeeper first-launch

- [ ] On a machine where ClipText has never been launched:
  - Right-click `ClipText.app` → Open → confirm the Gatekeeper dialog
  - OR approve via System Settings > Privacy & Security > Open Anyway
- [ ] Verify the app launches after approval

### Menu bar behavior

- [ ] Confirm ClipText appears only in the menu bar, not the Dock
- [ ] Click the menu bar icon — verify the menu appears with expected controls
- [ ] Verify Settings opens and all controls are functional

---

## 4. Edge Cases

- [ ] Copy an image — verify it appears in clipboard history with a thumbnail preview
- [ ] Copy from a password manager — verify concealed/transient clipboard items are **not** stored
- [ ] With Accessibility permission granted: verify the history panel anchors to the text caret position
- [ ] Without Accessibility permission: verify the panel appears centered on the active display

---

## Sign-off

| Tester | Date | macOS Version | Display Config | Result |
| :--- | :--- | :--- | :--- | :--- |
| | | | | |

> **Do not create a public GitHub Release until every checkbox above is checked.**
> The current build is **ad-hoc signed and not notarized**. It is not ready for unrestricted public distribution.
