import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum AccessibilityPermissionFlow {
    static func guidanceMessage(isTrusted: Bool) -> String? {
        guard !isTrusted else { return nil }
        return "Accessibility is optional. Enable it in Settings to position the picker near the field and paste automatically."
    }
}

enum HotKeyTarget: String, Equatable {
    case history
    case gif
    case ocr
    case stackStart
    case stackNext
}

enum ClipboardAppearance: String, CaseIterable, Hashable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ClipboardMaterial: String, CaseIterable, Hashable, Identifiable {
    case liquidGlass
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .standard: return "Standard"
        }
    }
}

struct ClipboardApplication: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hotKey: HotKeyConfiguration {
        didSet {
            guard hasStarted else {
                oldHotKey = hotKey
                persistHotKey(hotKey, key: Keys.hotKey)
                return
            }
            guard hotKey != oldHotKey else { return }
            guard !isHotKeyInUse(hotKey, excluding: .history) else {
                statusMessage = "Hotkeys must be different."
                hotKey = oldHotKey
                return
            }
            let candidate = hotKey
            if !hotKeyManager.register(candidate) {
                statusMessage = "Could not register shortcut \(candidate.displayString). Keeping \(oldHotKey.displayString)."
                hotKey = oldHotKey
                SanitizedDiagnosticsLog.shared.log(category: "HotKey", message: "Failed to register history hotkey")
            } else {
                oldHotKey = candidate
                persistHotKey(candidate, key: Keys.hotKey)
            }
        }
    }

    @Published var gifHotKey: HotKeyConfiguration {
        didSet {
            guard hasStarted else {
                oldGIFHotKey = gifHotKey
                persistHotKey(gifHotKey, key: Keys.gifHotKey)
                return
            }
            guard gifHotKey != oldGIFHotKey else { return }
            guard !isHotKeyInUse(gifHotKey, excluding: .gif) else {
                statusMessage = "Hotkeys must be different."
                gifHotKey = oldGIFHotKey
                return
            }
            let candidate = gifHotKey
            if !gifHotKeyManager.register(candidate) {
                statusMessage = "Could not register shortcut \(candidate.displayString). Keeping \(oldGIFHotKey.displayString)."
                gifHotKey = oldGIFHotKey
                SanitizedDiagnosticsLog.shared.log(category: "HotKey", message: "Failed to register GIF hotkey")
            } else {
                oldGIFHotKey = candidate
                persistHotKey(candidate, key: Keys.gifHotKey)
            }
        }
    }

    @Published var ocrHotKey: HotKeyConfiguration {
        didSet {
            guard hasStarted else {
                oldOCRHotKey = ocrHotKey
                persistHotKey(ocrHotKey, key: Keys.ocrHotKey)
                return
            }
            guard ocrHotKey != oldOCRHotKey else { return }
            guard !isHotKeyInUse(ocrHotKey, excluding: .ocr) else {
                statusMessage = "Hotkeys must be different."
                ocrHotKey = oldOCRHotKey
                return
            }
            let candidate = ocrHotKey
            if !ocrHotKeyManager.register(candidate) {
                statusMessage = "Could not register shortcut \(candidate.displayString). Keeping \(oldOCRHotKey.displayString)."
                ocrHotKey = oldOCRHotKey
                SanitizedDiagnosticsLog.shared.log(category: "HotKey", message: "Failed to register OCR hotkey")
            } else {
                oldOCRHotKey = candidate
                persistHotKey(candidate, key: Keys.ocrHotKey)
            }
        }
    }

    @Published var stackStartHotKey: HotKeyConfiguration? {
        didSet {
            guard hasStarted else {
                oldStackStartHotKey = stackStartHotKey
                persistOptionalHotKey(stackStartHotKey, key: Keys.stackStartHotKey)
                return
            }
            guard stackStartHotKey != oldStackStartHotKey else { return }
            guard !isHotKeyInUse(stackStartHotKey, excluding: .stackStart) else {
                statusMessage = "That hotkey is already in use."
                stackStartHotKey = oldStackStartHotKey
                return
            }
            let candidate = stackStartHotKey
            if !stackStartHotKeyManager.register(candidate) {
                let currentStr = oldStackStartHotKey?.displayString ?? "Not set"
                let candidateStr = candidate?.displayString ?? "Not set"
                statusMessage = "Could not register shortcut \(candidateStr). Keeping \(currentStr)."
                stackStartHotKey = oldStackStartHotKey
            } else {
                oldStackStartHotKey = candidate
                persistOptionalHotKey(candidate, key: Keys.stackStartHotKey)
            }
        }
    }

    @Published var stackNextHotKey: HotKeyConfiguration? {
        didSet {
            guard hasStarted else {
                oldStackNextHotKey = stackNextHotKey
                persistOptionalHotKey(stackNextHotKey, key: Keys.stackNextHotKey)
                return
            }
            guard stackNextHotKey != oldStackNextHotKey else { return }
            guard !isHotKeyInUse(stackNextHotKey, excluding: .stackNext) else {
                statusMessage = "That hotkey is already in use."
                stackNextHotKey = oldStackNextHotKey
                return
            }
            let candidate = stackNextHotKey
            if !stackNextHotKeyManager.register(candidate) {
                let currentStr = oldStackNextHotKey?.displayString ?? "Not set"
                let candidateStr = candidate?.displayString ?? "Not set"
                statusMessage = "Could not register shortcut \(candidateStr). Keeping \(currentStr)."
                stackNextHotKey = oldStackNextHotKey
            } else {
                oldStackNextHotKey = candidate
                persistOptionalHotKey(candidate, key: Keys.stackNextHotKey)
            }
        }
    }

    @Published var historyLimit: Int {
        didSet {
            historyLimit = min(max(historyLimit, 10), 200)
            UserDefaults.standard.set(historyLimit, forKey: Keys.historyLimit)
            store.setLimit(historyLimit)
        }
    }

    @Published var retention: ClipboardRetention {
        didSet {
            UserDefaults.standard.set(retention.rawValue, forKey: Keys.retention)
            store.setRetention(retention)
        }
    }

    @Published var ignoredBundleIdentifiers: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(ignoredBundleIdentifiers).sorted(), forKey: Keys.ignoredBundleIdentifiers)
            monitor.ignoredBundleIdentifiers = ignoredBundleIdentifiers
            refreshAvailableApplications()
        }
    }

    @Published private(set) var availableApplications: [ClipboardApplication] = []
    @Published private(set) var isHistoryPaused = false
    @Published private(set) var isCapturingStack = false
    @Published private(set) var clipboardStack = ClipboardStack()
    @Published private(set) var requireAuthenticationForPrivateViews = false
    @Published private(set) var hasCustomPanelPosition = false

    @Published var appearance: ClipboardAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance(appearance, to: settingsWindow)
            applyAppearance(appearance, to: favoritesWindow)
            panelController.setAppearance(appearance)
        }
    }

    @Published var material: ClipboardMaterial {
        didSet {
            UserDefaults.standard.set(material.rawValue, forKey: Keys.material)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isUpdatingLaunchAtLogin else { return }
            let requestedValue = launchAtLogin
            do {
                if requestedValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                UserDefaults.standard.set(requestedValue, forKey: Keys.launchAtLogin)
            } catch {
                isUpdatingLaunchAtLogin = true
                launchAtLogin = !requestedValue
                isUpdatingLaunchAtLogin = false
                statusMessage = "Launch at login could not be changed."
            }
        }
    }

    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var isRecordingHotKey = false
    @Published private(set) var isCapturingScreenshot = false
    @Published private(set) var isRecordingGIF = false
    @Published var statusMessage: String?
    @Published private(set) var installationHealth = InstallationHealth.current()

    let store: ClipboardStore
    let snippetStore: SnippetStore
    let permissionsManager: PermissionsManager
    let captureCoordinator: CaptureCoordinator

    var isDeviceAuthenticationAvailable: Bool {
        authenticationService.isAvailable
    }

    var isHistoryHotKeyRegistered: Bool {
        hotKeyManager.isRegistered
    }

    var isOCRHotKeyRegistered: Bool {
        ocrHotKeyManager.isRegistered
    }

    var canCopyAgainScreenOCR: Bool {
        captureCoordinator.canCopyAgain
    }

    private let monitor: PasteboardMonitor
    private let hotKeyManager: GlobalHotKeyManaging
    private let gifHotKeyManager: GlobalHotKeyManaging
    private let stackStartHotKeyManager: GlobalHotKeyManaging
    private let stackNextHotKeyManager: GlobalHotKeyManaging
    private let ocrHotKeyManager: GlobalHotKeyManaging
    private let panelController = ClipboardPanelController()
    private let screenshotCaptureService = ScreenshotCaptureService()
    private let screenGIFRecorder = ScreenGIFRecorder()
    private let quickLookPreview = ClipboardQuickLookPreview()
    private let annotationEditorController = AnnotationEditorController()
    private let authenticationService = DeviceAuthenticationService()
    private var settingsWindow: NSWindow?
    private var favoritesWindow: NSWindow?
    private var targetApplication: NSRunningApplication?
    private var recordingMonitor: Any?
    private var accessibilityTimer: Timer?
    private var hasStarted = false
    private var isUpdatingLaunchAtLogin = false
    private var isAuthenticatingPrivateView = false
    private var oldHotKey: HotKeyConfiguration
    private var oldGIFHotKey: HotKeyConfiguration
    private var oldOCRHotKey: HotKeyConfiguration
    private var oldStackStartHotKey: HotKeyConfiguration?
    private var oldStackNextHotKey: HotKeyConfiguration?
    private var recordingHotKeyTarget: HotKeyTarget?
    private enum Keys {
        static let hotKey = "clipboard.hotKey"
        static let gifHotKey = "clipboard.gifHotKey"
        static let hasMigratedGIFHotKey = "clipboard.hasMigratedGIFHotKey"
        static let ocrHotKey = "clipboard.ocrHotKey"
        static let stackStartHotKey = "clipboard.stackStartHotKey"
        static let stackNextHotKey = "clipboard.stackNextHotKey"
        static let historyLimit = "clipboard.historyLimit"
        static let retention = "clipboard.retention"
        static let ignoredBundleIdentifiers = "clipboard.ignoredBundleIdentifiers"
        static let appearance = "clipboard.appearance"
        static let material = "clipboard.material"
        static let launchAtLogin = "clipboard.launchAtLogin"
        static let requireAuthenticationForPrivateViews = "clipboard.requireAuthenticationForPrivateViews"
    }

    init(
        store: ClipboardStore? = nil,
        snippetStore: SnippetStore? = nil,
        permissionsManager: PermissionsManager? = nil,
        captureCoordinator: CaptureCoordinator? = nil,
        monitor: PasteboardMonitor? = nil,
        hotKeyManager: GlobalHotKeyManaging? = nil,
        gifHotKeyManager: GlobalHotKeyManaging? = nil,
        stackStartHotKeyManager: GlobalHotKeyManaging? = nil,
        stackNextHotKeyManager: GlobalHotKeyManaging? = nil,
        ocrHotKeyManager: GlobalHotKeyManaging? = nil
    ) {
        let actualMonitor = monitor ?? PasteboardMonitor()
        let actualPermissions = permissionsManager ?? PermissionsManager()
        let savedHistoryLimit = UserDefaults.standard.integer(forKey: Keys.historyLimit)
        let savedRetention = UserDefaults.standard.string(forKey: Keys.retention)
            .flatMap(ClipboardRetention.init(rawValue:)) ?? .never
        let actualStore = store ?? ClipboardStore(
            limit: savedHistoryLimit == 0 ? 50 : savedHistoryLimit,
            retention: savedRetention
        )
        self.store = actualStore
        self.snippetStore = snippetStore ?? SnippetStore()
        self.permissionsManager = actualPermissions
        self.monitor = actualMonitor
        self.captureCoordinator = captureCoordinator ?? CaptureCoordinator(
            store: actualStore,
            monitor: actualMonitor,
            permissionsManager: actualPermissions
        )
        self.hotKeyManager = hotKeyManager ?? GlobalHotKeyManager(identifier: 1)
        self.gifHotKeyManager = gifHotKeyManager ?? GlobalHotKeyManager(identifier: 2)
        self.stackStartHotKeyManager = stackStartHotKeyManager ?? GlobalHotKeyManager(identifier: 3)
        self.stackNextHotKeyManager = stackNextHotKeyManager ?? GlobalHotKeyManager(identifier: 4)
        self.ocrHotKeyManager = ocrHotKeyManager ?? GlobalHotKeyManager(identifier: 5)
        let savedHotKey = (UserDefaults.standard.data(forKey: Keys.hotKey).flatMap { try? JSONDecoder().decode(HotKeyConfiguration.self, from: $0) }) ?? .default

        let savedGIFHotKey = HotKeyConfiguration.resolveGIFHotKey()

        let savedOCRHotKey = (UserDefaults.standard.data(forKey: Keys.ocrHotKey).flatMap { try? JSONDecoder().decode(HotKeyConfiguration.self, from: $0) }) ?? .ocrDefault
        let savedStackStartHotKey = UserDefaults.standard.data(forKey: Keys.stackStartHotKey)
            .flatMap { try? JSONDecoder().decode(HotKeyConfiguration.self, from: $0) }
        let savedStackNextHotKey = UserDefaults.standard.data(forKey: Keys.stackNextHotKey)
            .flatMap { try? JSONDecoder().decode(HotKeyConfiguration.self, from: $0) }
        let savedIgnoredBundleIdentifiers = Set(UserDefaults.standard.stringArray(forKey: Keys.ignoredBundleIdentifiers) ?? [])
        let savedAppearance = UserDefaults.standard.string(forKey: Keys.appearance)
            .flatMap(ClipboardAppearance.init(rawValue:)) ?? .system
        let savedMaterial = UserDefaults.standard.string(forKey: Keys.material)
            .flatMap(ClipboardMaterial.init(rawValue:)) ?? .liquidGlass
        hotKey = savedHotKey
        oldHotKey = savedHotKey
        gifHotKey = savedGIFHotKey
        oldGIFHotKey = savedGIFHotKey
        ocrHotKey = savedOCRHotKey
        oldOCRHotKey = savedOCRHotKey
        stackStartHotKey = savedStackStartHotKey
        oldStackStartHotKey = savedStackStartHotKey
        stackNextHotKey = savedStackNextHotKey
        oldStackNextHotKey = savedStackNextHotKey
        historyLimit = actualStore.limit
        retention = savedRetention
        ignoredBundleIdentifiers = savedIgnoredBundleIdentifiers
        appearance = savedAppearance
        material = savedMaterial
        launchAtLogin = SMAppService.mainApp.status == .enabled
        requireAuthenticationForPrivateViews = UserDefaults.standard.bool(
            forKey: Keys.requireAuthenticationForPrivateViews
        )
        hasCustomPanelPosition = panelController.hasCustomPosition

        panelController.onPositionChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.hasCustomPanelPosition = self?.panelController.hasCustomPosition ?? false
            }
        }

        self.hotKeyManager.onHotKey = { [weak self] in
            self?.showPanel()
        }
        self.gifHotKeyManager.onHotKey = { [weak self] in
            self?.toggleGIFRecording()
        }
        self.ocrHotKeyManager.onHotKey = { [weak self] in
            self?.startScreenOCR()
        }
        self.stackStartHotKeyManager.onHotKey = { [weak self] in
            self?.startClipboardStack()
        }
        self.stackNextHotKeyManager.onHotKey = { [weak self] in
            self?.pasteNextStackItem()
        }
        actualMonitor.ignoredBundleIdentifiers = savedIgnoredBundleIdentifiers
        actualMonitor.onSnapshot = { [weak self] snapshot, sourceApplication in
            guard let self else { return }
            self.store.ingest(snapshot, sourceApplication: sourceApplication)
            guard self.isCapturingStack,
                  let item = self.store.items.first(where: { $0.fingerprint == snapshot.fingerprint })
            else { return }
            self.clipboardStack.append(item.id)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshAvailableApplications()
        refreshInstallationHealth()
        refreshPermissions()
        monitor.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        monitor.start()
        oldHotKey = hotKey
        oldGIFHotKey = gifHotKey
        oldOCRHotKey = ocrHotKey
        oldStackStartHotKey = stackStartHotKey
        oldStackNextHotKey = stackNextHotKey
        if !hotKeyManager.register(hotKey) {
            statusMessage = "Could not register \(hotKey.displayString); previous configuration kept."
        }
        if !gifHotKeyManager.register(gifHotKey) {
            statusMessage = "Could not register \(gifHotKey.displayString) for GIF recording."
        }
        if !ocrHotKeyManager.register(ocrHotKey) {
            statusMessage = "Could not register \(ocrHotKey.displayString) for Screen OCR."
        }
        _ = stackStartHotKeyManager.register(stackStartHotKey)
        _ = stackNextHotKeyManager.register(stackNextHotKey)
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAccessibilityTrusted = self?.permissionsManager.isAccessibilityTrusted ?? AXIsProcessTrusted()
                self?.refreshPauseState()
            }
        }
    }

    func stop() {
        monitor.stop()
        hotKeyManager.stop()
        gifHotKeyManager.stop()
        ocrHotKeyManager.stop()
        stackStartHotKeyManager.stop()
        stackNextHotKeyManager.stop()
        screenGIFRecorder.cancel()
        annotationEditorController.close()
        quickLookPreview.close()
        favoritesWindow?.orderOut(nil)
        isCapturingStack = false
        clipboardStack.removeAll()
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        stopRecordingHotKey()
    }

    func showPanel() {
        quickLookPreview.close()
        let currentProcessIdentifier = NSRunningApplication.current.processIdentifier
        let resolvedTargetApplication = panelController.targetApplication(
            excluding: currentProcessIdentifier
        )

        guard requireAuthenticationForPrivateViews else {
            presentPanel(targetApplication: resolvedTargetApplication)
            return
        }
        authenticatePrivateView(reason: "Open clipboard history") { [weak self] in
            self?.presentPanel(targetApplication: resolvedTargetApplication)
        }
    }

    private func presentPanel(targetApplication resolvedTargetApplication: NSRunningApplication?) {
        targetApplication = resolvedTargetApplication

        // Do not invoke AXIsProcessTrustedWithOptions here: that would present the
        // macOS authorization prompt every time the history picker is opened.
        if let guidance = AccessibilityPermissionFlow.guidanceMessage(isTrusted: isAccessibilityTrusted) {
            statusMessage = guidance
        }

        panelController.show(
            store: store,
            targetApplication: targetApplication,
            appearance: appearance,
            material: material,
            onPaste: { [weak self] item, format in self?.paste(item, format: format) },
            onTogglePin: { [weak self] item in self?.togglePin(item) },
            onPreview: { [weak self] item in self?.preview(item) },
            onEdit: { [weak self] item in self?.editImage(item) },
            onExtractText: { [weak self] item in self?.extractText(item) },
            onSaveGIF: { [weak self] item in self?.saveGIF(item) },
            onSaveFavorite: { [weak self] item in self?.saveAsFavorite(item) },
            onDelete: { [weak self] item in self?.deleteItem(item) }
        )
    }

    func resetPanelPosition() {
        panelController.resetPosition()
        hasCustomPanelPosition = panelController.hasCustomPosition
    }

    func editImage(_ item: ClipboardItem) {
        guard item.hasImage, !item.isGIF, let imageData = item.imageData,
              let image = NSImage(data: imageData) else {
            statusMessage = "This item cannot be edited."
            return
        }

        panelController.close()
        annotationEditorController.show(
            image: image,
            appearance: appearance,
            material: material,
            onCopy: { [weak self] data in self?.copyAnnotatedScreenshot(data) }
        )
    }

    func extractText(_ item: ClipboardItem) {
        guard item.canExtractText, let imageData = item.imageData else {
            statusMessage = "Text extraction is available for static images only."
            return
        }

        panelController.close()
        statusMessage = "Extracting text…"
        let storedOCRText = item.ocrText

        Task { [weak self] in
            let recognizedText: String?
            if let storedOCRText {
                recognizedText = storedOCRText
            } else {
                recognizedText = await Task.detached(priority: .userInitiated) {
                    LocalOCRService.recognize(imageData: imageData)
                }.value
            }

            guard let self else { return }
            guard let recognizedText, !recognizedText.isEmpty else {
                self.statusMessage = "No text was detected in the image."
                return
            }

            self.copyExtractedText(recognizedText, sourceApplication: item.sourceApplication)
        }
    }

    private func copyExtractedText(_ text: String, sourceApplication: ClipboardSourceApplication? = nil) {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(
            text: text,
            richTextData: nil,
            imageData: nil,
            imageType: nil,
            fileURLs: []
        )
        monitor.suppressFingerprint(snapshot.fingerprint)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            statusMessage = "The extracted text could not be copied."
            return
        }

        monitor.recordAppOriginatedWrite(changeCount: pasteboard.changeCount, fingerprint: snapshot.fingerprint)
        store.ingest(snapshot, sourceApplication: sourceApplication)
        statusMessage = "Extracted text copied to the clipboard."
    }

    func preview(_ item: ClipboardItem) {
        panelController.close()
        guard quickLookPreview.show(item: item) else {
            statusMessage = "No preview is available for this item."
            return
        }
        statusMessage = nil
    }

    func togglePin(_ item: ClipboardItem) {
        let shouldPin = !item.isPinned
        guard store.setPinned(item.id, pinned: shouldPin) else {
            if shouldPin {
                statusMessage = "Maximum of 3 pinned items."
            }
            return
        }
    }

    func deleteItem(_ item: ClipboardItem) {
        guard store.remove(item.id) else { return }
        statusMessage = "Item deleted."
    }

    func saveAsFavorite(_ item: ClipboardItem) {
        guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Only text items can be saved to the Library."
            return
        }
        _ = snippetStore.add(text: text)
        statusMessage = "Saved to Library."
    }

    func showFavorites() {
        panelController.close()
        let resolvedTargetApplication = panelController.targetApplication(
            excluding: NSRunningApplication.current.processIdentifier
        )

        guard requireAuthenticationForPrivateViews else {
            presentFavorites(targetApplication: resolvedTargetApplication)
            return
        }
        authenticatePrivateView(reason: "Open the clipboard Library") { [weak self] in
            self?.presentFavorites(targetApplication: resolvedTargetApplication)
        }
    }

    private func presentFavorites(targetApplication resolvedTargetApplication: NSRunningApplication?) {
        targetApplication = resolvedTargetApplication

        if favoritesWindow == nil {
            let favoritesSize = NSSize(width: 520, height: 430)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: favoritesSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance.nsAppearance
            window.setContentSize(favoritesSize)
            window.minSize = NSSize(width: 420, height: 320)
            window.title = "Library — clipboard"
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let rootView = FavoritesView(
                store: snippetStore,
                material: material,
                onPaste: { [weak self] snippet in self?.pasteSnippet(snippet) },
                onClose: { [weak self] in self?.favoritesWindow?.orderOut(nil) }
            )
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.view.frame = NSRect(origin: .zero, size: favoritesSize)
            hostingController.view.autoresizingMask = [.width, .height]
            window.contentViewController = hostingController

            window.center()
            favoritesWindow = window
        }

        applyAppearance(appearance, to: favoritesWindow)
        favoritesWindow?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        favoritesWindow?.orderFrontRegardless()
        favoritesWindow?.makeKey()
    }

    func setPrivateViewAuthenticationEnabled(_ enabled: Bool) {
        guard enabled else {
            requireAuthenticationForPrivateViews = false
            UserDefaults.standard.set(false, forKey: Keys.requireAuthenticationForPrivateViews)
            statusMessage = "History and Library authentication disabled."
            return
        }

        guard authenticationService.isAvailable else {
            statusMessage = "Touch ID or Mac authentication is unavailable."
            return
        }

        authenticatePrivateView(reason: "Protect clipboard history and Library") { [weak self] in
            guard let self else { return }
            self.requireAuthenticationForPrivateViews = true
            UserDefaults.standard.set(true, forKey: Keys.requireAuthenticationForPrivateViews)
            self.statusMessage = "History and Library authentication enabled."
        }
    }

    private func authenticatePrivateView(reason: String, onSuccess: @escaping () -> Void) {
        guard !isAuthenticatingPrivateView else { return }
        isAuthenticatingPrivateView = true
        authenticationService.authenticate(reason: reason) { [weak self] success in
            guard let self else { return }
            self.isAuthenticatingPrivateView = false
            if success {
                onSuccess()
            } else {
                self.statusMessage = "Authentication was cancelled or failed."
            }
        }
    }

    func showSettings() {
        panelController.close()
        refreshAvailableApplications()

        if settingsWindow == nil {
            let settingsSize = NSSize(width: 520, height: 500)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: settingsSize),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance.nsAppearance
            window.setContentSize(settingsSize)
            window.minSize = settingsSize
            window.title = "Settings — clipboard"
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.standardWindowButton(.closeButton)?.isEnabled = true
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = true

            let rootView = SettingsView()
                .environmentObject(self)
                .frame(width: settingsSize.width, height: settingsSize.height, alignment: .top)
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.view.frame = NSRect(origin: .zero, size: settingsSize)
            hostingController.view.autoresizingMask = [.width, .height]
            window.contentViewController = hostingController

            window.center()
            settingsWindow = window
        }

        applyAppearance(appearance, to: settingsWindow)
        settingsWindow?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.orderFrontRegardless()
        settingsWindow?.makeKey()
    }

    private func applyAppearance(_ appearance: ClipboardAppearance, to window: NSWindow?) {
        window?.appearance = appearance.nsAppearance
        window?.contentView?.appearance = appearance.nsAppearance
        window?.backgroundColor = .windowBackgroundColor
        window?.contentView?.needsDisplay = true
    }

    func clearHistory() {
        store.clear()
        statusMessage = "History cleared."
    }

    func clearUnpinnedHistory() {
        let removedCount = store.clearUnpinned()
        statusMessage = removedCount == 0
            ? "No unpinned items to clear."
            : "Cleared \(removedCount) unpinned item\(removedCount == 1 ? "" : "s")."
    }

    func pauseHistory(for duration: ClipboardPauseDuration) {
        monitor.pauseHistory(for: duration)
        isHistoryPaused = true
        statusMessage = "History capture paused."
    }

    func resumeHistory() {
        monitor.resumeHistory()
        isHistoryPaused = false
        statusMessage = "History capture resumed."
    }

    func refreshPauseState() {
        guard isHistoryPaused else { return }
        if !monitor.isPaused {
            isHistoryPaused = false
            statusMessage = "History capture resumed."
        }
    }

    func refreshAvailableApplications() {
        let currentProcessIdentifier = NSRunningApplication.current.processIdentifier
        var applications = NSWorkspace.shared.runningApplications
            .filter {
                $0.processIdentifier != currentProcessIdentifier &&
                $0.activationPolicy == .regular &&
                $0.bundleIdentifier != nil
            }
            .compactMap { application -> ClipboardApplication? in
                guard let bundleIdentifier = application.bundleIdentifier else { return nil }
                return ClipboardApplication(
                    bundleIdentifier: bundleIdentifier,
                    displayName: application.localizedName ?? bundleIdentifier
                )
            }

        let knownBundleIdentifiers = Set(applications.map(\.bundleIdentifier))
        applications.append(contentsOf: ignoredBundleIdentifiers
            .subtracting(knownBundleIdentifiers)
            .map { ClipboardApplication(bundleIdentifier: $0, displayName: $0) })
        availableApplications = applications.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func isApplicationIgnored(_ bundleIdentifier: String) -> Bool {
        ignoredBundleIdentifiers.contains(bundleIdentifier)
    }

    func setApplicationIgnored(_ bundleIdentifier: String, ignored: Bool) {
        var updated = ignoredBundleIdentifiers
        if ignored {
            updated.insert(bundleIdentifier)
        } else {
            updated.remove(bundleIdentifier)
        }
        ignoredBundleIdentifiers = updated
    }

    func startClipboardStack() {
        clipboardStack.removeAll()
        targetApplication = nil
        isCapturingStack = true
        statusMessage = "Stack capture started. Copy the items you want to paste in sequence."
    }

    func finishClipboardStack() {
        isCapturingStack = false
        if clipboardStack.isEmpty {
            statusMessage = "Stack capture finished without items."
        } else {
            let suffix = clipboardStack.count == 1 ? "" : "s"
            statusMessage = "Stack ready: \(clipboardStack.count) item\(suffix) queued."
        }
    }

    func cancelClipboardStack() {
        isCapturingStack = false
        clipboardStack.removeAll()
        targetApplication = nil
        statusMessage = "Stack cleared."
    }

    func clearClipboardStack() {
        clipboardStack.removeAll()
        targetApplication = nil
        statusMessage = "Stack cleared."
    }

    func pasteNextStackItem() {
        guard !isCapturingStack else {
            statusMessage = "Finish stack capture before pasting."
            return
        }

        while let firstID = clipboardStack.itemIDs.first,
              store.item(withID: firstID) == nil {
            _ = clipboardStack.removeFirst()
        }

        guard let firstID = clipboardStack.itemIDs.first,
              let item = store.item(withID: firstID)
        else {
            targetApplication = nil
            statusMessage = "The clipboard stack is empty."
            return
        }

        let currentProcessIdentifier = NSRunningApplication.current.processIdentifier
        targetApplication = panelController.targetApplication(excluding: currentProcessIdentifier) ?? targetApplication
        let canPasteAutomatically = AXIsProcessTrusted() && targetApplication != nil
        guard paste(item, targetApplicationOverride: targetApplication) else { return }
        _ = clipboardStack.removeFirst()

        if clipboardStack.isEmpty {
            targetApplication = nil
            statusMessage = canPasteAutomatically
                ? "Last stack item pasted."
                : "Last stack item is on the clipboard. Press ⌘V to paste."
        } else {
            statusMessage = canPasteAutomatically
                ? "Stack item pasted. (\(clipboardStack.count)) remaining."
                : "Stack item ready on the clipboard. Press ⌘V, then paste the next item."
        }
    }

    func ignoreNextCopy() {
        monitor.ignoreNextCopy()
        statusMessage = "Next clipboard copy will be ignored."
    }

    func beginRecordingHotKey() {
        beginRecordingHotKey(for: .history)
    }

    func beginRecordingHotKey(for target: HotKeyTarget) {
        stopRecordingHotKey()
        recordingHotKeyTarget = target
        isRecordingHotKey = true
        let prompt: String
        switch target {
        case .history: prompt = "Press a new history combination…"
        case .gif: prompt = "Press a new GIF combination…"
        case .ocr: prompt = "Press a new screen OCR combination…"
        case .stackStart: prompt = "Press a new stack start combination…"
        case .stackNext: prompt = "Press a new paste next combination…"
        }
        statusMessage = prompt
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.stopRecordingHotKey()
                return nil
            }
            let modifiers = HotKeyConfiguration.modifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return event }
            let candidate = HotKeyConfiguration(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            guard !self.isHotKeyInUse(candidate, excluding: target) else {
                self.statusMessage = "That hotkey is already in use."
                return nil
            }
            let registered: Bool
            switch target {
            case .history:
                registered = self.hotKeyManager.register(candidate)
                if registered {
                    self.oldHotKey = self.hotKey
                    self.hotKey = candidate
                    self.persistHotKey(candidate, key: Keys.hotKey)
                }
            case .gif:
                registered = self.gifHotKeyManager.register(candidate)
                if registered {
                    self.oldGIFHotKey = self.gifHotKey
                    self.gifHotKey = candidate
                    self.persistHotKey(candidate, key: Keys.gifHotKey)
                }
            case .ocr:
                registered = self.ocrHotKeyManager.register(candidate)
                if registered {
                    self.oldOCRHotKey = self.ocrHotKey
                    self.ocrHotKey = candidate
                    self.persistHotKey(candidate, key: Keys.ocrHotKey)
                }
            case .stackStart:
                registered = self.stackStartHotKeyManager.register(candidate)
                if registered {
                    self.oldStackStartHotKey = self.stackStartHotKey
                    self.stackStartHotKey = candidate
                    self.persistOptionalHotKey(candidate, key: Keys.stackStartHotKey)
                }
            case .stackNext:
                registered = self.stackNextHotKeyManager.register(candidate)
                if registered {
                    self.oldStackNextHotKey = self.stackNextHotKey
                    self.stackNextHotKey = candidate
                    self.persistOptionalHotKey(candidate, key: Keys.stackNextHotKey)
                }
            }
            if registered {
                self.statusMessage = "Hotkey set: \(candidate.displayString)"
            } else {
                let currentActive: String
                switch target {
                case .history: currentActive = self.hotKey.displayString
                case .gif: currentActive = self.gifHotKey.displayString
                case .ocr: currentActive = self.ocrHotKey.displayString
                case .stackStart: currentActive = self.stackStartHotKey?.displayString ?? "Not set"
                case .stackNext: currentActive = self.stackNextHotKey?.displayString ?? "Not set"
                }
                self.statusMessage = "Could not register shortcut \(candidate.displayString). Keeping \(currentActive)."
            }
            self.stopRecordingHotKey()
            return nil
        }
    }

    func stopRecordingHotKey() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        let shouldClearPrompt = statusMessage?.hasPrefix("Press a new") == true
        recordingHotKeyTarget = nil
        isRecordingHotKey = false
        if shouldClearPrompt {
            statusMessage = nil
        }
    }

    func isRecordingHotKey(for target: HotKeyTarget) -> Bool {
        isRecordingHotKey && recordingHotKeyTarget == target
    }

    func clearHotKey(for target: HotKeyTarget) {
        switch target {
        case .stackStart:
            stackStartHotKey = nil
            statusMessage = "Stack start hotkey cleared."
        case .stackNext:
            stackNextHotKey = nil
            statusMessage = "Paste next hotkey cleared."
        case .history, .gif, .ocr:
            break
        }
    }

    private func persistHotKey(_ configuration: HotKeyConfiguration, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(configuration), forKey: key)
    }

    private func persistOptionalHotKey(_ configuration: HotKeyConfiguration?, key: String) {
        guard let configuration else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(configuration), forKey: key)
    }

    private func isHotKeyInUse(_ candidate: HotKeyConfiguration?, excluding target: HotKeyTarget) -> Bool {
        guard let candidate else { return false }
        let configured: [(HotKeyTarget, HotKeyConfiguration?)] = [
            (.history, hotKey),
            (.gif, gifHotKey),
            (.ocr, ocrHotKey),
            (.stackStart, stackStartHotKey),
            (.stackNext, stackNextHotKey)
        ]
        return configured.contains { configuredTarget, configuration in
            configuredTarget != target && configuration == candidate
        }
    }

    var canRetryScreenOCR: Bool {
        captureCoordinator.canRetry
    }

    func startScreenOCR() {
        guard permissionsManager.hasScreenRecordingPermission else {
            statusMessage = CaptureRecovery.screenRecordingRequired
            return
        }
        panelController.close()
        annotationEditorController.close()
        settingsWindow?.orderOut(nil)
        captureCoordinator.startCapture()
    }

    func retryScreenOCR() {
        panelController.close()
        captureCoordinator.retryCapture()
    }

    func copyAgainScreenOCR() {
        captureCoordinator.copyAgain()
    }

    func refreshInstallationHealth() {
        installationHealth = InstallationHealth.current()
    }

    func refreshPermissions() {
        permissionsManager.checkPermissions()
        isAccessibilityTrusted = permissionsManager.isAccessibilityTrusted
    }

    func copyDiagnostics() {
        refreshInstallationHealth()
        refreshPermissions()
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let report = DiagnosticsReport.make(
            version: version,
            build: build,
            health: installationHealth,
            hasScreenRecordingPermission: permissionsManager.hasScreenRecordingPermission,
            isAccessibilityTrusted: permissionsManager.isAccessibilityTrusted,
            historyHotKey: hotKey.displayString,
            isHistoryHotKeyRegistered: isHistoryHotKeyRegistered,
            ocrHotKey: ocrHotKey.displayString,
            isOCRHotKeyRegistered: isOCRHotKeyRegistered
        )
        let snapshot = ClipboardSnapshot(text: report, richTextData: nil, imageData: nil, imageType: nil, fileURLs: [])
        let pasteboard = NSPasteboard.general
        monitor.suppressFingerprint(snapshot.fingerprint)
        pasteboard.clearContents()
        guard pasteboard.setString(report, forType: .string) else {
            statusMessage = "Diagnostics could not be copied."
            return
        }
        monitor.recordAppOriginatedWrite(changeCount: pasteboard.changeCount, fingerprint: snapshot.fingerprint)
        statusMessage = "Diagnostics copied to clipboard. No clipboard contents, OCR text, or private data were included."
    }

    func openScreenRecordingSettings() {
        permissionsManager.openScreenRecordingSettings()
    }

    func relaunchForPermissions() {
        permissionsManager.relaunchApplication()
    }

    func openAccessibilitySettings() {
        permissionsManager.openAccessibilitySettings()
    }

    func captureAndAnnotate() {
        guard !isCapturingScreenshot else {
            statusMessage = "A screen capture is already in progress."
            return
        }

        panelController.close()
        annotationEditorController.close()
        settingsWindow?.orderOut(nil)
        isCapturingScreenshot = true
        statusMessage = "Select an area to capture…"

        screenshotCaptureService.captureSelection { [weak self] result in
            guard let self else { return }
            self.isCapturingScreenshot = false
            switch result {
            case .success(let image):
                self.statusMessage = nil
                self.annotationEditorController.show(
                    image: image,
                    appearance: self.appearance,
                    material: self.material,
                    onCopy: { [weak self] data in self?.copyAnnotatedScreenshot(data) }
                )
            case .failure(.cancelled):
                self.statusMessage = nil
            case .failure(let error):
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private func copyAnnotatedScreenshot(_ data: Data) {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(
            text: nil,
            richTextData: nil,
            imageData: data,
            imageType: NSPasteboard.PasteboardType.png.rawValue,
            fileURLs: []
        )
        monitor.suppressFingerprint(snapshot.fingerprint)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            statusMessage = "The annotated screenshot could not be copied."
            return
        }
        monitor.recordAppOriginatedWrite(changeCount: pasteboard.changeCount, fingerprint: snapshot.fingerprint)
        store.ingest(snapshot)
        statusMessage = "Annotated screenshot copied to the clipboard."
    }

    func recordGIF() {
        guard !isRecordingGIF else {
            statusMessage = "A GIF recording is already in progress."
            return
        }

        panelController.close()
        annotationEditorController.close()
        settingsWindow?.orderOut(nil)
        isRecordingGIF = true
        statusMessage = "Drag to select an area. Release to start recording."

        screenGIFRecorder.start { [weak self] result in
            guard let self else { return }
            self.isRecordingGIF = false
            switch result {
            case .success(let data):
                self.copyGIFToClipboard(data)
            case .failure(.cancelled):
                self.statusMessage = nil
            case .failure(let error):
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func toggleGIFRecording() {
        if isRecordingGIF {
            finishGIFRecording()
        } else {
            recordGIF()
        }
    }

    func cancelGIFRecording() {
        guard isRecordingGIF else { return }
        statusMessage = "Cancelling GIF recording…"
        screenGIFRecorder.cancel()
    }

    func finishGIFRecording() {
        guard isRecordingGIF else { return }
        statusMessage = "Finishing GIF recording…"
        screenGIFRecorder.finish()
    }

    func saveLatestGIF() {
        guard let item = store.items.first(where: { $0.isGIF }) else {
            statusMessage = "No GIF is available to save."
            return
        }
        saveGIF(item)
    }

    func saveGIF(_ item: ClipboardItem) {
        guard item.isGIF, let data = item.imageData else {
            statusMessage = "This item is not a GIF."
            return
        }

        panelController.close()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = GIFFileExporter.defaultFilename()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let outputURL = try GIFFileExporter.write(data, to: url)
                self?.statusMessage = "GIF saved to \(outputURL.lastPathComponent)."
            } catch {
                self?.statusMessage = "The GIF could not be saved."
            }
        }
    }

    private func pasteSnippet(_ snippet: ClipboardSnippet) {
        favoritesWindow?.orderOut(nil)
        let item = ClipboardItem(
            fingerprint: "snippet-\(snippet.id.uuidString)",
            text: snippet.text,
            richTextData: nil,
            imageData: nil,
            imageType: nil,
            files: []
        )
        _ = paste(item, targetApplicationOverride: targetApplication)
    }

    private func copyGIFToClipboard(_ data: Data) {
        let pasteboard = NSPasteboard.general
        let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
        let snapshot = ClipboardSnapshot(
            text: nil,
            richTextData: nil,
            imageData: data,
            imageType: gifType.rawValue,
            fileURLs: []
        )
        monitor.suppressFingerprint(snapshot.fingerprint)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: gifType) else {
            statusMessage = "The GIF could not be copied to the clipboard."
            return
        }

        monitor.recordAppOriginatedWrite(changeCount: pasteboard.changeCount, fingerprint: snapshot.fingerprint)
        store.ingest(snapshot)
        statusMessage = "GIF copied to the clipboard. Press ⌘V to paste."
    }

    @discardableResult
    private func paste(
        _ item: ClipboardItem,
        format: ClipboardPasteFormat = .original,
        targetApplicationOverride: NSRunningApplication? = nil
    ) -> Bool {
        guard let payload = ClipboardPasteFormatter.payload(for: item, format: format) else {
            statusMessage = "\(format.title) is unavailable for this item."
            return false
        }

        panelController.close()
        let pasteboard = NSPasteboard.general
        monitor.suppressFingerprint(item.fingerprint)
        pasteboard.clearContents()

        if let text = payload.text { pasteboard.setString(text, forType: .string) }
        if let richTextData = payload.richTextData { pasteboard.setData(richTextData, forType: .rtf) }
        if let imageData = payload.imageData, let imageType = payload.imageType {
            pasteboard.setData(imageData, forType: NSPasteboard.PasteboardType(imageType))
        }
        let urls = payload.fileURLs
        if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }
        monitor.recordAppOriginatedWrite(changeCount: pasteboard.changeCount, fingerprint: item.fingerprint)

        guard let destination = targetApplicationOverride ?? targetApplication else {
            statusMessage = "Item restored to the clipboard. Press ⌘V to paste."
            return true
        }
        guard permissionsManager.isAccessibilityTrusted else {
            statusMessage = "Item copied to clipboard. Enable Accessibility for automatic paste."
            return true
        }

        destination.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
        return true
    }
}
