import AppKit
import Carbon
import Foundation
import TFDomain

/// Global hotkeys through Carbon `RegisterEventHotKey` (APP-04, APP-05, APP-10).
/// The trigger instant is taken in the event callback, before any actor hop (SPEC §02 §3).
@MainActor
public final class HotkeyCenter: HotkeyRegistering {
    private static let signature: OSType = 0x5446_3248 // 'TF2H'

    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var handlerReference: EventHandlerRef?
    private var handler: (@Sendable (HotkeyAction, ContinuousClock.Instant) -> Void)?

    public init() {}

    public func register(
        _ bindings: [HotkeyAction: GlobalShortcut],
        handler: @escaping @Sendable (HotkeyAction, ContinuousClock.Instant) -> Void
    ) async -> [HotkeyAction] {
        removeRegistrations()
        installHandlerIfNeeded()
        self.handler = handler
        var failed: [HotkeyAction] = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let shortcut = bindings[action], shortcut.isValid else { continue }
            let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.modifiers.rawValue, identifier, GetApplicationEventTarget(), 0, &reference
            )
            if status == noErr, let reference {
                references.append(reference)
                actions[identifier.id] = action
            } else {
                failed.append(action)
            }
        }
        return failed
    }

    public func unregisterAll() async { unregisterAllNow() }

    /// Synchronous variant for `applicationWillTerminate` (APP-10).
    public func unregisterAllNow() {
        removeRegistrations()
        handler = nil
    }

    private func removeRegistrations() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32, at instant: ContinuousClock.Instant) {
        guard let action = actions[id] else { return }
        handler?(action, instant)
    }

    private func installHandlerIfNeeded() {
        guard handlerReference == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            let instant = ContinuousClock.now
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id, at: instant) }
            return noErr
        }, 1, &spec, context, &handlerReference)
    }
}
