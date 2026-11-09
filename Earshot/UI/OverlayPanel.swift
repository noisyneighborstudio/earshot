import AppKit
import SwiftUI

/// A click-through, non-activating pill near the bottom of the screen. It never takes focus,
/// so the paste lands in the app the user was typing in.
@MainActor
final class OverlayPanel {
    private let panel: NSPanel
    private static let size = CGSize(width: 560, height: 72)
    /// Raised above the recording pill while a meeting records.
    var lift: CGFloat = 0

    init(controller: DictationController) {
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
        panel.ignoresMouseEvents = true
        // Undo is clickable without taking focus from the user's app.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(controller: controller))
    }

    func setInteractive(_ interactive: Bool) {
        panel.ignoresMouseEvents = !interactive
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 40 + lift))
        }
        panel.orderFrontRegardless()
    }
}

/// Dark glass so it reads over any app, light or dark.
struct OverlayView: View {
    let controller: DictationController
    private static let live = Color(red: 0.35, green: 0.78, blue: 0.98)
    /// Command mode looks different, so it's never mistaken for typing.
    private static let command = Color(red: 0.78, green: 0.55, blue: 1)

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, trailingPadding)
        .frame(minHeight: 44)
        .frame(maxWidth: 480)
        .background(Color(white: 0.11, opacity: 0.86), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.25), radius: 15, y: 8)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func symbol(_ kind: DictationController.Notice.Kind) -> String {
        switch kind {
        case .clipboard: "doc.on.clipboard"
        case .error: "exclamationmark.circle"
        case .done: "checkmark.circle.fill"
        case .question: "questionmark.circle.fill"
        }
    }

    private static func tint(_ kind: DictationController.Notice.Kind) -> Color {
        switch kind {
        case .clipboard: .orange
        case .error: Color(red: 1, green: 0.41, blue: 0.38)
        case .done, .question: command
        }
    }

    private var trailingPadding: CGFloat {
        if case .listening(handsFree: true) = controller.phase { return 8 }
        return 18
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .listening(let handsFree):
            LevelMeter(level: controller.level, color: controller.isCommand ? Self.command : Self.live)
            if controller.isCommand {
                Text("Command")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Self.command.opacity(0.3), in: Capsule())
            }
            if handsFree {
                Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
                Text(controller.partial.isEmpty ? String(localized: "Hands-free") : controller.partial)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.white.opacity(0.82))
                HStack(spacing: 4) {
                    Text("Press")
                    Text(verbatim: "fn").fontWeight(.semibold)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                    Text("to finish")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.14), in: Capsule())
            } else if controller.partial.isEmpty {
                Text("Listening…").foregroundStyle(.white.opacity(0.82))
            } else {
                Text(verbatim: controller.partial)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
            Text(controller.askingClaude ? "Asking Claude…" : controller.isCommand ? "Working…" : "Writing…").foregroundStyle(.white.opacity(0.82))
        case .idle:
            if let notice = controller.notice {
                Image(systemName: Self.symbol(notice.kind))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.tint(notice.kind))
                Text(verbatim: notice.text).lineLimit(2)
                if notice.learned != nil {
                    Button("Undo") { controller.forgetLearned() }.buttonStyle(PillButton())
                }
                ForEach(Array(notice.options.enumerated()), id: \.offset) { index, option in
                    Button { controller.choose(index) } label: { Text(verbatim: option).lineLimit(1) }
                        .buttonStyle(PillButton())
                }
            }
        }
    }
}

/// A small capsule button on the overlay: Undo, or an answer to Claude's question.
private struct PillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.16), in: Capsule())
    }
}
