import AppKit
import SwiftUI

/// Pure derivations behind Home, kept out of the view so they're testable.
enum HomeLogic {
    static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: String(localized: "Good morning")
        case 12..<17: String(localized: "Good afternoon")
        default: String(localized: "Good evening")
        }
    }

    /// First sentence of the notes' "## Summary" section (or of the first paragraph if there's no such heading).
    static func summaryLine(from notes: String?) -> String? {
        guard let notes else { return nil }
        let lines = notes.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let start = lines.firstIndex { $0.lowercased().hasPrefix("## summary") }.map { $0 + 1 } ?? 0
        guard let paragraph = lines[start...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { return nil }
        let text = paragraph.hasPrefix("- ") ? String(paragraph.dropFirst(2)) : paragraph
        if let end = text.firstRange(of: /[.!?](\s|$)/) {
            return String(text[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Open items across meetings: mine first, then newest meeting first, in note order.
    static func openActionItems(_ meetings: [Meeting], limit: Int) -> [ActionItem] {
        let items = meetings.flatMap(\.actionItems).filter { !$0.done }
        let sorted = items.sorted {
            if $0.isMine != $1.isMine { return $0.isMine }
            if $0.meetingDate != $1.meetingDate { return $0.meetingDate > $1.meetingDate }
            return $0.line < $1.line
        }
        return Array(sorted.prefix(limit))
    }

    /// A first-run user: nothing dictated, no meetings.
    static func isFirstRun(history: [HistoryEntry], meetings: [Meeting]) -> Bool {
        history.isEmpty && meetings.isEmpty
    }
}

/// Home: greeting, status, today's numbers, open action items, recent meetings, last dictation,
/// and a dictionary suggestion.
struct HomeView: View {
    let model: AppModel

    private var stats: UsageStats {
        UsageStats.compute(history: model.history.entries, meetings: model.meetings.meetings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HomeHeader(model: model)
                if HomeLogic.isFirstRun(history: model.history.entries, meetings: model.meetings.meetings) {
                    SetupChecklist(model: model)
                } else {
                    StatCards(stats: stats)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ActionItemsCard(model: model).frame(minWidth: 380)
                            RecentMeetingsCard(model: model).frame(minWidth: 300)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            ActionItemsCard(model: model)
                            RecentMeetingsCard(model: model)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            LastDictationCard(model: model).frame(minWidth: 380)
                            SuggestionCard(model: model).frame(minWidth: 300)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            LastDictationCard(model: model)
                            SuggestionCard(model: model)
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Header

private struct HomeHeader: View {
    let model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                hotkeyHint
            }
            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                hotkeyHint
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.everyMinute) { context in
                Text(verbatim: HomeLogic.greeting(for: context.date))
                    .font(.system(size: 26, weight: .bold))
            }
            HStack(spacing: 10) {
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                StatusDot(ok: model.speech.status == .ready, text: model.speech.statusDescription)
                StatusDot(
                    ok: ClaudeCLI.locate() != nil,
                    text: ClaudeCLI.locate() != nil
                        ? String(localized: "Claude Code found") : String(localized: "Claude Code not installed"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var hotkeyHint: some View {
        HStack(spacing: 6) {
            Text("Hold")
            Keycap(label: model.settings.hotkey.shortLabel)
            Text("anywhere to dictate")
        }
        .font(.caption)
    }
}

private struct StatusDot: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Theme.detected : Color.orange).frame(width: 6, height: 6)
            Text(verbatim: text)
        }
    }
}

// MARK: - Stats

private struct StatCards: View {
    let stats: UsageStats

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            StatCard(
                label: String(localized: "Dictated today"),
                value: String(localized: "\(stats.wordsDictatedToday) words"),
                detail: String(localized: "About \(stats.typingMinutesSavedToday) min of typing saved"))
            StatCard(
                label: String(localized: "Meetings today"),
                value: stats.meetingMinutesToday == 0
                    ? "\(stats.meetingsToday)"
                    : String(localized: "\(stats.meetingsToday) · \(Self.duration(stats.meetingMinutesToday))"),
                detail: stats.meetingsNeedingNotes > 0
                    ? String(localized: "\(stats.meetingsNeedingNotes) waiting for notes")
                    : stats.meetingsToday == 0
                        ? String(localized: "No meetings yet")
                        : String(localized: "None waiting for notes"))
            StatCard(
                label: String(localized: "Open action items"),
                value: "\(stats.openActionItems)",
                detail: String(localized: "\(stats.myOpenActionItems) assigned to you"))
        }
    }

    static func duration(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text(verbatim: detail).font(.caption).foregroundStyle(.primary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Action items

private struct ActionItemsCard: View {
    let model: AppModel

    var body: some View {
        let meetings = model.meetings.meetings
        let items = HomeLogic.openActionItems(meetings, limit: 4)
        let participants = Dictionary(meetings.map { ($0.id, $0.participants ?? []) }, uniquingKeysWith: { a, _ in a })
        HomeCard(title: String(localized: "Action items"), link: String(localized: "View all")) {
            model.navigation.section = .actionItems
        } content: {
            if items.isEmpty {
                Text("Nothing open. Action items from meeting notes show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Toggle(isOn: Binding(get: { item.done }, set: { _ in model.meetings.toggleTask(item) })) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Button {
                        model.mainWindow.show(meeting: item.meetingID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.text).font(.callout).foregroundStyle(.primary)
                            HStack(spacing: 4) {
                                Text(verbatim: item.meetingTitle)
                                Text(verbatim: "·")
                                Text(item.meetingDate, format: .relative(presentation: .named))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if let owner = item.owner {
                        Chip(text: owner,
                             color: Theme.color(forName: owner, participants: participants[item.meetingID] ?? []),
                             bold: true)
                    }
                }
            }
        }
    }
}

// MARK: - Recent meetings

private struct RecentMeetingsCard: View {
    let model: AppModel

    var body: some View {
        let meetings = model.meetings.meetings
        let recent = Array(meetings.filter { !$0.needsNotes }.prefix(3))
        let needsNotes = meetings.first { $0.needsNotes && !$0.lines.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent meetings").font(.system(size: 14, weight: .bold))
                Spacer()
                Button("All meetings") { model.navigation.section = .meetings }
                    .buttonStyle(.link)
                    .focusEffectDisabled()
                    .font(.caption)
            }
            if recent.isEmpty && needsNotes == nil {
                Text("Earshot offers to take notes when it detects a call.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(recent) { meeting in
                Button {
                    model.mainWindow.show(meeting: meeting.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: meeting.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(verbatim: Self.meta(meeting)).font(.caption).foregroundStyle(.secondary)
                        if let line = HomeLogic.summaryLine(from: meeting.summary) {
                            Text(verbatim: line).font(.caption).foregroundStyle(.primary.opacity(0.8)).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                }
                .buttonStyle(.plain)
            }
            if let meeting = needsNotes {
                HStack(spacing: 12) {
                    Text("\(Text(verbatim: meeting.title).fontWeight(.semibold)) was saved without notes.")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Write Notes") { model.recorder.resummarize(meeting.id) }
                        .controlSize(.small)
                        .disabled(model.recorder.state != .idle)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    static func meta(_ meeting: Meeting) -> String {
        var parts = [meeting.startedAt.formatted(
            Calendar.current.isDateInToday(meeting.startedAt) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())]
        if !meeting.platform.isEmpty { parts.append(meeting.platform) }
        if let duration = meeting.duration, duration >= 1 { parts.append(MeetingRow.minutes(duration)) }
        if let people = meeting.participants, !people.isEmpty {
            parts.append(String(localized: "\(people.count + 1) people"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Last dictation + suggestion

private struct LastDictationCard: View {
    let model: AppModel
    @State private var copied = false

    var body: some View {
        if let entry = model.history.entries.first {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text ?? entry.raw, forType: .string)
                copied = true
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last dictation").font(.callout.weight(.bold))
                        Spacer()
                        if copied {
                            Text("Copied").font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                Text(entry.date, format: .relative(presentation: .named))
                                if !entry.app.isEmpty { Text(verbatim: "· \(entry.app)") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Text(verbatim: entry.text ?? entry.raw).font(.callout).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Click to copy"))
        }
    }
}

private struct SuggestionCard: View {
    let model: AppModel

    var body: some View {
        if let suggestion = model.suggestions.ready.first {
            HStack(spacing: 12) {
                Text("You've corrected \(Text(verbatim: "“\(suggestion.word)”").fontWeight(.semibold)) \(suggestion.count) times. Add it so dictation spells it right?")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Not Now") { model.suggestions.dismiss(suggestion) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button("Add") { model.suggestions.accept(suggestion, into: model.settings) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

// MARK: - First run

private struct SetupChecklist: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        let cliFound = ClaudeCLI.locate() != nil
        HomeCard(title: String(localized: "Get set up"), link: nil, action: {}) {
            SetupRow(done: permissions.microphone, title: String(localized: "Microphone access"),
                     action: Self.grant(permissions.microphone) { permissions.requestMicrophone() })
            SetupRow(done: permissions.accessibility, title: String(localized: "Accessibility access"),
                     action: Self.grant(permissions.accessibility) { permissions.requestAccessibility() })
            SetupRow(done: permissions.inputMonitoring, title: String(localized: "Input Monitoring access"),
                     action: Self.grant(permissions.inputMonitoring) { permissions.requestInputMonitoring() })
            SetupRow(done: model.speech.status == .ready, title: model.speech.statusDescription, action: nil)
            SetupRow(done: cliFound,
                     title: cliFound
                        ? String(localized: "Claude Code found for meeting notes")
                        : String(localized: "Install Claude Code for meeting notes"),
                     action: nil)
            HStack(spacing: 6) {
                Text("Then hold")
                Keycap(label: model.settings.hotkey.shortLabel)
                Text("and speak, anywhere.")
            }
            .font(.callout)
            .padding(.top, 4)
        }
    }
}

extension SetupChecklist {
    /// A Grant button only while the permission is missing.
    static func grant(_ granted: Bool, _ request: @escaping () -> Void) -> (() -> Void)? {
        granted ? nil : request
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.detected : .secondary)
            Text(verbatim: title).font(.callout)
            Spacer()
            if let action { Button("Grant", action: action).controlSize(.small) }
        }
    }
}

// MARK: - Card shell

private struct HomeCard<Content: View>: View {
    let title: String
    let link: String?
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: title).font(.system(size: 14, weight: .bold))
                Spacer()
                if let link {
                    Button(link, action: action).buttonStyle(.link).font(.caption).focusEffectDisabled()
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}
