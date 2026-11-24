import AppKit

/// Composition root: builds the services once and wires them together.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let history = HistoryStore()
    let permissions = Permissions()
    let speech = SpeechEngine()
    let meetings = MeetingStore()
    let detector = MeetingDetector()
    let suggestions = DictionarySuggestions()
    let navigation = AppNavigation()
    let meetingActions = MeetingActions()
    let updater = Updater()
    let commands = VoiceCommands()
    let controller: DictationController
    let recorder: MeetingRecorder
    /// A detected call waiting on "Record?" (Ask mode). Shown in the floating pill, not a
    /// notification: macOS hides banners while the screen is shared, which calls often are.
    private(set) var callPrompt: DetectedCall?

    @ObservationIgnored let mainWindow = MainWindow()
    @ObservationIgnored private let corrections: CorrectionTracker
    @ObservationIgnored private let overlay: OverlayPanel
    @ObservationIgnored private let hotkeys: HotkeyMonitor
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var terminationSignal: DispatchSourceSignal?
    @ObservationIgnored private var reopenHandler: ReopenHandler?
    @ObservationIgnored private var recordingPanel: RecordingPanel?

    init() {
        let settings = self.settings
        let speech = self.speech
        let detector = self.detector
        let controller = DictationController(settings: settings, history: history, speech: speech, commands: commands)
        let recorder = MeetingRecorder(speech: speech, store: meetings, settings: settings)
        let mainWindow = self.mainWindow
        let corrections = CorrectionTracker(suggestions: suggestions, settings: settings)
        let overlay = OverlayPanel(controller: controller)
        let notifier = self.notifier
        // GCD main queue is FIFO, so key down/up are handled in the order the tap saw them.
        let hotkeys = HotkeyMonitor(hotkey: settings.hotkey) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.handle(event) } }
        }

        controller.onOverlayVisibilityChange = { overlay.setVisible($0) }
        controller.onOverlayInteractiveChange = { overlay.setInteractive($0) }
        controller.onActiveChange = { hotkeys.swallowEscape = $0 }
        controller.onInserted = { corrections.didInsert($0, context: $1) }
        settings.onHotkeyChange = { hotkeys.hotkey = $0 }
        settings.onLocaleChange = { speech.prepare(localeIdentifier: $0) }
        settings.onMeetingModeChange = { $0 == .off ? detector.stop() : detector.start() }

        notifier.onOpenMeeting = { mainWindow.show(meeting: $0) }
        recorder.onNotesReady = { notifier.notesReady($0) }

        self.controller = controller
        self.recorder = recorder
        self.corrections = corrections
        self.overlay = overlay
        self.hotkeys = hotkeys

        // Quit, or a kill: save the in-progress meeting first.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { recorder.persistForTermination() } }
        signal(SIGTERM, SIG_IGN)
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal.setEventHandler {
            MainActor.assumeIsolated { recorder.persistForTermination() }
            exit(0)
        }
        terminationSignal.resume()
        self.terminationSignal = terminationSignal

        mainWindow.model = self
        reopenHandler = ReopenHandler { mainWindow.show() }
        let recordingPanel = RecordingPanel(model: self)
        self.recordingPanel = recordingPanel
        recorder.onStateChange = { [weak self] _ in self?.updatePanel() }
        settings.onPillDockChange = { [weak self] dock in
            guard let self else { return }
            self.recordingPanel?.snap(to: dock, animated: true)
            self.updateOverlayLift()
        }
        detector.onCallStarted = { [weak self] call in
            guard let self else { return }
            switch settings.meetingMode {
            case .ask:
                callPrompt = call
                updatePanel()
            case .automatic:
                recorder.start(call: call, processes: detector.processObjects(for: call.platform),
                               pids: detector.pids(for: call.platform))
            case .off: break
            }
        }
        detector.onCallEnded = { [weak self] call in
            guard let self else { return }
            dismissCallPrompt()
            if recorder.state == .recording, recorder.call?.platform == call.platform { recorder.stop() }
        }
        hotkeys.start()
        permissions.startMonitoring()
        speech.prepare(localeIdentifier: settings.localeIdentifier)
        if settings.meetingMode != .off { detector.start() }
    }

    /// Manual start: records the detected call if there is one, else a voice note (mic only,
    /// unless the user asked to include computer audio). The floating pill shows it; the main
    /// window only jumps to it if it's already open.
    func recordMeeting() {
        callPrompt = nil
        let call = detector.current
        recorder.start(
            call: call,
            processes: call.map { detector.processObjects(for: $0.platform) } ?? [],
            pids: call.map { detector.pids(for: $0.platform) } ?? [],
            includeComputerAudio: call == nil && settings.noteIncludesComputerAudio)
        updatePanel()
        if mainWindow.isVisible, let id = recorder.current?.id { mainWindow.show(meeting: id) }
    }

    func dismissCallPrompt() {
        callPrompt = nil
        updatePanel()
    }

    private func updatePanel() {
        let visible = recorder.state != .idle || callPrompt != nil
        recordingPanel?.setVisible(visible)
        updateOverlayLift()
    }

    private func updateOverlayLift() {
        let visible = recorder.state != .idle || callPrompt != nil
        overlay.lift = visible && settings.pillDock == .bottom ? RecordingPanel.height : 0
    }
}
