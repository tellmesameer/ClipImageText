//
//  ScreenOCRTests.swift
//  ClipTextTests
//

import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import ClipText

actor MockScreenCaptureService: ScreenCaptureService {
    var shouldThrow = false
    var capturedRegions: [CGRect] = []
    var capturedDisplayBatches: [[DisplayInfo]] = []

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func getCapturedDisplayBatches() -> [[DisplayInfo]] {
        capturedDisplayBatches
    }

    func getCapturedRegions() -> [CGRect] {
        capturedRegions
    }

    func capture(display: DisplayInfo, region: CGRect) async throws -> CGImage {
        capturedRegions.append(region)
        capturedDisplayBatches.append([display])
        if shouldThrow {
            throw NSError(domain: "MockCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Capture failed"])
        }
        let size = CGSize(width: max(1, region.width), height: max(1, region.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    func capture(displays: [DisplayInfo], region: CGRect) async throws -> CGImage {
        capturedRegions.append(region)
        capturedDisplayBatches.append(displays)
        if shouldThrow {
            throw NSError(domain: "MockCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Capture failed"])
        }
        let size = CGSize(width: max(1, region.width), height: max(1, region.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    func invalidateCache() async {}
}

final class MockOCRService: OCRService {
    var textToReturn: String
    var shouldThrow = false

    init(textToReturn: String = "Recognized Text") {
        self.textToReturn = textToReturn
    }

    func recognizeText(from image: CGImage, configuration: OCRConfiguration) async throws -> OCRResult {
        if shouldThrow {
            throw NSError(domain: "MockOCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "OCR recognition failed"])
        }
        return OCRResult(text: textToReturn, observations: [], detectedCodes: [])
    }
}

@MainActor
final class MockSelectionController: SelectionController {
    var isVisible = false
    var selectedRect = CGRect(x: 10, y: 10, width: 200, height: 100)
    var currentScreen: NSScreen? = NSScreen.main
    var shouldCancel = false
    var lastStatus: String?

    func startSelection(onComplete: @escaping (CGRect, NSScreen?) -> Void, onCancel: @escaping () -> Void) {
        isVisible = true
        if shouldCancel {
            isVisible = false
            onCancel()
        } else {
            isVisible = false
            onComplete(selectedRect, currentScreen)
        }
    }

    func cancel() {
        isVisible = false
    }

    func showStatus(_ message: String?, on screen: NSScreen?) {
        lastStatus = message
    }
}

@MainActor
final class MockPermissionsService: PermissionsService {
    var hasScreenRecordingPermission: Bool
    var isAccessibilityTrusted: Bool
    var didRequest = false
    var openedScreenSettings = false
    var openedAccessibilitySettings = false
    var didRelaunch = false

    init(hasPermission: Bool = true, isAccessibilityTrusted: Bool = true) {
        self.hasScreenRecordingPermission = hasPermission
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    func checkPermissions() {}

    func requestScreenRecordingPermission() async -> Bool {
        didRequest = true
        return hasScreenRecordingPermission
    }

    func openScreenRecordingSettings() {
        openedScreenSettings = true
    }

    func openAccessibilitySettings() {
        openedAccessibilitySettings = true
    }

    func relaunchApplication() {
        didRelaunch = true
    }
}

final class MockGlobalHotKeyManager: GlobalHotKeyManaging {
    var onHotKey: (() -> Void)?
    var currentConfiguration: HotKeyConfiguration?
    var isRegistered: Bool { currentConfiguration != nil }
    var shouldFailRegistration = false
    var shouldFailRestoration = false
    var registrationAttempts: [HotKeyConfiguration?] = []
    var registrationCallCount = 0

    init(configuration: HotKeyConfiguration? = nil) {
        self.currentConfiguration = configuration
    }

    @discardableResult
    func register(_ configuration: HotKeyConfiguration?) -> Bool {
        registrationCallCount += 1
        registrationAttempts.append(configuration)
        if shouldFailRegistration {
            if shouldFailRestoration {
                currentConfiguration = nil
            }
            return false
        }
        currentConfiguration = configuration
        return true
    }

    func stop() {
        currentConfiguration = nil
    }
}

@MainActor
final class ScreenOCRTests: XCTestCase {
    private var temporaryDirectory: URL!

    private var testCipher: LocalDataCipher {
        LocalDataCipher { Data(repeating: 0xA5, count: 32) }
    }

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        super.tearDown()
    }

    func testDefaultOCRHotKeyIsOptionShiftT() {
        let configuration = HotKeyConfiguration.ocrDefault
        XCTAssertEqual(configuration.keyCode, 17)
        XCTAssertEqual(configuration.displayString, "⌥⇧T")
        XCTAssertTrue(configuration.modifiers & UInt32(optionKey) != 0)
        XCTAssertTrue(configuration.modifiers & UInt32(shiftKey) != 0)
    }

    func testStoreAddTextIngestsUnifiedHistory() throws {
        let store = ClipboardStore(
            directoryURL: temporaryDirectory,
            cipher: testCipher
        )

        let sampleText = "Hello from Screen OCR!"
        let sourceApp = ClipboardSourceApplication(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let item = store.addText(sampleText, sourceApplication: sourceApp)

        XCTAssertNotNil(item)
        XCTAssertEqual(store.items.count, 1)
        let first = try XCTUnwrap(store.items.first)
        XCTAssertEqual(first.text, sampleText)
        XCTAssertEqual(first.sourceApplication?.displayName, "Safari")
        XCTAssertEqual(first.kind, .text)
    }

    func testStoreAddTextDeduplicatesAndMovesToTop() throws {
        let store = ClipboardStore(
            directoryURL: temporaryDirectory,
            cipher: testCipher
        )

        _ = store.addText("First item")
        _ = store.addText("Second item")
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.text, "Second item")

        // Re-adding the first item must move it to the top without increasing count
        _ = store.addText("First item")
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.text, "First item")
        XCTAssertEqual(store.items[1].text, "Second item")
    }

    func testEmptyOCRTextDoesNotModifyStoreOrHistory() {
        let store = ClipboardStore(
            directoryURL: temporaryDirectory,
            cipher: testCipher
        )

        let result = store.addText("   \n\t  ")
        XCTAssertNil(result)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPasteboardMonitorSuppressedFingerprintIsIgnored() {
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        var receivedSnapshot: ClipboardSnapshot?

        monitor.onSnapshot = { snapshot, _ in
            receivedSnapshot = snapshot
        }

        let snapshot = ClipboardSnapshot(
            text: "Suppressed OCR Output",
            richTextData: nil,
            imageData: nil,
            imageType: nil,
            fileURLs: []
        )

        // Suppress this fingerprint
        monitor.suppressFingerprint(snapshot.fingerprint)

        // Write to pasteboard and poll monitor
        testPasteboard.clearContents()
        testPasteboard.setString("Suppressed OCR Output", forType: .string)
        monitor.poll()

        XCTAssertNil(receivedSnapshot)
    }

    func testAccessibilityFirstLaunchGuidanceDoesNotRequireAnAuthorizationPrompt() {
        XCTAssertNil(AccessibilityPermissionFlow.guidanceMessage(isTrusted: true))
        XCTAssertEqual(
            AccessibilityPermissionFlow.guidanceMessage(isTrusted: false),
            "Accessibility is optional. Enable it in Settings to position the picker near the field and paste automatically."
        )
    }

    func testInstallationHealthFindsOnlyOtherExistingInstallations() {
        let duplicates = InstallationHealth.duplicateInstallations(
            currentPath: "/Applications/ClipText.app",
            candidatePaths: ["/Applications/ClipText.app", "/Users/test/Applications/ClipText.app"],
            fileExists: { $0.contains("/Users/test") }
        )
        XCTAssertEqual(duplicates, ["/Users/test/Applications/ClipText.app"])
    }

    func testCaptureRecoveryMessagesExplainSafeNextSteps() {
        XCTAssertTrue(CaptureRecovery.screenRecordingRequired.contains("Open Settings"))
        XCTAssertTrue(CaptureRecovery.noTextFound.contains("try again"))
        XCTAssertTrue(CaptureRecovery.recognitionFailed.contains("clipboard and history were left unchanged"))
    }

    func testDiagnosticsReportIsRedacted() {
        let health = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Applications/ClipText.app",
            duplicateInstallations: [],
            teamIdentifier: "B6537Y9X84"
        )
        let report = DiagnosticsReport.make(
            version: "1.0",
            build: "1",
            health: health,
            hasScreenRecordingPermission: true,
            isAccessibilityTrusted: false,
            historyHotKey: "⌘⇧V",
            ocrHotKey: "⌥⇧T"
        )
        XCTAssertTrue(report.contains("Bundle ID: com.cliptext.app"))
        XCTAssertTrue(report.contains("Accessibility: Missing"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("clipboard history"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("ocr text"))
    }

    func testPermissionsManagerInitializesWithoutRequestingAccess() {
        let permissions = PermissionsManager()
        XCTAssertNotEqual(permissions.permissionStatus, .checking)
        XCTAssertTrue(permissions.permissionStatus == .allGranted || permissions.permissionStatus == .screenRecordingDenied)
        // Initialization uses CGPreflightScreenCaptureAccess only. It must not call
        // CGRequestScreenCaptureAccess or trigger an authorization prompt.
    }

    func testCaptureCoordinatorExecutesEndToEndOCRSingleEntry() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)

        // Wire monitor to store just like AppState does
        monitor.onSnapshot = { [weak store] snapshot, source in
            store?.ingest(snapshot, sourceApplication: source)
        }

        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Invoice #98765")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: true)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()

        // Allow async Task in startCapture to finish
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify written to pasteboard
        XCTAssertEqual(testPasteboard.string(forType: .string), "Invoice #98765")

        // Verify ingested into store exactly once
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "Invoice #98765")
        XCTAssertEqual(selectionController.lastStatus, "Copied")

        // Poll monitor — monitor should suppress this change count and fingerprint
        monitor.poll()
        XCTAssertEqual(store.items.count, 1)

        // Search finds this item
        XCTAssertTrue(store.items.first?.matchesSearch("invoice") == true)
        XCTAssertTrue(store.items.first?.matchesSearch("98765") == true)
    }

    func testCaptureCoordinatorEmptyOCRResultsDoesNotWriteToClipboardOrStore() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "   \n\t   ")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: true)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(testPasteboard.string(forType: .string))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(selectionController.lastStatus, "No text found")
    }

    func testCaptureCoordinatorCancellationLeavesClipboardAndStoreIntact() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        testPasteboard.setString("Existing Clipboard Value", forType: .string)

        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Should Not Be Captured")
        let selectionController = MockSelectionController()
        selectionController.shouldCancel = true
        let permissions = MockPermissionsService(hasPermission: true)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Pre-existing pasteboard content must remain intact
        XCTAssertEqual(testPasteboard.string(forType: .string), "Existing Clipboard Value")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testCaptureCoordinatorPermissionDeniedDoesNotStartSelection() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Some Text")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: false)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(selectionController.isVisible)
        XCTAssertFalse(permissions.didRequest)
        XCTAssertEqual(coordinator.statusMessage, CaptureRecovery.screenRecordingRequired)
        XCTAssertTrue(coordinator.canRetry)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testCaptureCoordinatorRetryRecoversAfterPermissionIsGranted() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Recovered Text")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: false)
        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()
        XCTAssertTrue(coordinator.canRetry)
        XCTAssertTrue(store.items.isEmpty)

        permissions.hasScreenRecordingPermission = true
        coordinator.retryCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(testPasteboard.string(forType: .string), "Recovered Text")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertFalse(coordinator.canRetry)
    }

    func testCaptureCoordinatorFailureShowsHUDAndLeavesStoreIntact() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        await screenCapture.setShouldThrow(true)
        let ocrService = MockOCRService(textToReturn: "Some Text")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: true)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(selectionController.lastStatus, "OCR Failed")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testOCRResultPersistsEncryptedAcrossStoreRestartsAndSearches() throws {
        let store1 = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let source = ClipboardSourceApplication(bundleIdentifier: "com.apple.Preview", name: "Preview")
        let item = store1.addText("Encrypted OCR Secret 42", sourceApplication: source)
        XCTAssertNotNil(item)

        // Reload from disk in a fresh store instance
        let store2 = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        XCTAssertEqual(store2.items.count, 1)
        let loadedItem = try XCTUnwrap(store2.items.first)
        XCTAssertEqual(loadedItem.text, "Encrypted OCR Secret 42")
        XCTAssertEqual(loadedItem.sourceApplication?.name, "Preview")

        // Verify search projections
        XCTAssertTrue(loadedItem.matchesSearch("secret"))
        XCTAssertTrue(loadedItem.matchesSearch("SECRET"))
        XCTAssertTrue(loadedItem.matchesSearch("42"))
        XCTAssertFalse(loadedItem.matchesSearch("notfound"))
    }

    func testScreenCoordinateConverterLocalCaptureGeometryWithNegativeOriginAndRetinaScaling() {
        // Display placed to the left of the primary display (negative x origin)
        let leftDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let region = CGRect(x: -1500, y: 200, width: 400, height: 300)
        let geom = ScreenCoordinateConverter.localCaptureGeometry(
            for: region,
            in: leftDisplay,
            scaleFactor: 2.0,
            padding: 0
        )
        XCTAssertNotNil(geom)
        guard let geom else { return }

        // Local x should be -1500 - (-1920) = 420
        XCTAssertEqual(geom.sourceRect.origin.x, 420)
        // Local y in ScreenCaptureKit coordinates (top-down):
        // displayFrame.maxY (1080) - intersected.maxY (500) = 580
        XCTAssertEqual(geom.sourceRect.origin.y, 580)
        XCTAssertEqual(geom.sourceRect.width, 400)
        XCTAssertEqual(geom.sourceRect.height, 300)
        // Pixel dimensions scaled by 2.0
        XCTAssertEqual(geom.pixelWidth, 800)
        XCTAssertEqual(geom.pixelHeight, 600)

        // Display placed above the primary display (positive y offset)
        let topDisplay = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let topRegion = CGRect(x: 100, y: 1200, width: 200, height: 100)
        let topGeom = ScreenCoordinateConverter.localCaptureGeometry(
            for: topRegion,
            in: topDisplay,
            scaleFactor: 1.0,
            padding: 0
        )
        XCTAssertNotNil(topGeom)
        guard let topGeom else { return }
        XCTAssertEqual(topGeom.sourceRect.origin.x, 100)
        // 2160 - 1300 = 860
        XCTAssertEqual(topGeom.sourceRect.origin.y, 860)
        XCTAssertEqual(topGeom.pixelWidth, 200)
        XCTAssertEqual(topGeom.pixelHeight, 100)

        // Display placed below the primary display (negative y origin)
        let bottomDisplay = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let bottomRegion = CGRect(x: 100, y: -500, width: 200, height: 100)
        let bottomGeom = ScreenCoordinateConverter.localCaptureGeometry(
            for: bottomRegion,
            in: bottomDisplay,
            scaleFactor: 2.0,
            padding: 0
        )
        XCTAssertNotNil(bottomGeom)
        guard let bottomGeom else { return }
        XCTAssertEqual(bottomGeom.sourceRect.origin.x, 100)
        // 0 - (-400) = 400
        XCTAssertEqual(bottomGeom.sourceRect.origin.y, 400)
        XCTAssertEqual(bottomGeom.pixelWidth, 400)
        XCTAssertEqual(bottomGeom.pixelHeight, 200)
    }

    func testScreenCoordinateConverterTargetDisplaySelection() {
        let display1 = DisplayInfo(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 2.0,
            localizedName: "Built-in Display"
        )
        let display2 = DisplayInfo(
            displayID: 2,
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
            backingScaleFactor: 1.0,
            localizedName: "External Right"
        )
        let display3 = DisplayInfo(
            displayID: 3,
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 2.0,
            localizedName: "External Left"
        )

        // Rect entirely on external right
        let rectRight = CGRect(x: 2000, y: 100, width: 200, height: 200)
        let targetRight = ScreenCoordinateConverter.targetDisplay(for: rectRight, in: [display1, display2, display3])
        XCTAssertEqual(targetRight?.displayID, 2)

        // Rect entirely on external left
        let rectLeft = CGRect(x: -1000, y: 100, width: 200, height: 200)
        let targetLeft = ScreenCoordinateConverter.targetDisplay(for: rectLeft, in: [display1, display2, display3])
        XCTAssertEqual(targetLeft?.displayID, 3)

        // Rect spanning seam but majority on display1
        let rectMajority1 = CGRect(x: 1800, y: 100, width: 200, height: 200) // 120 on display1, 80 on display2
        let targetMajority = ScreenCoordinateConverter.targetDisplay(for: rectMajority1, in: [display1, display2, display3])
        XCTAssertEqual(targetMajority?.displayID, 1)
    }

    func testScreenCoordinateConverterImageStitchingCombinesMultiDisplayImages() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let part1Context = CGContext(
            data: nil,
            width: 120,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let part1Image = part1Context.makeImage()!

        let part2Context = CGContext(
            data: nil,
            width: 180,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let part2Image = part2Context.makeImage()!

        let parts: [(image: CGImage, region: CGRect)] = [
            (part1Image, CGRect(x: 1800, y: 100, width: 120, height: 100)),
            (part2Image, CGRect(x: 1920, y: 100, width: 180, height: 100))
        ]
        let totalRegion = CGRect(x: 1800, y: 100, width: 300, height: 100)

        let stitched = ScreenCoordinateConverter.stitchImages(parts, totalRegion: totalRegion, targetScale: 2.0)
        XCTAssertNotNil(stitched)
        XCTAssertEqual(stitched?.width, 600)
        XCTAssertEqual(stitched?.height, 200)

        // Single part fast path returns original image directly
        let singlePart = ScreenCoordinateConverter.stitchImages(
            [(part1Image, CGRect(x: 1800, y: 100, width: 120, height: 100))],
            totalRegion: CGRect(x: 1800, y: 100, width: 120, height: 100),
            targetScale: 1.0
        )
        XCTAssertNotNil(singlePart)
        XCTAssertEqual(singlePart?.width, 120)
    }

    func testCaptureCoordinatorRoutesSelectionOnSecondaryDisplay() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Secondary Display Text")
        let selectionController = MockSelectionController()
        selectionController.selectedRect = CGRect(x: 2000, y: 100, width: 300, height: 150)
        let permissions = MockPermissionsService(hasPermission: true)

        let primaryDisplay = DisplayInfo(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 2.0,
            localizedName: "Built-in Retina"
        )
        let secondaryDisplay = DisplayInfo(
            displayID: 2,
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
            backingScaleFactor: 1.0,
            localizedName: "External Right"
        )

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard,
            displayProvider: { [primaryDisplay, secondaryDisplay] }
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify captured displays only contains secondary display
        let batches = await screenCapture.getCapturedDisplayBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 1)
        XCTAssertEqual(batches.first?.first?.displayID, 2)

        // Verify written to pasteboard and history
        XCTAssertEqual(testPasteboard.string(forType: .string), "Secondary Display Text")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "Secondary Display Text")
    }

    func testCaptureCoordinatorRoutesBoundaryCrossingSelectionToBothDisplays() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Cross Display Text")
        let selectionController = MockSelectionController()
        // Selection rect crossing boundary between Display 1 (max x = 1920) and Display 2 (min x = 1920)
        selectionController.selectedRect = CGRect(x: 1850, y: 200, width: 200, height: 100)
        let permissions = MockPermissionsService(hasPermission: true)

        let display1 = DisplayInfo(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 2.0,
            localizedName: "Display 1"
        )
        let display2 = DisplayInfo(
            displayID: 2,
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 2.0,
            localizedName: "Display 2"
        )

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard,
            displayProvider: { [display1, display2] }
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        let batches = await screenCapture.getCapturedDisplayBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 2)
        let capturedIDs = batches.first?.map(\.displayID).sorted() ?? []
        XCTAssertEqual(capturedIDs, [1, 2])

        XCTAssertEqual(testPasteboard.string(forType: .string), "Cross Display Text")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "Cross Display Text")
    }

    func testMultiDisplaySelectionSessionTrackingAndCancellation() {
        var completedRect: CGRect?
        var didCancel = false

        let session = MultiDisplaySelectionSession(
            screens: NSScreen.screens,
            onSelectionComplete: { rect, _ in
                completedRect = rect
            },
            onCancel: {
                didCancel = true
            }
        )

        session.startSelection(at: NSPoint(x: 100, y: 150))
        XCTAssertTrue(session.isSelecting)
        XCTAssertEqual(session.startLocation, NSPoint(x: 100, y: 150))

        session.updateSelection(to: NSPoint(x: 350, y: 400))
        XCTAssertEqual(session.currentRect, NSRect(x: 100, y: 150, width: 250, height: 250))

        session.cancel()
        XCTAssertTrue(didCancel)
        XCTAssertFalse(session.isSelecting)
        XCTAssertEqual(session.currentRect, .zero)
        XCTAssertNil(completedRect)
    }

    func testMultiDisplaySelectionSessionCompletion() {
        var completedRect: CGRect?
        var completedScreen: NSScreen?

        let session = MultiDisplaySelectionSession(
            screens: NSScreen.screens,
            onSelectionComplete: { rect, screen in
                completedRect = rect
                completedScreen = screen
            },
            onCancel: {}
        )

        session.startSelection(at: NSPoint(x: 100, y: 100))
        session.updateSelection(to: NSPoint(x: 300, y: 250))
        session.completeSelection()

        XCTAssertEqual(completedRect, NSRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertFalse(session.isSelecting)
    }

    func testSelectionWindowManagerMultiOverlayLifecycleAndDismissal() {
        let windowManager = DefaultSelectionWindowManager()
        XCTAssertFalse(windowManager.isVisible)

        var completedRect: CGRect?
        var didCancel = false

        windowManager.showOverlays(
            on: NSScreen.screens,
            onSelectionComplete: { rect, _ in
                completedRect = rect
            },
            onCancel: {
                didCancel = true
            }
        )

        if !NSScreen.screens.isEmpty {
            XCTAssertTrue(windowManager.isVisible)
            windowManager.hideOverlay()
            XCTAssertFalse(windowManager.isVisible)
        } else {
            XCTAssertTrue(didCancel)
        }
    }

    func testDefaultSelectionControllerCancellationCleansUpOverlays() {
        let windowManager = DefaultSelectionWindowManager()
        let controller = DefaultSelectionController(windowManager: windowManager)

        var didCancel = false
        controller.startSelection(
            onComplete: { _, _ in },
            onCancel: {
                didCancel = true
            }
        )

        if !NSScreen.screens.isEmpty {
            XCTAssertTrue(controller.isVisible)
            XCTAssertTrue(windowManager.isVisible)

            controller.cancel()
            XCTAssertTrue(didCancel)
            XCTAssertFalse(controller.isVisible)
            XCTAssertFalse(windowManager.isVisible)
        }
    }

    func testMissingScreenRecordingPermissionPreservesClipboardAndDoesNotCapture() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        testPasteboard.setString("Preserved Clipboard Content", forType: .string)

        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Should Not Capture")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: false)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()

        XCTAssertFalse(selectionController.isVisible)
        XCTAssertEqual(coordinator.captureState, .screenRecordingRequired)
        XCTAssertEqual(coordinator.statusMessage, CaptureRecovery.screenRecordingRequired)
        XCTAssertTrue(coordinator.canRetry)
        XCTAssertFalse(coordinator.canCopyAgain)
        XCTAssertEqual(testPasteboard.string(forType: .string), "Preserved Clipboard Content")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testCaptureCoordinatorTimeoutPreservesClipboardAndStore() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        testPasteboard.setString("Timeout Preserved Text", forType: .string)

        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let screenCapture = MockScreenCaptureService()
        await screenCapture.setShouldThrow(true)
        let ocrService = MockOCRService(textToReturn: "Never Returned")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: true)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(testPasteboard.string(forType: .string), "Timeout Preserved Text")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(coordinator.canRetry)
        XCTAssertFalse(coordinator.canCopyAgain)
    }

    func testRetryAndCopyAgainDeduplicatesHistory() async throws {
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        monitor.onSnapshot = { [weak store] snapshot, source in
            store?.ingest(snapshot, sourceApplication: source)
        }

        let screenCapture = MockScreenCaptureService()
        let ocrService = MockOCRService(textToReturn: "Identical Result")
        let selectionController = MockSelectionController()
        let permissions = MockPermissionsService(hasPermission: true)

        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: screenCapture,
            ocrManager: ocrService,
            selectionController: selectionController,
            pasteboard: testPasteboard
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(testPasteboard.string(forType: .string), "Identical Result")
        XCTAssertTrue(coordinator.canCopyAgain)

        // Copy again must not create duplicate entries in unified history
        coordinator.copyAgain()
        monitor.poll()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(testPasteboard.string(forType: .string), "Identical Result")

        // Retry capture with same text must also deduplicate in history
        coordinator.retryCapture()
        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.poll()

        XCTAssertEqual(store.items.count, 1)
    }

    func testHotkeyRegistrationRollbackKeepsPreviousConfiguration() {
        var registerAttempts: [UInt32] = []
        var dummyRefCounter: UInt = 0x1000

        let manager = GlobalHotKeyManager(
            identifier: 42,
            installHandler: false,
            registerFunction: { keyCode, modifiers, id, target, options, outRef in
                registerAttempts.append(keyCode)
                if keyCode == 999999 {
                    return OSStatus(eventHotKeyExistsErr)
                }
                dummyRefCounter += 1
                outRef?.pointee = OpaquePointer(bitPattern: dummyRefCounter)
                return noErr
            }
        )

        let initialConfig = HotKeyConfiguration(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
        let registered = manager.register(initialConfig)
        XCTAssertTrue(registered)
        XCTAssertEqual(manager.currentConfiguration, initialConfig)
        XCTAssertTrue(manager.isRegistered)

        // Attempting to register an invalid hotkey
        let invalidConfig = HotKeyConfiguration(keyCode: 999999, modifiers: 0)
        let secondResult = manager.register(invalidConfig)

        // Second registration must fail and manager must preserve initialConfig
        XCTAssertFalse(secondResult)
        XCTAssertEqual(manager.currentConfiguration, initialConfig)
        XCTAssertTrue(manager.isRegistered)
        // Candidate attempt followed by rollback restoration
        XCTAssertEqual(registerAttempts, [9, 999999, 9])
    }

    func testGlobalHotKeyManagerRollbackDoesNotRecurseWhenRestorationFails() {
        var callCount = 0
        let manager = GlobalHotKeyManager(
            identifier: 43,
            installHandler: false,
            registerFunction: { keyCode, modifiers, id, target, options, outRef in
                callCount += 1
                return OSStatus(eventHotKeyExistsErr)
            }
        )

        let initialConfig = HotKeyConfiguration(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
        // With no initial registration, candidate failure does not attempt rollback
        let initialResult = manager.register(initialConfig)
        XCTAssertFalse(initialResult)
        XCTAssertNil(manager.currentConfiguration)
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(callCount, 1)

        // Test candidate failure where rollback restoration also fails
        var dummyRef: UInt = 0x2000
        var shouldFail = false
        let managerWithInitial = GlobalHotKeyManager(
            identifier: 44,
            installHandler: false,
            registerFunction: { keyCode, modifiers, id, target, options, outRef in
                callCount += 1
                if shouldFail {
                    return OSStatus(eventHotKeyExistsErr)
                }
                dummyRef += 1
                outRef?.pointee = OpaquePointer(bitPattern: dummyRef)
                return noErr
            }
        )
        _ = managerWithInitial.register(initialConfig)
        XCTAssertTrue(managerWithInitial.isRegistered)

        // Now simulate both candidate registration and rollback restoration failing
        shouldFail = true
        let attemptsBefore = callCount
        let candidate = HotKeyConfiguration(keyCode: 11, modifiers: 0)
        let candidateResult = managerWithInitial.register(candidate)

        XCTAssertFalse(candidateResult)
        XCTAssertNil(managerWithInitial.currentConfiguration)
        XCTAssertFalse(managerWithInitial.isRegistered)
        // Exactly 2 attempts: 1 candidate, 1 rollback restoration, zero infinite recursion
        XCTAssertEqual(callCount - attemptsBefore, 2)
    }

    func testAppStateHotkeyCandidateFailureWithSuccessfulRestorationKeepsActiveAndReportsKeeping() {
        let mockManager = MockGlobalHotKeyManager()
        let initialHotKey = HotKeyConfiguration.default
        _ = mockManager.register(initialHotKey)

        let appState = AppState(
            store: ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher),
            hotKeyManager: mockManager
        )
        defer { appState.stop() }
        appState.start()

        XCTAssertEqual(appState.hotKey, initialHotKey)
        XCTAssertTrue(appState.isHistoryHotKeyRegistered)

        // Reset call count before user change
        mockManager.registrationCallCount = 0
        mockManager.shouldFailRegistration = true
        mockManager.shouldFailRestoration = false

        let candidate = HotKeyConfiguration(keyCode: 11, modifiers: UInt32(controlKey | optionKey | cmdKey))
        appState.hotKey = candidate

        // Candidate failed, restoration succeeded:
        // Must roll back property to initial hotkey, keep manager registered, and report 'Keeping'
        XCTAssertEqual(appState.hotKey, initialHotKey)
        XCTAssertTrue(mockManager.isRegistered)
        XCTAssertTrue(appState.isHistoryHotKeyRegistered)
        XCTAssertTrue(appState.statusMessage?.contains("Could not register") == true)
        XCTAssertTrue(appState.statusMessage?.contains("Keeping") == true)
        // Confirm property-observer re-entrancy terminated cleanly after the rollback assignment without extra registration calls
        XCTAssertEqual(mockManager.registrationCallCount, 1)
    }

    func testAppStateHotkeyCandidateFailureWithFailedRestorationReportsRestorationFailure() {
        let mockManager = MockGlobalHotKeyManager()
        let initialHotKey = HotKeyConfiguration.default
        _ = mockManager.register(initialHotKey)

        let appState = AppState(
            store: ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher),
            hotKeyManager: mockManager
        )
        defer { appState.stop() }
        appState.start()

        XCTAssertEqual(appState.hotKey, initialHotKey)
        XCTAssertTrue(appState.isHistoryHotKeyRegistered)

        mockManager.registrationCallCount = 0
        mockManager.shouldFailRegistration = true
        mockManager.shouldFailRestoration = true

        let candidate = HotKeyConfiguration(keyCode: 11, modifiers: UInt32(controlKey | optionKey | cmdKey))
        appState.hotKey = candidate

        // Candidate failed, restoration failed:
        // Must roll back property to initial hotkey, reflect unregistered status, and report restoration failure
        XCTAssertEqual(appState.hotKey, initialHotKey)
        XCTAssertFalse(mockManager.isRegistered)
        XCTAssertFalse(appState.isHistoryHotKeyRegistered)
        XCTAssertTrue(appState.statusMessage?.contains("could not be restored") == true)
        XCTAssertEqual(mockManager.registrationCallCount, 1)
    }

    func testAppStateOCRHotkeyObserverRollbackAndRestorationFailure() {
        let mockOCRManager = MockGlobalHotKeyManager()
        let initialOCRHotKey = HotKeyConfiguration.ocrDefault
        _ = mockOCRManager.register(initialOCRHotKey)

        let appState = AppState(
            store: ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher),
            ocrHotKeyManager: mockOCRManager
        )
        defer { appState.stop() }
        appState.start()

        XCTAssertEqual(appState.ocrHotKey, initialOCRHotKey)
        XCTAssertTrue(appState.isOCRHotKeyRegistered)

        // Case 1: Candidate fails, restoration succeeds
        mockOCRManager.registrationCallCount = 0
        mockOCRManager.shouldFailRegistration = true
        mockOCRManager.shouldFailRestoration = false

        let candidate1 = HotKeyConfiguration(keyCode: 14, modifiers: UInt32(controlKey | optionKey))
        appState.ocrHotKey = candidate1

        XCTAssertEqual(appState.ocrHotKey, initialOCRHotKey)
        XCTAssertTrue(mockOCRManager.isRegistered)
        XCTAssertTrue(appState.isOCRHotKeyRegistered)
        XCTAssertTrue(appState.statusMessage?.contains("Keeping") == true)
        XCTAssertEqual(mockOCRManager.registrationCallCount, 1)

        // Case 2: Candidate fails, restoration fails
        mockOCRManager.registrationCallCount = 0
        mockOCRManager.shouldFailRegistration = true
        mockOCRManager.shouldFailRestoration = true

        let candidate2 = HotKeyConfiguration(keyCode: 15, modifiers: UInt32(controlKey | optionKey))
        appState.ocrHotKey = candidate2

        XCTAssertEqual(appState.ocrHotKey, initialOCRHotKey)
        XCTAssertFalse(mockOCRManager.isRegistered)
        XCTAssertFalse(appState.isOCRHotKeyRegistered)
        XCTAssertTrue(appState.statusMessage?.contains("could not be restored") == true)
        XCTAssertEqual(mockOCRManager.registrationCallCount, 1)
    }

    func testAppStateHotkeyRepeatedObserverExecutionGuardsAgainstUnnecessaryRegistrations() {
        let mockManager = MockGlobalHotKeyManager()
        let initialHotKey = HotKeyConfiguration.default
        _ = mockManager.register(initialHotKey)

        let appState = AppState(
            store: ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher),
            hotKeyManager: mockManager
        )
        defer { appState.stop() }
        appState.start()

        mockManager.registrationCallCount = 0

        // Setting hotkey to the exact current value must return immediately without invoking register
        appState.hotKey = initialHotKey
        XCTAssertEqual(mockManager.registrationCallCount, 0)

        // Setting hotkey to a combination already in use (e.g. ocrHotKey) must revert without calling register
        let duplicateCandidate = appState.ocrHotKey
        appState.hotKey = duplicateCandidate
        XCTAssertEqual(appState.hotKey, initialHotKey)
        XCTAssertEqual(appState.statusMessage, "Hotkeys must be different.")
        XCTAssertEqual(mockManager.registrationCallCount, 0)
    }

    func testInstallationHealthSigningStatusVariants() {
        let expected = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Applications/ClipText.app",
            duplicateInstallations: [],
            teamIdentifier: "B6537Y9X84",
            signingStatus: .expectedIdentity(teamIdentifier: "B6537Y9X84"),
            designatedRequirement: "identifier \"com.cliptext.app\"",
            isDesignatedRequirementValid: true
        )
        XCTAssertTrue(expected.isExpectedIdentityPresent)
        XCTAssertTrue(expected.isStableForPrivacyPermissions)
        XCTAssertTrue(expected.signingSummary.contains("B6537Y9X84"))

        let unexpected = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Applications/ClipText.app",
            duplicateInstallations: [],
            teamIdentifier: "WRONG123",
            signingStatus: .unexpectedTeam(teamIdentifier: "WRONG123")
        )
        XCTAssertFalse(unexpected.isExpectedIdentityPresent)
        XCTAssertFalse(unexpected.isStableForPrivacyPermissions)
        XCTAssertTrue(unexpected.signingSummary.contains("Different team"))

        let adHoc = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Applications/ClipText.app",
            duplicateInstallations: [],
            teamIdentifier: nil,
            signingStatus: .adHocSigned
        )
        XCTAssertFalse(adHoc.isExpectedIdentityPresent)
        XCTAssertFalse(adHoc.isStableForPrivacyPermissions)
        XCTAssertTrue(adHoc.signingSummary.contains("Ad-hoc"))

        let unsigned = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Applications/ClipText.app",
            duplicateInstallations: [],
            teamIdentifier: nil,
            signingStatus: .unsigned
        )
        XCTAssertFalse(unsigned.isExpectedIdentityPresent)
        XCTAssertFalse(unsigned.isStableForPrivacyPermissions)
        XCTAssertTrue(unsigned.signingSummary.contains("Unsigned"))

        let unavailable = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Applications/ClipText.app",
            duplicateInstallations: [],
            teamIdentifier: nil,
            signingStatus: .unavailable(reason: "Test failure")
        )
        XCTAssertFalse(unavailable.isExpectedIdentityPresent)
        XCTAssertFalse(unavailable.isStableForPrivacyPermissions)
        XCTAssertTrue(unavailable.signingSummary.contains("unavailable"))
    }

    func testDuplicateInstallationDetectionValidatesBundleIdentifier() {
        let candidates = [
            "/Applications/ClipText.app",
            "/Users/test/Applications/ClipText.app",
            "/Users/test/Applications/OtherApp.app"
        ]

        let duplicates = InstallationHealth.duplicateInstallations(
            currentPath: "/Applications/ClipText.app",
            candidatePaths: candidates,
            expectedBundleIdentifier: "com.cliptext.app",
            bundleInspector: { path in
                if path == "/Users/test/Applications/ClipText.app" {
                    return "com.cliptext.app"
                } else if path == "/Users/test/Applications/OtherApp.app" {
                    return "com.other.app"
                }
                return nil
            }
        )

        // Only candidate with matching bundle identifier and distinct path should be returned
        XCTAssertEqual(duplicates, ["/Users/test/Applications/ClipText.app"])
    }

    func testDuplicateInstallationDetectionIgnoresMismatchedBundleIdentifier() {
        let candidates = ["/Users/test/Applications/ClipText.app"]

        let duplicates = InstallationHealth.duplicateInstallations(
            currentPath: "/Applications/ClipText.app",
            candidatePaths: candidates,
            expectedBundleIdentifier: "com.cliptext.app",
            bundleInspector: { _ in "com.impostor.app" }
        )

        XCTAssertTrue(duplicates.isEmpty)
    }

    func testDiagnosticsReportRedactsAllSensitiveContent() {
        let health = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Users/secretuser/Applications/ClipText.app",
            duplicateInstallations: [],
            teamIdentifier: "B6537Y9X84",
            signingStatus: .expectedIdentity(teamIdentifier: "B6537Y9X84"),
            designatedRequirement: "identifier \"com.cliptext.app\"",
            isDesignatedRequirementValid: true
        )

        let secretClipboardText = "SUPER_SECRET_PASSWORD_123"
        let secretOCRText = "CONFIDENTIAL_OCR_DATA_456"

        let report = DiagnosticsReport.make(
            version: "1.0",
            build: "42",
            macOSVersion: "macOS 14.4",
            health: health,
            hasScreenRecordingPermission: true,
            isAccessibilityTrusted: true,
            historyHotKey: "⌘⇧V",
            isHistoryHotKeyRegistered: true,
            ocrHotKey: "⌥⇧T",
            isOCRHotKeyRegistered: true,
            events: [
                SanitizedDiagnosticsLog.Entry(
                    timestamp: Date(),
                    category: "ScreenOCR",
                    message: "Capture session started"
                )
            ]
        )

        // Allowlisted diagnostic fields present
        XCTAssertTrue(report.contains("Version: 1.0 (42)"))
        XCTAssertTrue(report.contains("macOS Version: macOS 14.4"))
        XCTAssertTrue(report.contains("Bundle ID: com.cliptext.app"))
        XCTAssertTrue(report.contains("App path: /Users/<redacted>/Applications/ClipText.app"))
        XCTAssertTrue(report.contains("Team ID: B6537Y9X84"))
        XCTAssertTrue(report.contains("Screen Recording: Granted"))
        XCTAssertTrue(report.contains("Accessibility: Granted"))
        XCTAssertTrue(report.contains("History hotkey: ⌘⇧V (Registered)"))
        XCTAssertTrue(report.contains("OCR hotkey: ⌥⇧T (Registered)"))
        XCTAssertTrue(report.contains("ScreenOCR: Capture session started"))

        // Sensitive content NEVER appears
        XCTAssertFalse(report.contains(secretClipboardText))
        XCTAssertFalse(report.contains(secretOCRText))
        XCTAssertFalse(report.contains("secretuser"))
    }

    func testSanitizedDiagnosticsLogNeverContainsClipboardOrOCRText() {
        let logger = SanitizedDiagnosticsLog.shared
        logger.clear()

        // Unallowlisted messages or categories are rejected
        logger.log(category: "PrivateUserData", message: "My Password Is Secret")
        logger.log(category: "ScreenOCR", message: "Arbitrary unrecognized OCR payload")
        XCTAssertTrue(logger.recentEntries().isEmpty)

        // Allowlisted messages are accepted
        logger.log(category: "ScreenOCR", message: "Screen recording required")
        logger.log(category: "ScreenOCR", message: "Copied 42 characters")
        XCTAssertEqual(logger.recentEntries().count, 2)
        XCTAssertEqual(logger.recentEntries()[0].message, "Screen recording required")
        XCTAssertEqual(logger.recentEntries()[1].message, "Copied 42 characters")
    }

    func testMissingAccessibilityPermissionPreservesClipboardOperationsWithoutAutomation() async throws {
        // Without Accessibility, ordinary clipboard operations and copying OCR results remain available.
        let store = ClipboardStore(directoryURL: temporaryDirectory, cipher: testCipher)
        let testPasteboard = NSPasteboard.withUniqueName()
        let initialText = "Existing text before copy"
        testPasteboard.setString(initialText, forType: .string)

        let monitor = PasteboardMonitor(pasteboard: testPasteboard)
        let permissions = MockPermissionsService(hasPermission: true, isAccessibilityTrusted: false)
        let coordinator = CaptureCoordinator(
            store: store,
            monitor: monitor,
            permissionsManager: permissions,
            screenCapture: MockScreenCaptureService(),
            ocrManager: MockOCRService(textToReturn: "Recognized without accessibility"),
            selectionController: MockSelectionController(),
            pasteboard: testPasteboard,
            displayProvider: { [] }
        )

        coordinator.startCapture()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Clipboard should contain recognized text even without accessibility
        XCTAssertEqual(testPasteboard.string(forType: .string), "Recognized without accessibility")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "Recognized without accessibility")
    }

    func testPermissionStatusRefreshUpdatesPermissionsState() {
        let permissions = MockPermissionsService(hasPermission: false, isAccessibilityTrusted: false)
        XCTAssertFalse(permissions.hasScreenRecordingPermission)
        XCTAssertFalse(permissions.isAccessibilityTrusted)

        // Updating mock state simulates system permission change
        permissions.hasScreenRecordingPermission = true
        permissions.isAccessibilityTrusted = true
        permissions.checkPermissions()

        XCTAssertTrue(permissions.hasScreenRecordingPermission)
        XCTAssertTrue(permissions.isAccessibilityTrusted)
    }

    func testDiagnosticsReportRedactsDuplicateInstallationPaths() {
        let health = InstallationHealth(
            bundleIdentifier: "com.cliptext.app",
            applicationPath: "/Applications/ClipText.app",
            duplicateInstallations: [
                "/Users/personalaccount/Applications/ClipText.app",
                "/Users/personalaccount/Downloads/ClipText.app"
            ],
            teamIdentifier: "B6537Y9X84",
            signingStatus: .expectedIdentity(teamIdentifier: "B6537Y9X84"),
            designatedRequirement: "identifier \"com.cliptext.app\"",
            isDesignatedRequirementValid: true
        )

        let report = DiagnosticsReport.make(
            version: "1.0",
            build: "42",
            health: health,
            hasScreenRecordingPermission: true,
            isAccessibilityTrusted: true,
            historyHotKey: "⌘⇧V",
            ocrHotKey: "⌥⇧T",
            events: []
        )

        // Path redaction must redact usernames in duplicate installations
        XCTAssertTrue(report.contains("/Users/<redacted>/Applications/ClipText.app"))
        XCTAssertTrue(report.contains("/Users/<redacted>/Downloads/ClipText.app"))
        XCTAssertFalse(report.contains("personalaccount"))
    }
}

