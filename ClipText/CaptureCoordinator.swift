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

enum CaptureState: Equatable {
    case idle
    case selecting
    case recognizing
    case copied(count: Int)
    case noTextFound
    case screenRecordingRequired
    case cancelled
    case timedOut
    case displayUnavailable
    case failed(String)
}

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

    @Published private(set) var captureState: CaptureState = .idle
    @Published private(set) var isSelecting: Bool = false
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var canRetry: Bool = false
    @Published private(set) var canCopyAgain: Bool = false
    @Published var statusMessage: String?

    private(set) var lastRecognizedText: String?
    private(set) var lastSourceApplication: ClipboardSourceApplication?

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

        // Checking access is non-prompting. The user chooses when to open System Settings.
        guard permissionsManager.hasScreenRecordingPermission else {
            captureState = .screenRecordingRequired
            statusMessage = CaptureRecovery.screenRecordingRequired
            canRetry = true
            canCopyAgain = false
            SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "Screen recording required")
            return
        }

        statusMessage = "Select an area."
        captureState = .selecting
        canRetry = false
        canCopyAgain = false
        SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "Capture session started")

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
                self.captureState = .cancelled
                self.statusMessage = "Capture cancelled."
                self.canRetry = false
                self.canCopyAgain = false
                SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "Capture cancelled by user")
                previousApp?.activate()
            }
        )
    }

    func retryCapture() {
        startCapture()
    }

    func copyAgain() {
        guard let text = lastRecognizedText, !text.isEmpty else { return }
        let snapshot = ClipboardSnapshot(
            text: text,
            richTextData: nil,
            imageData: nil,
            imageType: nil,
            fileURLs: []
        )
        monitor?.suppressFingerprint(snapshot.fingerprint)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        monitor?.recordAppOriginatedWrite(changeCount: pasteboard.changeCount, fingerprint: snapshot.fingerprint)
        store?.ingest(snapshot, sourceApplication: lastSourceApplication)
        statusMessage = "Copied \(text.count) characters."
        selectionController.showStatus("Copied again", on: nil)
        SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "Copied recognized text again")
    }

    private func processCapture(rect: CGRect, on screen: NSScreen?, previousApp: NSRunningApplication?) async {
        guard !rect.isNull, !rect.isInfinite,
              !rect.origin.x.isNaN, !rect.origin.y.isNaN,
              !rect.size.width.isNaN, !rect.size.height.isNaN,
              rect.width > 2, rect.height > 2 else {
            captureState = .cancelled
            statusMessage = "Capture cancelled."
            canRetry = false
            canCopyAgain = false
            previousApp?.activate()
            return
        }

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
            captureState = .displayUnavailable
            statusMessage = "Display unavailable."
            canRetry = true
            canCopyAgain = false
            selectionController.showStatus("Display unavailable", on: screen)
            SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "Display unavailable")
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
        captureState = .recognizing
        statusMessage = "Recognizing…"
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
            statusMessage = "Recognizing…"
            let configuration = OCRConfiguration.accurate
            let result = try await withTimeout(60) { [ocrManager, image] in
                try await ocrManager.recognizeText(from: image, configuration: configuration)
            }

            let recognizedText = result.text.trimmingWhitespaceAndNewlines()
            guard !recognizedText.isEmpty else {
                captureState = .noTextFound
                statusMessage = "No text found."
                canRetry = true
                canCopyAgain = false
                selectionController.showStatus("No text found", on: targetScreen)
                SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "No text found in region")
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
            lastSourceApplication = sourceApp
            lastRecognizedText = recognizedText
            store?.ingest(snapshot, sourceApplication: sourceApp)

            // 4. Update user-facing state & HUD
            canRetry = false
            canCopyAgain = true
            captureState = .copied(count: recognizedText.count)
            statusMessage = "Copied \(recognizedText.count) characters."
            selectionController.showStatus("Copied", on: targetScreen)
            SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "Copied \(recognizedText.count) characters")
        } catch let error as ClipTextError {
            switch error {
            case .operationTimedOut:
                captureState = .timedOut
                statusMessage = "Capture timed out."
                canRetry = true
                canCopyAgain = false
                selectionController.showStatus("Capture timed out", on: targetScreen)
                SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "Capture timed out")
            default:
                captureState = .failed(error.localizedDescription)
                statusMessage = "OCR failed."
                canRetry = true
                canCopyAgain = false
                selectionController.showStatus("OCR Failed", on: targetScreen)
                SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "OCR failed")
            }
        } catch {
            Logger.shared.error("Screen OCR failed: \(error.localizedDescription)")
            captureState = .failed(error.localizedDescription)
            statusMessage = "OCR failed."
            canRetry = true
            canCopyAgain = false
            selectionController.showStatus("OCR Failed", on: targetScreen)
            SanitizedDiagnosticsLog.shared.log(category: "ScreenOCR", message: "OCR failed")
        }
    }
}
