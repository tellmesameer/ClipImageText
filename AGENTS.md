# ClipText: Project Instructions for Antigravity

## 1. Project goal

Build **ClipText**, a lightweight, native macOS menu-bar application that combines:

1. **PowerToys-style screen-region text extraction**: press a global keyboard shortcut, select a rectangle anywhere on the screen, run OCR locally, and copy the recognized text to the system clipboard automatically.
2. **Persistent clipboard history**: monitor ordinary clipboard copies, retain supported items locally, search history, and restore/paste prior entries.
3. **Unified storage**: text extracted by OCR must be saved into the same history as ordinary clipboard copies.

The essential product promise is: **one open-source app, one clipboard history, and a fast screen-to-text shortcut**. Do not implement these as disconnected features.

## 2. User and target environment

- Target device: MacBook Air M5 (Apple Silicon).
- Minimum target: macOS 14 (Sonoma), unless an upstream dependency or required API makes this impossible. If the minimum must change, explain why before changing it.
- Language: Swift.
- UI: SwiftUI with AppKit where native macOS APIs are needed.
- OCR: Apple Vision, entirely on-device.
- Clipboard: `NSPasteboard`.
- Screen selection/capture: reuse the tested approach in TextGrab rather than inventing a new overlay by default.
- Global shortcuts: prefer a proven existing implementation from the reference repositories; do not add a new shortcut dependency without a clear reason.
- Storage: begin with the existing storage approach in the selected clipboard-manager base. Do not migrate to SQLite without a demonstrated need.
- Privacy: local-first. No account, telemetry, remote OCR, or cloud dependency for core functions.

## 3. Reference repositories

Inspect these repositories and their current code before making architectural decisions. Do not rely only on README summaries.

### Primary base: clipboard history

- Repository: https://github.com/Kelsiito/clipboard
- Useful files:
  - `clipboard/ClipboardStore.swift`
  - `clipboard/PasteboardMonitor.swift`
  - `clipboard/LocalOCRService.swift`
  - `clipboard/GlobalHotKey.swift`
  - `clipboard/Models.swift`
  - `clipboard/ClipboardPanelController.swift`
  - `clipboard/SettingsView.swift`
  - `clipboard/SecureLocalStorage.swift`
- Reuse its working design for clipboard monitoring, local history, clipboard-item modeling, hotkeys, history UI, and local image OCR where appropriate.
- It already indexes text from copied images, but that is **not the same** as a system-wide shortcut that lets a user select an arbitrary screen region.

### Screen-region OCR reference

- Repository: https://github.com/arsh342/TextGrab
- Useful files:
  - `TextGrab/App/CaptureCoordinator.swift`
  - `TextGrab/App/CapturePipeline.swift`
  - `TextGrab/Capture/ScreenCaptureManager.swift`
  - `TextGrab/Selection/SelectionController.swift`
  - `TextGrab/Selection/SelectionOverlayView.swift`
  - `TextGrab/Selection/SelectionWindowManager.swift`
  - `TextGrab/OCR/OCRManager.swift`
  - `TextGrab/OCR/OCRModels.swift`
  - `TextGrab/Clipboard/ClipboardManager.swift`
  - `TextGrab/Shortcut/GlobalShortcutManager.swift`
  - `TextGrab/Permissions/PermissionsManager.swift`
- Adapt its screen-capture, screen-selection, Vision pipeline, shortcut, and permission patterns to ClipText's architecture.

### Additional architecture reference

- Repository: https://github.com/tamibot/klip
- Useful areas: `Sources/Klip/Capture/`, `Sources/Klip/Clipboard/`, `Sources/Klip/UI/`, `Sources/Klip/App/`.
- Use it as a secondary reference for separating capture, storage, and UI concerns.

### Source and licensing rules

- These repositories are references, not permission to ignore licensing.
- Check and preserve each upstream `LICENSE` and any applicable notices before copying or adapting code.
- Both the primary clipboard repository and TextGrab declare permissive MIT licensing at the time this brief was prepared. Verify the license files in the checked-out revisions before reuse.
- Preserve copyright notices and document substantial reuse in `Documentation/UpstreamAttributions.md`.
- Do not blindly merge whole repositories, duplicate app entry points, or copy conflicting model/UI types. Port only the minimum required components and integrate them deliberately.

## 4. Product behavior

### A. Screen OCR

- Register a configurable global shortcut. Suggested initial default: `Option + Shift + T`; check for conflicts and allow the user to change it.
- On activation, show a screen-region selection overlay and allow the user to cancel without side effects.
- Support multiple displays and correct Retina/backing-scale coordinate conversion.
- Capture only the selected region.
- Run Apple Vision text recognition locally.
- Keep recognized lines in natural reading order and join lines with newline characters.
- Copy the result to `NSPasteboard` automatically.
- Add that text to clipboard history through the same store/API used for normal copied text.
- Give short, non-intrusive feedback for success, empty OCR results, cancellation, and permission failures. Do not open an unnecessary editor window for the core workflow.
- Ensure OCR failures and cancellation do not erase or corrupt the user's existing clipboard/history.

### B. Clipboard history

- Monitor clipboard changes while the app is running.
- Support at minimum plain text and common image formats. Keep the data model extensible for rich text, URLs, and file references.
- Persist history across app restarts.
- Provide a history picker with search, keyboard navigation, selection, and recopy/paste behavior.
- Provide a configurable history limit and clear-history control.
- Deduplicate repeated clipboard entries and move a repeated entry to the top rather than creating unbounded duplicates.
- Add pin/favorite and age-based cleanup only after the core flow is stable.
- Respect macOS concealed/transient pasteboard markers where applicable. Do not intentionally retain password-manager or other explicitly concealed clipboard contents.
- Offer pause monitoring and per-app exclusions if practical, but do not delay the MVP for these extras.

### C. Keyboard shortcuts

- OCR shortcut: configurable; initial proposal `Option + Shift + T`.
- Clipboard history shortcut: configurable; initial proposal `Option + Shift + V`.
- Detect registration failures and show a useful settings message. Never silently pretend a shortcut was registered.
- Keep shortcut handling separate from OCR and history logic so the shortcut mechanism can be tested independently.

### D. App lifecycle and permissions

- Menu-bar app with no required Dock presence during normal use.
- Launch-at-login should be optional and disabled until the user enables it.
- Explain and request screen-capture permissions only when needed.
- Handle the macOS requirement to reopen/restart after granting Screen Recording access when necessary.
- Request Accessibility access only if a particular paste automation behavior actually requires it. Do not request permissions speculatively.

## 5. Suggested project layout

Adapt this layout to the actual base repository instead of renaming or moving files for cosmetic reasons.

```text
ClipText/
├── ClipText.xcodeproj/
├── ClipText/
│   ├── App/
│   │   ├── ClipTextApp.swift
│   │   ├── AppState.swift
│   │   └── CaptureCoordinator.swift
│   ├── Capture/
│   │   ├── CapturePipeline.swift
│   │   └── ScreenCaptureManager.swift
│   ├── Selection/
│   │   ├── SelectionController.swift
│   │   ├── SelectionOverlayView.swift
│   │   └── SelectionWindowManager.swift
│   ├── OCR/
│   │   ├── LocalOCRService.swift
│   │   ├── OCRModels.swift
│   │   └── OCRTextProcessor.swift
│   ├── Clipboard/
│   │   ├── PasteboardMonitor.swift
│   │   ├── PasteboardService.swift
│   │   ├── ClipboardSnapshot.swift
│   │   ├── ClipboardItem.swift
│   │   └── ClipboardStore.swift
│   ├── Shortcuts/
│   │   ├── GlobalHotKeyManager.swift
│   │   └── ShortcutConfiguration.swift
│   ├── UI/
│   │   ├── MenuBarView.swift
│   │   ├── ClipboardHistoryView.swift
│   │   ├── ClipboardHistoryViewModel.swift
│   │   ├── ClipboardItemRow.swift
│   │   └── SettingsView.swift
│   ├── Permissions/
│   │   └── PermissionManager.swift
│   ├── Utilities/
│   │   └── Logger.swift
│   └── Resources/
│       ├── Assets.xcassets/
│       ├── Info.plist
│       └── ClipText.entitlements
├── ClipTextTests/
├── ClipTextUITests/
├── Documentation/
│   ├── Architecture.md
│   ├── Permissions.md
│   └── UpstreamAttributions.md
├── README.md
├── LICENSE
└── .gitignore
```

## 6. Architecture and integration rules

- Keep the OCR pipeline independent from the history UI.
- Use a small, explicit boundary such as `ClipboardStore.addText(_:source:)` for both normal text copies and OCR output.
- The OCR success path should be conceptually:

  `Global hotkey -> region selection -> capture image -> Vision OCR -> normalize text -> clipboard write + history insert -> brief success feedback`

- The regular-copy path should be:

  `NSPasteboard change -> read supported content -> filter concealed/transient data -> normalize/fingerprint -> deduplicate -> persist -> update history UI`

- Prevent duplicate history entries when the app itself writes OCR results to the pasteboard and the monitor observes the same write. Use a source marker, expected change/fingerprint tracking, or store-level deduplication. Do not solve this with fragile timing alone.
- Ensure main-thread UI updates, but move expensive OCR, image decoding, and persistence work off the main thread as appropriate.
- Avoid creating multiple competing app delegates, `@main` entry points, settings stores, clipboard models, or hotkey managers while porting code.
- Prefer native Apple frameworks and existing dependencies in the base repo. Add external packages only when they provide necessary capability that is not reasonably available natively.
- Keep names, errors, and responsibilities clear. Avoid giant manager classes that own UI, permissions, hotkeys, OCR, and storage simultaneously.

## 7. Implementation phases

Work in small phases. Build and test after each phase. Do not attempt a broad rewrite in one step.

### Phase 0: Repository assessment

1. Inspect the selected primary repository and the TextGrab reference files.
2. Record the current Xcode project structure, deployment target, build method, entitlements, existing dependencies, and tests.
3. Verify current licenses and source attribution requirements.
4. Produce a short integration plan that identifies files to reuse, adapt, add, or leave untouched.
5. Do not change application code before presenting the plan and confirming the base build succeeds.

### Phase 1: Stable base and project identity

1. Start from the clipboard-manager repository as the base, preserving its history functionality.
2. Rename the app/product to ClipText only where required for a coherent build; avoid unnecessary global search-and-replace.
3. Run its existing build/tests and record the result.

### Phase 2: Screen-region OCR

1. Integrate the screen-selection and capture path from TextGrab.
2. Wire a configurable global OCR hotkey.
3. Run Apple Vision on the selected region.
4. Copy recognized text and persist it through the shared clipboard-history API.
5. Test cancellation, empty results, permission denial, multi-monitor selection, Retina scaling, and dark-background text.

### Phase 3: Unified clipboard history

1. Ensure ordinary text/image copies still enter history.
2. Ensure OCR results appear exactly once in history.
3. Test search, selection, recopy/paste, duplicate suppression, persistence after restart, and history limits.
4. Add protections for concealed/transient pasteboard types and a clear-history action.

### Phase 4: Settings, polish, and robustness

1. Expose shortcut configuration and history limit.
2. Add a pause-history control if it can be implemented cleanly.
3. Review accessibility, permission messaging, logging, and app lifecycle behavior.
4. Add automated tests for store behavior and OCR text processing.
5. Update README and documentation with installation, permissions, keyboard shortcuts, privacy behavior, and upstream attributions.

## 8. Acceptance criteria

The project is not considered complete until all of these work on a real Mac:

- [ ] The app builds with the documented command and opens normally.
- [ ] A global hotkey invokes screen-region selection from another foreground application.
- [ ] The selected region is recognized using on-device OCR.
- [ ] The result is automatically copied to the system clipboard.
- [ ] The result is added exactly once to the same persistent history as normal copies.
- [ ] Normal text and image copies are captured and can be retrieved later.
- [ ] Clipboard history is searchable and survives app restarts.
- [ ] A prior entry can be selected and restored/copied for pasting.
- [ ] OCR cancellation, errors, and denied permissions leave existing clipboard data intact.
- [ ] Hotkey conflicts and missing permissions are communicated clearly.
- [ ] No clipboard payloads are sent to a network service.
- [ ] Tests cover deduplication, persistence, text normalization, and OCR-to-history integration.
- [ ] License and upstream attribution files are preserved and accurate.

## 9. Build and test expectations

- First discover the actual project scheme and commands from the repository. Do not invent a scheme name or claim tests passed without running them.
- If the project is an Xcode project, prefer commands shaped like:

  ```bash
  xcodebuild -list -project ClipText.xcodeproj
  xcodebuild -project ClipText.xcodeproj -scheme ClipText -destination 'platform=macOS' build
  xcodebuild -project ClipText.xcodeproj -scheme ClipText -destination 'platform=macOS' test
  ```

- Adjust commands if the base repository uses Swift Package Manager or a different project/scheme name.
- Report exact commands executed and their results. If the build cannot run because Xcode/SDKs are missing, state that directly and do not mark it as successful.

## 10. How Antigravity should work

- Start by inspecting the workspace and the referenced upstream code. Do not assume files or APIs exist; verify them.
- Before modifying code, propose a concise plan and identify the exact files expected to change.
- Prefer incremental, compiling changes over large speculative edits.
- Do not replace functioning upstream implementations merely to match the suggested folder layout.
- Ask before destructive changes, deleting existing user data, changing licenses, or adding network/telemetry behavior.
- Never disable security checks, weaken permissions, or bypass macOS protections to make a demo appear to work.
- After each meaningful change, run the narrowest relevant tests/build and fix regressions before continuing.
- Keep documentation aligned with actual behavior. Clearly distinguish implemented features from planned features.
- When finished, summarize changes, tests run, known limitations, required permissions, and the exact build/run instructions.

## 11. First task for the agent

Do **Phase 0 only** first: inspect the current workspace and the reference repositories, verify licenses, identify the base build and scheme, and return a concrete integration plan with a file-by-file reuse/adaptation list. Do not implement features or rewrite the project during this first task.
