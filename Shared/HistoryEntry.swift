import Foundation

struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var date = Date()
    var app: String
    var raw: String
    /// The inserted text; nil when the pipeline failed after transcription.
    var text: String?
    var error: String?
}

extension HistoryEntry {
    /// Entries whose cleaned text, raw transcript, or app matches `query` (empty matches all).
    static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.text ?? "", entry.raw, entry.app].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}
