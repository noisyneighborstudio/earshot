import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts a synthetic ⌘V. The V key is looked up in the active keyboard layout (with ⌘ held,
/// so layouts like "Dvorak – QWERTY ⌘" resolve correctly).
enum KeySender {
    static func paste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command = CGKeyCode(kVK_Command)
        let v = keyCode(for: "v")
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

    static func keyCode(for character: Character) -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
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
        return fallback
    }
}
