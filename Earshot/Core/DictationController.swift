import AppKit
import os

/// The dictation state machine:
/// hold hotkey → talk → release → on-device transcript → paste.
/// A quick double-tap locks hands-free mode; press again to finish. Escape cancels.
/// Adding ⌃ makes it a voice command: the words run a command in the frontmost app instead.
@MainActor
@Observable
final class DictationController {
    struct Notice: Equatable {
        enum Kind { case clipboard, error, done }
        let text: String
        let kind: Kind
        /// A phrase just learned: the toast offers Undo.
        var learned: VoiceCommands.Learned?
    }

    enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        case processing
    }

    private(set) var phase: Phase = .idle { didSet { stateChanged() } }
    private(set) var level: Float = 0
    private(set) var partial = ""
    /// This press is a voice command (hotkey + ⌃), not dictation.
    private(set) var isCommand = false
    var askingClaude: Bool { commands.askingClaude }
    private(set) var notice: Notice? { didSet { stateChanged() } }

    @ObservationIgnored var onOverlayVisibilityChange: ((Bool) -> Void)?
    /// The overlay takes clicks only while it offers Undo; otherwise clicks pass through.
    @ObservationIgnored var onOverlayInteractiveChange: ((Bool) -> Void)?
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    /// After a paste landed: the inserted text and where it went (for correction tracking).
    @ObservationIgnored var onInserted: ((String, FocusContext) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let speech: SpeechEngine
    @ObservationIgnored private let commands: VoiceCommands
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "dictation")

    private struct Session {
        let audio: AudioCapture
        let transcription: TranscriptionSession
        let context: FocusContext
        /// Set once ⌃ joins: the app the command acts on.
        var command: CommandContext?
    }

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Bumped per dictation; async results from an older one are discarded.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastQuickTap: ContinuousClock.Instant?
    @ObservationIgnored private var noticeGeneration = 0

    private static let holdThreshold: Duration = .milliseconds(300)
    private static let doubleTapWindow: Duration = .milliseconds(500)

    init(settings: AppSettings, history: HistoryStore, speech: SpeechEngine, commands: VoiceCommands) {
        self.settings = settings
        self.history = history
        self.speech = speech
        self.commands = commands
    }

    func handle(_ event: HotkeyEvent) {
        switch (event, phase) {
        case (.press(let at), .idle):
            begin(at: at)
        case (.press, .listening(handsFree: true)):
            finish()
        case (.release(let at), .listening(handsFree: false)):
            released(at: at)
        case (.chord, .listening(handsFree: false)):
            cancel()
        case (.command, .listening):
            enterCommandMode()
        case (.escape, .listening), (.escape, .processing):
            cancel()
        default:
            break
        }
    }

    private func released(at: ContinuousClock.Instant) {
        guard let pressedAt else { return }
        if pressedAt.duration(to: at) >= Self.holdThreshold {
            finish()
        } else if let lastQuickTap, lastQuickTap.duration(to: at) < Self.doubleTapWindow {
            self.lastQuickTap = nil
            phase = .listening(handsFree: true)
        } else {
            // A lone quick tap isn't dictation; remember it in case a second tap follows.
            lastQuickTap = at
            cancel()
        }
    }

    private func enterCommandMode() {
        guard session != nil, session?.command == nil else { return }
        let context = CommandContext.capture()
        session?.command = context
        session?.transcription.expect(commands.vocabulary(for: context))
        isCommand = true
    }

    // MARK: - Pipeline

    private func begin(at: ContinuousClock.Instant) {
        generation += 1
        let current = generation
        guard let transcription = speech.makeSession(contextualStrings: settings.dictionary, onTranscript: { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.partial = text.display
                }
            }
        }) else {
            show(speech.statusDescription)
            return
        }
        notice = nil
        partial = ""
        level = 0
        isCommand = false

        let audio = AudioCapture()
        do {
            try audio.start(format: transcription.format) { [weak self] buffer, level in
                transcription.append(buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == current else { return }
                        self.level = level
                    }
                }
            }
        } catch {
            transcription.cancel()
            show(error.localizedDescription)
            return
        }

        pressedAt = at
        phase = .listening(handsFree: false)
        play("Tink")
        // After audio is running so a slow AX query can't clip the first word.
        session = Session(
            audio: audio, transcription: transcription, context: FocusReader.capture())
    }

    private func finish() {
        guard let session else { return }
        self.session = nil
        session.audio.stop()
        phase = .processing
        play("Pop")

        let current = generation
        let context = session.context
        if let command = session.command {
            work = Task { await runCommand(session.transcription, in: command, generation: current) }
            return
        }

        work = Task {
            do {
                let text = try await session.transcription.finish().text
                guard current == generation else { return }
                guard !text.isEmpty else {
                    phase = .idle
                    return
                }
                // Checked on the main actor right before pasting, so a cancel can't slip in between.
                guard current == generation, !Task.isCancelled else { return }
                let inserted = Spacing.join(before: context.before, insert: text)
                let outcome = await inserter.insert(inserted)
                if outcome == .pasted { onInserted?(inserted, context) }
                history.add(HistoryEntry(app: context.appName, raw: text, text: text))
                guard current == generation else { return }
                phase = .idle
                if outcome == .leftOnClipboard {
                    show(String(localized: "Couldn't paste. Text copied — press ⌘V."), kind: .clipboard)
                }
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                log.error("dictation failed: \(error.localizedDescription)")
                phase = .idle
                show(error.localizedDescription)
            }
        }
    }

    private func runCommand(_ transcription: TranscriptionSession, in context: CommandContext, generation current: Int) async {
        do {
            let text = try await transcription.finish().text
            guard current == generation, !Task.isCancelled else { return }
            guard !text.isEmpty else {
                phase = .idle
                return
            }
            let outcome = await commands.run(text, in: context)
            guard current == generation else { return }
            phase = .idle
            switch outcome {
            case .done(let what, nil): show(what, kind: .done)
            case .done(let what, let learned?):
                show(String(localized: "\(what) · Remembered “\(learned.phrase)”"), kind: .done, learned: learned, for: .seconds(6))
            case .added(let name, let learned):
                show(String(localized: "Added “\(name)” · say “\(learned.phrase)”"), kind: .done, learned: learned, for: .seconds(8))
            case .noMatch(let message), .failed(let message): show(message, for: .seconds(5))
            }
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            phase = .idle
            show(error.localizedDescription)
        }
    }

    /// Undo on the "Remembered …" toast.
    func forgetLearned() {
        guard let learned = notice?.learned else { return }
        do {
            try commands.forget(learned)
            show(String(localized: "Forgot “\(learned.phrase)”"), kind: .done)
        } catch {
            show(error.localizedDescription)
        }
    }

    private func cancel() {
        generation += 1
        work?.cancel()
        work = nil
        if let session {
            session.audio.stop()
            session.transcription.cancel()
            self.session = nil
        }
        phase = .idle
    }

    // MARK: - Feedback

    private func show(_ message: String, kind: Notice.Kind = .error, learned: VoiceCommands.Learned? = nil,
                      for duration: Duration = .seconds(3)) {
        noticeGeneration += 1
        let current = noticeGeneration
        notice = Notice(text: message, kind: kind, learned: learned)
        Task {
            try? await Task.sleep(for: duration)
            if noticeGeneration == current { notice = nil }
        }
    }

    private func play(_ sound: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(sound))?.play()
    }

    private func stateChanged() {
        onOverlayVisibilityChange?(phase != .idle || notice != nil)
        onOverlayInteractiveChange?(phase == .idle && notice?.learned != nil)
        onActiveChange?(phase != .idle)
    }
}
