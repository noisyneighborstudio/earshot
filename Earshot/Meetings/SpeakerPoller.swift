import AppKit
import ApplicationServices
import os

/// While recording, samples the call app's Accessibility tree for "who is talking" labels and
/// builds a timeline used to put names on the "Others" transcript. Runs off the main thread.
final class SpeakerPoller: Sendable {
    private struct State {
        var timeline: [SpeakerSample] = []
        var participants: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let loop: Task<Void, Never>
    private let startedAt: ContinuousClock.Instant

    private static let interval: Duration = .milliseconds(500)
    private static let nodeBudget = 4000
    private static let maxDepth = 40

    /// `pids` are the call app's main processes; for browsers only call-looking windows are read.
    init(pids: [pid_t], platform: MeetingPlatform, startedAt: ContinuousClock.Instant) {
        let markers = SpeakerMarkers.forPlatform(platform)
        let state = self.state
        self.startedAt = startedAt
        loop = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let names = Self.talking(pids: pids, browser: platform.isBrowser, markers: markers)
                if !names.isEmpty {
                    let time = startedAt.duration(to: .now).seconds
                    state.withLock {
                        $0.timeline.append(SpeakerSample(time: time, names: names))
                        $0.participants.formUnion(names)
                    }
                }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    var timeline: [SpeakerSample] { state.withLock { $0.timeline } }
    var participants: [String] { state.withLock { $0.participants.sorted() } }

    /// Names shown as talking within the last second or so.
    var speakingNow: [String] {
        let now = startedAt.duration(to: .now).seconds
        return state.withLock { s in
            guard let last = s.timeline.last, now - last.time < 1.25 else { return [] }
            return last.names
        }
    }

    func stop() { loop.cancel() }

    private static func talking(pids: [pid_t], browser: Bool, markers: SpeakerMarkers) -> [String] {
        var names: [String] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            // Electron apps and Chromium browsers only expose web content when asked. The browser
            // flag can disturb window managers, so it's limited to browsers.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if browser { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
            for window in elements(app, kAXWindowsAttribute) {
                if browser, !MeetingPlatform.looksLikeCall(windowTitle: string(window, kAXTitleAttribute) ?? "") { continue }
                walk(window, markers: markers, into: &names)
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func walk(_ root: AXUIElement, markers: SpeakerMarkers, into names: inout [String]) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var next = 0
        while next < queue.count, next < nodeBudget {
            let (element, depth) = queue[next]
            next += 1
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                if let label = string(element, attribute), let name = markers.name(in: label) { names.append(name) }
            }
            if depth < maxDepth {
                queue.append(contentsOf: elements(element, kAXChildrenAttribute).map { ($0, depth + 1) })
            }
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (s, attoseconds) = components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }
}
