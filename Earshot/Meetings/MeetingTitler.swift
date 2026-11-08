import Foundation

/// Short meeting titles: from the transcript while recording (Haiku), and from the notes' heading after.
struct MeetingTitler: Sendable {
    let cli: ClaudeCLI

    /// Transcript word counts at which a live title is (re)generated.
    static let thresholds = [120, 600]

    static let system = """
    Write a short, specific title for a meeting from its transcript so far: three to six words, \
    naming the main topic (for example "Q3 launch timeline" or "Onboarding design review"). \
    Use the meeting's language. Output only the title: no quotes, no trailing punctuation.
    """

    func title(for meeting: Meeting) async throws -> String? {
        let raw = try await cli.run(
            model: "claude-haiku-5-5", effort: "low", system: Self.system,
            input: "<transcript>\n\(meeting.transcriptText)\n</transcript>", timeout: .seconds(30))
        return Self.clean(raw)
    }

    /// The notes' "# Title" line.
    static func fromNotes(_ notes: String) -> String? {
        notes.components(separatedBy: "\n")
            .first { $0.hasPrefix("# ") }
            .flatMap { clean(String($0.dropFirst(2))) }
    }

    /// Until a real title is generated. The start time is already shown alongside, so it isn't repeated.
    static func placeholder(platform: String, startedAt: Date) -> String {
        platform.isEmpty ? String(localized: "Untitled meeting") : String(localized: "\(platform) call")
    }

    static func clean(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let title = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’#*`"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?").union(.whitespaces))
        guard !title.isEmpty else { return nil }
        return title.count > 80 ? String(title.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" : title
    }
}

extension Meeting {
    var wordCount: Int { lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
}
