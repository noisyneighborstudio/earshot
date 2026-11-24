import AppKit
import SwiftUI

/// A floating pill while a meeting or note records (including automatic recordings): what's
/// recording, for how long, who's talking, and Stop. In Ask mode it also offers to record a
/// detected call. Draggable to any screen edge (top, bottom, left, right) with live snap preview.
/// Clickable, but it never takes focus away from the app you're in.
@MainActor
final class RecordingPanel {
    static let height: CGFloat = 64

    private let panel: NSPanel
    private let preview: DockPreviewPanel
    private let model: AppModel
    private let drag = PillDragState()
    private var dockedScreenID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        self.preview = DockPreviewPanel()
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: model.settings.pillDock.panelSize),
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

        drag.onDragChanged = { [weak self] in self?.handleDragChanged() }
        drag.onDragEnded = { [weak self] in self?.handleDragEnded() }
        panel.contentView = NSHostingView(rootView: RecordingPill(model: model, drag: drag))

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.drag.isDragging else { return }
                self.snap(to: self.model.settings.pillDock, animated: false)
            }
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            if drag.isDragging {
                drag.end()
                NSCursor.pop()
            }
            preview.hide()
            panel.orderOut(nil)
            return
        }
        snap(to: model.settings.pillDock, animated: false)
        panel.orderFrontRegardless()
    }

    func snap(to dock: PillDock, on screen: NSScreen? = nil, animated: Bool) {
        guard let targetScreen = screen ?? preferredScreen() else { return }
        dockedScreenID = Self.displayID(of: targetScreen)
        let targetFrame = dock.frame(in: targetScreen.visibleFrame)
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func handleDragChanged() {
        let mouse = NSEvent.mouseLocation
        if !drag.isDragging {
            drag.begin(mouse: mouse, origin: panel.frame.origin)
            NSCursor.closedHand.push()
        }
        let origin = CGPoint(
            x: drag.startOrigin.x + (mouse.x - drag.startMouse.x),
            y: drag.startOrigin.y + (mouse.y - drag.startMouse.y)
        )
        panel.setFrameOrigin(origin)

        if let screen = screenContaining(mouse) {
            let targetDock = PillDock.nearest(to: mouse, in: screen.visibleFrame)
            preview.show(dock: targetDock, in: screen.visibleFrame, below: panel)
        }
    }

    private func handleDragEnded() {
        guard drag.isDragging else { return }
        let mouse = NSEvent.mouseLocation
        drag.end()
        NSCursor.pop()
        preview.hide()

        let screen = screenContaining(mouse) ?? preferredScreen()
        guard let screen else { return }
        let targetDock = PillDock.nearest(to: mouse, in: screen.visibleFrame)
        dockedScreenID = Self.displayID(of: screen)
        if model.settings.pillDock != targetDock {
            // onPillDockChange animates the snap after updating settings.
            model.settings.pillDock = targetDock
        } else {
            snap(to: targetDock, on: screen, animated: true)
        }
    }

    private func preferredScreen() -> NSScreen? {
        if let dockedScreenID,
           let matched = NSScreen.screens.first(where: { Self.displayID(of: $0) == dockedScreenID }) {
            return matched
        }
        return panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? preferredScreen()
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Coordinates drag state between the SwiftUI pill and its NSPanel, and suppresses accidental
/// button clicks on release right after a drag.
@MainActor
@Observable
private final class PillDragState {
    private(set) var isDragging = false
    @ObservationIgnored var startMouse: CGPoint = .zero
    @ObservationIgnored var startOrigin: CGPoint = .zero
    @ObservationIgnored private var lastDragEndedAt: ContinuousClock.Instant?
    @ObservationIgnored var onDragChanged: (() -> Void)?
    @ObservationIgnored var onDragEnded: (() -> Void)?

    var suppressClick: Bool {
        if isDragging { return true }
        guard let lastDragEndedAt else { return false }
        return lastDragEndedAt.duration(to: .now) < .milliseconds(250)
    }

    func begin(mouse: CGPoint, origin: CGPoint) {
        startMouse = mouse
        startOrigin = origin
        isDragging = true
    }

    func end() {
        isDragging = false
        lastDragEndedAt = .now
    }
}

/// Translucent drop-zone ghost showing which screen edge the pill will snap to on release.
@MainActor
private final class DockPreviewPanel {
    @Observable
    final class State {
        var dock: PillDock = .bottom
    }

    private let panel: NSPanel
    private let state = State()

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: PillDock.bottom.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DockPreviewView(state: state))
    }

    func show(dock: PillDock, in visibleFrame: CGRect, below owner: NSPanel) {
        let target = dock.frame(in: visibleFrame)
        let wasVisible = panel.isVisible
        let changed = state.dock != dock || panel.frame != target
        state.dock = dock
        if !wasVisible {
            panel.setFrame(target, display: true)
            panel.order(.below, relativeTo: owner.windowNumber)
        } else if changed {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct DockPreviewView: View {
    let state: DockPreviewPanel.State

    var body: some View {
        Group {
            if state.dock.isHorizontal {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .overlay { label }
                    .frame(width: 460, height: 48)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    )
                    .overlay { label }
                    .frame(width: 240, height: 108)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var label: some View {
        Label("Dock \(state.dock.label)", systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private var icon: String {
        switch state.dock {
        case .top: "rectangle.topthird.inset.filled"
        case .bottom: "rectangle.bottomthird.inset.filled"
        case .left: "rectangle.leadingthird.inset.filled"
        case .right: "rectangle.trailingthird.inset.filled"
        }
    }
}

private struct RecordingPill: View {
    let model: AppModel
    let drag: PillDragState
    @State private var pulse = false

    private var recorder: MeetingRecorder { model.recorder }
    private var dock: PillDock { model.settings.pillDock }

    var body: some View {
        Group {
            if dock.isHorizontal {
                horizontalBody
            } else {
                sideBody
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { _ in drag.onDragChanged?() }
                .onEnded { _ in drag.onDragEnded?() }
        )
        .contextMenu {
            ForEach(PillDock.allCases) { edge in
                Button {
                    model.settings.pillDock = edge
                } label: {
                    if dock == edge {
                        Label("Dock \(edge.label)", systemImage: "checkmark")
                    } else {
                        Text("Dock \(edge.label)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var horizontalBody: some View {
        Group {
            if recorder.state == .idle, let call = model.callPrompt {
                CallPromptHorizontal(model: model, call: call, drag: drag)
            } else {
                recordingHorizontal
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 48)
        .frame(maxWidth: 460)
        .background(Color(white: 0.11, opacity: 0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .contentShape(Capsule())
    }

    private var sideBody: some View {
        Group {
            if recorder.state == .idle, let call = model.callPrompt {
                CallPromptSide(model: model, call: call, drag: drag)
            } else {
                recordingSide
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 240, height: 108)
        .background(Color(white: 0.11, opacity: 0.88), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var recordingHorizontal: some View {
        HStack(spacing: 10) {
            DragGrip()
            indicator
            titleButton
            if recorder.state == .recording { stopButton(fullWidth: false) }
        }
    }

    private var recordingSide: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                indicator
                titleButton
                DragGrip()
            }
            if recorder.state == .recording { stopButton(fullWidth: true) }
        }
    }

    @ViewBuilder private var indicator: some View {
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
    }

    private var titleButton: some View {
        Button {
            guard !drag.suppressClick else { return }
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
        .help(Text("Show live transcript · Drag to dock"))
    }

    private func stopButton(fullWidth: Bool) -> some View {
        Button {
            guard !drag.suppressClick else { return }
            recorder.stop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: 28)
                .background(Theme.recording, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("Stop and write notes"))
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

/// Subtle 6-dot drag handle signaling the pill can be dragged to another edge.
private struct DragGrip: View {
    var body: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(.white.opacity(0.35))
        .help(Text("Drag to dock (top, bottom, left, right)"))
        .accessibilityHidden(true)
    }
}

/// "Zoom call detected · Not Now · Record" (horizontal dock).
private struct CallPromptHorizontal: View {
    let model: AppModel
    let call: DetectedCall
    let drag: PillDragState

    var body: some View {
        HStack(spacing: 10) {
            DragGrip()
            Image(systemName: "phone.fill")
                .foregroundStyle(Theme.detected)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(call.platform.name) call detected")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("Record and summarize it? Let others know you're transcribing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Not Now") {
                guard !drag.suppressClick else { return }
                model.dismissCallPrompt()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.7))

            Button {
                guard !drag.suppressClick else { return }
                model.recordMeeting()
            } label: {
                Label("Record", systemImage: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.recording, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("Record the call and write notes"))
        }
    }
}

/// Compact side-docked call prompt (left/right edges).
private struct CallPromptSide: View {
    let model: AppModel
    let call: DetectedCall
    let drag: PillDragState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "phone.fill")
                    .foregroundStyle(Theme.detected)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(call.platform.name) call detected")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Record and summarize it?")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DragGrip()
            }
            HStack(spacing: 10) {
                Button("Not Now") {
                    guard !drag.suppressClick else { return }
                    model.dismissCallPrompt()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(.white.opacity(0.1), in: Capsule())

                Button {
                    guard !drag.suppressClick else { return }
                    model.recordMeeting()
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(Theme.recording, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(Text("Record the call and write notes"))
            }
        }
    }
}
