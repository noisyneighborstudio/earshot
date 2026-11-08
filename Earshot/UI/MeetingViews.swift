import AppKit
import SwiftUI

// Meeting list rows and the meeting detail screens (notes and live), shown by the Meetings section.

struct MeetingRow: View {
    let meeting: Meeting
    let recorder: MeetingRecorder

    private var isRecording: Bool { recorder.current?.id == meeting.id && recorder.state == .recording }
    private var isSummarizing: Bool { recorder.current?.id == meeting.id && recorder.state == .summarizing }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isRecording { Circle().fill(Theme.recording).frame(width: 8, height: 8) }
                Text(verbatim: meeting.title).fontWeight(.medium).lineLimit(1)
                if meeting.isStarred && !isRecording {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        .accessibilityLabel(Text("Starred"))
                }
            }
            Group {
                if isRecording {
                    HStack(spacing: 4) {
                        Text("Recording")
                        if !meeting.platform.isEmpty { Text(verbatim: "· \(meeting.platform) ·") }
                        Text(meeting.startedAt, style: .timer).monospacedDigit()
                    }
                    .foregroundStyle(Theme.recording)
                } else {
                    HStack(spacing: 4) {
                        Text(meeting.startedAt, format: Calendar.current.isDateInToday(meeting.startedAt)
                             ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
                        if !meeting.platform.isEmpty { Text(verbatim: "· \(meeting.platform)") }
                        if let duration = meeting.duration, duration >= 1 { Text(verbatim: "· \(Self.minutes(duration))") }
                        if isSummarizing { Text("· writing notes") }
                        else if let flag = Self.flag(for: meeting) { Text(verbatim: "· \(flag)").foregroundStyle(.orange) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }

    /// Orange status for meetings that need attention: interrupted, or saved without notes.
    static func flag(for meeting: Meeting) -> String? {
        guard meeting.needsNotes else { return nil }
        if meeting.summaryError?.localizedCaseInsensitiveContains("interrupted") == true
            || meeting.summaryError?.localizedCaseInsensitiveContains("quit while recording") == true {
            return String(localized: "interrupted")
        }
        return String(localized: "needs notes")
    }

    /// "9 sec" under a minute, else rounded minutes.
    static func minutes(_ duration: TimeInterval) -> String {
        duration < 59.5
            ? String(localized: "\(max(1, Int(duration.rounded()))) sec")
            : String(localized: "\(Int((duration / 60).rounded())) min")
    }
}

// MARK: - Notes

struct MeetingNotesView: View {
    let meeting: Meeting
    let model: AppModel

    private var store: MeetingStore { model.meetings }
    private var recorder: MeetingRecorder { model.recorder }
    private var isBusy: Bool { recorder.current?.id == meeting.id }

    private var isSummarizing: Bool { recorder.current?.id == meeting.id && recorder.state == .summarizing }
    private var notes: (title: String, body: String)? {
        guard let summary = meeting.summary else { return nil }
        var lines = summary.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].hasPrefix("# ") else { return (meeting.title, summary) }
        let title = String(lines[first].dropFirst(2))
        lines.remove(at: first)
        return (title, lines.joined(separator: "\n"))
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(verbatim: meeting.title)
                                .font(.system(size: 24, weight: .bold))
                                .textSelection(.enabled)
                            Button {
                                model.meetingActions.beginRename(meeting)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .disabled(isBusy)
                            .help(Text("Rename meeting"))
                            .accessibilityLabel(Text("Rename meeting"))
                            Spacer(minLength: 12)
                            actions
                        }
                        MeetingMeta(meeting: meeting)
                    }
                    if let error = meeting.summaryError, !isSummarizing {
                        Label {
                            Text(verbatim: error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    if isSummarizing {
                        Label("Claude is writing notes…", systemImage: "sparkles").foregroundStyle(.secondary)
                    } else if let notes {
                        NotesMarkdown(markdown: notes.body, participants: meeting.participants ?? []) { index in
                            toggle(bodyLine: index)
                        }
                    }
                    Text("Transcribed on this Mac · Notes written by Claude")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            TranscriptPanel(meeting: meeting)
                .frame(width: 330)
        }
    }

    /// Star, Share, Copy and More, beside the title (no window toolbar, so the header stays put).
    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                store.toggleStar(meeting.id)
            } label: {
                Image(systemName: meeting.isStarred ? "star.fill" : "star")
                    .foregroundStyle(meeting.isStarred ? Color.yellow : Color.secondary)
                    .frame(width: 30, height: 28)
            }
            .disabled(isBusy)
            .help(Text(meeting.isStarred ? "Unstar" : "Star"))
            .accessibilityLabel(Text(meeting.isStarred ? "Unstar" : "Star"))
            ShareLink(item: meeting.markdown, subject: Text(verbatim: meeting.title)) {
                Image(systemName: "square.and.arrow.up").frame(width: 30, height: 28)
            }
            .help(Text("Share notes and transcript"))
            .accessibilityLabel(Text("Share"))
            Button {
                model.meetingActions.copyNotes(meeting)
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 30, height: 28)
            }
            .help(Text("Copy notes and transcript as Markdown"))
            .accessibilityLabel(Text("Copy Notes"))
            Menu {
                MeetingActionsMenu(meeting: meeting, model: model)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("More actions"))
            .accessibilityLabel(Text("More actions"))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.system(size: 15))
    }

    /// The body drops the title line, so its line numbers are offset by one in the saved notes.
    private func toggle(bodyLine index: Int) {
        guard let summary = meeting.summary else { return }
        let lines = summary.components(separatedBy: "\n")
        let titleIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let offset = titleIndex.map { lines[$0].hasPrefix("# ") && $0 <= index ? 1 : 0 } ?? 0
        var updated = meeting
        updated.toggleTask(atLine: index + offset)
        store.save(updated)
    }
}

private struct MeetingMeta: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: when).font(.caption).foregroundStyle(.secondary)
            if let folder = meeting.folder { Chip(text: folder, color: .secondary) }
            Chip(text: String(localized: "Me"), color: Theme.me)
            ForEach(meeting.participants ?? [], id: \.self) { name in
                Chip(text: name, color: Theme.color(forName: name, participants: meeting.participants ?? []))
            }
        }
    }

    private var when: String {
        var parts: [String] = []
        if !meeting.platform.isEmpty { parts.append(meeting.platform) }
        let start = meeting.startedAt.formatted(.dateTime.month().day().hour().minute())
        parts.append(meeting.endedAt.map { "\(start)–\($0.formatted(.dateTime.hour().minute()))" } ?? start)
        return parts.joined(separator: " · ")
    }
}

/// The notes Markdown: section headings, bullets, checkable action items with owner chips.
private struct NotesMarkdown: View {
    let markdown: String
    let participants: [String]
    let onToggle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { index, raw in
                row(index: index, line: raw.trimmingCharacters(in: .whitespaces))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(index: Int, line: String) -> some View {
        if line.hasPrefix("## ") || line.hasPrefix("# ") {
            Text(verbatim: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            let done = !line.hasPrefix("- [ ] ")
            let (owner, task) = Self.split(String(line.dropFirst(6)))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(isOn: Binding(get: { done }, set: { _ in onToggle(index) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                if let owner { Chip(text: owner, color: Theme.color(forName: owner, participants: participants), bold: true) }
                inline(task).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                inline(String(line.dropFirst(2)))
            }
        } else if !line.isEmpty {
            inline(line).lineSpacing(3)
        }
    }

    /// "Owner: task" → owner chip + task, when the prefix looks like a name.
    static func split(_ item: String) -> (String?, String) {
        guard let colon = item.range(of: ": "), item.distance(from: item.startIndex, to: colon.lowerBound) <= 32 else {
            return (nil, item)
        }
        return (String(item[..<colon.lowerBound]), String(item[colon.upperBound...]))
    }

    private func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed).font(.system(size: 14))
    }
}

private struct TranscriptPanel: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.callout.weight(.bold))
                Spacer()
                Text("\(meeting.lines.count) lines").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if meeting.lines.isEmpty {
                        Text("Nothing was transcribed.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(meeting.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: line.label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.color(for: line, participants: meeting.participants ?? []))
                                Text(verbatim: Meeting.timestamp(line.start))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: line.text).font(.callout).lineSpacing(2)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .background(.background.secondary)
    }
}

// MARK: - Live

struct LiveMeetingView: View {
    let meeting: Meeting
    let recorder: MeetingRecorder

    /// Everyone seen so far, sorted so colours stay put as people join.
    private var participants: [String] {
        Array(Set(meeting.lines.compactMap(\.name) + recorder.speakingNow)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.recording).frame(width: 8, height: 8)
                        .shadow(color: Theme.recording.opacity(0.5), radius: 3)
                    Text("Recording")
                    Text(meeting.startedAt, style: .timer).monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.recording)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.recording.opacity(0.12), in: Capsule())
                Text(verbatim: subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    recorder.stop()
                } label: {
                    Label("Stop & Write Notes", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.recording)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: meeting.title).font(.system(size: 24, weight: .bold))
                FlowChips(participants: participants, speaking: Set(recorder.speakingNow))
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if meeting.lines.isEmpty && recorder.pending.isEmpty {
                            Text("Listening…").foregroundStyle(.secondary)
                        }
                        ForEach(Array(meeting.lines.enumerated()), id: \.offset) { _, line in
                            LiveLine(time: Meeting.timestamp(line.start), name: line.label,
                                     color: Theme.color(for: line, participants: participants), text: line.text, pending: false)
                        }
                        ForEach(pendingLines, id: \.name) { line in
                            LiveLine(time: "", name: line.name, color: line.color, text: line.text, pending: true)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 18)
                }
                .onChange(of: meeting.lines.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: recorder.pending) { proxy.scrollTo("end", anchor: .bottom) }
            }

            Divider()
            Text("Names come from the call app's active-speaker label; lines it couldn't match say \"Others\". Claude writes notes when you stop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
                .padding(.vertical, 10)
        }
    }

    private var subtitle: String {
        let source = String(localized: "Your mic and call audio, transcribed on this Mac")
        return meeting.platform.isEmpty ? source : "\(meeting.platform) · \(source)"
    }

    private var pendingLines: [(name: String, color: Color, text: String)] {
        var lines: [(String, Color, String)] = []
        if let mine = recorder.pending[.me] { lines.append((String(localized: "Me"), Theme.me, mine)) }
        if let theirs = recorder.pending[.others] {
            let name = recorder.speakingNow.first
            lines.append((name ?? String(localized: "Others"),
                          name.map { Theme.color(forName: $0, participants: participants) } ?? Theme.unknown, theirs))
        }
        return lines
    }
}

private struct FlowChips: View {
    let participants: [String]
    let speaking: Set<String>

    var body: some View {
        HStack(spacing: 10) {
            ParticipantChip(name: String(localized: "Me"), initials: String(localized: "Me"), color: Theme.me, speaking: false)
            ForEach(participants, id: \.self) { name in
                ParticipantChip(name: name, initials: Self.initials(name),
                                color: Theme.color(forName: name, participants: participants),
                                speaking: speaking.contains(name))
            }
        }
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct ParticipantChip: View {
    let name: String
    let initials: String
    let color: Color
    let speaking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color.opacity(0.16)).frame(width: 26, height: 26)
                .overlay(Text(verbatim: initials).font(.system(size: 10, weight: .bold)).foregroundStyle(color))
            Text(verbatim: name).font(.callout.weight(speaking ? .semibold : .regular))
            if speaking {
                LevelMeter(level: 0.7, color: color)
                    .frame(width: 22, height: 14)
                    .scaleEffect(0.7)
                    .accessibilityLabel(Text("speaking"))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(speaking ? AnyShapeStyle(color.opacity(0.1)) : AnyShapeStyle(.quaternary), in: Capsule())
        .overlay(Capsule().strokeBorder(speaking ? color.opacity(0.6) : .clear, lineWidth: 2))
        .animation(.easeInOut(duration: 0.2), value: speaking)
    }
}

private struct LiveLine: View {
    let time: String
    let name: String
    let color: Color
    let text: String
    let pending: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(verbatim: name).font(.callout.weight(.bold)).foregroundStyle(color).lineLimit(1).frame(width: 110, alignment: .leading)
            Text("\(Text(verbatim: text))\(Text(verbatim: pending ? " ▍" : "").foregroundStyle(color))")
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(pending ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}
