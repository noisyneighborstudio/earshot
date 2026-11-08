import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Pure helpers

/// Filtering, naming and grouping for meeting lists (no UI; unit-tested in SidebarTests).
enum MeetingQuery {
    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [meeting.title, meeting.platform, meeting.folder ?? "", meeting.summary ?? "", meeting.transcriptText]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func passes(_ meeting: Meeting, _ filter: MeetingFilter) -> Bool {
        switch filter {
        case .all: true
        case .starred: meeting.isStarred
        case .needsNotes: meeting.needsNotes
        case .folder(let name): meeting.folder == name
        }
    }

    static func apply(_ meetings: [Meeting], filter: MeetingFilter, query: String) -> [Meeting] {
        meetings.filter { passes($0, filter) && matches($0, query: query) }
    }

    static func openActionItems(_ meetings: [Meeting]) -> Int {
        meetings.reduce(0) { $0 + $1.actionItems.filter { !$0.done }.count }
    }

    static func count(_ meetings: [Meeting], inFolder folder: String) -> Int {
        meetings.filter { $0.folder == folder }.count
    }

    static func title(for filter: MeetingFilter) -> String {
        switch filter {
        case .all: String(localized: "All Meetings")
        case .starred: String(localized: "Starred")
        case .needsNotes: String(localized: "Needs Notes")
        case .folder(let name): name
        }
    }

    /// "Meetings › Product" for a meeting in a folder, else "Meetings".
    static func breadcrumb(for meeting: Meeting) -> String {
        let root = String(localized: "Meetings")
        return meeting.folder.map { "\(root) › \($0)" } ?? root
    }

    /// "2026-11-07 Friday release go-ahead.md", safe for any file system.
    static func exportFileName(for meeting: Meeting) -> String {
        let day = meeting.startedAt.formatted(.iso8601.year().month().day())
        let title = meeting.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(day) \(title.isEmpty ? String(localized: "Meeting") : title).md"
    }
}

// MARK: - Actions

/// Meeting actions shared by the sidebar, the meetings list and the notes toolbar, plus the
/// prompt/undo state they need. Owned by AppModel; the sidebar presents its alerts and undo banner.
@MainActor
@Observable
final class MeetingActions {

    enum Prompt: Equatable {
        case renameMeeting(Meeting.ID)
        /// New folder, optionally moving a meeting into it.
        case newFolder(moving: Meeting.ID?)
        case renameFolder(String)
    }

    var prompt: Prompt?
    var promptText = ""
    /// A deleted meeting that can still be restored.
    private(set) var deleted: Meeting?

    @ObservationIgnored private var undoGeneration = 0
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "meetings")

    static let undoWindow: Duration = .seconds(6)

    func beginRename(_ meeting: Meeting) {
        promptText = meeting.title
        prompt = .renameMeeting(meeting.id)
    }

    func beginNewFolder(moving id: Meeting.ID? = nil) {
        promptText = ""
        prompt = .newFolder(moving: id)
    }

    func beginRenameFolder(_ name: String) {
        promptText = name
        prompt = .renameFolder(name)
    }

    func commitPrompt(model: AppModel) {
        defer { prompt = nil }
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let prompt else { return }
        switch prompt {
        case .renameMeeting(let id):
            model.meetings.rename(id, to: text)
        case .newFolder(let moving):
            model.meetings.createFolder(text)
            if let moving { model.meetings.move(moving, toFolder: text) }
        case .renameFolder(let old):
            model.meetings.renameFolder(old, to: text)
            if model.navigation.filter == .folder(old) { model.navigation.filter = .folder(text) }
        }
    }

    func deleteFolder(_ name: String, model: AppModel) {
        model.meetings.deleteFolder(name)
        if model.navigation.filter == .folder(name) { model.navigation.filter = .all }
    }

    func copyNotes(_ meeting: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.markdown, forType: .string)
    }

    func exportMarkdown(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MeetingQuery.exportFileName(for: meeting)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try meeting.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.error("export failed: \(error.localizedDescription)")
            NSAlert(error: error).runModal()
        }
    }

    func showInFinder(_ meeting: Meeting, store: MeetingStore) {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: meeting.id)])
    }

    func delete(_ id: Meeting.ID, model: AppModel) {
        guard let removed = model.meetings.delete(id) else { return }
        if model.navigation.meetingID == id { model.navigation.meetingID = nil }
        deleted = removed
        undoGeneration += 1
        let generation = undoGeneration
        Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard let self, self.undoGeneration == generation else { return }
            self.deleted = nil
        }
    }

    func undoDelete(model: AppModel) {
        guard let meeting = deleted else { return }
        deleted = nil
        undoGeneration += 1
        model.meetings.restore(meeting)
        model.navigation.section = .meetings
        model.navigation.meetingID = meeting.id
    }

    func select(_ id: Meeting.ID, navigation: AppNavigation) {
        navigation.section = .meetings
        navigation.meetingID = id
    }
}

/// The per-meeting actions, used as a context menu and in the notes toolbar's More menu.
struct MeetingActionsMenu: View {
    let meeting: Meeting
    let model: AppModel
    private var actions: MeetingActions { model.meetingActions }
    /// The meeting being recorded or summarized can't be edited away from under the recorder.
    private var isBusy: Bool { model.recorder.current?.id == meeting.id }

    var body: some View {
        Button("Rename…") { actions.beginRename(meeting) }.disabled(isBusy)
        Button(meeting.isStarred ? "Unstar" : "Star") { model.meetings.toggleStar(meeting.id) }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(isBusy)
        Divider()
        Button("Copy Notes") { actions.copyNotes(meeting) }
        Button("Export as Markdown…") { actions.exportMarkdown(meeting) }
        ShareLink(item: meeting.markdown, subject: Text(verbatim: meeting.title)) { Text("Share…") }
        Divider()
        Button("Regenerate Notes") { model.recorder.resummarize(meeting.id) }
            .disabled(model.recorder.state != .idle || meeting.lines.isEmpty)
        Menu("Move to Folder") {
            ForEach(model.meetings.folders, id: \.self) { folder in
                Toggle(folder, isOn: Binding(
                    get: { meeting.folder == folder },
                    set: { _ in model.meetings.move(meeting.id, toFolder: folder) }))
            }
            Toggle("No Folder", isOn: Binding(
                get: { meeting.folder == nil },
                set: { _ in model.meetings.move(meeting.id, toFolder: nil) }))
            Divider()
            Button("New Folder…") { actions.beginNewFolder(moving: meeting.id) }
        }
        .disabled(isBusy)
        Button("Show in Finder") { actions.showInFinder(meeting, store: model.meetings) }
        Divider()
        Button("Delete", role: .destructive) { actions.delete(meeting.id, model: model) }
            .disabled(isBusy)
    }
}

// MARK: - Section

/// The Meetings section: the selected meeting's notes or live view, else the filtered list.
struct MeetingsSection: View {
    let model: AppModel

    var body: some View {
        if let id = model.navigation.meetingID, let meeting = meeting(id) {
            if model.recorder.current?.id == id && model.recorder.state == .recording {
                LiveMeetingView(meeting: meeting, recorder: model.recorder)
            } else {
                MeetingNotesView(meeting: meeting, model: model)
            }
        } else {
            MeetingList(model: model)
        }
    }

    /// The live copy while recording or summarizing, else the saved one.
    private func meeting(_ id: Meeting.ID) -> Meeting? {
        model.recorder.current?.id == id ? model.recorder.current : model.meetings.meetings.first { $0.id == id }
    }
}

private struct MeetingList: View {
    let model: AppModel

    private var navigation: AppNavigation { model.navigation }
    private var meetings: [Meeting] {
        MeetingQuery.apply(model.meetings.meetings, filter: navigation.filter, query: navigation.query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: MeetingQuery.title(for: navigation.filter)).font(.system(size: 24, weight: .bold))
                Text("\(meetings.count) meetings").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if navigation.filter != .all || !navigation.query.isEmpty {
                    Button("Show All") {
                        navigation.filter = .all
                        navigation.query = ""
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 12)

            if meetings.isEmpty {
                Group {
                    if !navigation.query.isEmpty {
                        ContentUnavailableView.search(text: navigation.query)
                    } else if model.meetings.meetings.isEmpty {
                        ContentUnavailableView("No meetings yet", systemImage: "person.2.wave.2",
                                               description: Text("Earshot offers to take notes when it detects a call."))
                    } else {
                        ContentUnavailableView("Nothing here", systemImage: "tray",
                                               description: Text("No meetings match this filter."))
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(meetings) { meeting in
                    Button {
                        model.meetingActions.select(meeting.id, navigation: navigation)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: meeting.isStarred ? "star.fill" : "star")
                                .foregroundStyle(meeting.isStarred ? Color.yellow : Color.secondary.opacity(0.4))
                                .font(.caption)
                                .padding(.top, 4)
                                .accessibilityHidden(!meeting.isStarred)
                            MeetingRow(meeting: meeting, recorder: model.recorder)
                            Spacer()
                            if let folder = meeting.folder { Chip(text: folder, color: .secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { MeetingActionsMenu(meeting: meeting, model: model) }
                }
                .listStyle(.inset)
            }
        }
    }
}
