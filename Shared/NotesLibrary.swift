import Foundation

/// Read-only view of Earshot's data for the earshot-mcp helper. Files are decoded and indexed on
/// first use and re-read only when their modification date or size changes. Never writes.
actor NotesLibrary {
    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private let meetingsDirectory: URL
    private let historyURL: URL
    private var documents: [String: (stamp: Stamp, document: NotesDocument)] = [:]
    /// Unreadable files, kept so they are retried only after they change.
    private var failures: [String: (stamp: Stamp, error: String)] = [:]
    private var history: (stamp: Stamp, entries: [HistoryEntry])?
    private var semantic = SemanticIndex()

    init(directory: URL = EarshotData.directory) {
        meetingsDirectory = directory.appending(path: "Meetings")
        historyURL = directory.appending(path: "history.json")
    }

    // MARK: Tools

    func search(_ args: ToolArguments) throws -> Page<SearchHit> {
        guard let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw NotesError("`query` is required.")
        }
        let terms = Terms.query(query)
        guard !terms.isEmpty else { throw NotesError("`query` has no searchable words.") }
        let candidates = try filtered(args)
        let (offset, limit) = Self.paging(args, default: 10, max: 50)
        let lexical = Ranker.rank(candidates, terms: terms, phrase: query)

        var semanticIDs: [Meeting.ID] = []
        var status = "off"
        if args.mode ?? .hybrid == .hybrid {
            (semanticIDs, status) = semantic.nearest(to: query, in: candidates, limit: 5)
        }
        // Reciprocal rank fusion; semantic counts half so it mostly adds recall for paraphrases.
        var fused: [Meeting.ID: Double] = [:]
        for (rank, hit) in lexical.enumerated() { fused[hit.document.meeting.id, default: 0] += 1 / Double(61 + rank) }
        for (rank, id) in semanticIDs.enumerated() { fused[id, default: 0] += 0.5 / Double(61 + rank) }
        let hits = Dictionary(lexical.map { ($0.document.meeting.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(candidates.map { ($0.meeting.id, $0) }, uniquingKeysWith: { a, _ in a })
        let semanticSet = Set(semanticIDs)

        let ranked = fused.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
        let results: [SearchHit] = ranked.compactMap { id, _ in
            guard let document = byID[id] else { return nil }
            let snippets = hits[id].map { hit in hit.chunks.prefix(3).map { document.snippet($0, terms: terms) } }
                ?? [Snippet(field: .notes, text: Terms.excerpt(document.gist, around: []))]
            let match = hits[id] == nil ? "semantic" : semanticSet.contains(id) ? "both" : "lexical"
            return SearchHit(meeting: MeetingSummary(document), match: match, snippets: snippets)
        }
        var page = paginate(results, offset: offset, limit: limit)
        page.semantic = status
        return page
    }

    func list(_ args: ToolArguments) throws -> Page<MeetingSummary> {
        let (offset, limit) = Self.paging(args, default: 20, max: 100)
        return paginate(try filtered(args).map(MeetingSummary.init), offset: offset, limit: limit)
    }

    func meeting(_ args: ToolArguments) throws -> MeetingDetail {
        let document = try document(args.id)
        let meeting = document.meeting
        var transcript: TranscriptPage?
        if args.includeTranscript == true {
            let offset = min(max(0, args.transcriptOffset ?? 0), meeting.lines.count)
            let limit = min(max(1, args.transcriptLimit ?? 200), 1000)
            let end = min(offset + limit, meeting.lines.count)
            transcript = TranscriptPage(
                lines: meeting.lines[offset..<end].map(\.formatted), offset: offset, total: meeting.lines.count,
                nextOffset: end < meeting.lines.count ? end : nil)
        }
        return MeetingDetail(
            meeting: MeetingSummary(document), endedAt: meeting.endedAt, notes: meeting.summary,
            notesError: meeting.summaryError, transcript: transcript)
    }

    func actionItems(_ args: ToolArguments) throws -> Page<ActionItem> {
        var candidates = try filtered(args)
        if let id = args.meetingId { candidates = [try document(id)] }
        let owner = args.owner.map(Terms.fold)
        let items = candidates.flatMap(\.meeting.actionItems).filter { item in
            switch args.state ?? .open {
            case .open: guard !item.done else { return false }
            case .done: guard item.done else { return false }
            case .all: break
            }
            return owner.map { Terms.fold(item.owner ?? "Unassigned").contains($0) } ?? true
        }
        let (offset, limit) = Self.paging(args, default: 50, max: 200)
        return paginate(items, offset: offset, limit: limit)
    }

    func dictations(_ args: ToolArguments) throws -> Page<Dictation> {
        let (after, before) = try Self.dateRange(args)
        let app = args.app.map(Terms.fold)
        let entries = HistoryEntry.filter(try historyEntries(), query: args.query ?? "").filter { entry in
            after.map { entry.date >= $0 } ?? true && before.map { entry.date < $0 } ?? true
                && app.map { Terms.fold(entry.app).contains($0) } ?? true
        }
        .sorted { $0.date > $1.date }
        let (offset, limit) = Self.paging(args, default: 20, max: 200)
        var page = paginate(entries.map(Dictation.init), offset: offset, limit: limit)
        page.unreadableFiles = nil
        return page
    }

    // MARK: Resources and prompts

    /// Meetings for `resources/list`, newest first.
    func summaries() throws -> [MeetingSummary] { try filtered(ToolArguments()).map(MeetingSummary.init) }

    func markdown(_ reference: String) throws -> String { try document(reference).meeting.markdown }

    /// Context for "brief me before my meeting with `person`": their recent meetings' notes and open items.
    func brief(person: String, topic: String?) throws -> String {
        let name = Terms.fold(person)
        let all = try filtered(ToolArguments())
        let withThem = all.filter { document in
            document.people.contains { Terms.fold($0).contains(name) } || Terms.fold(document.meeting.title).contains(name)
        }
        let recent = withThem.prefix(5)
        let open = withThem.flatMap(\.meeting.actionItems).filter { !$0.done }
            + all.flatMap(\.meeting.actionItems).filter { !$0.done && Terms.fold($0.owner ?? "").contains(name) }
        var seen = Set<String>()
        let items = open.filter { seen.insert($0.id).inserted }.prefix(20)

        var text = "I have a meeting with \(person) coming up\(topic.map { " about \($0)" } ?? ""). "
            + "Brief me: who they are to me, what we discussed recently, decisions made, what I owe them and "
            + "they owe me, open questions, and what to raise. Cite meetings by title and date. "
            + "Use the Earshot tools (search_notes, get_meeting) if you need more detail.\n\n"
        if recent.isEmpty {
            text += "Earshot has no meetings with \(person) by name. Try search_notes with other spellings or topics."
            return text
        }
        text += "## Recent meetings with \(person) (\(withThem.count) total)\n\n"
        for document in recent {
            let meeting = document.meeting
            text += "### \(meeting.title) — \(Output.date(meeting.startedAt)) (id \(meeting.id.uuidString))\n\n"
            text += meeting.summary.map { String($0.prefix(2500)) } ?? "(no notes yet; see the transcript via get_meeting)"
            text += "\n\n"
        }
        if !items.isEmpty {
            text += "## Open action items\n\n"
            text += items.map { "- \($0.owner ?? "Unassigned"): \($0.text) (\($0.meetingTitle), \(Output.date($0.meetingDate)))" }
                .joined(separator: "\n")
        }
        return text
    }

    // MARK: Loading

    /// All readable meetings, newest first, after re-reading anything that changed.
    private func refresh() throws -> [NotesDocument] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: meetingsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles)
        } catch {
            throw NotesError("No Earshot meetings at \(meetingsDirectory.path) (\(error.localizedDescription)). Has Earshot recorded anything yet?")
        }
        var present = Set<String>()
        for url in urls where url.pathExtension == "json" {
            let name = url.lastPathComponent
            // The app names meeting files by id; anything else (folders.json, temp files) isn't a meeting.
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize else { continue }
            let stamp = Stamp(modified: modified, size: size)
            present.insert(name)
            if documents[name]?.stamp == stamp || failures[name]?.stamp == stamp { continue }
            do {
                // Read after stat: if the app replaces the file in between, the next stamp differs and it's re-read.
                let meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: url))
                documents[name] = (stamp, NotesDocument(meeting))
                failures[name] = nil
            } catch CocoaError.fileReadNoSuchFile {
                present.remove(name)
            } catch {
                documents[name] = nil
                failures[name] = (stamp, Self.describe(error))
            }
        }
        documents = documents.filter { present.contains($0.key) }
        failures = failures.filter { present.contains($0.key) }
        semantic.retain(Set(documents.values.map(\.document.meeting.id)))
        return documents.values.map(\.document).sorted {
            $0.meeting.startedAt != $1.meeting.startedAt
                ? $0.meeting.startedAt > $1.meeting.startedAt : $0.meeting.id.uuidString < $1.meeting.id.uuidString
        }
    }

    private func filtered(_ args: ToolArguments) throws -> [NotesDocument] {
        let (after, before) = try Self.dateRange(args)
        let participant = args.participant.map(Terms.fold)
        let platform = args.platform.map(Terms.fold)
        let folder = args.folder.map(Terms.fold)
        return try refresh().filter { document in
            let meeting = document.meeting
            if let kind = args.kind, (meeting.kind ?? .meeting) != kind { return false }
            if let status = args.status, MeetingStatus(meeting) != status { return false }
            if let starred = args.starred, meeting.isStarred != starred { return false }
            if let after, meeting.startedAt < after { return false }
            if let before, meeting.startedAt >= before { return false }
            if let platform, !Terms.fold(meeting.platform).contains(platform) { return false }
            if let folder, Terms.fold(meeting.folder ?? "") != folder { return false }
            if let participant, !document.people.contains(where: { Terms.fold($0).contains(participant) }) { return false }
            return true
        }
    }

    /// A meeting by full id or unique id prefix (8+ characters).
    private func document(_ reference: String?) throws -> NotesDocument {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else {
            throw NotesError("`id` is required.")
        }
        let prefix = reference.replacingOccurrences(of: "earshot://meeting/", with: "").uppercased()
        guard prefix.count >= 8 else { throw NotesError("Meeting id '\(reference)' is too short; use at least 8 characters.") }
        let matches = try refresh().filter { $0.meeting.id.uuidString.hasPrefix(prefix) }
        if matches.count > 1 { throw NotesError("Meeting id '\(reference)' is ambiguous; use the full id.") }
        if let match = matches.first { return match }
        if let failure = failures.first(where: { $0.key.uppercased().hasPrefix(prefix) }) {
            throw NotesError("Meeting file \(failure.key) is unreadable: \(failure.value.error)")
        }
        throw NotesError("No meeting with id '\(reference)'. Find ids with search_notes or list_meetings.")
    }

    private func historyEntries() throws -> [HistoryEntry] {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        } catch {
            throw NotesError("No dictation history at \(historyURL.path). Has Earshot been used for dictation yet?")
        }
        guard let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int else {
            throw NotesError("Can't read \(historyURL.path)'s attributes.")
        }
        let stamp = Stamp(modified: modified, size: size)
        if let history, history.stamp == stamp { return history.entries }
        do {
            let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: historyURL))
            history = (stamp, entries)
            return entries
        } catch {
            throw NotesError("Dictation history is unreadable: \(Self.describe(error))")
        }
    }

    // MARK: Helpers

    private func paginate<Item>(_ items: [Item], offset: Int, limit: Int) -> Page<Item> {
        let start = min(offset, items.count), end = min(start + limit, items.count)
        let failed = failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.error)" }
        return Page(
            items: Array(items[start..<end]), total: items.count, offset: start,
            nextOffset: end < items.count ? end : nil,
            unreadableFiles: failed.isEmpty ? nil : Array(failed.prefix(5)) + (failed.count > 5 ? ["…and \(failed.count - 5) more"] : []))
    }

    private static func paging(_ args: ToolArguments, default fallback: Int, max upper: Int) -> (Int, Int) {
        (max(0, args.offset ?? 0), min(max(1, args.limit ?? fallback), upper))
    }

    /// `after` inclusive, `before` exclusive; a bare date for `before` includes that whole day.
    static func dateRange(_ args: ToolArguments) throws -> (Date?, Date?) {
        (try args.after.map { try date($0, name: "after", endOfDay: false) },
         try args.before.map { try date($0, name: "before", endOfDay: true) })
    }

    static func date(_ text: String, name: String, endOfDay: Bool) throws -> Date {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3, text.count == 10,
           let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
            return endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: day)! : day
        }
        throw NotesError("`\(name)` must be a date like 2026-03-14 or 2026-03-14T09:30:00-07:00, not '\(text)'.")
    }

    /// Short, specific reasons instead of DecodingError's dumps.
    static func describe(_ error: Error) -> String {
        func path(_ keys: [any CodingKey]) -> String {
            keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case DecodingError.dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not valid JSON (truncated or corrupt)" : "invalid value at \(path(context.codingPath))"
        case DecodingError.keyNotFound(let key, let context):
            return "missing \(path(context.codingPath + [key]))"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "wrong type at \(path(context.codingPath))"
        default:
            return error.localizedDescription
        }
    }
}

struct NotesError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Arguments and results (model-facing, so English)

/// Every tool's arguments; each tool reads the ones it documents.
struct ToolArguments: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable { case hybrid, lexical }
    enum State: String, Decodable, Sendable { case open, done, all }

    var query: String?
    var id: String?
    var kind: Meeting.Kind?
    var status: MeetingStatus?
    var participant: String?
    var platform: String?
    var folder: String?
    var starred: Bool?
    var after: String?
    var before: String?
    var limit: Int?
    var offset: Int?
    var mode: Mode?
    var includeTranscript: Bool?
    var transcriptOffset: Int?
    var transcriptLimit: Int?
    var owner: String?
    var state: State?
    var meetingId: String?
    var app: String?
}

enum MeetingStatus: String, Codable, Sendable {
    /// No end yet: recording now, or Earshot quit mid-recording (the app closes it out on next launch).
    case recording
    case notesPending = "notes_pending"
    case notesFailed = "notes_failed"
    case ready

    init(_ meeting: Meeting) {
        self = meeting.endedAt == nil ? .recording
            : meeting.summaryError != nil ? .notesFailed
            : meeting.summary == nil ? .notesPending : .ready
    }
}

struct Page<Item: Encodable & Sendable>: Encodable, Sendable {
    var items: [Item]
    var total: Int
    var offset: Int
    var nextOffset: Int?
    var semantic: String?
    var unreadableFiles: [String]?
}

struct MeetingSummary: Encodable, Sendable {
    let id: Meeting.ID
    let title: String
    let date: Date
    let durationMinutes: Int?
    let kind: Meeting.Kind
    let status: MeetingStatus
    let platform: String?
    let folder: String?
    let starred: Bool?
    let participants: [String]?
    let openActionItems: Int?
    let transcriptLines: Int

    init(_ document: NotesDocument) {
        let meeting = document.meeting
        id = meeting.id
        title = meeting.title
        date = meeting.startedAt
        durationMinutes = meeting.duration.map { Int(($0 / 60).rounded()) }
        kind = meeting.kind ?? .meeting
        status = MeetingStatus(meeting)
        platform = meeting.platform.isEmpty ? nil : meeting.platform
        folder = meeting.folder
        starred = meeting.isStarred ? true : nil
        participants = document.people.isEmpty ? nil : document.people
        openActionItems = meeting.openTaskCount > 0 ? meeting.openTaskCount : nil
        transcriptLines = meeting.lines.count
    }
}

struct SearchHit: Encodable, Sendable {
    let meeting: MeetingSummary
    /// lexical, semantic, or both.
    let match: String
    let snippets: [Snippet]
}

struct MeetingDetail: Encodable, Sendable {
    let meeting: MeetingSummary
    let endedAt: Date?
    /// The notes, as markdown. Action items are "- [ ] Owner: task" lines.
    let notes: String?
    let notesError: String?
    let transcript: TranscriptPage?
}

struct TranscriptPage: Encodable, Sendable {
    let lines: [String]
    let offset: Int
    let total: Int
    let nextOffset: Int?
}

struct Dictation: Encodable, Sendable {
    let date: Date
    let app: String
    let text: String
    let error: String?

    init(_ entry: HistoryEntry) {
        date = entry.date
        app = entry.app
        text = entry.text ?? entry.raw
        error = entry.error
    }
}

enum Output {
    /// Local time with offset, e.g. 2026-03-14T09:30:00-07:00.
    static func date(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.date(date))
        }
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
