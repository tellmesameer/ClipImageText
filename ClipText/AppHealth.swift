import Foundation
import Security

struct InstallationHealth: Equatable {
    let bundleIdentifier: String
    let applicationPath: String
    let duplicateInstallations: [String]
    let teamIdentifier: String?

    var signingSummary: String {
        guard let teamIdentifier, !teamIdentifier.isEmpty else {
            return "No certificate team identifier detected"
        }
        return "Apple team (teamIdentifier)"
    }

    var isStableForPrivacyPermissions: Bool {
        teamIdentifier != nil && !teamIdentifier!.isEmpty
    }

    static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstallationHealth {
        let applicationPath = bundle.bundleURL.standardizedFileURL.path
        let candidates = [
            "/Applications/ClipText.app",
            homeDirectory.appendingPathComponent("Applications/ClipText.app").path
        ]

        let duplicates = duplicateInstallations(
            currentPath: applicationPath,
            candidatePaths: candidates,
            fileExists: fileManager.fileExists(atPath:)
        )

        return InstallationHealth(
            bundleIdentifier: bundle.bundleIdentifier ?? "Unknown",
            applicationPath: applicationPath,
            duplicateInstallations: duplicates,
            teamIdentifier: currentTeamIdentifier()
        )
    }

    static func duplicateInstallations(
        currentPath: String,
        candidatePaths: [String],
        fileExists: (String) -> Bool
    ) -> [String] {
        candidatePaths.filter { $0 != currentPath && fileExists($0) }
    }

    private static func currentTeamIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.team-identifier" as CFString,
                nil
              ) as? String
        else {
            return nil
        }
        return value
    }
}

enum DiagnosticsReport {
    static func make(
        version: String,
        build: String,
        health: InstallationHealth,
        hasScreenRecordingPermission: Bool,
        isAccessibilityTrusted: Bool,
        historyHotKey: String,
        ocrHotKey: String
    ) -> String {
        let duplicatePaths = health.duplicateInstallations.isEmpty
            ? "None"
            : health.duplicateInstallations.joined(separator: ", ")
        return """
        ClipText Diagnostics
        Version: \(version) (\(build))
        Bundle ID: \(health.bundleIdentifier)
        App path: \(health.applicationPath)
        Signing: \(health.signingSummary)
        Privacy identity stable: \(health.isStableForPrivacyPermissions ? "Yes" : "No")
        Other ClipText installations: \(duplicatePaths)
        Screen Recording: \(hasScreenRecordingPermission ? "Granted" : "Missing")
        Accessibility: \(isAccessibilityTrusted ? "Granted" : "Missing")
        History hotkey: \(historyHotKey)
        OCR hotkey: \(ocrHotKey)
        """
    }
}

enum CaptureRecovery {
    static let screenRecordingRequired =
        "Screen Recording is required for Screen OCR. Open Settings to enable it, then relaunch ClipText."
    static let noTextFound =
        "No text was found. Select a tighter region or try again with clearer text."
    static let captureFailed =
        "The screen region could not be captured. Check Screen Recording access and try again."
    static let recognitionFailed =
        "Text recognition failed. Your clipboard and history were left unchanged; try again."
    static let noDisplayAvailable =
        "No display is available for capture. Reconnect a display and try again."
}
