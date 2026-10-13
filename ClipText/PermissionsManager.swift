//
//  PermissionsManager.swift
//  ClipText
//
//  Adapted from TextGrab (https://github.com/arsh342/TextGrab)
//  Copyright (c) 2026 arsh342. MIT License.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
protocol PermissionsService: AnyObject {
    var hasScreenRecordingPermission: Bool { get }
    var isAccessibilityTrusted: Bool { get }
    func checkPermissions()
    func requestScreenRecordingPermission() async -> Bool
    func openScreenRecordingSettings()
    func openAccessibilitySettings()
    func relaunchApplication()
}

@MainActor
final class PermissionsManager: ObservableObject, PermissionsService {
    @Published var hasScreenRecordingPermission: Bool = false
    @Published var isAccessibilityTrusted: Bool = false
    @Published var permissionStatus: PermissionStatus = .unknown
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    enum PermissionStatus: Equatable {
        case unknown
        case checking
        case screenRecordingDenied
        case accessibilityDenied
        case allGranted
    }

    init() {
        checkPermissions()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissions()
            }
        }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissions()
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
    }

    func checkPermissions() {
        permissionStatus = .checking

        let screenRecording = checkScreenRecordingPermission()
        let accessibility = checkAccessibilityPermission()

        let screenChanged = (screenRecording != hasScreenRecordingPermission)
        let accessibilityChanged = (accessibility != isAccessibilityTrusted)

        hasScreenRecordingPermission = screenRecording
        isAccessibilityTrusted = accessibility

        if !screenRecording {
            permissionStatus = .screenRecordingDenied
        } else if !accessibility {
            permissionStatus = .accessibilityDenied
        } else {
            permissionStatus = .allGranted
        }

        if screenChanged {
            SanitizedDiagnosticsLog.shared.log(
                category: "Permissions",
                message: screenRecording ? "Screen recording granted" : "Screen recording missing"
            )
        }
        if accessibilityChanged {
            SanitizedDiagnosticsLog.shared.log(
                category: "Permissions",
                message: accessibility ? "Accessibility active" : "Accessibility disabled"
            )
        }

        Logger.shared.debug("Permissions - Screen: \(screenRecording), Accessibility: \(accessibility)")
    }

    private func checkScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestScreenRecordingPermission() async -> Bool {
        Logger.shared.info("Requesting screen recording permission")
        _ = CGRequestScreenCaptureAccess()
        checkPermissions()
        return hasScreenRecordingPermission
    }

    func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ].compactMap(URL.init(string:))
        openFirstAvailableSettingsURL(urls)
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ].compactMap(URL.init(string:))
        openFirstAvailableSettingsURL(urls)
    }

    func relaunchApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
        } catch {
            Logger.shared.error("Relaunch failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private func openFirstAvailableSettingsURL(_ urls: [URL]) {
        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }
}
