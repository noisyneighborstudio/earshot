import AppKit
import SwiftUI

/// The menu-bar tray.
struct MenuView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    private var settings: AppSettings { model.settings }
    private var permissions: Permissions { model.permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !permissions.allGranted {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        PermissionRow(title: "Microphone", granted: permissions.microphone, request: permissions.requestMicrophone)
                        PermissionRow(title: "Accessibility", granted: permissions.accessibility, request: permissions.requestAccessibility)
                        PermissionRow(title: "Input Monitoring", granted: permissions.inputMonitoring, request: permissions.requestInputMonitoring)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Hold")
                        Keycap(label: settings.hotkey.shortLabel)
                        Text("to dictate")
                    }
                    .font(.callout.weight(.semibold))
                    Text("Double-tap for hands-free · Esc cancels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.speech.status != .ready {
                        Label {
                            Text(verbatim: model.speech.statusDescription)
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if settings.meetingMode != .off && ClaudeCLI.locate() == nil {
                        Label("Install Claude Code for meeting notes.", systemImage: "terminal")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Card { MeetingCard(model: model) }

            if !model.history.entries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 2)
                    ForEach(model.history.entries.prefix(3)) { HistoryRow(entry: $0) }
                }
            }

            Divider()
            HStack(spacing: 2) {
                FooterIcon(title: "Open Earshot", systemImage: "macwindow") { model.mainWindow.show(section: .home) }
                FooterIcon(title: "Meetings", systemImage: "person.2.wave.2") { model.mainWindow.show(section: .meetings) }
                FooterIcon(title: "Settings", systemImage: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                FooterIcon(title: "Quit Earshot", systemImage: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph()
            Text("Earshot").font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusLabel)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 4)
    }

    private var statusLabel: String {
        if model.recorder.state == .recording { return String(localized: "Recording") }
        switch model.controller.phase {
        case .idle: return String(localized: "Ready")
        case .listening: return String(localized: "Listening")
        case .processing: return String(localized: "Writing")
        }
    }

    private var statusColor: Color {
        if model.recorder.state == .recording { return Theme.recording }
        return model.controller.phase == .idle ? Theme.detected : .accentColor
    }
}

/// An icon-only footer button with a hover highlight; the title is its tooltip and accessibility label.
private struct FooterIcon: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

private struct MeetingCard: View {
    let model: AppModel
    private var recorder: MeetingRecorder { model.recorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    title.font(.callout.weight(.semibold))
                    subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                action
            }
            if recorder.state == .idle && RecordPrompt.showsComputerAudioOption(model) {
                ComputerAudioToggle(settings: model.settings).controlSize(.small)
            }
            if let error = recorder.lastError {
                Text(verbatim: error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var icon: some View {
        let (symbol, color): (String, Color) = switch recorder.state {
        case .recording: ("record.circle.fill", Theme.recording)
        case .summarizing: ("sparkles", .accentColor)
        case .idle: model.detector.current == nil ? ("mic.fill", .accentColor) : ("phone.fill", Theme.detected)
        }
        return Circle()
            .fill(color.opacity(0.14))
            .frame(width: 32, height: 32)
            .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var title: some View {
        switch recorder.state {
        case .recording: Text(verbatim: recorder.current?.title ?? "")
        case .summarizing: Text("Writing meeting notes…")
        case .idle: Text(verbatim: RecordPrompt.title(model))
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch recorder.state {
        case .recording:
            if let started = recorder.current?.startedAt {
                HStack(spacing: 4) {
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
            Button("Stop") { recorder.stop() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.recording)
                .controlSize(.small)
        case .summarizing:
            ProgressView().controlSize(.small)
        case .idle:
            Button(RecordPrompt.buttonTitle(model)) { model.recordMeeting() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted { Button("Grant", action: request).controlSize(.small) }
        }
        .font(.callout)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text ?? entry.raw, forType: .string)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.text ?? entry.raw)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(entry.date, style: .relative)
                    if !entry.app.isEmpty { Text(verbatim: "· \(entry.app)") }
                    if entry.error != nil { Text("· not inserted").foregroundStyle(.orange) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("Click to copy"))
    }
}
