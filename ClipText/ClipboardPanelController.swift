import ApplicationServices
import AppKit
import SwiftUI

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if isVisible { orderOut(nil) }
    }
}

struct ScreenGeometry: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect

    init(frame: NSRect, visibleFrame: NSRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    init(screen: NSScreen) {
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
    }
}

enum ClipboardPanelPlacement {
    static let defaultSize = NSSize(width: 480, height: 350)
    static let visibleListHeight: CGFloat = 220
    static let margin: CGFloat = 12
    static let savedPositionKey = "clipboard.savedPanelPosition"

    static func composerAnchor(in window: CGRect, bottomInset: CGFloat = 96) -> CGRect {
        let y = max(window.minY, window.maxY - max(bottomInset, 0))
        return CGRect(x: window.midX - 0.5, y: y, width: 1, height: 1)
    }

    static func origin(
        anchor: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat = 12
    ) -> NSPoint {
        let minimumX = visibleFrame.minX + margin
        let maximumX = max(minimumX, visibleFrame.maxX - panelSize.width - margin)
        let originX = min(max(anchor.midX - panelSize.width / 2, minimumX), maximumX)

        var originY = anchor.maxY + margin
        if originY + panelSize.height > visibleFrame.maxY - margin {
            originY = anchor.minY - panelSize.height - margin
        }
        let minimumY = visibleFrame.minY + margin
        let maximumY = max(minimumY, visibleFrame.maxY - panelSize.height - margin)
        originY = min(max(originY, minimumY), maximumY)

        return NSPoint(x: originX, y: originY)
    }

    static func clampedOrigin(
        proposed: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat = 12
    ) -> NSPoint {
        let minimumX = visibleFrame.minX + margin
        let maximumX = max(minimumX, visibleFrame.maxX - panelSize.width - margin)
        let originX = min(max(proposed.x, minimumX), maximumX)

        let minimumY = visibleFrame.minY + margin
        let maximumY = max(minimumY, visibleFrame.maxY - panelSize.height - margin)
        let originY = min(max(proposed.y, minimumY), maximumY)

        return NSPoint(x: originX, y: originY)
    }

    static func bestScreen(
        for proposedRect: NSRect,
        in screens: [ScreenGeometry],
        fallback: ScreenGeometry
    ) -> ScreenGeometry {
        guard !screens.isEmpty else { return fallback }

        var best: ScreenGeometry?
        var maxIntersectionArea: CGFloat = 0

        for screen in screens {
            let intersection = screen.frame.intersection(proposedRect)
            if !intersection.isNull && !intersection.isEmpty {
                let area = intersection.width * intersection.height
                if area > maxIntersectionArea {
                    maxIntersectionArea = area
                    best = screen
                }
            }
        }

        if let best { return best }

        let targetCenter = CGPoint(x: proposedRect.midX, y: proposedRect.midY)
        let closest = screens.min(by: { s1, s2 in
            let c1 = CGPoint(x: s1.frame.midX, y: s1.frame.midY)
            let c2 = CGPoint(x: s2.frame.midX, y: s2.frame.midY)
            let d1 = (c1.x - targetCenter.x) * (c1.x - targetCenter.x) + (c1.y - targetCenter.y) * (c1.y - targetCenter.y)
            let d2 = (c2.x - targetCenter.x) * (c2.x - targetCenter.x) + (c2.y - targetCenter.y) * (c2.y - targetCenter.y)
            return d1 < d2
        })

        return closest ?? fallback
    }

    static func resolveOrigin(
        savedOrigin: NSPoint?,
        anchor: NSRect?,
        panelSize: NSSize,
        screens: [ScreenGeometry],
        fallbackScreen: ScreenGeometry,
        margin: CGFloat = margin
    ) -> NSPoint {
        if let savedOrigin {
            let proposedRect = NSRect(origin: savedOrigin, size: panelSize)
            let targetScreen = bestScreen(for: proposedRect, in: screens, fallback: fallbackScreen)
            return clampedOrigin(
                proposed: savedOrigin,
                panelSize: panelSize,
                visibleFrame: targetScreen.visibleFrame,
                margin: margin
            )
        }

        if let anchor {
            let targetScreen = screens.first(where: { $0.frame.intersects(anchor) }) ?? fallbackScreen
            return origin(
                anchor: anchor,
                panelSize: panelSize,
                visibleFrame: targetScreen.visibleFrame,
                margin: margin
            )
        }

        let centerOrigin = NSPoint(
            x: fallbackScreen.visibleFrame.midX - panelSize.width / 2,
            y: fallbackScreen.visibleFrame.midY - panelSize.height / 2
        )
        return clampedOrigin(
            proposed: centerOrigin,
            panelSize: panelSize,
            visibleFrame: fallbackScreen.visibleFrame,
            margin: margin
        )
    }
}

final class PanelDragHandleNSView: NSView {
    var hasCustomPosition: Bool = false
    var onDragEnded: ((NSPoint) -> Void)?
    var onResetRequested: (() -> Void)?

    private var isHovered: Bool = false

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            bgPath.fill()
        }

        let dotDiameter: CGFloat = 3
        let spacing: CGFloat = 3
        let totalWidth = 2 * dotDiameter + spacing
        let totalHeight = 3 * dotDiameter + 2 * spacing

        let startX = (bounds.width - totalWidth) / 2
        let startY = (bounds.height - totalHeight) / 2

        let dotColor: NSColor
        if hasCustomPosition {
            dotColor = NSColor.systemCyan.withAlphaComponent(isHovered ? 1.0 : 0.8)
        } else {
            dotColor = NSColor.secondaryLabelColor.withAlphaComponent(isHovered ? 0.9 : 0.6)
        }
        dotColor.setFill()

        for col in 0..<2 {
            for row in 0..<3 {
                let x = startX + CGFloat(col) * (dotDiameter + spacing)
                let y = startY + CGFloat(row) * (dotDiameter + spacing)
                let dotRect = NSRect(x: x, y: y, width: dotDiameter, height: dotDiameter)
                let dotPath = NSBezierPath(ovalIn: dotRect)
                dotPath.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onResetRequested?()
            return
        }
        guard let window = self.window else { return }
        window.performDrag(with: event)
        onDragEnded?(window.frame.origin)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let resetItem = NSMenuItem(
            title: "Reset to Caret Placement",
            action: #selector(handleResetAction),
            keyEquivalent: ""
        )
        resetItem.target = self
        resetItem.isEnabled = hasCustomPosition
        menu.addItem(resetItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func handleResetAction() {
        onResetRequested?()
    }
}

struct PanelDragHandleRepresentable: NSViewRepresentable {
    var hasCustomPosition: Bool
    var onDragEnded: ((NSPoint) -> Void)?
    var onResetPosition: (() -> Void)?

    func makeNSView(context: Context) -> PanelDragHandleNSView {
        let view = PanelDragHandleNSView()
        view.hasCustomPosition = hasCustomPosition
        view.onDragEnded = onDragEnded
        view.onResetRequested = onResetPosition
        view.toolTip = hasCustomPosition
            ? "Drag to move panel • Double-click or right-click to reset to caret"
            : "Drag to move panel"
        return view
    }

    func updateNSView(_ nsView: PanelDragHandleNSView, context: Context) {
        nsView.hasCustomPosition = hasCustomPosition
        nsView.onDragEnded = onDragEnded
        nsView.onResetRequested = onResetPosition
        nsView.toolTip = hasCustomPosition
            ? "Drag to move panel • Double-click or right-click to reset to caret"
            : "Drag to move panel"
        nsView.needsDisplay = true
    }
}

@MainActor
final class ClipboardPanelController {
    private var panel: ClipboardPanel?
    private let userDefaults: UserDefaults
    private var currentAnchor: TextAnchor?
    private var currentTargetApplication: NSRunningApplication?
    var onPositionChanged: (() -> Void)?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var hasCustomPosition: Bool {
        savedPosition() != nil
    }

    func savedPosition() -> NSPoint? {
        guard let dict = userDefaults.dictionary(forKey: ClipboardPanelPlacement.savedPositionKey),
              let x = dict["x"] as? CGFloat,
              let y = dict["y"] as? CGFloat else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    func savePosition(_ origin: NSPoint) {
        userDefaults.set(["x": origin.x, "y": origin.y], forKey: ClipboardPanelPlacement.savedPositionKey)
        onPositionChanged?()
    }

    func resetPosition() {
        userDefaults.removeObject(forKey: ClipboardPanelPlacement.savedPositionKey)
        onPositionChanged?()
        if let panel = self.panel, panel.isVisible {
            repositionToAnchor(panel)
        }
    }

    func handlePanelDragged(to rawOrigin: NSPoint) {
        guard let panel = self.panel else { return }
        let screens = NSScreen.screens.map(ScreenGeometry.init)
        let mainScreen = NSScreen.main ?? NSScreen.screens.first!
        let fallbackScreen = ScreenGeometry(screen: mainScreen)
        let targetScreen = ClipboardPanelPlacement.bestScreen(
            for: NSRect(origin: rawOrigin, size: ClipboardPanelPlacement.defaultSize),
            in: screens,
            fallback: fallbackScreen
        )
        let clamped = ClipboardPanelPlacement.clampedOrigin(
            proposed: rawOrigin,
            panelSize: ClipboardPanelPlacement.defaultSize,
            visibleFrame: targetScreen.visibleFrame
        )
        if panel.frame.origin != clamped {
            panel.setFrameOrigin(clamped)
        }
        savePosition(clamped)
    }

    func targetApplication(excluding processIdentifier: pid_t) -> NSRunningApplication? {
        if AXIsProcessTrusted(), let focusedApplication = focusedApplicationElement() {
            var focusedProcessIdentifier: pid_t = 0
            if AXUIElementGetPid(focusedApplication, &focusedProcessIdentifier) == .success,
               focusedProcessIdentifier != processIdentifier,
               let application = NSRunningApplication(processIdentifier: focusedProcessIdentifier) {
                return application
            }
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != processIdentifier
        else {
            return nil
        }
        return frontmostApplication
    }

    func show(
        store: ClipboardStore,
        targetApplication: NSRunningApplication?,
        appearance: ClipboardAppearance,
        material: ClipboardMaterial,
        onPaste: @escaping (ClipboardItem, ClipboardPasteFormat) -> Void,
        onTogglePin: @escaping (ClipboardItem) -> Void,
        onPreview: @escaping (ClipboardItem) -> Void,
        onEdit: @escaping (ClipboardItem) -> Void,
        onExtractText: @escaping (ClipboardItem) -> Void,
        onSaveGIF: @escaping (ClipboardItem) -> Void,
        onSaveFavorite: @escaping (ClipboardItem) -> Void,
        onDelete: @escaping (ClipboardItem) -> Void
    ) {
        // Resolve the caret before creating or activating any clipboard UI so focus
        // still belongs to the app where the user intends to paste.
        let textPosition = textAnchor(for: targetApplication)
        let fallbackPosition = textPosition == nil ? fallbackAnchor(for: targetApplication) : nil
        let anchor = textPosition ?? fallbackPosition
        self.currentAnchor = anchor
        self.currentTargetApplication = targetApplication

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.appearance = appearance.nsAppearance
        panel.contentViewController = NSHostingController(
            rootView: ClipboardPanelView(
                store: store,
                material: material,
                initialHasCustomPosition: hasCustomPosition,
                onPaste: onPaste,
                onTogglePin: onTogglePin,
                onPreview: onPreview,
                onEdit: onEdit,
                onExtractText: onExtractText,
                onSaveGIF: onSaveGIF,
                onSaveFavorite: onSaveFavorite,
                onDelete: onDelete,
                onClose: { [weak self] in self?.close() },
                onPanelDragged: { [weak self] newOrigin in self?.handlePanelDragged(to: newOrigin) },
                onResetPosition: { [weak self] in self?.resetPosition() }
            )
        )
        panel.contentView?.appearance = appearance.nsAppearance
        panel.setContentSize(ClipboardPanelPlacement.defaultSize)
        positionPanel(panel, anchor: anchor)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    func close() {
        panel?.orderOut(nil)
    }

    func setAppearance(_ appearance: ClipboardAppearance) {
        panel?.appearance = appearance.nsAppearance
        panel?.contentView?.appearance = appearance.nsAppearance
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: ClipboardPanelPlacement.defaultSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func positionPanel(_ panel: NSPanel, anchor: TextAnchor?) {
        let screens = NSScreen.screens.map(ScreenGeometry.init)
        let mainScreen = NSScreen.main ?? NSScreen.screens.first!
        let fallbackScreen = ScreenGeometry(screen: anchor?.screen ?? mainScreen)
        let resolved = ClipboardPanelPlacement.resolveOrigin(
            savedOrigin: savedPosition(),
            anchor: anchor?.rect,
            panelSize: ClipboardPanelPlacement.defaultSize,
            screens: screens,
            fallbackScreen: fallbackScreen
        )
        panel.setFrameOrigin(resolved)
    }

    private func repositionToAnchor(_ panel: NSPanel) {
        let textPosition = textAnchor(for: currentTargetApplication)
        let fallbackPosition = textPosition == nil ? fallbackAnchor(for: currentTargetApplication) : nil
        let anchor = textPosition ?? fallbackPosition
        self.currentAnchor = anchor
        let screens = NSScreen.screens.map(ScreenGeometry.init)
        let mainScreen = NSScreen.main ?? NSScreen.screens.first!
        let fallbackScreen = ScreenGeometry(screen: anchor?.screen ?? mainScreen)
        let resolved = ClipboardPanelPlacement.resolveOrigin(
            savedOrigin: nil,
            anchor: anchor?.rect,
            panelSize: ClipboardPanelPlacement.defaultSize,
            screens: screens,
            fallbackScreen: fallbackScreen
        )
        panel.setFrameOrigin(resolved)
    }

    private struct TextAnchor {
        let screen: NSScreen
        let rect: NSRect
    }

    private func textAnchor(for application: NSRunningApplication?) -> TextAnchor? {
        guard AXIsProcessTrusted(), let application else { return nil }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let focusedElement = focusedTextElement(
            for: applicationElement,
            processIdentifier: application.processIdentifier
        ),
              isEditableTextElement(focusedElement)
        else { return nil }

        var selectedRangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
           let selectedRangeValue,
           let rangeForCaret = caretRange(from: selectedRangeValue) {
            if let caretBounds = bounds(of: focusedElement, for: rangeForCaret) {
                return anchor(for: caretBounds)
            }
            if let selectionBounds = bounds(of: focusedElement, for: selectedRangeValue) {
                return anchor(for: selectionBounds)
            }
        }

        if let focusedFrame = frame(of: focusedElement) {
            return anchor(for: focusedFrame)
        }

        return nil
    }

    private func anchor(for accessibilityRect: CGRect) -> TextAnchor? {
        let rect = CGRect(
            x: accessibilityRect.minX,
            y: accessibilityRect.minY,
            width: max(accessibilityRect.width, 1),
            height: max(accessibilityRect.height, 1)
        )

        let accessibilityCenter = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard displayBounds.contains(accessibilityCenter) else { continue }

            let cocoaRect = NSRect(
                x: screen.frame.minX + rect.minX - displayBounds.minX,
                y: screen.frame.maxY - (rect.maxY - displayBounds.minY),
                width: rect.width,
                height: rect.height
            )
            return TextAnchor(screen: screen, rect: cocoaRect)
        }

        return nil
    }

    private func focusedElement(for applicationElement: AXUIElement) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                applicationElement,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            ) == .success,
            let focusedValue
        else {
            return nil
        }
        return (focusedValue as! AXUIElement)
    }

    private func focusedElement(
        for applicationElement: AXUIElement,
        processIdentifier: pid_t
    ) -> AXUIElement? {
        if let applicationFocusedElement = focusedElement(for: applicationElement) {
            return applicationFocusedElement
        }

        guard let systemFocusedElement = systemWideFocusedElement()
        else { return nil }

        var focusedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(systemFocusedElement, &focusedProcessIdentifier) == .success,
              focusedProcessIdentifier == processIdentifier
        else { return nil }
        return systemFocusedElement
    }

    private func focusedTextElement(
        for applicationElement: AXUIElement,
        processIdentifier: pid_t
    ) -> AXUIElement? {
        if let focusedElement = focusedElement(
            for: applicationElement,
            processIdentifier: processIdentifier
        ), isEditableTextElement(focusedElement) {
            return focusedElement
        }

        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        if focusedWindowResult == .success, let focusedWindowValue {
            var visited = Set<CFHashCode>()
            if let match = findEditableTextElement(
                in: focusedWindowValue as! AXUIElement,
                depth: 0,
                visited: &visited
            ) {
                return match
            }
        }

        if let systemFocusedElement = systemWideFocusedElement() {
            var focusedProcessIdentifier: pid_t = 0
            guard AXUIElementGetPid(systemFocusedElement, &focusedProcessIdentifier) == .success,
                  focusedProcessIdentifier == processIdentifier
            else { return nil }

            var visited = Set<CFHashCode>()
            return findEditableTextElement(
                in: systemFocusedElement,
                depth: 0,
                visited: &visited
            )
        }
        return nil
    }

    private func findEditableTextElement(
        in element: AXUIElement,
        depth: Int,
        visited: inout Set<CFHashCode>
    ) -> AXUIElement? {
        guard depth < 12, visited.insert(CFHash(element)).inserted else { return nil }

        var focusedValue: CFTypeRef?
        let isFocused = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            &focusedValue
        ) == .success && (focusedValue as? Bool == true)

        if isEditableTextElement(element) {
            return element
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return nil }

        let orderedChildren = isFocused ? children : children.reversed()
        for child in orderedChildren {
            if let match = findEditableTextElement(
                in: child,
                depth: depth + 1,
                visited: &visited
            ) {
                return match
            }
        }
        return nil
    }

    private func systemWideFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue
        else { return nil }
        return (focusedValue as! AXUIElement)
    }

    private func focusedApplicationElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedApplicationValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWideElement,
                kAXFocusedApplicationAttribute as CFString,
                &focusedApplicationValue
            ) == .success,
            let focusedApplicationValue
        else {
            return nil
        }
        return (focusedApplicationValue as! AXUIElement)
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
              let role = roleValue as? String
        else { return false }

        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
    }

    private func caretRange(from selectedRangeValue: CFTypeRef) -> CFTypeRef? {
        guard CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else { return nil }
        let rangeValue = selectedRangeValue as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else { return nil }

        var caretRange = CFRange(
            location: selectedRange.location + selectedRange.length,
            length: 0
        )
        return AXValueCreate(.cfRange, &caretRange)
    }

    private func fallbackAnchor(for application: NSRunningApplication?) -> TextAnchor? {
        guard let application, let window = windowBounds(for: application) else { return nil }

        if application.bundleIdentifier == "com.openai.codex" {
            return anchor(for: ClipboardPanelPlacement.composerAnchor(in: window))
        }

        return anchor(for: window)
    }

    private func windowBounds(for application: NSRunningApplication?) -> CGRect? {
        guard let application else { return nil }

        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]

        let candidates = windows?.compactMap { info -> CGRect? in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            guard ownerPID == application.processIdentifier,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1,
                  rect.height > 1
            else { return nil }
            return rect
        }

        guard let rect = candidates?.max(by: { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        })
        else {
            return nil
        }

        return rect
    }

    private func bounds(of element: AXUIElement, for range: CFTypeRef) -> CGRect? {
        var boundsValue: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                range,
                &boundsValue
            ) == .success,
            let boundsValue
        else {
            return nil
        }
        let axValue = boundsValue as! AXValue

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect),
              !rect.isNull,
              rect.minX.isFinite,
              rect.minY.isFinite,
              rect.height > 0
        else { return nil }
        return rect
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard
            AXValueGetValue(position, .cgPoint, &point),
            AXValueGetValue(size, .cgSize, &dimensions)
        else {
            return nil
        }
        return CGRect(origin: point, size: dimensions)
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    let material: ClipboardMaterial
    let initialHasCustomPosition: Bool
    let onPaste: (ClipboardItem, ClipboardPasteFormat) -> Void
    let onTogglePin: (ClipboardItem) -> Void
    let onPreview: (ClipboardItem) -> Void
    let onEdit: (ClipboardItem) -> Void
    let onExtractText: (ClipboardItem) -> Void
    let onSaveGIF: (ClipboardItem) -> Void
    let onSaveFavorite: (ClipboardItem) -> Void
    let onDelete: (ClipboardItem) -> Void
    let onClose: () -> Void
    var onPanelDragged: ((NSPoint) -> Void)? = nil
    var onResetPosition: (() -> Void)? = nil

    @State private var hasCustomPosition: Bool
    @State private var selectedID: UUID?
    @State private var searchQuery = ""
    @State private var typeFilter: ClipboardHistoryTypeFilter = .all
    @State private var dateFilter: ClipboardHistoryDateFilter = .allTime
    @State private var sourceAppFilter: String?
    @State private var pinnedOnly = false
    @State private var hasOCR = false
    @State private var isPresented = false
    @FocusState private var isSearchFocused: Bool

    init(
        store: ClipboardStore,
        material: ClipboardMaterial,
        initialHasCustomPosition: Bool = false,
        onPaste: @escaping (ClipboardItem, ClipboardPasteFormat) -> Void,
        onTogglePin: @escaping (ClipboardItem) -> Void,
        onPreview: @escaping (ClipboardItem) -> Void,
        onEdit: @escaping (ClipboardItem) -> Void,
        onExtractText: @escaping (ClipboardItem) -> Void,
        onSaveGIF: @escaping (ClipboardItem) -> Void,
        onSaveFavorite: @escaping (ClipboardItem) -> Void,
        onDelete: @escaping (ClipboardItem) -> Void,
        onClose: @escaping () -> Void,
        onPanelDragged: ((NSPoint) -> Void)? = nil,
        onResetPosition: (() -> Void)? = nil
    ) {
        self.store = store
        self.material = material
        self.initialHasCustomPosition = initialHasCustomPosition
        self._hasCustomPosition = State(initialValue: initialHasCustomPosition)
        self.onPaste = onPaste
        self.onTogglePin = onTogglePin
        self.onPreview = onPreview
        self.onEdit = onEdit
        self.onExtractText = onExtractText
        self.onSaveGIF = onSaveGIF
        self.onSaveFavorite = onSaveFavorite
        self.onDelete = onDelete
        self.onClose = onClose
        self.onPanelDragged = onPanelDragged
        self.onResetPosition = onResetPosition
    }

    var body: some View {
        let allItems = store.items
        let items = allItems.filter {
            $0.matchesSearch(searchQuery) && $0.matches(historyFilter)
        }
        let panelShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            headerView(allItemsCount: allItems.count, filteredCount: items.count)

            searchField

            if allItems.isEmpty {
                emptyHistoryView
            } else if items.isEmpty {
                noMatchesView
            } else {
                itemsListView(items: items)
            }
        }
        .padding(14)
        .frame(
            width: ClipboardPanelPlacement.defaultSize.width,
            height: ClipboardPanelPlacement.defaultSize.height,
            alignment: .top
        )
        .clipShape(panelShape)
        .clipboardGlassSurface(in: panelShape, material: material)
        .opacity(isPresented ? 1 : 0)
        .scaleEffect(isPresented ? 1 : 0.94, anchor: .bottom)
        .offset(y: isPresented ? 0 : 26)
        .clipboardGlassEntranceTransition(material: material)
        .onAppear {
            selectedID = items.first?.id
            isPresented = false
            DispatchQueue.main.async {
                isSearchFocused = true
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    isPresented = true
                }
            }
        }
        .onChange(of: searchQuery) { _ in
            keepSelectionVisible(in: items)
        }
        .onChange(of: store.items) { _ in
            keepSelectionVisible(in: items)
        }
        .onExitCommand(perform: clearSearchOrClose)
        .onKeyPress(characters: .decimalDigits, phases: [.down]) { press in
            numberedShortcutResult(for: press)
        }
    }

    private func headerView(allItemsCount: Int, filteredCount: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("ClipText")
                    .font(.headline.weight(.semibold))
            }

            Spacer()

            PanelDragHandleRepresentable(
                hasCustomPosition: hasCustomPosition,
                onDragEnded: { newOrigin in
                    hasCustomPosition = true
                    onPanelDragged?(newOrigin)
                },
                onResetPosition: {
                    hasCustomPosition = false
                    onResetPosition?()
                }
            )
            .frame(width: 44, height: 22)
            .help(hasCustomPosition
                  ? "Drag to move panel • Double-click or right-click to reset to caret"
                  : "Drag to move panel")

            Spacer()

            Text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "\(allItemsCount)"
                 : "\(filteredCount)/\(allItemsCount)")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: Capsule())

            closeButton
        }
        .contextMenu {
            if hasCustomPosition {
                Button("Reset to Caret Placement") {
                    hasCustomPosition = false
                    onResetPosition?()
                }
            }
        }
    }

    private var emptyHistoryView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Your clipboard is empty")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Copied text, images, and files will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Text("Extract text from screen:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 2) {
                    Text("⌥⇧T")
                        .font(.caption.weight(.semibold).monospaced())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(.primary)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: ClipboardPanelPlacement.visibleListHeight)
    }

    private var noMatchesView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("No matches")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if !searchQuery.isEmpty {
                    Text("No clipboard items match “\(searchQuery)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No clipboard items match active filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if !searchQuery.isEmpty {
                    Button("Clear search") {
                        searchQuery = ""
                        isSearchFocused = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if !historyFilter.isDefault {
                    Button("Reset filters") {
                        resetFilters()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: ClipboardPanelPlacement.visibleListHeight)
    }

    private func itemsListView(items: [ClipboardItem]) -> some View {
        List(items) { item in
            ClipboardRow(
                item: item,
                isSelected: selectedID == item.id,
                onPaste: onPaste,
                onTogglePin: { onTogglePin(item) },
                onPreview: { onPreview(item) },
                onEdit: { onEdit(item) },
                onExtractText: { onExtractText(item) },
                onSaveGIF: { onSaveGIF(item) }
            )
            .contextMenu {
                Button(item.isPinned ? "Unpin" : "Pin") { onTogglePin(item) }
                if item.hasText {
                    Button("Save to Library…") { onSaveFavorite(item) }
                }
                if item.canExtractText {
                    Button("Edit image") { onEdit(item) }
                    Button("Extract Text & Copy") { onExtractText(item) }
                }
                if item.isGIF {
                    Button("Save GIF…") { onSaveGIF(item) }
                }
                Button("Quick Look") { onPreview(item) }
                Divider()
                Button("Paste") { onPaste(item, .original) }
                Button("Delete", role: .destructive) { onDelete(item) }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: ClipboardPanelPlacement.visibleListHeight)
        .focusEffectDisabled()
        .onMoveCommand { direction in moveSelection(direction) }
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
            switch press.key {
            case .upArrow:
                moveSelection(.up)
            case .downArrow:
                moveSelection(.down)
            default:
                break
            }
            return .handled
        }
        .onKeyPress(.return) {
            submitSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            clearSearchOrClose()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search history", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isSearchFocused)
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    switch press.key {
                    case .upArrow:
                        moveSelection(.up)
                    case .downArrow:
                        moveSelection(.down)
                    default:
                        break
                    }
                    return .handled
                }
                .onKeyPress(.return) {
                    submitSelection()
                    return .handled
                }
                .onKeyPress(.escape) {
                    clearSearchOrClose()
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: [.down]) { press in
                    numberedShortcutResult(for: press)
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            filterMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var historyFilter: ClipboardHistoryFilter {
        ClipboardHistoryFilter(
            type: typeFilter,
            date: dateFilter,
            sourceAppBundleIdentifier: sourceAppFilter,
            pinnedOnly: pinnedOnly,
            hasOCR: hasOCR
        )
    }

    private var sourceApplications: [ClipboardSourceApplication] {
        Array(Set(store.items.compactMap(\.sourceApplication)))
            .sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $typeFilter) {
                ForEach(ClipboardHistoryTypeFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            Picker("Date", selection: $dateFilter) {
                ForEach(ClipboardHistoryDateFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            if !sourceApplications.isEmpty {
                Picker("Source app", selection: $sourceAppFilter) {
                    Text("All apps").tag(Optional<String>.none)
                    ForEach(sourceApplications) { application in
                        Text(application.displayName)
                            .tag(Optional(application.bundleIdentifier))
                    }
                }
            }

            Divider()

            Toggle("Pinned only", isOn: $pinnedOnly)
            Toggle("Has OCR text", isOn: $hasOCR)

            if !historyFilter.isDefault {
                Divider()
                Button("Reset filters") {
                    resetFilters()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: historyFilter.isDefault
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
                if historyFilter.activeFilterCount > 0 {
                    Text("\(historyFilter.activeFilterCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(historyFilter.isDefault ? Color.secondary : Color.cyan)
            .padding(.horizontal, historyFilter.isDefault ? 4 : 6)
            .padding(.vertical, 3)
            .background(
                historyFilter.isDefault
                    ? Color.clear
                    : Color.cyan.opacity(0.14),
                in: Capsule()
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Filter history")
        .accessibilityLabel("Filter history")
    }

    private func resetFilters() {
        typeFilter = .all
        dateFilter = .allTime
        sourceAppFilter = nil
        pinnedOnly = false
        hasOCR = false
    }

    @ViewBuilder
    private var closeButton: some View {
        if material == .liquidGlass, #available(macOS 26.0, *) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Close")
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let items = store.items.filter {
            $0.matchesSearch(searchQuery) && $0.matches(historyFilter)
        }
        guard !items.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let nextIndex: Int
        switch direction {
        case .up: nextIndex = max(currentIndex - 1, 0)
        case .down: nextIndex = min(currentIndex + 1, items.count - 1)
        default: return
        }
        selectedID = items[nextIndex].id
    }

    private func submitSelection() {
        let items = store.items.filter {
            $0.matchesSearch(searchQuery) && $0.matches(historyFilter)
        }
        guard let selectedID, let item = items.first(where: { $0.id == selectedID }) else { return }
        onPaste(item, .original)
    }

    private func keepSelectionVisible(in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            selectedID = nil
            return
        }
        guard let selectedID, items.contains(where: { $0.id == selectedID }) else {
            self.selectedID = items.first?.id
            return
        }
    }

    private func clearSearchOrClose() {
        if searchQuery.isEmpty {
            onClose()
        } else {
            searchQuery = ""
            isSearchFocused = true
        }
    }

    private func numberedShortcutResult(for press: KeyPress) -> KeyPress.Result {
        guard press.modifiers == .command,
              let number = Int(press.characters),
              (1...9).contains(number)
        else { return .ignored }

        let visibleItems = store.items.filter {
            $0.matchesSearch(searchQuery) && $0.matches(historyFilter)
        }
        guard visibleItems.indices.contains(number - 1) else { return .handled }
        onPaste(visibleItems[number - 1], .original)
        return .handled
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let onPaste: (ClipboardItem, ClipboardPasteFormat) -> Void
    let onTogglePin: () -> Void
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onExtractText: () -> Void
    let onSaveGIF: () -> Void

    @State private var isRowHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Main content area: clicking here pastes the item
            Button {
                onPaste(item, .original)
            } label: {
                HStack(spacing: 12) {
                    thumbnailView

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.preview)
                            .lineLimit(2)
                            .font(.system(.body, design: .default))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        metadataView
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Independent action buttons area: clicking here never triggers paste
            HStack(spacing: 4) {
                SmartPasteMenu(
                    item: item,
                    onPaste: onPaste,
                    onExtractText: onExtractText
                )

                RowActionButton(
                    systemImage: "eye",
                    title: "Quick Look",
                    action: onPreview
                )

                if item.isGIF {
                    RowActionButton(
                        systemImage: "square.and.arrow.down",
                        title: "Save GIF",
                        action: onSaveGIF
                    )
                }

                if item.hasImage && !item.isGIF {
                    RowActionButton(
                        systemImage: "pencil",
                        title: "Edit image",
                        action: onEdit
                    )
                }

                Button(action: onTogglePin) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.isPinned ? Color.cyan : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(item.isPinned ? Color.cyan.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin")
                .accessibilityLabel(item.isPinned ? "Unpin" : "Pin")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.12)
                        : (isRowHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isRowHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let imageData = item.imageData, let nsImage = NSImage(data: imageData) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            Image(systemName: iconName)
                .font(.system(size: 18))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(Color.cyan)
        }
    }

    private var metadataView: some View {
        HStack(spacing: 6) {
            if item.isPinned {
                Label("Pinned", systemImage: "pin.fill")
                    .foregroundStyle(.cyan)
            }
            Text(item.kindLabel)
                .foregroundStyle(.secondary)
            if let app = item.sourceApplicationLabel {
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(app)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    private var iconName: String {
        if item.hasFiles { return "doc.on.doc" }
        if item.hasImage { return "photo" }
        return "text.alignleft"
    }
}

private struct RowActionButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct SmartPasteMenu: View {
    let item: ClipboardItem
    let onPaste: (ClipboardItem, ClipboardPasteFormat) -> Void
    let onExtractText: () -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            Section("Paste as") {
                ForEach(ClipboardPasteFormat.available(for: item)) { format in
                    Button {
                        onPaste(item, format)
                    } label: {
                        Label(format.title, systemImage: format.systemImage)
                    }
                }
            }
            if item.canExtractText {
                Divider()
                Button {
                    onExtractText()
                } label: {
                    Label("Extract Text & Copy", systemImage: "doc.text.magnifyingglass")
                }
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cyan)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.cyan.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .accessibilityLabel("Smart Paste")
        .help("Smart Paste")
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct FavoritesView: View {
    @ObservedObject var store: SnippetStore
    let material: ClipboardMaterial
    let onPaste: (ClipboardSnippet) -> Void
    let onClose: () -> Void

    @State private var searchQuery = ""
    @State private var editingSnippet: ClipboardSnippet?
    @State private var selectedCollection: String?
    @State private var selectedTag: String?

    private var collections: [String] {
        Array(Set(store.snippets.compactMap(\.collection)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var tags: [String] {
        Array(Set(store.snippets.flatMap(\.tags)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var hasMetadataFilter: Bool {
        selectedCollection != nil || selectedTag != nil
    }

    private var visibleSnippets: [ClipboardSnippet] {
        store.snippets.filter {
            $0.matchesLibrary(
                query: searchQuery,
                collection: selectedCollection,
                tag: selectedTag
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("Library")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(hasMetadataFilter || !searchQuery.isEmpty
                     ? "\(visibleSnippets.count)/\(store.snippets.count)"
                     : "\(store.snippets.count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Button(action: { editingSnippet = ClipboardSnippet(title: "", text: "") }) {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New favorite")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search library", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }

                Menu {
                    Menu("Collection") {
                        Button {
                            selectedCollection = nil
                        } label: {
                            Label("All collections", systemImage: selectedCollection == nil ? "checkmark" : "folder")
                        }
                        if !collections.isEmpty {
                            Divider()
                            ForEach(collections, id: \.self) { collection in
                                Button {
                                    selectedCollection = collection
                                } label: {
                                    Label(collection, systemImage: selectedCollection == collection ? "checkmark" : "folder")
                                }
                            }
                        }
                    }

                    Menu("Tag") {
                        Button {
                            selectedTag = nil
                        } label: {
                            Label("All tags", systemImage: selectedTag == nil ? "checkmark" : "tag")
                        }
                        if !tags.isEmpty {
                            Divider()
                            ForEach(tags, id: \.self) { tag in
                                Button {
                                    selectedTag = tag
                                } label: {
                                    Label(tag, systemImage: selectedTag == tag ? "checkmark" : "tag")
                                }
                            }
                        }
                    }

                    if hasMetadataFilter {
                        Divider()
                        Button("Reset filters") {
                            selectedCollection = nil
                            selectedTag = nil
                        }
                    }
                } label: {
                    Image(systemName: hasMetadataFilter
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(hasMetadataFilter ? Color.cyan : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter library")
                .accessibilityLabel("Filter library")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if visibleSnippets.isEmpty {
                ContentUnavailableView(
                    searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasMetadataFilter
                        ? "No library items yet"
                        : "No matches",
                    systemImage: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasMetadataFilter
                        ? "star"
                        : "magnifyingglass",
                    description: Text("Save a text item from history or create one with +.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleSnippets) { snippet in
                    FavoriteRow(
                        snippet: snippet,
                        onPaste: { onPaste(snippet) },
                        onEdit: { editingSnippet = snippet },
                        onDelete: { _ = store.remove(snippet.id) }
                    )
                    .contextMenu {
                        Button("Paste") { onPaste(snippet) }
                        Button("Edit") { editingSnippet = snippet }
                        Divider()
                        Button("Delete", role: .destructive) { _ = store.remove(snippet.id) }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorView(snippet: snippet) { updated in
                if store.upsert(updated) {
                    editingSnippet = nil
                }
            } onCancel: {
                editingSnippet = nil
            }
        }
    }
}

private struct FavoriteRow: View {
    let snippet: ClipboardSnippet
    let onPaste: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(snippet.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if snippet.collection != nil || !snippet.tags.isEmpty {
                    HStack(spacing: 8) {
                        if let collection = snippet.collection {
                            Label(collection, systemImage: "folder")
                                .lineLimit(1)
                        }
                        ForEach(snippet.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(action: onPaste) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.cyan)
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Paste")
            .accessibilityLabel("Paste favorite")

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.primary.opacity(isHovered ? 0.95 : 0.72))
            }
            .buttonStyle(.plain)
            .help("Edit")
            .accessibilityLabel("Edit favorite")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(Color.primary.opacity(isHovered ? 0.95 : 0.72))
            }
            .buttonStyle(.plain)
            .help("Delete")
            .accessibilityLabel("Delete favorite")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct SnippetEditorView: View {
    let snippet: ClipboardSnippet
    let onSave: (ClipboardSnippet) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var text: String
    @State private var collection: String
    @State private var tagsText: String

    init(
        snippet: ClipboardSnippet,
        onSave: @escaping (ClipboardSnippet) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snippet = snippet
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: snippet.title)
        _text = State(initialValue: snippet.text)
        _collection = State(initialValue: snippet.collection ?? "")
        _tagsText = State(initialValue: snippet.tags.joined(separator: ", "))
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snippet.text.isEmpty ? "New Library Item" : "Edit Library Item")
                .font(.title3.weight(.semibold))

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("Collection (optional)", text: $collection)
                .textFieldStyle(.roundedBorder)

            TextField("Tags, separated by commas", text: $tagsText)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $text)
                .font(.body)
                .padding(6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(ClipboardSnippet(
                        id: snippet.id,
                        createdAt: snippet.createdAt,
                        title: title,
                        text: text,
                        collection: collection,
                        tags: tagsText.split(separator: ",").map(String.init)
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440, height: 370)
    }
}
