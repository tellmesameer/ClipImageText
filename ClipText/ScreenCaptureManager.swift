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
struct DisplayInfo: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScaleFactor: CGFloat
    let localizedName: String
}

struct ScreenCoordinateConverter {
    struct LocalCaptureGeometry: Equatable {
        let sourceRect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func targetScreen(for rect: CGRect, in screens: [NSScreen]) -> NSScreen? {
        guard !screens.isEmpty else { return nil }
        var bestScreen: NSScreen?
        var maxArea: CGFloat = 0

        for screen in screens {
            let intersection = rect.intersection(screen.frame)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > maxArea {
                    maxArea = area
                    bestScreen = screen
                }
            }
        }
        if let bestScreen { return bestScreen }
        let rectCenter = CGPoint(x: rect.midX, y: rect.midY)
        return screens.min(by: { s1, s2 in
            let d1 = hypot(s1.frame.midX - rectCenter.x, s1.frame.midY - rectCenter.y)
            let d2 = hypot(s2.frame.midX - rectCenter.x, s2.frame.midY - rectCenter.y)
            return d1 < d2
        }) ?? screens.first
    }

    static func targetDisplay(for rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard !displays.isEmpty else { return nil }
        var bestDisplay: DisplayInfo?
        var maxArea: CGFloat = 0

        for display in displays {
            let intersection = rect.intersection(display.frame)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > maxArea {
                    maxArea = area
                    bestDisplay = display
                }
            }
        }
        if let bestDisplay { return bestDisplay }
        let rectCenter = CGPoint(x: rect.midX, y: rect.midY)
        return displays.min(by: { d1, d2 in
            let d1Dist = hypot(d1.frame.midX - rectCenter.x, d1.frame.midY - rectCenter.y)
            let d2Dist = hypot(d2.frame.midX - rectCenter.x, d2.frame.midY - rectCenter.y)
            return d1Dist < d2Dist
        }) ?? displays.first
    }

    static func convertToScreenCoordinates(localRect: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.origin.x + localRect.origin.x,
            y: screenFrame.maxY - localRect.origin.y - localRect.height,
            width: localRect.width,
            height: localRect.height
        )
    }

    static func localCaptureGeometry(
        for globalRegion: CGRect,
        in displayFrame: CGRect,
        scaleFactor: CGFloat,
        padding: CGFloat = 2
    ) -> LocalCaptureGeometry? {
        let padded = padding > 0 ? globalRegion.insetBy(dx: -padding, dy: -padding) : globalRegion
        let intersected = padded.intersection(displayFrame)
        guard !intersected.isNull, intersected.width > 0, intersected.height > 0 else {
            return nil
        }
        let localSourceRect = CGRect(
            x: intersected.origin.x - displayFrame.origin.x,
            y: displayFrame.maxY - intersected.maxY,
            width: intersected.width,
            height: intersected.height
        )
        let pixelWidth = max(1, Int((localSourceRect.width * scaleFactor).rounded()))
        let pixelHeight = max(1, Int((localSourceRect.height * scaleFactor).rounded()))
        return LocalCaptureGeometry(
            sourceRect: localSourceRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    static func stitchImages(
        _ parts: [(image: CGImage, region: CGRect)],
        totalRegion: CGRect,
        targetScale: CGFloat
    ) -> CGImage? {
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 { return parts[0].image }

        let targetWidth = max(1, Int((totalRegion.width * targetScale).rounded()))
        let targetHeight = max(1, Int((totalRegion.height * targetScale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return parts[0].image
        }

        // Fill background with white
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        for part in parts {
            let destX = (part.region.origin.x - totalRegion.origin.x) * targetScale
            let destY = (part.region.origin.y - totalRegion.origin.y) * targetScale
            let destW = part.region.width * targetScale
            let destH = part.region.height * targetScale
            let destRect = CGRect(x: destX, y: destY, width: destW, height: destH)
            context.draw(part.image, in: destRect)
        }

        return context.makeImage()
    }
}

protocol ScreenCaptureService: Actor {
    func capture(display: DisplayInfo, region: CGRect) async throws -> CGImage
    func capture(displays: [DisplayInfo], region: CGRect) async throws -> CGImage
    func invalidateCache() async
}

extension ScreenCaptureService {
    func capture(displays: [DisplayInfo], region: CGRect) async throws -> CGImage {
        guard let first = displays.first else {
            throw ClipTextError.captureFailed("No displays provided")
        }
        return try await capture(display: first, region: region)
    }
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
        guard let geometry = ScreenCoordinateConverter.localCaptureGeometry(
            for: region,
            in: display.frame,
            scaleFactor: display.backingScaleFactor
        ) else {
            throw ClipTextError.captureFailed("Selected region is outside the display")
        }

        let configuration = SCStreamConfiguration()
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        configuration.sourceRect = geometry.sourceRect
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        Logger.shared.debug("Capture completed: \(image.width)x\(image.height)")
        return image
    }

    func capture(displays: [DisplayInfo], region: CGRect) async throws -> CGImage {
        installDisplayChangeObserverIfNeeded()
        let intersecting = displays.filter { display in
            let intersection = region.intersection(display.frame)
            return !intersection.isNull && intersection.width > 2 && intersection.height > 2
        }
        guard !intersecting.isEmpty else {
            throw ClipTextError.captureFailed("Selected region is outside all displays")
        }
        if intersecting.count == 1 {
            return try await capture(display: intersecting[0], region: region)
        }

        // Multi-display stitching
        let maxScale = intersecting.map(\.backingScaleFactor).max() ?? 2.0
        var parts: [(image: CGImage, region: CGRect)] = []

        for display in intersecting {
            let subRegion = region.intersection(display.frame)
            guard !subRegion.isNull, subRegion.width > 2, subRegion.height > 2 else { continue }
            do {
                let img = try await capture(display: display, region: subRegion)
                parts.append((img, subRegion))
            } catch {
                Logger.shared.warning("Failed to capture sub-region on \(display.localizedName): \(error.localizedDescription)")
            }
        }

        guard !parts.isEmpty else {
            throw ClipTextError.captureFailed("Failed to capture from any intersecting display")
        }

        if parts.count == 1 {
            return parts[0].image
        }

        guard let stitched = ScreenCoordinateConverter.stitchImages(parts, totalRegion: region, targetScale: maxScale) else {
            return parts[0].image
        }
        return stitched
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
