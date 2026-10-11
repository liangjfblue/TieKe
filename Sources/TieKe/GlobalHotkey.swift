import Carbon

final class GlobalHotkeys {
    private static let signature: OSType = 0x50505250
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
            var identifier = EventHotKeyID(signature: 0, id: 0)
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == GlobalHotkeys.signature,
                  let action = owner.actions[identifier.id] else { return OSStatus(eventNotHandledErr) }
            action()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                  action: @escaping () -> Void) -> Bool {
        guard handler != nil, actions[id] == nil else { return false }
        let identifier = EventHotKeyID(signature: Self.signature, id: id)
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, let hotKey else { return false }
        hotKeys.append(hotKey)
        actions[id] = action
        return true
    }

    deinit {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
