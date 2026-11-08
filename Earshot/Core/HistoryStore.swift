import Foundation
import os

/// Recent dictations, persisted as JSON in Application Support.
@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let limit = 200
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "history")

    init(url: URL = EarshotData.history) {
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

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            log.error("history save failed: \(error.localizedDescription)")
        }
    }
}
