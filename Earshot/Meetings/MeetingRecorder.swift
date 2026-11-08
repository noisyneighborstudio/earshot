import CoreAudio
import Foundation
import os

/// Records a call as two on-device transcripts — the mic ("Me") and call audio ("Others") —
/// then writes notes with Claude. Everything is saved locally as it goes.
@MainActor
@Observable
final class MeetingRecorder {
    enum State: Equatable {
        case idle
        case recording
        case summarizing
    }

    private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    /// The meeting being recorded or summarized, with live lines while recording.
    private(set) var current: Meeting?
    private(set) var lastError: String?
    /// Who the call app shows as talking right now.
    private(set) var speakingNow: [String] = []
    /// Still-changing text per stream, shown after the final lines.
    private(set) var pending: [Meeting.Speaker: String] = [:]

    @ObservationIgnored var onStateChange: ((State) -> Void)?
    @ObservationIgnored var onNotesReady: ((Meeting) -> Void)?

    @ObservationIgnored private let speech: SpeechEngine
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "meetings")

    private struct Capture {
        let mic: AudioCapture
        /// nil for a voice note: mic only.
        let tap: SystemAudioTap?
        let me: TranscriptionSession
        let others: TranscriptionSession?
    }

    @ObservationIgnored private var capture: Capture?
    /// Keeps App Nap from throttling us (and the Mac from idling to sleep) while recording.
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var lastSave = ContinuousClock.now
    @ObservationIgnored private var speakers: SpeakerPoller?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var liveMe: [TranscriptSegment] = []
    @ObservationIgnored private var liveOthers: [TranscriptSegment] = []
    /// Live-title thresholds not reached yet, and the in-flight request.
    @ObservationIgnored private var pendingTitleThresholds: [Int] = []
    @ObservationIgnored private var titling: Task<Void, Never>?
    /// The detected call this recording belongs to, so it can stop when the call ends.
    @ObservationIgnored private(set) var call: DetectedCall?

    init(speech: SpeechEngine, store: MeetingStore, settings: AppSettings) {
        self.speech = speech
        self.store = store
        self.settings = settings
    }

    /// `processes` are the call app's Core Audio processes (empty taps all system audio);
    /// `pids` its app processes, read for who is talking. Without a call and without
    /// `includeComputerAudio`, it's a voice note: mic only, so music or videos aren't captured.
    func start(call: DetectedCall?, processes: [AudioObjectID], pids: [pid_t], includeComputerAudio: Bool = false) {
        let computerAudio = call != nil || includeComputerAudio
        guard state == .idle else { return }
        lastError = nil
        liveMe = []
        liveOthers = []
        pending = [:]
        speakingNow = []

        let dictionary = settings.dictionary
        guard let me = speech.makeSession(purpose: .meeting, contextualStrings: dictionary, onTranscript: { [weak self] in
                  self?.update($0, from: .me)
              }, onSegment: { [weak self] in
                  self?.receive($0, from: .me)
              })
        else {
            lastError = speech.statusDescription
            return
        }
        var others: TranscriptionSession?
        if computerAudio {
            others = speech.makeSession(purpose: .meeting, contextualStrings: dictionary, onTranscript: { [weak self] in
                self?.update($0, from: .others)
            }, onSegment: { [weak self] in
                self?.receive($0, from: .others)
            })
        }

        let mic = AudioCapture()
        let tap = others.map { _ in SystemAudioTap() }
        do {
            try mic.start(format: me.format) { buffer, _ in me.append(buffer) }
            if let tap, let others {
                try tap.start(processes: processes, format: others.format) { others.append($0) }
            }
        } catch {
            mic.stop()
            tap?.stop()
            me.cancel()
            others?.cancel()
            lastError = error.localizedDescription
            log.error("meeting start failed: \(error.localizedDescription)")
            return
        }

        let startedAt = Date.now
        let platform = call?.platform.name ?? ""
        var meeting = Meeting(
            title: computerAudio ? MeetingTitler.placeholder(platform: platform, startedAt: startedAt)
                                 : String(localized: "Voice note"),
            platform: platform, startedAt: startedAt)
        meeting.kind = computerAudio ? .meeting : .note
        pendingTitleThresholds = MeetingTitler.thresholds
        store.save(meeting)
        lastSave = .now
        current = meeting
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting")
        capture = Capture(mic: mic, tap: tap, me: me, others: others)
        speakers = call.map { SpeakerPoller(pids: pids, platform: $0.platform, startedAt: .now) }
        self.call = call
        state = .recording

        // Only refreshes who's talking; saving is driven by new transcript, not timers.
        autosave = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.state == .recording else { return }
                let speaking = self.speakers?.speakingNow ?? []
                if speaking != self.speakingNow { self.speakingNow = speaking }
            }
        }
    }

    func stop() {
        guard state == .recording, let capture, var meeting = current else { return }
        self.capture = nil
        autosave?.cancel()
        titling?.cancel()
        titling = nil
        capture.mic.stop()
        capture.tap?.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        speakers?.stop()
        let timeline = speakers?.timeline ?? []
        let participants = speakers?.participants ?? []
        speakers = nil
        speakingNow = []
        pending = [:]
        meeting.endedAt = .now
        meeting.participants = participants.isEmpty ? nil : participants
        current = meeting
        call = nil
        state = .summarizing
        let meSession = capture.me
        let othersSession = capture.others

        Task {
            var problems: [String] = []
            // The finished transcripts are authoritative; live lines were only for display and autosave.
            async let me = meSession.finish()
            async let others = othersSession?.finish()
            var mine = liveMe, theirs = liveOthers
            do { mine = try await me.segments } catch { problems.append(error.localizedDescription) }
            do { theirs = try await others?.segments ?? [] } catch { problems.append(error.localizedDescription) }
            meeting.lines = Meeting.lines(me: mine, others: theirs, speakers: timeline)
            store.save(meeting)
            current = meeting

            await summarize(&meeting, problems: problems)
            store.save(meeting)
            current = nil
            state = .idle
            onNotesReady?(meeting)
        }
    }

    /// Earshot is quitting or being killed mid-recording: keep what was transcribed.
    func persistForTermination() {
        guard state == .recording, var meeting = current else { return }
        meeting.endedAt = .now
        meeting.summaryError = String(localized: "Earshot quit while recording. The transcript up to that point was saved.")
        store.save(meeting)
    }

    /// Re-runs the summary for a saved meeting (e.g. after a CLI error).
    func resummarize(_ id: Meeting.ID) {
        guard state == .idle, var meeting = store.meetings.first(where: { $0.id == id }) else { return }
        state = .summarizing
        current = meeting
        Task {
            await summarize(&meeting, problems: [])
            store.save(meeting)
            current = nil
            state = .idle
        }
    }

    private func summarize(_ meeting: inout Meeting, problems: [String]) async {
        var problems = problems
        meeting.summaryError = nil
        if meeting.lines.isEmpty {
            problems.append(String(localized: "Nothing was transcribed."))
        } else if let cli = ClaudeCLI.locate() {
            do {
                let notes = try await MeetingSummarizer(cli: cli).summarize(meeting)
                meeting.summary = notes
                if let title = MeetingTitler.fromNotes(notes) { meeting.title = title }
            } catch {
                problems.append(error.localizedDescription)
            }
        } else {
            problems.append(ClaudeCLIError.notFound.localizedDescription)
        }
        if !problems.isEmpty {
            let message = problems.joined(separator: "\n")
            meeting.summaryError = message
            log.error("meeting notes incomplete: \(message, privacy: .public)")
        }
    }

    /// Generates a live title once the transcript passes the next word threshold.
    private func titleIfDue(_ meeting: Meeting) {
        guard titling == nil, let next = pendingTitleThresholds.first, meeting.wordCount >= next,
              let cli = ClaudeCLI.locate() else { return }
        pendingTitleThresholds.removeFirst()
        titling = Task { [weak self] in
            defer { self?.titling = nil }
            do {
                guard let title = try await MeetingTitler(cli: cli).title(for: meeting),
                      let self, self.state == .recording, self.current?.id == meeting.id else { return }
                self.current?.title = title
                if let current = self.current { self.store.save(current) }
            } catch {
                guard !Task.isCancelled else { return }
                self?.log.error("live title failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Called on the speech threads.
    nonisolated private func update(_ update: TranscriptUpdate, from speaker: Meeting.Speaker) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.state == .recording, self.pending[speaker] != update.volatile else { return }
                self.pending[speaker] = update.volatile.isEmpty ? nil : update.volatile
            }
        }
    }

    /// Called on the speech threads.
    nonisolated private func receive(_ segment: TranscriptSegment, from speaker: Meeting.Speaker) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.state == .recording, var meeting = self.current else { return }
                switch speaker {
                case .me: self.liveMe.append(segment)
                case .others: self.liveOthers.append(segment)
                }
                meeting.lines = Meeting.lines(
                    me: self.liveMe, others: self.liveOthers, speakers: self.speakers?.timeline ?? [])
                self.current = meeting
                if self.lastSave.duration(to: .now) >= .seconds(5) {
                    self.store.save(meeting)
                    self.lastSave = .now
                }
                self.titleIfDue(meeting)
            }
        }
    }
}
