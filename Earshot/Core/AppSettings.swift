import Foundation

/// The key that starts dictation. `deviceFlag` is the device-specific bit in CGEventFlags,
/// so the left/right variants of a modifier are told apart.
enum Hotkey: String, CaseIterable, Identifiable, Sendable {
    case fn, rightOption, rightCommand

    var id: String { rawValue }
    var keyCode: Int64 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        }
    }
    var deviceFlag: UInt64 {
        switch self {
        case .fn: 0x800000        // NX_SECONDARYFNMASK
        case .rightOption: 0x40   // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x10  // NX_DEVICERCMDKEYMASK
        }
    }
    /// For a keycap.
    var shortLabel: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        }
    }
    var label: String {
        switch self {
        case .fn: String(localized: "fn (Globe)")
        case .rightOption: String(localized: "Right Option")
        case .rightCommand: String(localized: "Right Command")
        }
    }
}

/// What happens when a call is detected.
enum MeetingMode: String, CaseIterable, Identifiable, Sendable {
    case off, ask, automatic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: String(localized: "Don't detect calls")
        case .ask: String(localized: "Ask to take notes")
        case .automatic: String(localized: "Take notes automatically")
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var meetingMode: MeetingMode {
        didSet {
            defaults.set(meetingMode.rawValue, forKey: "meetingMode")
            onMeetingModeChange?(meetingMode)
        }
    }
    var hotkey: Hotkey {
        didSet {
            defaults.set(hotkey.rawValue, forKey: "hotkey")
            onHotkeyChange?(hotkey)
        }
    }
    /// Locale identifier for on-device speech recognition.
    var localeIdentifier: String {
        didSet {
            defaults.set(localeIdentifier, forKey: "locale")
            onLocaleChange?(localeIdentifier)
        }
    }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Notes (no call detected) are mic-only unless this is on.
    var noteIncludesComputerAudio: Bool {
        didSet { defaults.set(noteIncludesComputerAudio, forKey: "noteIncludesComputerAudio") }
    }
    /// One term per line.
    var dictionaryText: String { didSet { defaults.set(dictionaryText, forKey: "dictionary") } }

    @ObservationIgnored var onHotkeyChange: ((Hotkey) -> Void)?
    @ObservationIgnored var onLocaleChange: ((String) -> Void)?
    @ObservationIgnored var onMeetingModeChange: ((MeetingMode) -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard

    var dictionary: [String] {
        dictionaryText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init() {
        let defaults = UserDefaults.standard
        meetingMode = defaults.string(forKey: "meetingMode").flatMap(MeetingMode.init(rawValue:)) ?? .ask
        hotkey = defaults.string(forKey: "hotkey").flatMap(Hotkey.init(rawValue:)) ?? .fn
        localeIdentifier = defaults.string(forKey: "locale") ?? Locale.current.identifier
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        noteIncludesComputerAudio = defaults.bool(forKey: "noteIncludesComputerAudio")
        dictionaryText = defaults.string(forKey: "dictionary") ?? ""
    }
}
