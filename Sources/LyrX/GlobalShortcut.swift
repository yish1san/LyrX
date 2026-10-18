import AppKit
import Carbon

/// 只向系统注册一个明确的组合键，不监听或记录其他按键。
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?
    private var pressed = false
    private let identity = EventHotKeyID(signature: 0x4C795258, id: 1)

    func start(action: @escaping () -> Void) -> Bool {
        stop()
        self.action = action
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().handle(event)
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { stop(); return false }
        // 独占注册，冲突时反馈失败，避免多个应用同时响应同一个按键。
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), identity,
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr else { stop(); return false }
        return true
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil; eventHandler = nil; action = nil; pressed = false
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var key = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
              key.signature == identity.signature, key.id == identity.id else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { pressed = false }
        else if !pressed { pressed = true; action?() }
        return noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
