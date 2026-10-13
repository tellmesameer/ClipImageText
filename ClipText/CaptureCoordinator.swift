//
//  CaptureCoordinator.swift
//  ClipText
//
//  Adapted from TextGrab (https://github.com/arsh342/TextGrab)
//  Copyright (c) 2026 arsh342. MIT License.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class CaptureCoordinator: ObservableObject {
    private let screenCapture: ScreenCaptureService
    private let ocrManager: OCRService
    private let selectionController: SelectionController
    private let permissionsManager: PermissionsService
    private let pasteboard: NSPasteboard
    private let displayProvider: () -> [DisplayInfo]
    private weak var store: ClipboardStore?
    private weak var monitor: PasteboardMonitor?

    @Published private(set) var isSelecting: Bool = false
    @Published private(set) var isProcessing: Bool = false
    @Published var statusMessage: String?

    init(
        store: ClipboardStore,
        monitor: PasteboardMonitor,
        permissionsManager: PermissionsService? = nil,
        screenCapture: ScreenCaptureService? = nil,
        ocrManager: OCRService? = nil,
        selectionController: SelectionController? = nil,
        pasteboard: NSPasteboard = .general,
        displayProvider: (() -> [DisplayInfo])? = nil
    ) {
        self.store = store
        self.monitor = monitor
        self.permissionsManager = permissionsManager ?? PermissionsManager()
        self.screenCapture = screenCapture ?? ScreenCaptureManager()
        self.ocrManager = ocrManager ?? OCRManager()
        self.selectionController = selectionController ?? DefaultSelectionController.makeDefault()
        self.pasteboard = pasteboard
        self.displayProvider = displayProvider ?? {
            NSScreen.screens.compactMap { screen in
                guard let displayID = screen.displayID else { return nil }
                return DisplayInfo(
                    displayID: displayID,
                    frame: screen.frame,
                    backingScaleFactor: screen.backingScaleFactor,
                    localizedName: screen.localizedName
                )
            }
        }
    }

    func startCapture() {
        guard !isSelecting && !isProcessing else { return }

        // Check screen recording permission first
        guard permissionsManager.hasScreenRecordingPermission else {
            Task { @MainActor in
                let granted = await permissionsManager.requestScreenRecordingPermission()
                if !granted {
                    statusMessage = "Screen Recording permission required. Enable in System Settings and relaunch ClipText."
                }
            }
            return
        }

        let previousApp = NSWorkspace.shared.frontmostApplication
        isSelecting = true

        selectionController.startSelection(
            onComplete: { [weak self] rect, screen in
                guard let self else { return }
                self.isSelecting = false
                Task { @MainActor in
                    await self.processCapture(rect: rect, on: screen, previousApp: previousApp)
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.isSelecting = false
                previousApp?.activate()
            }
        )
    }

    private func processCapture(rect: CGRect, on screen: NSScreen?, previousApp: NSRunningApplication?) async {
        let displays = displayProvider()
        let availableDisplays: [DisplayInfo]
        if !displays.isEmpty {
            availableDisplays = displays
        } else if let screen, let displayID = screen.displayID {
            availableDisplays = [
                DisplayInfo(
                    displayID: displayID,
                    frame: screen.frame,
                    backingScaleFactor: screen.backingScaleFactor,
                    localizedName: screen.localizedName
                )
            ]
        } else if let main = NSScreen.main, let displayID = main.displayID {
            availableDisplays = [
                DisplayInfo(
                    displayID: displayID,
                    frame: main.frame,
                    backingScaleFactor: main.backingScaleFactor,
                    localizedName: main.localizedName
                )
            ]
        } else {
            previousApp?.activate()
            return
        }

        let intersecting = availableDisplays.filter { display in
            let intersection = rect.intersection(display.frame)
            return !intersection.isNull && intersection.width > 2 && intersection.height > 2
        }
        let displaysToCapture = intersecting.isEmpty ? availableDisplays : intersecting
        let targetDisplay = ScreenCoordinateConverter.targetDisplay(for: rect, in: displaysToCapture) ?? displaysToCapture[0]
        let targetScreen = screen ?? NSScreen.screens.first(where: { $0.displayID == targetDisplay.displayID }) ?? NSScreen.main

        isProcessing = true
        defer {
            isProcessing = false
            previousApp?.activate()
        }

        do {
            // 1. Capture selected screen region (multi-display aware)
            let image = try await withTimeout(15) { [screenCapture] in
                try await screenCapture.capture(displays: displaysToCapture, region: rect)
            }

            // 2. Perform Apple Vision OCR
            let configuration = OCRConfiguration.accurate
            let result = try await withTimeout(60) { [ocrManager, image] in
                try await ocrManager.recognizeText(from: image, configuration: configuration)
            }

            let recognizedText = result.text.trimmingWhitespaceAndNewlines()
            guard !recognizedText.isEmpty else {
                selectionController.showStatus("No text found", on: targetScreen)
                return
            }

            // 3. Write recognized text to clipboard and unified history
            let snapshot = ClipboardSnapshot(
                text: recognizedText,
                richTextData: nil,
                imageData: nil,
                imageType: nil,
                fileURLs: []
            )

            // Suppress monitor capture and record fingerprint for deduplication
            monitor?.suppressFingerprint(snapshot.fingerprint)

            // Write to system pasteboard
            pasteboard.clearContents()
            pasteboard.setString(recognizedText, forType: .string)
            monitor?.recordAppOriginatedWrite(changeCount: pasteboard.changeCount, fingerprint: snapshot.fingerprint)

            // Ingest into unified store
            let sourceApp = previousApp.flatMap { app -> ClipboardSourceApplication? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return ClipboardSourceApplication(bundleIdentifier: bundleID, name: app.localizedName ?? bundleID)
            }
            store?.ingest(snapshot, sourceApplication: sourceApp)

            // 4. Show success indicator HUD pill
            selectionController.showStatus("Copied", on: targetScreen)
        } catch {
            Logger.shared.error("Screen OCR failed: \(error.localizedDescription)")
            selectionController.showStatus("OCR Failed", on: targetScreen)
        }
    }
}
