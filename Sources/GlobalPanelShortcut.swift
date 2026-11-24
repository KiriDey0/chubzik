import AppKit
import Carbon

final class GlobalPanelShortcut {
    private let identifier: EventHotKeyID
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredKey: (key: UInt32, modifiers: UInt32)?
    private let action: () -> Void

    init(id: UInt32 = 1, action: @escaping () -> Void) {
        identifier = EventHotKeyID(signature: 0x43485A4B, id: id)
        self.action = action
    }

    func set(_ shortcut: PanelShortcut) -> Bool {
        switch shortcut {
        case .off: return set(key: nil, modifiers: 0)
        case .space: return set(key: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        case .letterJ: return set(key: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey))
        }
    }

    func setQuickChat(_ enabled: Bool) -> Bool {
        set(key: enabled ? UInt32(kVK_Space) : nil, modifiers: UInt32(optionKey))
    }

    func setProjectFolder(_ shortcut: ProjectFolderShortcut) -> Bool {
        let key: Int?
        switch shortcut {
        case .off: key = nil
        case .letterP: key = kVK_ANSI_P
        case .letterO: key = kVK_ANSI_O
        }
        return set(key: key.map(UInt32.init), modifiers: UInt32(controlKey | optionKey))
    }

    func setClipboardPocket(_ enabled: Bool) -> Bool {
        set(key: enabled ? UInt32(kVK_ANSI_V) : nil, modifiers: UInt32(controlKey | optionKey))
    }

    func setFileShortcut(_ shortcut: FileShortcut) -> Bool {
        let key: Int?
        switch shortcut {
        case .off: key = nil
        case .letterF: key = kVK_ANSI_F
        case .letterR: key = kVK_ANSI_R
        case .letterU: key = kVK_ANSI_U
        case .letterY: key = kVK_ANSI_Y
        }
        return set(key: key.map(UInt32.init), modifiers: UInt32(controlKey | optionKey))
    }

    func setEscape(_ enabled: Bool) -> Bool {
        set(key: enabled ? UInt32(kVK_Escape) : nil, modifiers: 0)
    }

    private func set(key: UInt32?, modifiers: UInt32) -> Bool {
        if let key, let registeredKey, registeredKey.key == key, registeredKey.modifiers == modifiers { return true }
        guard let key else {
            if let reference { UnregisterEventHotKey(reference) }
            reference = nil
            registeredKey = nil
            return true
        }

        let target = GetApplicationEventTarget()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(target, { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr
                else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<GlobalPanelShortcut>.fromOpaque(context).takeUnretainedValue()
                guard id.signature == shortcut.identifier.signature, id.id == shortcut.identifier.id
                else { return OSStatus(eventNotHandledErr) }
                shortcut.action()
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        var candidate: EventHotKeyRef?
        guard RegisterEventHotKey(key, modifiers, identifier, target, 0, &candidate) == noErr,
              let candidate else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate
        registeredKey = (key, modifiers)
        return true
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
