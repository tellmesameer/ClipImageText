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

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func capture(display: DisplayInfo, region: CGRect) async throws -> CGImage {
        capturedRegions.append(region)
        if shouldThrow {
            throw NSError(domain: "MockCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Capture failed"])
        }
        let size = CGSize(width: 100, height: 40)
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
    var didRequest = false

    init(hasPermission: Bool = true) {
        self.hasScreenRecordingPermission = hasPermission
    }

    func requestScreenRecordingPermission() async -> Bool {
        didRequest = true
        return hasScreenRecordingPermission
    }

    func openScreenRecordingSettings() {}
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

    func testPermissionsManagerInitializesCleanly() {
        let permissions = PermissionsManager()
        XCTAssertTrue(permissions.permissionStatus == .allGranted || permissions.permissionStatus == .screenRecordingDenied)
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
        XCTAssertTrue(permissions.didRequest)
        XCTAssertNotNil(coordinator.statusMessage)
        XCTAssertTrue(store.items.isEmpty)
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
}

