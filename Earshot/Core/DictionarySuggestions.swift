import Foundation
import os

/// Words the user keeps correcting after dictation, offered for the Dictionary.
/// Fed by `CorrectionTracker`; shown on Home and in the Dictionary screen.
@MainActor
@Observable
final class DictionarySuggestions {
    struct Suggestion: Codable, Identifiable, Hashable, Sendable {
        /// The spelling the user typed.
        var word: String
        /// How many times they corrected dictation to it.
        var count: Int
        var lastSeen: Date
        var id: String { word.lowercased() }
    }

    /// Corrections seen this many times are offered.
    static let threshold = 2

    private(set) var all: [Suggestion] = []

    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "suggestions")

    private struct Stored: Codable {
        var suggestions: [Suggestion]
        var dismissed: [String]
    }

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Earshot/suggestions.json")) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            all = stored.suggestions
            dismissed = Set(stored.dismissed)
        } catch {
            log.error("suggestions unreadable: \(error.localizedDescription)")
        }
    }

    /// Ready to offer, most frequent first.
    var ready: [Suggestion] {
        all.filter { $0.count >= Self.threshold }.sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }
    }

    /// Records corrected spellings (e.g. "Lyft" typed over a dictated "lift").
    /// Words already in the dictionary, or dismissed before, are ignored.
    func record(_ words: [String], dictionary: [String]) {
        let known = Set(dictionary.map { $0.lowercased() })
        for word in words {
            let key = word.lowercased()
            guard !known.contains(key), !dismissed.contains(key) else { continue }
            if let index = all.firstIndex(where: { $0.id == key }) {
                all[index].count += 1
                all[index].lastSeen = .now
            } else {
                all.append(Suggestion(word: word, count: 1, lastSeen: .now))
            }
        }
        persist()
    }

    func accept(_ suggestion: Suggestion, into settings: AppSettings) {
        let existing = settings.dictionaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.dictionaryText = existing.isEmpty ? suggestion.word : existing + "\n" + suggestion.word
        all.removeAll { $0.id == suggestion.id }
        persist()
    }

    func dismiss(_ suggestion: Suggestion) {
        dismissed.insert(suggestion.id)
        all.removeAll { $0.id == suggestion.id }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(suggestions: all, dismissed: Array(dismissed))).write(to: url, options: .atomic)
        } catch {
            log.error("suggestions save failed: \(error.localizedDescription)")
        }
    }
}
