//
//  SelectionWindowManager.swift
//  ClipText
//
//  Adapted from TextGrab (https://github.com/arsh342/TextGrab)
//  Copyright (c) 2026 arsh342. MIT License.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
protocol SelectionWindowManager: AnyObject {
    var isVisible: Bool { get }

    func showOverlays(
        on screens: [NSScreen],
        onSelectionComplete: @escaping (CGRect, NSScreen?) -> Void,
        onCancel: @escaping () -> Void
    )

    func showOverlay(
        on screen: NSScreen,
        content: SelectionOverlayView,
        onSelectionComplete: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    )

    func hideOverlay()
}

@MainActor
final class MultiDisplaySelectionSession {
    let screens: [NSScreen]
    var startLocation: NSPoint?
    var currentRect: NSRect = .zero
    var isSelecting: Bool = false
    var activeScreen: NSScreen?
    let onSelectionComplete: (CGRect, NSScreen?) -> Void
    let onCancel: () -> Void
    var overlayViews: [MultiDisplaySelectionView] = []

    init(
        screens: [NSScreen],
        onSelectionComplete: @escaping (CGRect, NSScreen?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screens = screens
        self.onSelectionComplete = onSelectionComplete
        self.onCancel = onCancel
    }

    func updateAllViews() {
        for view in overlayViews {
            view.needsDisplay = true
        }
    }

    func startSelection(at screenPoint: NSPoint) {
        startLocation = screenPoint
        isSelecting = true
        currentRect = .zero
        activeScreen = screens.first(where: { $0.frame.contains(screenPoint) })
        updateAllViews()
    }

    func updateSelection(to screenPoint: NSPoint) {
        guard let start = startLocation else { return }
        let minX = min(start.x, screenPoint.x)
        let minY = min(start.y, screenPoint.y)
        let width = abs(screenPoint.x - start.x)
        let height = abs(screenPoint.y - start.y)
        currentRect = NSRect(x: minX, y: minY, width: width, height: height)
        activeScreen = screens.first(where: { $0.frame.contains(screenPoint) })
        updateAllViews()
    }

    func completeSelection() {
        guard isSelecting, currentRect.width > 10, currentRect.height > 10 else {
            cancel()
            return
        }
        let completedRect = currentRect
        let target = ScreenCoordinateConverter.targetScreen(for: completedRect, in: screens)
        reset()
        onSelectionComplete(completedRect, target)
    }

    func cancel() {
        reset()
        onCancel()
    }

    private func reset() {
        startLocation = nil
        currentRect = .zero
        isSelecting = false
        activeScreen = nil
        updateAllViews()
    }
}

final class MultiDisplaySelectionView: NSView {
    let screen: NSScreen
    weak var session: MultiDisplaySelectionSession?

    init(screen: NSScreen, session: MultiDisplaySelectionSession) {
        self.screen = screen
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        self.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        session?.startSelection(at: screenPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        session?.updateSelection(to: screenPoint)
    }

    override func mouseUp(with event: NSEvent) {
        session?.completeSelection()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            session?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        session?.cancel()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let session else { return }

        // 1. Dark translucent backdrop
        NSColor.black.withAlphaComponent(0.2).setFill()
        dirtyRect.fill()

        let screenFrame = screen.frame
        let globalRect = session.currentRect

        // 2. Selection rectangle
        let intersection = globalRect.intersection(screenFrame)
        if session.isSelecting && !intersection.isNull && intersection.width > 0 && intersection.height > 0 {
            let localRect = NSRect(
                x: intersection.origin.x - screenFrame.origin.x,
                y: intersection.origin.y - screenFrame.origin.y,
                width: intersection.width,
                height: intersection.height
            )

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            localRect.fill()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            localRect.fill()

            NSColor.controlAccentColor.setStroke()
            let borderPath = NSBezierPath(rect: localRect)
            borderPath.lineWidth = 2.0
            borderPath.stroke()
            NSGraphicsContext.restoreGraphicsState()

            if session.activeScreen == screen && globalRect.width > 50 && globalRect.height > 30 {
                let badgeText = "\(Int(globalRect.width)) × \(Int(globalRect.height))"
                drawBadge(text: badgeText, near: localRect)
            }
        }

        // 3. Instructions
        if !session.isSelecting || session.activeScreen == screen {
            let message = session.isSelecting
                ? "Drag to select area • Release to capture • Esc to cancel"
                : "Click and drag to select text area • Esc to cancel"
            drawInstructions(message: message)
        }
    }

    private func drawBadge(text: String, near localRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let badgeRect = NSRect(
            x: min(localRect.maxX - textSize.width - 16, bounds.width - textSize.width - 24),
            y: max(localRect.minY + 6, 12),
            width: textSize.width + 12,
            height: textSize.height + 6
        )

        NSColor.black.withAlphaComponent(0.75).setFill()
        let bgPath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        bgPath.fill()

        (text as NSString).draw(
            at: NSPoint(x: badgeRect.origin.x + 6, y: badgeRect.origin.y + 3),
            withAttributes: attributes
        )
    }

    private func drawInstructions(message: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let textSize = (message as NSString).size(withAttributes: attributes)
        let pillRect = NSRect(
            x: bounds.midX - (textSize.width + 32) / 2,
            y: max(bounds.minY + 72, 32),
            width: textSize.width + 32,
            height: textSize.height + 16
        )

        NSColor.black.withAlphaComponent(0.65).setFill()
        let bgPath = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
        bgPath.fill()

        (message as NSString).draw(
            at: NSPoint(x: pillRect.origin.x + 16, y: pillRect.origin.y + 8),
            withAttributes: attributes
        )
    }
}

@MainActor
final class DefaultSelectionWindowManager: SelectionWindowManager {
    private var overlayWindows: [NSWindow] = []
    private var escapeMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private var selectionSession: MultiDisplaySelectionSession?

    private(set) var isVisible: Bool = false

    func showOverlays(
        on screens: [NSScreen],
        onSelectionComplete: @escaping (CGRect, NSScreen?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        hideOverlay()
        guard !screens.isEmpty else {
            onCancel()
            return
        }

        let session = MultiDisplaySelectionSession(
            screens: screens,
            onSelectionComplete: { [weak self] rect, screen in
                self?.hideOverlay()
                onSelectionComplete(rect, screen)
            },
            onCancel: { [weak self] in
                self?.hideOverlay()
                onCancel()
            }
        )
        self.selectionSession = session

        for screen in screens {
            let window = SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.hasShadow = false
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = false
            window.alphaValue = 1

            let view = MultiDisplaySelectionView(screen: screen, session: session)
            window.contentView = view
            session.overlayViews.append(view)
            overlayWindows.append(window)
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.selectionSession?.cancel()
            return nil
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.selectionSession?.cancel()
        }

        self.isVisible = true

        for (index, window) in overlayWindows.enumerated() {
            let screen = screens[index]
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouseLocation = NSEvent.mouseLocation
        let keyWindow = overlayWindows.first(where: { $0.frame.contains(mouseLocation) }) ?? overlayWindows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
    }

    func showOverlay(
        on screen: NSScreen,
        content: SelectionOverlayView,
        onSelectionComplete: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        showOverlays(
            on: [screen],
            onSelectionComplete: { rect, _ in
                onSelectionComplete(rect)
            },
            onCancel: onCancel
        )
    }

    func hideOverlay() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        selectionSession = nil
        isVisible = false
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
