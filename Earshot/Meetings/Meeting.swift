import Foundation
import os

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

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Plain transcript for Claude and for copying. Speaker labels are model-facing, so English.
    var transcriptText: String {
        lines.map { "[\(Self.timestamp($0.start))] \($0.label): \($0.text)" }
            .joined(separator: "\n")
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

struct ActionItem: Identifiable, Hashable, Sendable {
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
}

/// One JSON file per meeting in Application Support.
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "meetings")

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Earshot/Meetings")) {
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
