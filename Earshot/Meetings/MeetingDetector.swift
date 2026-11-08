import AppKit
import ApplicationServices
import CoreAudio

struct DetectedCall: Equatable, Sendable {
    let platform: MeetingPlatform
    /// Window title when we could read one (useful as a meeting title).
    let title: String
}

/// Detects calls: a known call app (or a browser showing a call)
/// is holding the microphone. Polls Core Audio's process list; debounced both ways.
@MainActor
@Observable
final class MeetingDetector {
    private(set) var current: DetectedCall?

    @ObservationIgnored var onCallStarted: ((DetectedCall) -> Void)?
    @ObservationIgnored var onCallEnded: ((DetectedCall) -> Void)?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var seenStreak = 0
    @ObservationIgnored private var missingStreak = 0
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let interval: Duration = .seconds(2)
    private static let startAfter = 2   // polls
    private static let endAfter = 4     // polls

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        seenStreak = 0
        missingStreak = 0
        current = nil
    }

    /// Core Audio process objects for a platform, e.g. to tap the call's audio.
    func processObjects(for platform: MeetingPlatform) -> [AudioObjectID] {
        AudioProcesses.all()
            .filter { $0.pid != ownPID && MeetingPlatform.forBundleID($0.bundleID)?.id == platform.id }
            .map(\.objectID)
    }

    /// The platform's app processes (not helpers), for reading its UI.
    func pids(for platform: MeetingPlatform) -> [pid_t] {
        apps(for: platform).map(\.processIdentifier)
    }

    private func apps(for platform: MeetingPlatform) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in app.bundleIdentifier.flatMap(MeetingPlatform.forBundleID)?.id == platform.id }
    }

    private func poll() {
        let found = detect()
        if let found {
            missingStreak = 0
            seenStreak += 1
            if current == nil, seenStreak >= Self.startAfter {
                current = found
                onCallStarted?(found)
            }
        } else {
            seenStreak = 0
            missingStreak += 1
            if let call = current, missingStreak >= Self.endAfter {
                current = nil
                onCallEnded?(call)
            }
        }
    }

    private func detect() -> DetectedCall? {
        let holders = AudioProcesses.all().filter { $0.isRunningInput && $0.pid != ownPID }
        let platforms = Set(holders.compactMap { MeetingPlatform.forBundleID($0.bundleID) })
        // A dedicated call app wins over a browser.
        for platform in platforms.sorted(by: { !$0.isBrowser && $1.isBrowser }) {
            let titles = windowTitles(for: platform)
            if !platform.isBrowser {
                return DetectedCall(platform: platform, title: titles.first ?? "")
            }
            if let title = titles.first(where: MeetingPlatform.looksLikeCall(windowTitle:)) {
                return DetectedCall(platform: platform, title: title)
            }
        }
        return nil
    }

    private func windowTitles(for platform: MeetingPlatform) -> [String] {
        apps(for: platform)
            .flatMap { app -> [String] in
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.2)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { return [] }
                return windows.compactMap { window in
                    var title: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                    return (title as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
            }
    }
}
