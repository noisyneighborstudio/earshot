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

/// Which screen edge the floating recording pill docks to.
enum PillDock: String, CaseIterable, Identifiable, Sendable {
    case top, bottom, left, right

    var id: String { rawValue }
    var isHorizontal: Bool { self == .top || self == .bottom }

    var label: String {
        switch self {
        case .top: String(localized: "Top")
        case .bottom: String(localized: "Bottom")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        }
    }

    var panelSize: CGSize {
        isHorizontal ? CGSize(width: 480, height: 64) : CGSize(width: 256, height: 124)
    }

    /// Nearest screen edge to `point`, using normalized coordinates so wide displays give
    /// left/right docking the same reach as top/bottom.
    static func nearest(to point: CGPoint, in visibleFrame: CGRect) -> PillDock {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return .bottom }
        let distances: [(PillDock, CGFloat)] = [
            (.top, (visibleFrame.maxY - point.y) / visibleFrame.height),
            (.bottom, (point.y - visibleFrame.minY) / visibleFrame.height),
            (.left, (point.x - visibleFrame.minX) / visibleFrame.width),
            (.right, (visibleFrame.maxX - point.x) / visibleFrame.width),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    /// The docked panel frame inside `visibleFrame` (AppKit coordinates: origin at bottom-left).
    func frame(in visibleFrame: CGRect) -> CGRect {
        let size = panelSize
        let origin: CGPoint = switch self {
        case .top:
            CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.maxY - size.height - 12)
        case .bottom:
            CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 24)
        case .left:
            CGPoint(x: visibleFrame.minX + 12, y: visibleFrame.midY - size.height / 2)
        case .right:
            CGPoint(x: visibleFrame.maxX - size.width - 12, y: visibleFrame.midY - size.height / 2)
        }
        return CGRect(origin: origin, size: size)
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
    /// Which screen edge the floating recording pill snaps to.
    var pillDock: PillDock {
        didSet {
            defaults.set(pillDock.rawValue, forKey: "pillDock")
            onPillDockChange?(pillDock)
        }
    }

    @ObservationIgnored var onHotkeyChange: ((Hotkey) -> Void)?
    @ObservationIgnored var onLocaleChange: ((String) -> Void)?
    @ObservationIgnored var onMeetingModeChange: ((MeetingMode) -> Void)?
    @ObservationIgnored var onPillDockChange: ((PillDock) -> Void)?
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
        pillDock = defaults.string(forKey: "pillDock").flatMap(PillDock.init(rawValue:)) ?? .bottom
    }
}
