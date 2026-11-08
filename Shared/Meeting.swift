import Foundation

/// Where the app keeps its data. The earshot-mcp helper reads it; only the app writes it.
enum EarshotData {
    static let directory = URL.applicationSupportDirectory.appending(path: "Earshot")
    static var meetings: URL { directory.appending(path: "Meetings") }
    static var history: URL { directory.appending(path: "history.json") }
}

struct Meeting: Codable, Identifiable, Sendable, Equatable {
    enum Speaker: String, Codable, Sendable {
        /// The user's microphone.
        case me
        /// Call audio: everyone else.
        case others
    }

    struct Line: Codable, Sendable, Equatable {
        var speaker: Speaker
        var start: TimeInterval
        var text: String
        /// Who was talking per the call app, for "Others" lines.
        var name: String?

        var label: String { name ?? (speaker == .me ? "Me" : "Others") }
        /// "[mm:ss] Label: text", one transcript line.
        var formatted: String { "[\(Meeting.timestamp(start))] \(label): \(text)" }
    }

    var id = UUID()
    var title: String
    var platform: String
    var startedAt: Date
    var endedAt: Date?
    var lines: [Line] = []
    /// Names seen talking in the call UI.
    var participants: [String]?
    var summary: String?
    var summaryError: String?
    enum Kind: String, Codable, Sendable {
        /// A call: mic plus call audio.
        case meeting
        /// Just the user talking (mic only).
        case note
    }

    /// Optional so meetings saved before these existed still decode.
    var kind: Kind?
    var starred: Bool?
    var folder: String?

    var isStarred: Bool { starred == true }
    var isNote: Bool { kind == .note }
    /// Saved, but without usable notes (failed, interrupted, or never written).
    var needsNotes: Bool { endedAt != nil && (summary == nil || summaryError != nil) }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Plain transcript for Claude and for copying. Speaker labels are model-facing, so English.
    var transcriptText: String {
        lines.map(\.formatted).joined(separator: "\n")
    }

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    /// "- [ ] Owner: task" lines in the notes. `line` indexes `summary` split on "\n".
    var actionItems: [ActionItem] {
        (summary ?? "").components(separatedBy: "\n").enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let open = line.hasPrefix("- [ ] ")
            guard open || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") else { return nil }
            let (owner, text) = Self.splitOwner(String(line.dropFirst(6)))
            return ActionItem(
                meetingID: id, meetingTitle: title, meetingDate: startedAt,
                line: index, owner: owner, text: text, done: !open)
        }
    }

    /// "Owner: task" → (owner, task) when the prefix is short enough to be a name.
    static func splitOwner(_ item: String) -> (String?, String) {
        guard let colon = item.range(of: ": "), item.distance(from: item.startIndex, to: colon.lowerBound) <= 32 else {
            return (nil, item)
        }
        return (String(item[..<colon.lowerBound]), String(item[colon.upperBound...]))
    }

    /// Open "- [ ]" items in the notes.
    var openTaskCount: Int {
        (summary ?? "").components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ] ") }.count
    }

    /// Flips the checkbox on one line of the notes.
    mutating func toggleTask(atLine index: Int) {
        guard var lines = summary?.components(separatedBy: "\n"), lines.indices.contains(index) else { return }
        let line = lines[index]
        if let range = line.range(of: "- [ ] ") {
            lines[index] = line.replacingCharacters(in: range, with: "- [x] ")
        } else if let range = line.range(of: "- [x] ") {
            lines[index] = line.replacingCharacters(in: range, with: "- [ ] ")
        }
        summary = lines.joined(separator: "\n")
    }

    var markdown: String {
        var parts: [String] = []
        if let summary { parts.append(summary) } else { parts.append("# \(title)") }
        parts.append("## Transcript\n\n" + transcriptText)
        return parts.joined(separator: "\n\n")
    }
}

struct ActionItem: Identifiable, Hashable, Sendable, Encodable {
    let meetingID: Meeting.ID
    let meetingTitle: String
    let meetingDate: Date
    /// Index into the meeting's `summary` lines; pass to `Meeting.toggleTask(atLine:)`.
    let line: Int
    let owner: String?
    let text: String
    let done: Bool

    var id: String { "\(meetingID.uuidString)-\(line)" }
    var isMine: Bool { owner == "Me" }

    /// What earshot-mcp reports; `line` only means something to the app.
    private enum CodingKeys: String, CodingKey { case text, owner, done, meetingID = "meeting_id", meetingTitle, meetingDate }
}
