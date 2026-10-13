import Carbon.HIToolbox
import Foundation

protocol GlobalHotKeyManaging: AnyObject {
    var onHotKey: (() -> Void)? { get set }
    var currentConfiguration: HotKeyConfiguration? { get }
    var isRegistered: Bool { get }
    @discardableResult
    func register(_ configuration: HotKeyConfiguration?) -> Bool
    func stop()
}

final class GlobalHotKeyManager: GlobalHotKeyManaging {
    var onHotKey: (() -> Void)?
    private(set) var currentConfiguration: HotKeyConfiguration?

    var isRegistered: Bool {
        hotKeyRef != nil
    }

    private static let signature = OSType(0x434C4950)
    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(identifier: UInt32 = 1) {
        self.identifier = identifier
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == GlobalHotKeyManager.signature,
                      hotKeyID.id == manager.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                manager.onHotKey?()
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &handlerRef
        )
    }

    @discardableResult
    func register(_ configuration: HotKeyConfiguration?) -> Bool {
        register(configuration, isRollback: false)
    }

    private func register(_ configuration: HotKeyConfiguration?, isRollback: Bool) -> Bool {
        let previous = currentConfiguration
        unregisterHotKey()

        guard let configuration else {
            currentConfiguration = nil
            return true
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: self.identifier)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        guard status == noErr else {
            if let previous, !isRollback {
                _ = register(previous, isRollback: true)
            } else {
                currentConfiguration = nil
            }
            return false
        }
        hotKeyRef = newRef
        currentConfiguration = configuration
        return true
    }

    func stop() {
        unregisterHotKey()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        currentConfiguration = nil
    }

    deinit { stop() }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
