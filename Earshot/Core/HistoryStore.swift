import Foundation
import os

struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var date = Date()
    var app: String
    var raw: String
    /// The inserted text; nil when the pipeline failed after transcription.
    var text: String?
    var error: String?
}

/// Recent dictations, persisted as JSON in Application Support.
@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let limit = 200
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "history")

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Earshot/history.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: url))
        } catch {
            log.error("history unreadable, moving aside: \(error.localizedDescription)")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    func delete(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    /// Entries whose cleaned text, raw transcript, or app matches `query` (empty matches all).
    nonisolated static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.text ?? "", entry.raw, entry.app].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            log.error("history save failed: \(error.localizedDescription)")
        }
    }
}
