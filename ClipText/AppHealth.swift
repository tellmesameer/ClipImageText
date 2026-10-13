import Foundation
import Security

enum SigningStatus: Equatable {
    case expectedIdentity(teamIdentifier: String)
    case unexpectedTeam(teamIdentifier: String)
    case adHocSigned
    case unsigned
    case unavailable(reason: String)

    var isExpected: Bool {
        if case .expectedIdentity = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .expectedIdentity(let team):
            return "Apple Development (\(team))"
        case .unexpectedTeam(let team):
            return "Different team identifier (\(team))"
        case .adHocSigned:
            return "Ad-hoc signed (unstable for macOS privacy permissions)"
        case .unsigned:
            return "Unsigned (unstable for macOS privacy permissions)"
        case .unavailable(let reason):
            return "Signing metadata unavailable (\(reason))"
        }
    }
}

final class SanitizedDiagnosticsLog: @unchecked Sendable {
    static let shared = SanitizedDiagnosticsLog()

    struct Entry: Equatable {
        let timestamp: Date
        let category: String
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let maxEntries = 20

    private let allowlistedCategories: Set<String> = [
        "ScreenOCR", "Permissions", "HotKey", "Persistence", "Lifecycle", "Installation"
    ]

    private let allowlistedMessages: Set<String> = [
        "Screen recording required",
        "Screen recording missing",
        "Screen recording granted",
        "Capture session started",
        "Capture cancelled",
        "Capture cancelled by user",
        "Display unavailable",
        "Capture timed out",
        "No text found",
        "No text found in region",
        "OCR failed",
        "Capture error",
        "Copied recognized text",
        "Copied recognized text again",
        "Failed to register history hotkey",
        "Failed to register OCR hotkey",
        "Failed to register GIF hotkey",
        "Accessibility active",
        "Accessibility disabled",
        "Storage write warning",
        "Storage save error"
    ]

    func log(category: String, message: String) {
        guard allowlistedCategories.contains(category) else { return }
        let isAllowlisted = allowlistedMessages.contains(message) || message.hasPrefix("Copied ")
        guard isAllowlisted else { return }

        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(timestamp: Date(), category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func recentEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}

struct InstallationHealth: Equatable {
    let bundleIdentifier: String
    let applicationPath: String
    let duplicateInstallations: [String]
    let teamIdentifier: String?
    let signingStatus: SigningStatus
    let designatedRequirement: String?
    let isDesignatedRequirementValid: Bool

    static let expectedTeamIdentifier = "B6537Y9X84"
    static let expectedBundleIdentifier = "com.cliptext.app"

    var signingSummary: String {
        signingStatus.description
    }

    var isExpectedIdentityPresent: Bool {
        signingStatus.isExpected
    }

    var isStableForPrivacyPermissions: Bool {
        isExpectedIdentityPresent && teamIdentifier != nil && !teamIdentifier!.isEmpty
    }

    init(
        bundleIdentifier: String,
        applicationPath: String,
        duplicateInstallations: [String],
        teamIdentifier: String?,
        signingStatus: SigningStatus? = nil,
        designatedRequirement: String? = nil,
        isDesignatedRequirementValid: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.duplicateInstallations = duplicateInstallations
        self.teamIdentifier = teamIdentifier
        if let signingStatus {
            self.signingStatus = signingStatus
        } else if let teamIdentifier, !teamIdentifier.isEmpty {
            if teamIdentifier == Self.expectedTeamIdentifier {
                self.signingStatus = .expectedIdentity(teamIdentifier: teamIdentifier)
            } else {
                self.signingStatus = .unexpectedTeam(teamIdentifier: teamIdentifier)
            }
        } else {
            self.signingStatus = .adHocSigned
        }
        self.designatedRequirement = designatedRequirement
        self.isDesignatedRequirementValid = isDesignatedRequirementValid
    }

    static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        expectedTeam: String = expectedTeamIdentifier,
        expectedBundleID: String = expectedBundleIdentifier,
        signingInspector: (() -> CodeSigningInspection)? = nil,
        bundleInspector: ((String) -> String?)? = nil
    ) -> InstallationHealth {
        let applicationPath = bundle.bundleURL.standardizedFileURL.path
        let candidates = [
            "/Applications/ClipText.app",
            homeDirectory.appendingPathComponent("Applications/ClipText.app").path
        ]

        let inspector = bundleInspector ?? { path in
            guard fileManager.fileExists(atPath: path) else { return nil }
            guard let candidateBundle = Bundle(path: path) else { return nil }
            return candidateBundle.bundleIdentifier
        }

        let duplicates = duplicateInstallations(
            currentPath: applicationPath,
            candidatePaths: candidates,
            expectedBundleIdentifier: expectedBundleID,
            bundleInspector: inspector
        )

        let signingInfo = signingInspector?() ?? inspectCodeSigning(expectedTeam: expectedTeam)

        return InstallationHealth(
            bundleIdentifier: bundle.bundleIdentifier ?? expectedBundleID,
            applicationPath: applicationPath,
            duplicateInstallations: duplicates,
            teamIdentifier: signingInfo.teamIdentifier,
            signingStatus: signingInfo.status,
            designatedRequirement: signingInfo.designatedRequirement,
            isDesignatedRequirementValid: signingInfo.isRequirementValid
        )
    }

    static func duplicateInstallations(
        currentPath: String,
        candidatePaths: [String],
        expectedBundleIdentifier: String = expectedBundleIdentifier,
        bundleInspector: (String) -> String?
    ) -> [String] {
        candidatePaths.filter { candidate in
            guard candidate != currentPath else { return false }
            guard let id = bundleInspector(candidate) else { return false }
            return id == expectedBundleIdentifier
        }
    }

    static func duplicateInstallations(
        currentPath: String,
        candidatePaths: [String],
        fileExists: (String) -> Bool
    ) -> [String] {
        duplicateInstallations(
            currentPath: currentPath,
            candidatePaths: candidatePaths,
            expectedBundleIdentifier: expectedBundleIdentifier,
            bundleInspector: { path in fileExists(path) ? expectedBundleIdentifier : nil }
        )
    }

    struct CodeSigningInspection: Equatable {
        let teamIdentifier: String?
        let status: SigningStatus
        let designatedRequirement: String?
        let isRequirementValid: Bool
    }

    static func inspectCodeSigning(expectedTeam: String = expectedTeamIdentifier) -> CodeSigningInspection {
        var secCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &secCode)
        guard selfStatus == errSecSuccess, let secCode else {
            return CodeSigningInspection(
                teamIdentifier: nil,
                status: .unavailable(reason: "SecCodeCopySelf returned \(selfStatus)"),
                designatedRequirement: nil,
                isRequirementValid: false
            )
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(secCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return CodeSigningInspection(
                teamIdentifier: nil,
                status: .unavailable(reason: "SecCodeCopyStaticCode returned \(staticStatus)"),
                designatedRequirement: nil,
                isRequirementValid: false
            )
        }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            if infoStatus == errSecCSUnsigned {
                return CodeSigningInspection(
                    teamIdentifier: nil,
                    status: .unsigned,
                    designatedRequirement: nil,
                    isRequirementValid: false
                )
            }
            return CodeSigningInspection(
                teamIdentifier: nil,
                status: .unavailable(reason: "SecCodeCopySigningInformation returned \(infoStatus)"),
                designatedRequirement: nil,
                isRequirementValid: false
            )
        }

        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? currentTeamIdentifier()

        let certs = info[kSecCodeInfoCertificates as String] as? [Any]
        let hasCertificates = certs != nil && !(certs!.isEmpty)

        var requirementString: String?
        var isRequirementValid = false
        var reqRef: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &reqRef) == errSecSuccess, let reqRef {
            var cfStr: CFString?
            if SecRequirementCopyString(reqRef, [], &cfStr) == errSecSuccess, let cfStr {
                requirementString = cfStr as String
            }
            isRequirementValid = (SecCodeCheckValidity(secCode, [], reqRef) == errSecSuccess)
        }

        let status: SigningStatus
        if !hasCertificates {
            let format = info[kSecCodeInfoFormat as String] as? String
            if format != nil {
                status = .adHocSigned
            } else {
                status = .unsigned
            }
        } else if let team = teamID, !team.isEmpty {
            if team == expectedTeam {
                status = .expectedIdentity(teamIdentifier: team)
            } else {
                status = .unexpectedTeam(teamIdentifier: team)
            }
        } else {
            status = .adHocSigned
        }

        return CodeSigningInspection(
            teamIdentifier: teamID,
            status: status,
            designatedRequirement: requirementString,
            isRequirementValid: isRequirementValid
        )
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
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        health: InstallationHealth,
        hasScreenRecordingPermission: Bool,
        isAccessibilityTrusted: Bool,
        historyHotKey: String,
        isHistoryHotKeyRegistered: Bool = true,
        ocrHotKey: String,
        isOCRHotKeyRegistered: Bool = true,
        events: [SanitizedDiagnosticsLog.Entry] = SanitizedDiagnosticsLog.shared.recentEntries()
    ) -> String {
        let duplicatePaths = health.duplicateInstallations.isEmpty
            ? "None"
            : health.duplicateInstallations.map(sanitizePath).joined(separator: ", ")

        let historyStatus = isHistoryHotKeyRegistered ? "Registered" : "Unregistered"
        let ocrStatus = isOCRHotKeyRegistered ? "Registered" : "Unregistered"

        let reqStatus = health.isDesignatedRequirementValid ? "Verified" : (health.designatedRequirement != nil ? "Invalid" : "Unavailable")
        let sanitizedAppPath = sanitizePath(health.applicationPath)

        var lines = [
            "ClipText Diagnostics",
            "Version: \(version) (\(build))",
            "macOS Version: \(macOSVersion)",
            "Bundle ID: \(health.bundleIdentifier)",
            "App path: \(sanitizedAppPath)",
            "Signing: \(health.signingSummary)",
            "Expected identity present: \(health.isExpectedIdentityPresent ? "Yes" : "No")",
            "Expected Team ID: \(InstallationHealth.expectedTeamIdentifier)",
            "Actual Team ID: \(health.teamIdentifier ?? "None")",
            "Team ID: \(health.teamIdentifier ?? "None")",
            "Designated requirement: \(reqStatus)",
            "Privacy identity stable: \(health.isStableForPrivacyPermissions ? "Yes" : "No")",
            "Other ClipText installations: \(duplicatePaths)",
            "Screen Recording: \(hasScreenRecordingPermission ? "Granted" : "Missing")",
            "Accessibility: \(isAccessibilityTrusted ? "Granted" : "Missing")",
            "History hotkey: \(historyHotKey) (\(historyStatus))",
            "OCR hotkey: \(ocrHotKey) (\(ocrStatus))"
        ]

        let isoFormatter = ISO8601DateFormatter()
        if events.isEmpty {
            lines.append("Recent events: None")
        } else {
            lines.append("Recent events:")
            for event in events {
                lines.append("- [\(isoFormatter.string(from: event.timestamp))] \(event.category): \(event.message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func sanitizePath(_ path: String) -> String {
        if path.hasPrefix("/Users/") {
            let components = path.split(separator: "/")
            if components.count >= 2 {
                var rebuilt = ["", "Users", "<redacted>"]
                rebuilt.append(contentsOf: components.dropFirst(2).map(String.init))
                return rebuilt.joined(separator: "/")
            }
        }
        return path
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
    static let captureTimedOut =
        "Capture timed out. Select a smaller region and try again."
    static let captureCancelled =
        "Screen OCR cancelled."
}
