import Foundation
import os

extension Meeting {
    /// Merges the two streams into one timeline, naming "Others" lines from the speaker timeline.
    /// Mic segments that are just the call coming out of the speakers are dropped.
    static func lines(me: [TranscriptSegment], others: [TranscriptSegment], speakers: [SpeakerSample] = []) -> [Line] {
        (me.filter { !isEcho($0, of: others) }.map { Line(speaker: .me, start: $0.start, text: $0.text) }
            + others.map {
                Line(speaker: .others, start: $0.start, text: $0.text,
                     name: SpeakerAttribution.speaker(for: $0, in: speakers))
            })
            .sorted { $0.start < $1.start }
    }

    /// Without headphones the mic hears the call too. A mic segment of 3+ words whose words mostly
    /// appear in call audio around the same time is that echo, not the user.
    static func isEcho(_ segment: TranscriptSegment, of others: [TranscriptSegment], window: TimeInterval = 3) -> Bool {
        let mine = words(segment.text)
        guard mine.count >= 3 else { return false }
        let nearby = others
            .filter { $0.end >= segment.start - window && $0.start <= segment.end + window }
            .reduce(into: Set<String>()) { $0.formUnion(words($1.text)) }
        let shared = mine.filter(nearby.contains).count
        return Double(shared) / Double(mine.count) >= 0.7
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// One JSON file per meeting in Application Support.
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "meetings")

    init(directory: URL = EarshotData.meetings) {
        self.directory = directory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        meetings = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "folders.json" }.compactMap { url in
            do {
                return try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: url))
            } catch {
                log.error("unreadable meeting \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
                return nil
            }
        }
        .sorted { $0.startedAt > $1.startedAt }
        if let data = try? Data(contentsOf: foldersURL) {
            savedFolders = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        recoverInterrupted()
    }

    /// Meetings left without an end (Earshot was killed or crashed mid-recording) get closed out
    /// with what was saved, so they can still get notes.
    private func recoverInterrupted() {
        for var meeting in meetings where meeting.endedAt == nil {
            meeting.endedAt = meeting.startedAt.addingTimeInterval(meeting.lines.last.map { $0.start + 5 } ?? 0)
            meeting.summaryError = meeting.lines.isEmpty
                ? String(localized: "Recording was interrupted before anything was transcribed.")
                : String(localized: "Recording was interrupted. The transcript up to that point was saved.")
            log.info("recovered interrupted meeting \(meeting.id, privacy: .public)")
            save(meeting)
        }
    }

    private var savedFolders: [String] = []

    func save(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(meeting).write(to: fileURL(for: meeting.id), options: .atomic)
        } catch {
            log.error("meeting save failed: \(error.localizedDescription)")
        }
    }

    /// Returns the removed meeting so the caller can offer Undo (`restore`).
    @discardableResult
    func delete(_ id: Meeting.ID) -> Meeting? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        meetings.removeAll { $0.id == id }
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch {
            log.error("meeting delete failed: \(error.localizedDescription)")
        }
        return meeting
    }

    func restore(_ meeting: Meeting) {
        save(meeting)
        meetings.sort { $0.startedAt > $1.startedAt }
    }

    func update(_ id: Meeting.ID, _ change: (inout Meeting) -> Void) {
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        change(&meeting)
        save(meeting)
    }

    func rename(_ id: Meeting.ID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(id) { $0.title = title }
    }

    func toggleStar(_ id: Meeting.ID) { update(id) { $0.starred = !$0.isStarred } }

    func move(_ id: Meeting.ID, toFolder folder: String?) {
        if let folder { createFolder(folder) }
        update(id) { $0.folder = folder }
    }

    func toggleTask(_ item: ActionItem) { update(item.meetingID) { $0.toggleTask(atLine: item.line) } }

    // MARK: Folders

    /// Folder names, including empty ones the user created.
    var folders: [String] {
        Array(Set(savedFolders + meetings.compactMap(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func createFolder(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !savedFolders.contains(name) else { return }
        savedFolders.append(name)
        persistFolders()
    }

    func renameFolder(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return }
        savedFolders = savedFolders.map { $0 == old ? new : $0 }
        persistFolders()
        for meeting in meetings where meeting.folder == old { update(meeting.id) { $0.folder = new } }
    }

    /// Meetings in it move to No Folder.
    func deleteFolder(_ name: String) {
        savedFolders.removeAll { $0 == name }
        persistFolders()
        for meeting in meetings where meeting.folder == name { update(meeting.id) { $0.folder = nil } }
    }

    private var foldersURL: URL { directory.appending(path: "folders.json") }

    private func persistFolders() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(savedFolders).write(to: foldersURL, options: .atomic)
        } catch {
            log.error("folders save failed: \(error.localizedDescription)")
        }
    }

    // MARK: Files

    func fileURL(for id: Meeting.ID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
