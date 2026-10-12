import AppKit
import Foundation
import os

final class Logger {
    static let shared = Logger()

    private let logger: os.Logger
    private let isDebug: Bool

    private init() {
        self.logger = os.Logger(subsystem: "com.cliptext.ClipText", category: "general")
        #if DEBUG
        self.isDebug = true
        #else
        self.isDebug = false
        #endif
    }

    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard isDebug else { return }
        let fileName = (file as NSString).lastPathComponent
        logger.debug("[\(fileName):\(line)] \(function) - \(message)")
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        logger.info("[\(fileName):\(line)] \(function) - \(message)")
    }

    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        logger.warning("[\(fileName):\(line)] \(function) - \(message)")
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        logger.error("[\(fileName):\(line)] \(function) - \(message)")
    }
}

enum ClipTextError: LocalizedError, Equatable {
    case permissionDenied(String)
    case captureFailed(String)
    case ocrFailed(String)
    case clipboardFailed(String)
    case shortcutRegistrationFailed(String)
    case operationTimedOut(TimeInterval)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg): return "Permission denied: \(msg)"
        case .captureFailed(let msg): return "Capture failed: \(msg)"
        case .ocrFailed(let msg): return "OCR failed: \(msg)"
        case .clipboardFailed(let msg): return "Clipboard failed: \(msg)"
        case .shortcutRegistrationFailed(let msg): return "Shortcut registration failed: \(msg)"
        case .operationTimedOut(let sec): return "Timed out after \(Int(sec))s — try a smaller selection"
        case .unknown(let msg): return "Error: \(msg)"
        }
    }
}

typealias TextGrabError = ClipTextError

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension String {
    func trimmingWhitespaceAndNewlines() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isNotEmpty: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        let gate = NIOLockedValueBox<Bool>(false)

        group.addTask { @Sendable in
            let result = try await operation()
            let shouldReturn = gate.withLockedValue { completed in
                if !completed {
                    completed = true
                    return true
                }
                return false
            }
            if !shouldReturn {
                throw CancellationError()
            }
            return result
        }

        group.addTask { @Sendable in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let shouldThrow = gate.withLockedValue { completed in
                if !completed {
                    completed = true
                    return true
                }
                return false
            }
            if shouldThrow {
                throw ClipTextError.operationTimedOut(seconds)
            }
            throw CancellationError()
        }

        guard let result = try await group.next() else {
            throw ClipTextError.operationTimedOut(seconds)
        }
        group.cancelAll()
        return result
    }
}

final class NIOLockedValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLockedValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
