//
//  ScreenCaptureManager.swift
//  ClipText
//
//  Adapted from TextGrab (https://github.com/arsh342/TextGrab)
//  Copyright (c) 2026 arsh342. MIT License.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Sendable snapshot of an NSScreen's capture-relevant properties.
struct DisplayInfo: Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScaleFactor: CGFloat
    let localizedName: String
}

protocol ScreenCaptureService: Actor {
    func capture(display: DisplayInfo, region: CGRect) async throws -> CGImage
    func invalidateCache() async
}

actor ScreenCaptureManager: ScreenCaptureService {
    private var availableContent: SCShareableContent?
    private var contentLoadTask: Task<SCShareableContent, Error>?
    private var currentOperationID: UUID?
    private var displayChangeObserver: NSObjectProtocol?
    private var observerInstalled = false

    init() {}

    private func installDisplayChangeObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.invalidateCache() }
        }
    }

    deinit {
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func capture(display: DisplayInfo, region: CGRect) async throws -> CGImage {
        installDisplayChangeObserverIfNeeded()
        Logger.shared.debug("Capturing screen region: \(region) on display: \(display.localizedName)")

        var content = try await getShareableContent()
        var scDisplay = content.displays.first(where: { $0.displayID == display.displayID })
        if scDisplay == nil {
            await invalidateCache()
            content = try await getShareableContent()
            scDisplay = content.displays.first(where: { $0.displayID == display.displayID })
        }
        guard let scDisplay else {
            throw ClipTextError.captureFailed("Display not found in shareable content")
        }

        let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
        let displayFrame = display.frame
        let captureRegion = region
            .insetBy(dx: -2, dy: -2)
            .intersection(displayFrame)
        guard !captureRegion.isNull, captureRegion.width > 0, captureRegion.height > 0 else {
            throw ClipTextError.captureFailed("Selected region is outside the display")
        }
        let localRegion = CGRect(
            x: captureRegion.origin.x - displayFrame.origin.x,
            y: displayFrame.maxY - captureRegion.maxY,
            width: captureRegion.width,
            height: captureRegion.height
        )

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((localRegion.width * display.backingScaleFactor).rounded()))
        configuration.height = max(1, Int((localRegion.height * display.backingScaleFactor).rounded()))
        configuration.sourceRect = localRegion
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        Logger.shared.debug("Capture completed: \(image.width)x\(image.height)")
        return image
    }

    func invalidateCache() async {
        availableContent = nil
        contentLoadTask?.cancel()
        contentLoadTask = nil
        currentOperationID = nil
        Logger.shared.debug("ScreenCaptureKit cache invalidated")
    }

    private func getShareableContent() async throws -> SCShareableContent {
        if let cached = availableContent {
            return cached
        }

        if let existingTask = contentLoadTask {
            return try await existingTask.value
        }

        let operationID = UUID()
        currentOperationID = operationID

        let task = Task { () -> SCShareableContent in
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return content
        }
        contentLoadTask = task

        do {
            let content = try await task.value
            if currentOperationID == operationID {
                if !task.isCancelled {
                    availableContent = content
                }
                contentLoadTask = nil
                currentOperationID = nil
            }
            return content
        } catch {
            if currentOperationID == operationID {
                contentLoadTask = nil
                currentOperationID = nil
            }
            throw error
        }
    }
}
