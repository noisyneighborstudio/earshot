import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts a synthetic ⌘V. The V key is looked up in the active keyboard layout (with ⌘ held,
/// so layouts like "Dvorak – QWERTY ⌘" resolve correctly).
enum KeySender {
    static func paste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command = CGKeyCode(kVK_Command)
        let v = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        post(source, command, down: true, flags: .maskCommand)
        post(source, v, down: true, flags: .maskCommand)
        post(source, v, down: false, flags: .maskCommand)
        post(source, command, down: false, flags: [])
    }

    private static func post(_ source: CGEventSource?, _ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        // Some apps drop events that arrive in the same instant.
        usleep(5_000)
    }

    /// A voice command's keystroke, into whatever app is frontmost.
    static func press(_ keystroke: Keystroke) throws {
        guard let key = Self.named[keystroke.key] ?? keystroke.key.first.flatMap(keyCode(for:)) else {
            throw ActionError(String(localized: "The key “\(keystroke.key)” isn't on this keyboard layout."))
        }
        var flags: CGEventFlags = []
        for modifier in keystroke.modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        post(source, key, down: true, flags: flags)
        post(source, key, down: false, flags: flags)
    }

    private static let named: [String: CGKeyCode] = {
        var keys: [String: Int] = [
            "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "escape": kVK_Escape, "delete": kVK_Delete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in functionKeys.enumerated() { keys["f\(i + 1)"] = code }
        return keys.mapValues { CGKeyCode($0) }
    }()

    /// The key that types `character` in the active layout, or nil if none does.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let target = String(character)
        let commandState = UInt32((cmdKey >> 8) & 0xFF)

        for code in 0..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDisplay), commandState, UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                return CGKeyCode(code)
            }
        }
        return nil
    }
}
