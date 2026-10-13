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

### First-time Screen Recording permission

- [ ] Open a different application (e.g., Safari, Notes, or Terminal) so ClipText is **not** the frontmost app
- [ ] Press `⌥⇧T` (Option + Shift + T)
- [ ] macOS should present the Screen Recording permission prompt
- [ ] Grant permission in **System Settings > Privacy & Security > Screen Recording**
- [ ] Quit and relaunch ClipText (macOS requires this after granting Screen Recording)
- [ ] Confirm ClipText's Settings view no longer shows a "Relaunch" warning for Screen Recording

### Subsequent OCR use

- [ ] Switch to an application with visible text (e.g., a webpage or PDF)
- [ ] Press `⌥⇧T`
- [ ] A selection overlay should appear across the full screen
- [ ] Draw a rectangle around a block of text
- [ ] Release the mouse — a brief success feedback HUD should appear
- [ ] Paste (`⌘V`) into any text field — the extracted text should be present
- [ ] Open clipboard history (`⌘⇧V`) — the OCR text should appear **exactly once**

### Multi-display selection

- [ ] If an external display is connected, press `⌥⇧T` and drag a selection on the **external** display
- [ ] Verify text is extracted correctly from the external display
- [ ] Verify Retina / non-Retina scaling does not distort the capture region

### Cancellation

- [ ] Press `⌥⇧T`, then press `Esc` before releasing the mouse
- [ ] Verify nothing is copied — the previous clipboard content is preserved
- [ ] Verify no new entry appears in clipboard history

### Empty result

- [ ] Press `⌥⇧T` and select a region with no text (e.g., a solid background)
- [ ] Verify the clipboard is not modified
- [ ] Verify a non-intrusive "No text found" HUD appears

---

## 2. Clipboard History (`⌘⇧V`)

### Basic history and search

- [ ] Copy several different text items using `⌘C` in various apps
- [ ] Press `⌘⇧V` — the history panel should appear
- [ ] Verify all copied items are listed in reverse chronological order
- [ ] Type a search query — results should filter to matching items
- [ ] Use arrow keys to navigate and press `Enter` to select an item
- [ ] Paste (`⌘V`) — the selected historical item should be pasted

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
