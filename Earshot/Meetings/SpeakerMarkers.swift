import AppKit
import Foundation

/// Recognizes "who is talking" labels that call apps expose through Accessibility.
/// Templates use `%@` for the name, e.g. Zoom's "Talking: %@" (localized per Zoom UI language).
struct SpeakerMarkers: Sendable {
    let templates: [String]

    /// Generic labels some web call UIs use; unverified per app, so they're only a best effort.
    private static let genericSuffixes = [" is speaking", ", speaking", " (speaking)", " is talking"]
    private static var countLabel: Regex<(Substring, Substring)> { /^\+?\d+\s+(more|others?|participants?)$/ }
    private static var trailingParenthetical: Regex<Substring> { /\s*\([^()]*\)\s*$/ }

    func name(in label: String) -> String? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        for template in templates {
            let parts = template.components(separatedBy: "%@")
            guard parts.count == 2 else { continue }
            let (prefix, suffix) = (parts[0], parts[1])
            if label.count > prefix.count + suffix.count, label.hasPrefix(prefix), label.hasSuffix(suffix) {
                return Self.clean(String(label.dropFirst(prefix.count).dropLast(suffix.count)))
            }
        }
        for suffix in Self.genericSuffixes where label.lowercased().hasSuffix(suffix) {
            return Self.clean(String(label.dropLast(suffix.count)))
        }
        return nil
    }

    /// Strips "(You)", "(Host)" etc. and rejects non-names like "+3 more".
    static func clean(_ raw: String) -> String? {
        let name = raw.replacing(trailingParenthetical, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, (try? countLabel.wholeMatch(in: name.lowercased())) == nil else {
            return nil
        }
        return name
    }

    static func forPlatform(_ platform: MeetingPlatform) -> SpeakerMarkers {
        switch platform.id {
        case "zoom": SpeakerMarkers(templates: zoomTemplates() + ["Talking: %@"])
        case "slack": SpeakerMarkers(templates: ["Talking: %@"])
        default: SpeakerMarkers(templates: [])
        }
    }

    /// Zoom's own localized "Talking: %@", looked up by key prefix because the numeric suffix changes.
    private static func zoomTemplates() -> [String] {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos"),
              let bundle = Bundle(url: url),
              let path = bundle.path(forResource: "Localizable", ofType: "strings"),
              let strings = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [] }
        return strings.filter { $0.key.hasPrefix("LN_Accessibility_Active_Speaker_Name") }.map(\.value)
    }
}

/// A moment when the call UI showed someone talking; seconds since recording start.
struct SpeakerSample: Sendable, Equatable {
    var time: TimeInterval
    var names: [String]
}

enum SpeakerAttribution {
    /// The name most often shown as talking during a segment (with a little slack for UI lag).
    static func speaker(for segment: TranscriptSegment, in timeline: [SpeakerSample], slack: TimeInterval = 0.75) -> String? {
        var counts: [String: Int] = [:]
        for sample in timeline where sample.time >= segment.start - slack && sample.time <= segment.end + slack {
            for name in sample.names { counts[name, default: 0] += 1 }
        }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
