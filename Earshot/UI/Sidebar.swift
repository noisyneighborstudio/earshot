import SwiftUI

/// What a sidebar row points at. One selection type, so sections, meetings and folders share a List.
enum SidebarItem: Hashable {
    case section(AppSection)
    case meeting(Meeting.ID)
    case folder(String)

    /// The row that reflects the current navigation.
    @MainActor
    static func current(_ navigation: AppNavigation) -> SidebarItem {
        if navigation.section == .meetings {
            if let id = navigation.meetingID { return .meeting(id) }
            if case .folder(let name) = navigation.filter { return .folder(name) }
        }
        return .section(navigation.section)
    }

    @MainActor
    func apply(to navigation: AppNavigation) {
        switch self {
        case .section(let section):
            navigation.section = section
            if section == .meetings {
                navigation.meetingID = nil
                if case .folder = navigation.filter { navigation.filter = .all }
            }
        case .meeting(let id):
            navigation.section = .meetings
            navigation.meetingID = id
        case .folder(let name):
            navigation.section = .meetings
            navigation.meetingID = nil
            navigation.filter = .folder(name)
        }
    }
}

/// Sidebar v2: call status + Take Notes, search, sections, starred, recent, folders, footer.
struct AppSidebar: View {
    let model: AppModel
    private var actions: MeetingActions { model.meetingActions }

    static let recentLimit = 8

    var body: some View {
        @Bindable var navigation = model.navigation
        @Bindable var actions = actions
        let meetings = model.meetings.meetings
        let recent = Array(MeetingQuery.apply(meetings, filter: recentFilter, query: "").prefix(Self.recentLimit))
        let starred = MeetingQuery.apply(meetings, filter: .starred, query: "")

        List(selection: Binding(get: { SidebarItem.current(navigation) }, set: { $0?.apply(to: navigation) })) {
            Section {
                ForEach(AppSection.allCases) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 22, alignment: .center)
                            .foregroundStyle(Color.accentColor)
                        Text(section.title)
                        Spacer()
                        if let count = count(for: section), count > 0 {
                            Text(verbatim: "\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(SidebarItem.section(section))
                }
            }

            if !starred.isEmpty {
                Section("Starred") {
                    ForEach(starred) { meetingRow($0) }
                }
            }

            Section {
                if recent.isEmpty {
                    Text(recentFilter == .all ? "No meetings yet" : "Nothing matches")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(recent) { meetingRow($0) }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Menu {
                        Picker("Show", selection: Binding(get: { recentFilter }, set: { navigation.filter = $0 })) {
                            Text("All").tag(MeetingFilter.all)
                            Text("Starred").tag(MeetingFilter.starred)
                            Text("Needs Notes").tag(MeetingFilter.needsNotes)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(verbatim: MeetingQuery.title(for: recentFilter))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .padding(.trailing, 4)
                }
            }

            Section {
                ForEach(model.meetings.folders, id: \.self) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .frame(width: 22, alignment: .center)
                            .foregroundStyle(.secondary)
                        Text(verbatim: folder)
                        Spacer()
                        Text(verbatim: "\(MeetingQuery.count(meetings, inFolder: folder))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(SidebarItem.folder(folder))
                    .contextMenu {
                        Button("Rename…") { actions.beginRenameFolder(folder) }
                        Button("Delete Folder", role: .destructive) { actions.deleteFolder(folder, model: model) }
                    }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        actions.beginNewFolder()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.trailing, 4)
                    .help(Text("New Folder"))
                    .accessibilityLabel(Text("New Folder"))
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .searchable(text: $navigation.query, placement: .sidebar, prompt: Text("Search notes and transcripts"))
        .onChange(of: navigation.query) { _, query in
            // Results show in the Meetings list.
            if !query.isEmpty {
                navigation.section = .meetings
                navigation.meetingID = nil
            }
        }
        .safeAreaInset(edge: .top) {
            CallStatusCard(model: model)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let deleted = actions.deleted {
                    UndoBanner(title: deleted.title) { actions.undoDelete(model: model) }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                SidebarFooter()
            }
            .animation(.easeInOut(duration: 0.2), value: actions.deleted?.id)
        }
        .alert(promptTitle, isPresented: Binding(get: { actions.prompt != nil }, set: { if !$0 { actions.prompt = nil } })) {
            TextField(promptPlaceholder, text: $actions.promptText)
            Button(promptAction) { actions.commitPrompt(model: model) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { actions.prompt = nil }
        }
    }

    /// The Recent list follows the meetings filter, except folders (those have their own rows).
    private var recentFilter: MeetingFilter {
        if case .folder = model.navigation.filter { return .all }
        return model.navigation.filter
    }

    private func count(for section: AppSection) -> Int? {
        switch section {
        case .meetings: model.meetings.meetings.count
        case .actionItems: MeetingQuery.openActionItems(model.meetings.meetings)
        default: nil
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        MeetingRow(meeting: meeting, recorder: model.recorder)
            .padding(.vertical, 2)
            .tag(SidebarItem.meeting(meeting.id))
            .contextMenu { MeetingActionsMenu(meeting: meeting, model: model) }
    }

    private var promptTitle: String {
        switch actions.prompt {
        case .renameMeeting: String(localized: "Rename Meeting")
        case .renameFolder: String(localized: "Rename Folder")
        case .newFolder, nil: String(localized: "New Folder")
        }
    }

    private var promptPlaceholder: String {
        switch actions.prompt {
        case .renameMeeting: String(localized: "Meeting title")
        default: String(localized: "Folder name")
        }
    }

    private var promptAction: String {
        switch actions.prompt {
        case .newFolder: String(localized: "Create")
        default: String(localized: "Rename")
        }
    }
}

/// Top of the sidebar: the detected or live call, with the primary Take Notes / Stop action (⇧⌘N).
private struct CallStatusCard: View {
    let model: AppModel
    private var recorder: MeetingRecorder { model.recorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                    .shadow(color: dotColor.opacity(0.4), radius: dotColor == .secondary ? 0 : 3)
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.callout.weight(.semibold))
                    subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            action.controlSize(.large)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.separator.opacity(0.6)))
    }

    private var dotColor: Color {
        switch recorder.state {
        case .recording: Theme.recording
        case .summarizing: .accentColor
        case .idle: model.detector.current == nil ? .secondary : Theme.detected
        }
    }

    @ViewBuilder private var title: some View {
        switch recorder.state {
        case .recording: Text(verbatim: recorder.current?.title ?? "")
        case .summarizing: Text("Writing notes…")
        case .idle: Text(verbatim: RecordPrompt.title(model))
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch recorder.state {
        case .recording:
            if let started = recorder.current?.startedAt {
                HStack(spacing: 3) {
                    Text("Recording")
                    Text(started, style: .timer).monospacedDigit()
                }
            }
        case .summarizing: Text("Claude is reading the transcript")
        case .idle: Text(verbatim: RecordPrompt.subtitle(model))
        }
    }

    @ViewBuilder private var action: some View {
        switch recorder.state {
        case .recording:
            Button {
                recorder.stop()
            } label: {
                Label("Stop & Write Notes", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.recording)
            .keyboardShortcut("n", modifiers: [.command, .shift])
        case .summarizing:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.recordMeeting()
                } label: {
                    Label(RecordPrompt.buttonTitle(model), systemImage: RecordPrompt.buttonImage(model))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help(Text("Start recording (⇧⌘N)"))
                if RecordPrompt.showsComputerAudioOption(model) {
                    ComputerAudioToggle(settings: model.settings).controlSize(.small)
                }
            }
        }
    }
}

private struct UndoBanner: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text("Deleted “\(title)”").font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo", action: undo)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.6)))
    }
}

private struct SidebarFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            Text("Transcribed on this Mac").font(.caption).foregroundStyle(.secondary)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(Text("Settings"))
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }
}
