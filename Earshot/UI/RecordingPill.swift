import AppKit
import SwiftUI

/// A floating bar at the bottom of the screen while a meeting or note records (including
/// automatic recordings): what's recording, for how long, who's talking, and Stop.
/// Clickable, but it never takes focus away from the app you're in.
@MainActor
final class RecordingPanel {
    static let height: CGFloat = 64
    private let panel: NSPanel
    private static let size = CGSize(width: 480, height: height)

    init(model: AppModel) {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingPill(model: model))
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            panel.orderOut(nil)
            return
        }
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 32))
        }
        panel.orderFrontRegardless()
    }
}

private struct RecordingPill: View {
    let model: AppModel
    @State private var pulse = false

    private var recorder: MeetingRecorder { model.recorder }

    var body: some View {
        HStack(spacing: 12) {
            if recorder.state == .summarizing {
                ProgressView().controlSize(.small).tint(.white)
            } else if recorder.current?.isNote == true {
                // Mic only: show it's hearing you.
                LevelMeter(level: recorder.micLevel, color: Theme.recording)
            } else {
                Circle()
                    .fill(Theme.recording)
                    .frame(width: 10, height: 10)
                    .opacity(pulse ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .accessibilityHidden(true)
            }

            Button {
                if let id = recorder.current?.id { model.mainWindow.show(meeting: id) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: recorder.current?.title ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    detail
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Show live transcript"))

            if recorder.state == .recording {
                Button {
                    recorder.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Theme.recording, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(Text("Stop and write notes"))
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 48)
        .frame(maxWidth: 460)
        .background(Color(white: 0.11, opacity: 0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var detail: some View {
        switch recorder.state {
        case .recording:
            HStack(spacing: 4) {
                if let started = recorder.current?.startedAt {
                    Text(started, style: .timer).monospacedDigit()
                }
                Text(verbatim: "·")
                if let speaking = recorder.speakingNow.first {
                    Text("\(speaking) speaking")
                } else if recorder.current?.isNote == true {
                    Text("Mic only")
                } else {
                    Text("Your mic and the call audio")
                }
            }
        case .summarizing:
            Text("Claude is writing notes…")
        case .idle:
            EmptyView()
        }
    }
}
